import Foundation

/// 声紋プロファイルの管理・永続化・診断ログを担当
class VoiceProfileStore {

    // MARK: - VoiceProfile 定義

    /// 話者ごとの声紋プロファイル
    struct VoiceProfile {
        let name: String
        var features: [Float]
        var sampleCount: Int
        var mode: VoiceDiarizer.Mode
        var pitchMean: Float?
        var pitchStd: Float?
    }

    // MARK: - プロパティ

    /// 登録済みの声紋プロファイル
    var profiles: [String: VoiceProfile] = [:]

    var onLog: ((String) -> Void)?

    /// 登録済みの話者名一覧
    var registeredSpeakers: [String] {
        Array(profiles.keys)
    }

    // MARK: - CRUD

    func clearProfile(for speaker: String) {
        profiles.removeValue(forKey: speaker)
        saveProfiles()
    }

    func clearAllProfiles() {
        profiles.removeAll()
        saveProfiles()
    }

    func resetAdaptiveLearning(for speaker: String) {
        guard var profile = profiles[speaker] else { return }
        profile.sampleCount = 1
        profiles[speaker] = profile
        saveProfiles()
        onLog?("🔄 \(speaker)の適応学習カウンターをリセット")
    }

    // MARK: - 永続化

    private var profilesURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GravityReader")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voice_profiles.json")
    }

    func saveProfiles() {
        var data: [[String: Any]] = []
        for (_, profile) in profiles {
            var dict: [String: Any] = [
                "name": profile.name,
                "features": profile.features.map { Double($0) },
                "featureDim": profile.features.count,
                "sampleCount": profile.sampleCount,
                "mode": profile.mode == .neural ? "neural" : "mfcc"
            ]
            if let pm = profile.pitchMean { dict["pitchMean"] = Double(pm) }
            if let ps = profile.pitchStd { dict["pitchStd"] = Double(ps) }
            data.append(dict)
        }
        do {
            let json = try JSONSerialization.data(withJSONObject: data)
            guard let str = String(data: json, encoding: .utf8) else { return }
            try str.write(to: profilesURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[VoiceProfile] プロファイル保存エラー: \(error)")
            onLog?("⚠️ 声紋プロファイル保存に失敗: \(error.localizedDescription)")
        }
    }

    func loadProfiles(currentMode: VoiceDiarizer.Mode, featureDimension: Int) {
        let data: Data
        let arr: [[String: Any]]
        do {
            data = try Data(contentsOf: profilesURL)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            arr = parsed
        } catch {
            // ファイルが存在しない場合は正常（初回起動時）
            return
        }

        for item in arr {
            guard let name = item["name"] as? String,
                  let count = item["sampleCount"] as? Int else { continue }

            let profileMode: VoiceDiarizer.Mode = (item["mode"] as? String) == "neural" ? .neural : .mfcc
            let pitchMean = (item["pitchMean"] as? Double).map { Float($0) }
            let pitchStd = (item["pitchStd"] as? Double).map { Float($0) }

            if let feats = item["features"] as? [Double], feats.count == featureDimension, profileMode == currentMode {
                profiles[name] = VoiceProfile(
                    name: name,
                    features: feats.map { Float($0) },
                    sampleCount: count,
                    mode: profileMode,
                    pitchMean: pitchMean,
                    pitchStd: pitchStd
                )
            } else {
                onLog?("⚠️ \(name) の声紋は現在のモード(\(currentMode == .neural ? "neural" : "mfcc"))と互換性がないため再登録が必要です")
            }
        }
        if !profiles.isEmpty {
            onLog?("🎤 声紋プロファイル読み込み(\(currentMode == .neural ? "neural" : "mfcc")): \(profiles.keys.joined(separator: ", "))")
        }
    }

    // MARK: - 構造化診断ログ出力（JSONL）

    var diagnosticsEnabled = true

    private lazy var diagnosticsURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GravityReader/diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("identify.jsonl")
    }()

    private let diagnosticsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func writeDiagnosticEvent(_ event: VoiceDiarizer.IdentificationDebugEvent) {
        guard diagnosticsEnabled else { return }
        do {
            let data = try diagnosticsEncoder.encode(event)
            guard let line = String(data: data, encoding: .utf8) else { return }
            let lineWithNewline = line + "\n"
            if let handle = try? FileHandle(forWritingTo: diagnosticsURL) {
                handle.seekToEndOfFile()
                handle.write(lineWithNewline.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try lineWithNewline.write(to: diagnosticsURL, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("[VoiceProfile] 診断ログ書き込みエラー: \(error)")
        }
    }
}
