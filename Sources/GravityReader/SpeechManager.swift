import AVFoundation
import AppKit

enum VoiceMode: Equatable {
    case system          // macOS標準 AVSpeechSynthesizer
    case voicevox(Int)   // VOICEVOX speaker ID
}

struct VoicevoxSpeaker {
    let id: Int
    let name: String    // e.g. "ずんだもん"
    let style: String   // e.g. "ノーマル"
}

class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var queue: [(text: String, voice: VoiceMode)] = []
    private(set) var isSpeaking = false {
        didSet {
            if oldValue != isSpeaking {
                onSpeakingChanged?(isSpeaking)
            }
        }
    }

    /// TTS再生状態変化コールバック
    var onSpeakingChanged: ((Bool) -> Void)?

    /// デフォルト音声（メニューで選択されたもの）
    var voiceMode: VoiceMode = .system {
        didSet { AppDefaults.suite.set(voiceModeToString(voiceMode), forKey: "GR_VoiceMode") }
    }

    /// ユーザー別ボイス割り当て（ユーザー名 → VoiceMode）
    private var userVoiceMap: [String: VoiceMode] = [:]

    /// キャッシュされたスピーカー一覧
    private(set) var cachedSpeakers: [VoicevoxSpeaker] = []

    /// 読み辞書（表記 → 読み）
    private(set) var readingDictionary: [String: String] = [:]
    private let readingDictKey = "GR_ReadingDictionary"

    var onSpeakingStateChanged: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    /// VOICEVOX API のベースURL（デフォルト: localhost:50021）
    var voicevoxBaseURL = "http://127.0.0.1:50021"

    override init() {
        super.init()
        synthesizer.delegate = self
        // 保存済み設定を復元
        if let saved = AppDefaults.suite.string(forKey: "GR_VoiceMode") {
            voiceMode = stringToVoiceMode(saved)
        }
        // ユーザー別ボイス設定を復元
        if let savedMap = AppDefaults.suite.dictionary(forKey: "GR_UserVoiceMap") as? [String: String] {
            for (user, modeStr) in savedMap {
                userVoiceMap[user] = stringToVoiceMode(modeStr)
            }
        }
        // 読み辞書を復元
        if let savedDict = AppDefaults.suite.dictionary(forKey: readingDictKey) as? [String: String] {
            readingDictionary = savedDict
        }
        // デフォルト辞書（未登録のエントリのみ自動追加）
        let defaults: [String: String] = [
            "辛い": "つらい",
            "どんな風": "どんなふう",
            "こんな風": "こんなふう",
            "そんな風": "そんなふう",
            "あんな風": "あんなふう",
            "同じ風": "おなじふう",
            "C3PO": "シースリーピーオー",
            "C-3PO": "シースリーピーオー",
            "R2D2": "アールツーディーツー",
            "R2-D2": "アールツーディーツー",
            "w": "わら",
            "www": "わらわら",
        ]
        var added = false
        for (word, reading) in defaults where readingDictionary[word] == nil {
            readingDictionary[word] = reading
            added = true
        }
        if added { saveReadingDictionary() }
    }

    // MARK: - Public

    /// テキストをデフォルト音声で読み上げ
    func speak(_ text: String) {
        queue.append((text: text, voice: voiceMode))
        speakNext()
    }

    /// テキストを指定した音声で読み上げ
    func speak(_ text: String, withVoice voice: VoiceMode) {
        queue.append((text: text, voice: voice))
        speakNext()
    }

    /// テキストをユーザー固有音声で読み上げ（未設定なら自動割り当て）
    func speak(_ text: String, forUser user: String) {
        let voice = resolveVoice(for: user)
        queue.append((text: text, voice: voice))
        speakNext()
    }

    /// ユーザーの声を解決（未割り当てなら自動でVOICEVOXから割り当て）
    private func resolveVoice(for user: String) -> VoiceMode {
        // 完全一致
        if let mode = userVoiceMap[user] { return mode }
        // 部分一致
        for (key, mode) in userVoiceMap {
            if user.contains(key) || key.contains(user) { return mode }
        }
        // 未割り当て → 自動割り当て
        if let auto = autoAssignVoice(for: user) {
            return auto
        }
        return voiceMode
    }

    /// VOICEVOXの声を自動割り当て（他ユーザーと被らないように）
    private func autoAssignVoice(for user: String) -> VoiceMode? {
        guard !cachedSpeakers.isEmpty else { return nil }

        // 使用済みのspeaker IDを集める
        let usedIds = Set(userVoiceMap.values.compactMap { mode -> Int? in
            if case .voicevox(let id) = mode { return id }
            return nil
        })

        // 自動割り当て用の優先スピーカー（バリエーション豊かに）
        let preferredNames = [
            "ずんだもん", "四国めたん", "春日部つむぎ", "雨晴はう",
            "波音リツ", "玄野武宏", "白上虎太郎", "青山龍星",
            "冥鳴ひまり", "九州そら", "もち子さん", "剣崎雌雄",
            "WhiteCUL", "後鬼", "No.7", "ちび式じい",
            "櫻歌ミコ", "小夜/SAYO", "ナースロボ＿タイプＴ",
        ]

        // 優先リストから未使用を探す
        for name in preferredNames {
            if let speaker = cachedSpeakers.first(where: {
                $0.name == name && !usedIds.contains($0.id)
            }) {
                let mode = VoiceMode.voicevox(speaker.id)
                setVoiceForUser(user, mode: mode)
                onLog?("🎤 \(user)に自動割り当て: \(speaker.name)（\(speaker.style)）")
                return mode
            }
        }

        // 優先リストが尽きたら、未使用のスピーカーから割り当て
        if let speaker = cachedSpeakers.first(where: { !usedIds.contains($0.id) }) {
            let mode = VoiceMode.voicevox(speaker.id)
            setVoiceForUser(user, mode: mode)
            onLog?("🎤 \(user)に自動割り当て: \(speaker.name)（\(speaker.style)）")
            return mode
        }

        return nil
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        queue.removeAll()
        isSpeaking = false
        onSpeakingStateChanged?(false)
    }

    // MARK: - ユーザー別ボイス管理

    /// ユーザーにVOICEVOX音声を割り当て
    func setVoiceForUser(_ userName: String, mode: VoiceMode) {
        userVoiceMap[userName] = mode
        saveUserVoiceMap()
    }

    /// ユーザーのボイス割り当てを取得（部分一致対応）
    func voiceForUser(_ userName: String) -> VoiceMode {
        return resolveVoice(for: userName)
    }

    /// 全ユーザーのボイス割り当てを取得
    func allUserVoiceAssignments() -> [String: VoiceMode] {
        return userVoiceMap
    }

    /// スピーカー名からIDを検索（部分一致）
    func findSpeakerByName(_ name: String) -> VoicevoxSpeaker? {
        let lower = name.lowercased()
        // 完全一致（名前）を優先
        if let exact = cachedSpeakers.first(where: { $0.name.lowercased() == lower }) {
            return exact
        }
        // 部分一致
        if let partial = cachedSpeakers.first(where: { $0.name.lowercased().contains(lower) }) {
            return partial
        }
        // スタイル含めて検索
        if let styleMatch = cachedSpeakers.first(where: {
            "\($0.name)\($0.style)".lowercased().contains(lower)
        }) {
            return styleMatch
        }
        return nil
    }

    private func saveUserVoiceMap() {
        var dict: [String: String] = [:]
        for (user, mode) in userVoiceMap {
            dict[user] = voiceModeToString(mode)
        }
        AppDefaults.suite.set(dict, forKey: "GR_UserVoiceMap")
    }

    // MARK: - 読み辞書

    /// テキストに読み辞書を適用（TTS前に呼ぶ）
    func applyReadingDictionary(_ text: String) -> String {
        var result = text
        // 長いキーから先にマッチさせる（部分置換の衝突防止）
        let sortedKeys = readingDictionary.keys.sorted { $0.count > $1.count }
        for key in sortedKeys {
            if let reading = readingDictionary[key] {
                result = result.replacingOccurrences(of: key, with: reading)
            }
        }
        return result
    }

    /// 辞書に登録
    func registerReading(word: String, reading: String) {
        readingDictionary[word] = reading
        saveReadingDictionary()
        onLog?("📖 読み辞書登録: \(word) → \(reading)")
    }

    /// 辞書から削除
    func removeReading(word: String) {
        readingDictionary.removeValue(forKey: word)
        saveReadingDictionary()
        onLog?("📖 読み辞書削除: \(word)")
    }

    /// 辞書一覧を返す
    func readingDictionaryEntries() -> [(word: String, reading: String)] {
        return readingDictionary.map { (word: $0.key, reading: $0.value) }
            .sorted { $0.word < $1.word }
    }

    private func saveReadingDictionary() {
        AppDefaults.suite.set(readingDictionary, forKey: readingDictKey)
    }

    // MARK: - VOICEVOX スピーカー取得

    /// VOICEVOXエンジンから利用可能なスピーカー一覧を取得
    func fetchVoicevoxSpeakers() async -> [VoicevoxSpeaker] {
        guard let url = URL(string: "\(voicevoxBaseURL)/speakers") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            var speakers: [VoicevoxSpeaker] = []
            for speaker in json {
                guard let name = speaker["name"] as? String,
                      let styles = speaker["styles"] as? [[String: Any]] else { continue }
                for style in styles {
                    guard let styleName = style["name"] as? String,
                          let id = style["id"] as? Int else { continue }
                    speakers.append(VoicevoxSpeaker(id: id, name: name, style: styleName))
                }
            }
            self.cachedSpeakers = speakers
            return speakers
        } catch {
            return []
        }
    }

    /// callback版（既存呼び出し元との互換用）
    func fetchVoicevoxSpeakers(completion: @escaping ([VoicevoxSpeaker]) -> Void) {
        Task {
            let speakers = await fetchVoicevoxSpeakers()
            await MainActor.run { completion(speakers) }
        }
    }

    // MARK: - Private

    private func speakNext() {
        guard !isSpeaking, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        isSpeaking = true
        onSpeakingStateChanged?(true)

        switch item.voice {
        case .system:
            speakWithSystem(item.text)
        case .voicevox(let speakerID):
            speakWithVoicevox(item.text, speaker: speakerID)
        }
    }

    private func speakWithSystem(_ text: String) {
        let processed = applyReadingDictionary(text)
        let utterance = AVSpeechUtterance(string: processed)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    private func speakWithVoicevox(_ text: String, speaker: Int) {
        let processed = applyReadingDictionary(text)
        let encodedText = processed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? processed
        guard let queryURL = URL(string: "\(voicevoxBaseURL)/audio_query?text=\(encodedText)&speaker=\(speaker)") else {
            finishCurrentAndNext()
            return
        }
        var queryReq = URLRequest(url: queryURL)
        queryReq.httpMethod = "POST"

        URLSession.shared.dataTask(with: queryReq) { [weak self] data, _, error in
            guard let self = self, let queryData = data, error == nil else {
                DispatchQueue.main.async {
                    self?.onLog?("⚠️ VOICEVOX接続エラー — エンジンが起動しているか確認してください")
                    self?.speakWithSystem(text)
                }
                return
            }

            guard let synthURL = URL(string: "\(self.voicevoxBaseURL)/synthesis?speaker=\(speaker)") else {
                DispatchQueue.main.async { self.finishCurrentAndNext() }
                return
            }
            var synthReq = URLRequest(url: synthURL)
            synthReq.httpMethod = "POST"
            synthReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
            synthReq.httpBody = queryData

            URLSession.shared.dataTask(with: synthReq) { [weak self] wavData, _, error in
                guard let self = self, let wavData = wavData, error == nil else {
                    DispatchQueue.main.async { self?.finishCurrentAndNext() }
                    return
                }
                DispatchQueue.main.async {
                    self.playWav(wavData)
                }
            }.resume()
        }.resume()
    }

    private func playWav(_ data: Data) {
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.play()
        } catch {
            NSLog("[SpeechManager] WAV playback error: \(error)")
            finishCurrentAndNext()
        }
    }

    private func finishCurrentAndNext() {
        isSpeaking = false
        if queue.isEmpty { onSpeakingStateChanged?(false) }
        speakNext()
    }

    // MARK: - Persistence helpers

    private func voiceModeToString(_ mode: VoiceMode) -> String {
        switch mode {
        case .system: return "system"
        case .voicevox(let id): return "voicevox:\(id)"
        }
    }

    private func stringToVoiceMode(_ s: String) -> VoiceMode {
        if s.hasPrefix("voicevox:"), let id = Int(s.replacingOccurrences(of: "voicevox:", with: "")) {
            return .voicevox(id)
        }
        return .system
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishCurrentAndNext()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        onSpeakingStateChanged?(false)
    }
}

// MARK: - AVAudioPlayerDelegate

extension SpeechManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishCurrentAndNext()
    }
}
