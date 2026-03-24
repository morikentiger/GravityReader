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
    private(set) var isSpeaking = false

    /// デフォルト音声（メニューで選択されたもの）
    var voiceMode: VoiceMode = .system {
        didSet { UserDefaults.standard.set(voiceModeToString(voiceMode), forKey: "GR_VoiceMode") }
    }

    /// ユーザー別ボイス割り当て（ユーザー名 → VoiceMode）
    private var userVoiceMap: [String: VoiceMode] = [:]

    /// キャッシュされたスピーカー一覧
    private(set) var cachedSpeakers: [VoicevoxSpeaker] = []

    var onSpeakingStateChanged: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    /// VOICEVOX API のベースURL（デフォルト: localhost:50021）
    var voicevoxBaseURL = "http://127.0.0.1:50021"

    override init() {
        super.init()
        synthesizer.delegate = self
        // 保存済み設定を復元
        if let saved = UserDefaults.standard.string(forKey: "GR_VoiceMode") {
            voiceMode = stringToVoiceMode(saved)
        }
        // ユーザー別ボイス設定を復元
        if let savedMap = UserDefaults.standard.dictionary(forKey: "GR_UserVoiceMap") as? [String: String] {
            for (user, modeStr) in savedMap {
                userVoiceMap[user] = stringToVoiceMode(modeStr)
            }
        }
    }

    // MARK: - Public

    /// テキストをデフォルト音声で読み上げ
    func speak(_ text: String) {
        queue.append((text: text, voice: voiceMode))
        speakNext()
    }

    /// テキストをユーザー固有音声で読み上げ（未設定ならデフォルト）
    func speak(_ text: String, forUser user: String) {
        let voice = userVoiceMap[user] ?? voiceMode
        queue.append((text: text, voice: voice))
        speakNext()
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

    /// ユーザーのボイス割り当てを取得
    func voiceForUser(_ userName: String) -> VoiceMode {
        return userVoiceMap[userName] ?? voiceMode
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
        UserDefaults.standard.set(dict, forKey: "GR_UserVoiceMap")
    }

    // MARK: - VOICEVOX スピーカー取得

    /// VOICEVOXエンジンから利用可能なスピーカー一覧を取得
    func fetchVoicevoxSpeakers(completion: @escaping ([VoicevoxSpeaker]) -> Void) {
        guard let url = URL(string: "\(voicevoxBaseURL)/speakers") else {
            completion([])
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion([])
                return
            }
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
            DispatchQueue.main.async {
                self?.cachedSpeakers = speakers
                completion(speakers)
            }
        }.resume()
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
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    private func speakWithVoicevox(_ text: String, speaker: Int) {
        let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
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
