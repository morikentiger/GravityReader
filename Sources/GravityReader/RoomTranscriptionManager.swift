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
    private let silenceGracePeriod: TimeInterval = 0.3

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
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
    private let maxAudioSamplesForProfile: Int = 44100 * 3  // 3秒分
    private var audioSamplesLock = NSLock()

    /// テキストチャットがあった時刻と話者名（声紋学習のトリガー）
    private var recentChatMessages: [(timestamp: Date, speaker: String)] = []
    private let chatCorrelationWindow: TimeInterval = 4.0  // チャット前後4秒以内の音声を紐付け

    // MARK: - 話者追跡

    /// 現在のセグメントの推定話者
    private var currentSegmentSpeaker: String = "不明"

    /// 前回の部分結果テキスト全体（デルタ計算用）
    private var previousFullText: String = ""

    /// 話者ごとの累積テキスト
    private var speakerTexts: [String: String] = [:]

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
            onLog?("🎙 ルーム音声文字起こし開始（声紋学習モード — チャットすると声を覚えます）")
        } else {
            onLog?("🎙 ルーム音声文字起こし開始（登録済み声紋: \(speakers.joined(separator: ", "))）")
        }
        startSession()
    }

    func stop() {
        isListening = false
        stopSession()
        confirmAllSpeakers()
        isSomeoneSpeaking = false
        onLog?("🎙 ルーム音声文字起こし停止")
    }

    /// テキストチャットがあったことを通知（声紋学習のトリガー）
    /// GravityCaptureManagerから呼ばれる
    func notifyChatMessage(speaker: String) {
        let now = Date()
        recentChatMessages.append((timestamp: now, speaker: speaker))

        // 古いエントリを掃除
        recentChatMessages.removeAll { now.timeIntervalSince($0.timestamp) > chatCorrelationWindow * 2 }

        // 現在音声が来てたら、直近の音声サンプルで声紋学習
        tryEnrollFromRecentAudio(speaker: speaker)
    }

    /// 直近の音声バッファから声紋学習を試みる
    private func tryEnrollFromRecentAudio(speaker: String) {
        audioSamplesLock.lock()
        let samples = recentAudioSamples
        audioSamplesLock.unlock()

        guard samples.count >= 22050 else { return }  // 最低0.5秒

        if let features = diarizer.extractFeatures(from: samples) {
            diarizer.enroll(speaker: speaker, features: features)
        }
    }

    // MARK: - 話者確定

    private func confirmCurrentSegment() {
        let speaker = currentSegmentSpeaker
        guard let text = speakerTexts[speaker], !text.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            speakerTexts.removeValue(forKey: speaker)
            onClearPartial?(speaker)
            return
        }
        if lastConfirmedTexts[speaker] == trimmed {
            speakerTexts.removeValue(forKey: speaker)
            onClearPartial?(speaker)
            return
        }
        lastConfirmedTexts[speaker] = trimmed
        // パーシャル行を白に変換して確定（黄→白演出）
        onTranscription?(speaker, trimmed)
        speakerTexts.removeValue(forKey: speaker)
    }

    private func confirmAllSpeakers() {
        for speaker in Array(speakerTexts.keys) {
            let text = speakerTexts[speaker] ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2 && lastConfirmedTexts[speaker] != trimmed {
                lastConfirmedTexts[speaker] = trimmed
                // パーシャル行を白に変換して確定（黄→白演出）
                onTranscription?(speaker, trimmed)
            } else {
                onClearPartial?(speaker)
            }
        }
        speakerTexts.removeAll()
    }

    /// 無音になったら確定
    private func scheduleSilenceConfirm() {
        silenceConfirmTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.confirmAllSpeakers()
            self.previousFullText = ""
            // セッションリフレッシュ（新しい発話用にきれいな状態に）
            self.restartSession()
        }
        silenceConfirmTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: - 声紋マッチング

    /// 直近の音声サンプルから話者を推定
    private func identifySpeaker() -> String {
        audioSamplesLock.lock()
        let samples = recentAudioSamples
        audioSamplesLock.unlock()

        guard samples.count >= 11025 else { return "不明" }  // 最低0.25秒

        if let features = diarizer.extractFeatures(from: samples),
           let result = diarizer.identify(features: features) {
            return result.speaker
        }
        return "不明"
    }

    // MARK: - Session Management

    private func startSession() {
        guard isListening else { return }
        guard !isRecognizing else { return }
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
                    // 最大3秒分に制限
                    if self.recentAudioSamples.count > self.maxAudioSamplesForProfile {
                        self.recentAudioSamples.removeFirst(self.recentAudioSamples.count - self.maxAudioSamplesForProfile)
                    }
                    self.audioSamplesLock.unlock()
                }
            }
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let fullText = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if result.isFinal {
                    // isFinal → パーシャル更新してから確定（黄→白の演出）
                    self.silenceConfirmTimer?.cancel()
                    self.silenceConfirmTimer = nil
                    self.attributeDelta(fullText: fullText)
                    self.confirmAllSpeakers()
                    self.previousFullText = ""
                } else if !fullText.isEmpty {
                    self.attributeDelta(fullText: fullText)
                }
            }

            if let error = error {
                let code = (error as NSError).code
                if code != 1101 && code != 216 {
                    NSLog("[RoomTx] 認識エラー: \(error.localizedDescription) (code: \(code))")
                }
                DispatchQueue.main.async {
                    self.isRecognizing = false
                    if self.isListening {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                            self?.startSession()
                        }
                    }
                }
            }
        }

        self.recognitionRequest = request
        isRecognizing = true
        previousFullText = ""

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

    /// 部分結果のデルタを計算し、推定話者に振り分け＋パーシャル表示
    private func attributeDelta(fullText: String) {
        // デルタ計算
        let commonLen = commonPrefixLength(previousFullText, fullText)
        let delta = String(fullText.suffix(fullText.count - commonLen))
        previousFullText = fullText

        guard !delta.isEmpty else { return }

        // 声紋から話者推定（新しいデルタが来るたびに試行）
        let identified = identifySpeaker()
        if identified != "不明" && identified != currentSegmentSpeaker {
            // 話者が変わった → 前の話者を確定
            if !currentSegmentSpeaker.isEmpty && currentSegmentSpeaker != "不明" {
                confirmCurrentSegment()
            }
            currentSegmentSpeaker = identified
        } else if currentSegmentSpeaker == "不明" && identified != "不明" {
            currentSegmentSpeaker = identified
        }

        // デルタを現在の話者に追加
        speakerTexts[currentSegmentSpeaker, default: ""] += delta

        // パーシャル表示（黄色）
        let speakerText = speakerTexts[currentSegmentSpeaker] ?? delta
        DispatchQueue.main.async {
            self.onPartialResult?(self.currentSegmentSpeaker, speakerText)
        }
    }

    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        var i = 0
        while i < aChars.count && i < bChars.count && aChars[i] == bChars[i] {
            i += 1
        }
        return i
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.recognitionTask?.cancel()
            self?.recognitionTask = nil
        }
        isRecognizing = false
    }

    private func restartSession() {
        stopSession()
        // 音声バッファをクリア（新しいセッション用）
        audioSamplesLock.lock()
        recentAudioSamples.removeAll()
        audioSamplesLock.unlock()

        if isListening {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.startSession()
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

        isEnrolling = true
        enrollingUser = user

        // マイクが動いてなければ一時起動
        if !isListening {
            startedMicForEnrollment = true
            startEnrollmentMic()
        }

        // ランダムなテキストを選択
        let textIndex = abs(user.hashValue) % enrollmentTexts.count
        let text = enrollmentTexts[textIndex]

        onLog?("🎤 \(user)さんの声紋登録開始…")
        onLog?("📝 読み上げ文: 「\(text)」")

        // YUiが指示 → TTS完了を待ってから録音開始
        onSpeakRequest?("\(user)さん、声を覚えたいから、次の文章を読み上げてくれる？「\(text)」") { [weak self] in
            guard let self = self, self.isEnrolling else { return }
            self.startRecording(for: user)
        }
    }

    /// 声紋登録専用のマイク起動（音声認識なし、音声サンプル蓄積のみ）
    private func startEnrollmentMic() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, !self.isTTSPlaying else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

            self.audioSamplesLock.lock()
            self.recentAudioSamples.append(contentsOf: samples)
            if self.recentAudioSamples.count > self.maxAudioSamplesForProfile {
                self.recentAudioSamples.removeFirst(self.recentAudioSamples.count - self.maxAudioSamplesForProfile)
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
    private func startRecording(for user: String) {
        onLog?("🎤 \(user)さん、どうぞ！（8秒間録音します）")

        // 音声バッファをクリア（YUiの声を完全に除外）
        audioSamplesLock.lock()
        recentAudioSamples.removeAll()
        audioSamplesLock.unlock()

        // 8秒後に録音終了＆声紋登録
        enrollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            self?.completeEnrollment(for: user)
        }
    }

    /// ユーザーの声紋登録を完了
    private func completeEnrollment(for user: String) {
        audioSamplesLock.lock()
        let samples = recentAudioSamples
        recentAudioSamples.removeAll()
        audioSamplesLock.unlock()

        let seconds = samples.count / 44100

        if samples.count >= 22050,
           let features = diarizer.extractFeatures(from: samples) {
            diarizer.enroll(speaker: user, features: features)
            onLog?("✅ \(user)さんの声紋登録完了！（\(seconds)秒分の音声）")
            onSpeakRequest?("\(user)さん、ありがとう！声を覚えたよ！", nil)
        } else {
            onLog?("❌ \(user)さんの声紋登録失敗（音声が足りません: \(seconds)秒）")
            onSpeakRequest?("\(user)さん、ごめん、声がうまく拾えなかった。もう一回試してみてくれる？", nil)
        }

        enrollingUser = nil
        isEnrolling = false
        enrollTimer?.invalidate()
        enrollTimer = nil

        // 登録のためだけにマイク起動していた場合は停止
        if startedMicForEnrollment {
            startedMicForEnrollment = false
            stopEnrollmentMic()
        }
    }

    /// シーケンスを中止
    func cancelEnrollmentSequence() {
        guard isEnrolling else { return }
        isEnrolling = false
        enrollingUser = nil
        enrollTimer?.invalidate()
        enrollTimer = nil

        if startedMicForEnrollment {
            startedMicForEnrollment = false
            stopEnrollmentMic()
        }
        onLog?("🎤 声紋登録を中止しました")
    }
}
