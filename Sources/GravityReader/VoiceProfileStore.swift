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
    private let profilesURL: URL
    private var activeMode: VoiceDiarizer.Mode?
    private var activeFeatureDimension: Int?

    init(profilesURL: URL? = nil) {
        self.profilesURL = profilesURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GravityReader/voice_profiles.json")
    }

    /// 登録済みの話者名一覧
    var registeredSpeakers: [String] {
        Array(profiles.keys)
    }

    // MARK: - CRUD

    func clearProfile(for speaker: String) {
        do {
            // A user's explicit deletion applies to every stored extraction mode.
            let remaining = try readStoredProfiles().filter { $0["name"] as? String != speaker }
            try writeStoredProfiles(remaining)
            profiles.removeValue(forKey: speaker)
        } catch { reportStorageError(error) }
    }

    func clearAllProfiles() {
        do {
            try writeStoredProfiles([])
            profiles.removeAll()
        } catch { reportStorageError(error) }
    }

    func resetAdaptiveLearning(for speaker: String) {
        guard var profile = profiles[speaker] else { return }
        profile.sampleCount = 1
        profiles[speaker] = profile
        saveProfiles()
        onLog?("🔄 \(speaker)の適応学習カウンターをリセット")
    }

    // MARK: - 永続化

    private func modeName(_ mode: VoiceDiarizer.Mode) -> String {
        mode == .neural ? "neural" : "mfcc"
    }

    private func storedModeName(_ item: [String: Any]) -> String {
        // Older files did not have a mode and contained MFCC profiles.
        item["mode"] as? String ?? "mfcc"
    }

    /// A matching dimension does not imply a matching feature representation.
    /// Legacy neural vectors used a different frontend and cannot be converted
    /// without the original recording. Keep them stored, but never compare them.
    private func isCompatible(_ item: [String: Any], with mode: VoiceDiarizer.Mode) -> Bool {
        guard storedModeName(item) == modeName(mode) else { return false }
        return mode != .neural || item["extractor"] as? String == SpeakerEmbeddingModel.extractorIdentifier
    }

    private func readStoredProfiles() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: profilesURL.path) else { return [] }
        let data = try Data(contentsOf: profilesURL)
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "VoiceProfileStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "声紋ファイルの形式が不正です。元のファイルは保持します。"])
        }
        return records
    }

    private func writeStoredProfiles(_ records: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: records)
        try FileManager.default.createDirectory(at: profilesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: profilesURL, options: .atomic)
    }

    private func reportStorageError(_ error: Error) {
        NSLog("[VoiceProfile] プロファイル保存エラー: %@", error.localizedDescription)
        onLog?("⚠️ 声紋プロファイル保存に失敗: \(error.localizedDescription)")
    }

    func saveProfiles() {
        let mode = activeMode ?? profiles.values.first?.mode ?? .mfcc
        let dimension = activeFeatureDimension ?? (mode == .neural ? SpeakerEmbeddingModel.embeddingDim : MFCCFeatureExtractor().featureDimension)
        guard dimension > 0, profiles.values.allSatisfy({ profile in
            !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            profile.mode == mode && profile.features.count == dimension &&
            profile.features.allSatisfy(\.isFinite) && profile.sampleCount > 0 &&
            (profile.pitchMean?.isFinite ?? true) && (profile.pitchStd?.isFinite ?? true)
        }) else {
            onLog?("⚠️ 不正な声紋データの保存を中止しました。保存済みデータは保持します。")
            return
        }
        do {
            // Preserve inactive modes AND inactive neural frontend versions.
            var data = try readStoredProfiles().filter { !isCompatible($0, with: mode) }
            for profile in profiles.values.sorted(by: { $0.name < $1.name }) {
                var dict: [String: Any] = [
                    "name": profile.name,
                    "features": profile.features.map { Double($0) },
                    "featureDim": profile.features.count,
                    "sampleCount": profile.sampleCount,
                    "mode": modeName(profile.mode)
                ]
                if profile.mode == .neural { dict["extractor"] = SpeakerEmbeddingModel.extractorIdentifier }
                if let pm = profile.pitchMean { dict["pitchMean"] = Double(pm) }
                if let ps = profile.pitchStd { dict["pitchStd"] = Double(ps) }
                data.append(dict)
            }
            try writeStoredProfiles(data)
        } catch { reportStorageError(error) }
    }

    func loadProfiles(currentMode: VoiceDiarizer.Mode, featureDimension: Int) {
        activeMode = currentMode
        activeFeatureDimension = featureDimension
        // Inactive modes and frontend versions remain in the file and are merged
        // back by saveProfiles(). Loading never rewrites existing registrations.
        profiles.removeAll()
        guard featureDimension > 0 else { return }
        do {
            let stored = try readStoredProfiles()
            for item in stored {
                guard isCompatible(item, with: currentMode),
                      let name = item["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let count = item["sampleCount"] as? Int, count > 0,
                      let feats = item["features"] as? [Double], feats.count == featureDimension,
                      feats.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { continue }
                let pitchMean = (item["pitchMean"] as? Double).map { Float($0) }
                let pitchStd = (item["pitchStd"] as? Double).map { Float($0) }
                profiles[name] = VoiceProfile(name: name, features: feats.map { Float($0) }, sampleCount: count,
                                             mode: currentMode, pitchMean: pitchMean?.isFinite == true ? pitchMean : nil,
                                             pitchStd: pitchStd?.isFinite == true ? pitchStd : nil)
            }
            if !profiles.isEmpty {
                onLog?("🎤 声紋プロファイル読み込み(\(modeName(currentMode))): \(profiles.keys.sorted().joined(separator: ", "))")
            }
            if currentMode == .neural {
                let inactiveNames = Set(stored.compactMap { item -> String? in
                    guard storedModeName(item) == "neural", !isCompatible(item, with: .neural),
                          let name = item["name"] as? String, !name.isEmpty, profiles[name] == nil else { return nil }
                    return name
                }).sorted()
                if !inactiveNames.isEmpty {
                    onLog?("⚠️ 旧方式の声紋は保存したまま照合から除外しました。音声前処理の修正に伴い再登録が必要です: \(inactiveNames.joined(separator: ", "))")
                }
            }
        } catch {
            onLog?("⚠️ 声紋プロファイルを読み込めません。保存済みファイルは保持します。")
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
