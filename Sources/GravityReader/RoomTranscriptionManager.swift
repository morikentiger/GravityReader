import Foundation
import AVFoundation
import Speech

/// GRAVITYルームの音声をマイクで常時リスニングし、リアルタイム文字起こしするクラス。
/// スピーカー出力をマイクが拾う前提。
/// 声紋識別（VoiceDiarizer）で話者を自動判別。
/// テキストチャットと音声のタイミング相関で声紋を自動学習。
class RoomTranscriptionManager {

    /// 文字起こし確定コールバック（話者名, 確定テキスト）
    var onTranscription: ((String, String) -> Void)?

    /// リアルタイム途中結果コールバック（話者名, その話者の累積テキスト）
    var onPartialResult: ((String, String) -> Void)?

    /// 話者の途中行をクリアするコールバック
    var onClearPartial: ((String) -> Void)?

    /// ログ
    var onLog: ((String) -> Void)?

    /// 誰かが喋っている判定（RMSベース）
    private(set) var isSomeoneSpeaking: Bool = false
    var speakingThreshold: Float = 0.01
    private var lastSpeakingTime: Date?
    private let silenceGracePeriod: TimeInterval = 0.8

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var isListening = false

    /// TTS再生中フラグ — trueの間はマイク入力を認識に送らない
    var isTTSPlaying: Bool = false
    private var isRecognizing = false

    /// セッション自動再起動タイマー（55秒）
    private var sessionTimer: Timer?
    private let maxSessionDuration: TimeInterval = 55

    // MARK: - 声紋識別

    let diarizer = VoiceDiarizer()

    /// 音声バッファを一時蓄積（声紋抽出用）
    private var recentAudioSamples: [Float] = []
    private var audioSamplesLock = NSLock()
    private var capturedSampleRate: Double = 44100
    private var captureDuration: Double = 3

    /// 識別スロットル（重い処理を毎回やらない）
    private var lastIdentifyTime: Date?
    private let identifyInterval: TimeInterval = 0.5

    // MARK: - 話者追跡

    /// 現在のセグメントの推定話者
    private var currentSegmentSpeaker: String = "不明"

    private var hypothesis = SpeechHypothesisBuffer()
    private var partialSpeakers: Set<String> = []
    private var pendingSpeaker: String?
    private var pendingSpeakerCount = 0
    private var recognitionGeneration = UUID()

    /// 最後に確定したテキスト（重複排除）
    private var lastConfirmedTexts: [String: String] = [:]

    /// 無音検出で確定するタイマー
    private var silenceConfirmTimer: DispatchWorkItem?

    /// 音声アクティビティの開始時刻
    private var speechStartTime: Date?

    // MARK: - Public

    func start() {
        guard !isListening else { return }

        // 声紋プロファイル読み込み
        diarizer.loadProfiles()
        diarizer.onLog = { [weak self] msg in self?.onLog?(msg) }

        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] s in
                DispatchQueue.main.async {
                    if s == .authorized {
                        self?.beginListening()
                    } else {
                        self?.onLog?("⚠️ 音声認識の許可が必要です")
                    }
                }
            }
            return
        }
        if status != .authorized {
            onLog?("⚠️ 音声認識の許可が必要です（設定 > プライバシー > 音声認識）")
            return
        }
        beginListening()
    }

    private func beginListening() {
        isListening = true
        let speakers = diarizer.registeredSpeakers
        if speakers.isEmpty {
            onLog?("🎙 ルーム音声文字起こし開始（声紋未登録 — 音声と声紋メニューから登録できます）")
        } else {
            onLog?("🎙 ルーム音声文字起こし開始（登録済み声紋: \(speakers.joined(separator: ", "))）")
        }
        startSession()
    }

    func stop() {
        isListening = false
        if isEnrolling { cleanupEnrollment() }
        stopSession()
        confirmAllSpeakers()
        isSomeoneSpeaking = false
        onLog?("🎙 ルーム音声文字起こし停止")
    }


    // MARK: - 話者確定

    private func confirmAllSpeakers() {
        // Dictionaryの順序ではなく、実際の発言順で確定する。
        for segment in hypothesis.segments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2 && lastConfirmedTexts[segment.speaker] != trimmed {
                lastConfirmedTexts[segment.speaker] = trimmed
                onTranscription?(segment.speaker, trimmed)
            } else {
                onClearPartial?(segment.speaker)
            }
        }
        for speaker in partialSpeakers { onClearPartial?(speaker) }
        partialSpeakers.removeAll()
        hypothesis.reset()
    }

    /// 無音になったら確定
    private func scheduleSilenceConfirm() {
        silenceConfirmTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isEnrolling else { return }
            self.confirmAllSpeakers()
            // セッションリフレッシュ（新しい発話用にきれいな状態に）
            self.restartSession()
        }
        silenceConfirmTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - 声紋マッチング

    /// 直近の音声サンプルから話者を推定（スロットル付き）
    private var lastIdentifiedSpeaker: String = "不明"
    private var unknownStreakCount: Int = 0

    private func identifySpeaker() -> String {
        guard !isEnrolling else { return "不明" }
        // スロットル: 0.5秒に1回だけ実行
        if let last = lastIdentifyTime, Date().timeIntervalSince(last) < identifyInterval {
            return lastIdentifiedSpeaker
        }
        lastIdentifyTime = Date()

        audioSamplesLock.lock()
        // 識別には直近2秒分を実際のサンプルレートで取り出す
        let rate = capturedSampleRate
        let windowSize = min(recentAudioSamples.count, Int(rate * 2))
        let nativeSamples = Array(recentAudioSamples.suffix(windowSize))
        audioSamplesLock.unlock()
        let samples = diarizer.embeddingModel.resample(nativeSamples, from: Float(rate), to: 44100)

        guard samples.count >= 22050 else { return "不明" }  // 最低0.5秒

        // ピッチ複合判定用に生音声サンプルをセット
        diarizer.setRawSamplesForNextIdentify(samples)

        if let features = diarizer.extractFeatures(from: samples),
           let result = diarizer.identifyWithConfidence(features: features) {
            lastIdentifiedSpeaker = result.speaker
            // 適応学習: 厳格マージン確定時のみ実行（推定判定でプロファイルを汚染しない）
            if result.level == .strict {
                diarizer.adaptiveUpdate(speaker: result.speaker, features: features)
            }
            return result.speaker
        }
        lastIdentifiedSpeaker = "不明"
        return "不明"
    }

    // MARK: - Session Management

    private func startSession() {
        guard isListening, !isEnrolling else { return }
        guard !isRecognizing else { return }
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: AppDefaults.suite.string(forKey: "GR_RecognitionLanguage") ?? "ja-JP"))
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onLog?("⚠️ 音声認識エンジンが利用不可（10秒後リトライ）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.startSession()
            }
            return
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = false

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        audioSamplesLock.lock()
        capturedSampleRate = format.sampleRate
        recentAudioSamples.removeAll()
        audioSamplesLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }

            let isTTS = self.isTTSPlaying

            // TTS再生中でなければ認識に送る
            if !isTTS {
                request.append(buffer)
            }

            // 音声サンプルを蓄積（声紋抽出用）— TTS中は蓄積しない
            if !isTTS, let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

                // RMS計算
                var sumOfSquares: Float = 0
                for s in samples { sumOfSquares += s * s }
                let rms = sqrtf(sumOfSquares / Float(frameLength))

                DispatchQueue.main.async {
                    if rms >= self.speakingThreshold {
                        let wasSpeaking = self.isSomeoneSpeaking
                        self.isSomeoneSpeaking = true
                        self.lastSpeakingTime = Date()
                        if !wasSpeaking {
                            self.speechStartTime = Date()
                        }
                        self.silenceConfirmTimer?.cancel()
                    } else {
                        if let last = self.lastSpeakingTime,
                           Date().timeIntervalSince(last) > self.silenceGracePeriod {
                            if self.isSomeoneSpeaking {
                                self.isSomeoneSpeaking = false
                                // 無音になった → 確定スケジュール
                                self.scheduleSilenceConfirm()
                            }
                        }
                    }
                }

                // 音声サンプル蓄積（RMSが閾値以上の時だけ）
                if rms >= self.speakingThreshold {
                    self.audioSamplesLock.lock()
                    self.recentAudioSamples.append(contentsOf: samples)
                    let limit = Int(format.sampleRate * self.captureDuration)
                    if self.recentAudioSamples.count > limit {
                        self.recentAudioSamples.removeFirst(self.recentAudioSamples.count - limit)
                    }
                    self.audioSamplesLock.unlock()
                }
            }
        }

        let generation = UUID()
        recognitionGeneration = generation
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.recognitionGeneration == generation, !self.isEnrolling else { return }
                if let result = result {
                    let fullText = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !self.isEnrolling { self.attributeDelta(fullText: fullText, silent: result.isFinal) }
                    if result.isFinal {
                        self.confirmAllSpeakers()
                        self.restartSession()
                        return
                    }
                }
                if let error = error {
                    let code = (error as NSError).code
                    if code != 1101 && code != 216 {
                        NSLog("[RoomTx] 認識エラー: %@ (code: %d)", error.localizedDescription, code)
                    }
                    self.confirmAllSpeakers()
                    self.restartSession()
                }
            }
        }

        self.recognitionRequest = request
        isRecognizing = true
        hypothesis.reset()
        currentSegmentSpeaker = "不明"
        pendingSpeaker = nil
        pendingSpeakerCount = 0

        do {
            try audioEngine.start()
            NSLog("[RoomTx] 🎙 セッション開始")
        } catch {
            onLog?("⚠️ マイク起動エラー: \(error.localizedDescription)")
            isRecognizing = false
            audioEngine.inputNode.removeTap(onBus: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.startSession()
            }
            return
        }

        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: maxSessionDuration, repeats: false) { [weak self] _ in
            NSLog("[RoomTx] ⏱ セッション時間切れ → 再起動")
            self?.confirmAllSpeakers()
            self?.restartSession()
        }
    }

    /// 訂正を反映した最新仮説から、話者別の途中表示を再構築する。
    private func attributeDelta(fullText: String, silent: Bool = false) {
        let identified = identifySpeaker()
        if identified == "不明" && diarizer.isUsingSiamese {
            // A rejected voice must not inherit the last person's name in the UI.
            currentSegmentSpeaker = "不明"
            pendingSpeaker = nil
            pendingSpeakerCount = 0
        }
        if identified != "不明" {
            if currentSegmentSpeaker == "不明" {
                currentSegmentSpeaker = identified
            } else if identified != currentSegmentSpeaker {
                if pendingSpeaker == identified { pendingSpeakerCount += 1 }
                else { pendingSpeaker = identified; pendingSpeakerCount = 1 }
                // 声紋の一瞬の揺れで「おじ」等を独立した発言として確定しない。
                if pendingSpeakerCount >= 2 && fullText.hasPrefix(hypothesis.text) {
                    currentSegmentSpeaker = identified
                    pendingSpeaker = nil
                    pendingSpeakerCount = 0
                }
            } else {
                pendingSpeaker = nil
                pendingSpeakerCount = 0
            }
        }
        hypothesis.update(fullText, speaker: currentSegmentSpeaker)
        guard !silent else { return }
        var bySpeaker: [String: String] = [:]
        for segment in hypothesis.segments { bySpeaker[segment.speaker, default: ""] += segment.text }
        let speakers = Set(bySpeaker.keys)
        for speaker in partialSpeakers.subtracting(speakers) { onClearPartial?(speaker) }
        partialSpeakers = speakers
        for (speaker, text) in bySpeaker { onPartialResult?(speaker, text) }
    }

    private func stopSession() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        silenceConfirmTimer?.cancel()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionGeneration = UUID()
        let task = recognitionTask
        recognitionTask = nil
        task?.cancel()
        isRecognizing = false
    }

    private func restartSession() {
        guard !isEnrolling else { return }
        stopSession()
        // 音声バッファをクリア（新しいセッション用）
        audioSamplesLock.lock()
        recentAudioSamples.removeAll()
        audioSamplesLock.unlock()

        if isListening {
            let generation = recognitionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.isListening, self.recognitionGeneration == generation else { return }
                self.startSession()
            }
        }
    }

    // MARK: - 声紋登録シーケンス

    /// 登録シーケンス中かどうか
    private(set) var isEnrolling: Bool = false

    /// 登録シーケンスのキュー（未処理のユーザー名リスト）
    private var enrollQueue: [String] = []

    /// 現在登録中のユーザー
    private var enrollingUser: String?

    /// 登録中の音声収集タイマー
    private var enrollTimer: Timer?
    private var enrollmentSession = VoiceEnrollmentSessionState()

    /// 登録のためだけにマイクを起動したかどうか（完了後に停止する）
    private var startedMicForEnrollment = false

    /// YUiに喋らせるコールバック（テキスト, 完了コールバック）
    /// 完了コールバックはTTS再生が終わったら呼ばれる
    var onSpeakRequest: ((String, (() -> Void)?) -> Void)?

    /// 登録用の読み上げテキスト（十分な長さの日本語文）
    private let enrollmentTexts = [
        "今日はとてもいい天気ですね。こうしてみんなで集まって話すのは楽しいです。",
        "最近気になっていることはありますか？私は新しいお店を見つけました。",
        "春の桜は本当にきれいですよね。お花見に行きたいなと思っています。",
        "好きな食べ物は何ですか？私はラーメンとお寿司が好きです。",
        "休みの日は何をして過ごしていますか？ゆっくり音楽を聴くのが好きです。",
        "おすすめの映画とかありますか？最近面白いのを探しているんです。",
    ]

    /// 声紋登録シーケンスを開始（1人指定）
    /// 読み上げ停止中でもマイクを一時起動して登録可能
    func startEnrollmentSequence(participants: [String]) {
        guard !isEnrolling else {
            onLog?("⚠️ 声紋登録中です。完了をお待ちください。")
            return
        }
        guard let user = participants.first else {
            onLog?("⚠️ 登録対象のユーザーがいません")
            return
        }

        confirmAllSpeakers()
        silenceConfirmTimer?.cancel()
        isEnrolling = true
        enrollingUser = user
        let session = enrollmentSession.begin()

        // マイクが動いてなければ一時起動
        if !isListening {
            startedMicForEnrollment = true
            startEnrollmentMic()
        }

        // 独立した登録ごとに異なる文章を案内
        let textIndex = (diarizer.siameseVerifier.enrollmentCounts[user] ?? 0) % enrollmentTexts.count
        let text = enrollmentTexts[textIndex]

        onLog?("🎤 \(user)さんの声紋登録開始…")
        onLog?("📝 読み上げ文: 「\(text)」")

        // YUiが指示 → TTS完了を待ってから録音開始
        onSpeakRequest?("\(user)さん、声を覚えたいから、次の文章を読み上げてくれる？「\(text)」") { [weak self] in
            guard let self = self, self.isEnrolling else { return }
            self.startRecording(for: user, session: session)
        }
    }

    /// 声紋登録専用のマイク起動（音声認識なし、音声のある部分だけ蓄積）
    private func startEnrollmentMic() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        audioSamplesLock.lock()
        capturedSampleRate = format.sampleRate
        recentAudioSamples.removeAll()
        audioSamplesLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, !self.isTTSPlaying else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

            // RMS計算 — 声がある部分だけ蓄積
            var sumOfSquares: Float = 0
            for s in samples { sumOfSquares += s * s }
            let rms = sqrtf(sumOfSquares / Float(frameLength))

            guard rms >= self.speakingThreshold else { return }

            self.audioSamplesLock.lock()
            self.recentAudioSamples.append(contentsOf: samples)
            // 登録用は12秒分まで蓄積
            let limit = Int(format.sampleRate * 12)
            if self.recentAudioSamples.count > limit {
                self.recentAudioSamples.removeFirst(self.recentAudioSamples.count - limit)
            }
            self.audioSamplesLock.unlock()
        }

        do {
            try audioEngine.start()
            onLog?("🎙 声紋登録用マイク起動")
        } catch {
            onLog?("⚠️ マイク起動エラー: \(error.localizedDescription)")
        }
    }

    /// 声紋登録専用マイクを停止
    private func stopEnrollmentMic() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        onLog?("🎙 声紋登録用マイク停止")
    }

    /// TTS完了後に録音開始
    private func startRecording(for user: String, session: UUID) {
        // A cancelled registration's delayed TTS callback must not start a new
        // timer or clear the buffer of a later registration, even for the same name.
        guard isEnrolling, enrollingUser == user, enrollmentSession.startRecording(session) else { return }
        onLog?("🎤 \(user)さん、どうぞ！（12秒間録音します）")

        // 音声バッファをクリア（YUiの声を完全に除外）
        audioSamplesLock.lock()
        recentAudioSamples.removeAll()
        captureDuration = 12
        audioSamplesLock.unlock()

        // 12秒後に録音終了＆声紋登録
        enrollTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.completeEnrollment(for: user, session: session)
        }
    }

    /// ユーザーの声紋登録を完了（品質検査付き: P0-2）
    private func completeEnrollment(for user: String, session: UUID) {
        guard isEnrolling, enrollingUser == user, enrollmentSession.completeRecording(session) else { return }
        audioSamplesLock.lock()
        let nativeSamples = recentAudioSamples
        let rate = capturedSampleRate
        recentAudioSamples.removeAll()
        audioSamplesLock.unlock()
        let samples = diarizer.embeddingModel.resample(nativeSamples, from: Float(rate), to: 44100)

        let seconds = samples.count / 44100

        guard samples.count >= 22050 else {
            onLog?("❌ \(user)さんの声紋登録失敗（音声が足りません: \(seconds)秒）")
            onSpeakRequest?("\(user)さん、ごめん、声がうまく拾えなかった。もう一回試してみてくれる？", nil)
            cleanupEnrollment()
            return
        }

        // 品質検査付き enrollment
        let result = diarizer.enrollWithQualityCheck(speaker: user, samples: samples)
        if result.success {
            onLog?("✅ \(user)さんの声紋登録完了！（\(seconds)秒分の音声）")
            onSpeakRequest?("\(user)さん、ありがとう！登録用の声を受け取ったよ！", nil)
        } else {
            onLog?("❌ \(user)さんの声紋登録失敗: \(result.message)")
            onSpeakRequest?("\(user)さん、ごめん、\(result.message)。もう一回試してみてくれる？", nil)
        }

        cleanupEnrollment()
    }

    private func cleanupEnrollment() {
        enrollmentSession.cancel()
        audioSamplesLock.lock()
        captureDuration = 3
        recentAudioSamples.removeAll()
        audioSamplesLock.unlock()
        enrollingUser = nil
        isEnrolling = false
        enrollTimer?.invalidate()
        enrollTimer = nil

        if startedMicForEnrollment {
            startedMicForEnrollment = false
            stopEnrollmentMic()
        }
        if isListening { restartSession() }
    }

    /// シーケンスを中止
    func cancelEnrollmentSequence() {
        guard isEnrolling else { return }
        cleanupEnrollment()
        onLog?("🎤 声紋登録を中止しました")
    }
}

/// Main-queue lifecycle for delayed enrollment callbacks. Each registration has
/// its own token, and each recording may start and complete only once.
struct VoiceEnrollmentSessionState {
    private var current: UUID?
    private var recording = false

    mutating func begin() -> UUID {
        let token = UUID()
        current = token
        recording = false
        return token
    }

    mutating func startRecording(_ token: UUID) -> Bool {
        guard current == token, !recording else { return false }
        recording = true
        return true
    }

    mutating func completeRecording(_ token: UUID) -> Bool {
        guard current == token, recording else { return false }
        cancel()
        return true
    }

    mutating func cancel() {
        current = nil
        recording = false
    }
}
