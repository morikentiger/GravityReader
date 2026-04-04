import Foundation
import Accelerate
import AVFoundation

/// 声の特徴量で話者を識別するクラス。
/// ニューラルモード（ECAPA-TDNN 192次元）とMFCCフォールバック（39次元）をサポート。
class VoiceDiarizer {

    // MARK: - 型定義

    enum Mode {
        case neural
        case mfcc
    }

    enum IdentifyConfidence {
        case strict
        case estimated
    }

    enum UnknownReason: String, Codable {
        case insufficientQuality = "insufficient_quality"
        case belowMinSimilarity = "below_min_similarity"
        case belowMargin = "below_margin"
        case voteNotConverged = "vote_not_converged"
        case modeUnavailable = "mode_unavailable"
        case noProfiles = "no_profiles"
        case featureMismatch = "feature_mismatch"
    }

    struct IdentificationDebugEvent: Codable {
        let timestamp: Date
        let mode: String
        let topSpeaker: String?
        let topSimilarity: Float?
        let secondSpeaker: String?
        let secondSimilarity: Float?
        let margin: Float?
        let decisionType: String
        let recentVotes: [String]
        let finalDecision: String
        let unknownReason: String?
        let adaptiveUpdated: Bool
        let adaptiveRejectedReason: String?
        let inputQuality: InputQualityInfo?

        struct InputQualityInfo: Codable {
            let rms: Float
            let voicedRatio: Float
            let effectiveDuration: Float
        }
    }

    // MARK: - サブコンポーネント

    let embeddingModel = SpeakerEmbeddingModel()
    let profileStore = VoiceProfileStore()
    let voting = VoiceTemporalVoting()
    let mfccExtractor = MFCCFeatureExtractor()

    // MARK: - プロパティ

    private(set) var mode: Mode = .mfcc

    // ニューラルモード用パラメータ
    var minSimilarity: Float = 0.45
    var similarityMargin: Float = 0.06
    var softMargin: Float = 0.01

    // MFCCモード用パラメータ
    var maxDistance: Float = 30.0
    var marginRatio: Float = 1.10

    var onLog: ((String) -> Void)?

    var diagnosticsEnabled: Bool {
        get { profileStore.diagnosticsEnabled }
        set { profileStore.diagnosticsEnabled = newValue }
    }

    /// 特徴ベクトルの次元数
    var featureDimension: Int {
        switch mode {
        case .neural: return SpeakerEmbeddingModel.embeddingDim
        case .mfcc:   return mfccExtractor.featureDimension
        }
    }

    /// 登録済みの話者名一覧
    var registeredSpeakers: [String] { profileStore.registeredSpeakers }

    /// 最後の適応学習診断情報
    private(set) var lastAdaptiveRejectedReason: String?

    /// 直近の識別に使った生音声サンプル（ピッチ複合判定用）
    private var lastIdentifySamples: [Float]?

    private let maxAdaptiveUpdates = 100

    // MARK: - モデル初��化

    func initializeNeuralModel() {
        embeddingModel.onLog = onLog
        embeddingModel.loadAsync()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for _ in 0..<100 {
                if self?.embeddingModel.isAvailable == true {
                    DispatchQueue.main.async {
                        self?.switchToNeuralMode()
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            self?.onLog?("⚠️ ECAPA-TDNN ロードタイムアウト、MFCCモードで動作")
        }
    }

    private func switchToNeuralMode() {
        let hadProfiles = !profileStore.profiles.isEmpty
        mode = .neural
        onLog?("🧠 声紋識別: ECAPA-TDNN ニューラルモードに切り替え")
        if hadProfiles {
            let names = profileStore.profiles.keys.joined(separator: ", ")
            profileStore.profiles.removeAll()
            profileStore.saveProfiles()
            onLog?("⚠️ \(names) の声紋はニューラルモード用に再登録が必要です")
        }
    }

    // MARK: - ログ連携

    private func setupSubcomponentLogs() {
        profileStore.onLog = onLog
        voting.onLog = onLog
    }

    // MARK: - Public API

    func extractFeatures(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount >= mfccExtractor.fftSize else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        return extractFeatures(from: samples)
    }

    func extractFeatures(from samples: [Float]) -> [Float]? {
        switch mode {
        case .neural:
            guard samples.count >= Int(mfccExtractor.sampleRate * 0.5) else { return nil }
            let quality = AudioQualityEvaluator.evaluate(samples: samples, sampleRate: mfccExtractor.sampleRate)
            if !quality.isSufficientForInference {
                let reasons = quality.failureReasons.joined(separator: ", ")
                onLog?("🔇 音声品質不足でスキップ: \(reasons)")
                return nil
            }
            return embeddingModel.extractEmbedding(from: samples, sampleRate: mfccExtractor.sampleRate)
        case .mfcc:
            guard samples.count >= mfccExtractor.fftSize else { return nil }
            return mfccExtractor.extractFullFeatures(from: samples)
        }
    }

    func enroll(speaker: String, features: [Float]) {
        guard features.count == featureDimension else { return }

        if var existing = profileStore.profiles[speaker] {
            let alpha: Float = 2.0 / Float(min(existing.sampleCount + 2, 20))
            var updated = existing.features
            for i in 0..<featureDimension {
                updated[i] = updated[i] * (1 - alpha) + features[i] * alpha
            }
            if mode == .neural { updated = l2Normalize(updated) }
            existing.features = updated
            existing.sampleCount += 1
            profileStore.profiles[speaker] = existing
            onLog?("🎤 声紋更新: \(speaker)（サンプル\(existing.sampleCount)）")
        } else {
            profileStore.profiles[speaker] = VoiceProfileStore.VoiceProfile(
                name: speaker, features: features, sampleCount: 1, mode: mode)
            onLog?("🎤 声紋登録: \(speaker)")
        }

        switch mode {
        case .neural:
            onLog?("   📊 ECAPA-TDNN 埋め込み \(featureDimension)次元")
        case .mfcc:
            let pitchIdx = mfccExtractor.numMFCC * 3
            let meanF0 = features[pitchIdx] * (mfccExtractor.pitchNormMax - mfccExtractor.pitchNormMin) + mfccExtractor.pitchNormMin
            let stdF0 = features[pitchIdx + 1] * (mfccExtractor.pitchNormMax - mfccExtractor.pitchNormMin)
            onLog?("   📊 ピッチ: 平均\(String(format: "%.0f", meanF0))Hz, 標準偏差\(String(format: "%.0f", stdF0))Hz")
        }

        if mode == .neural {
            for (otherName, otherProfile) in profileStore.profiles where otherName != speaker && otherProfile.mode == .neural {
                let sim = cosineSimilarity(features, otherProfile.features)
                if sim > 0.85 {
                    onLog?("⚠️ 登録警告: \(speaker)と\(otherName)の類似度が\(String(format: "%.3f", sim))で高すぎます")
                }
            }
        }

        profileStore.saveProfiles()
    }

    func enrollWithQualityCheck(speaker: String, samples: [Float]) -> (success: Bool, message: String) {
        let quality = AudioQualityEvaluator.evaluate(samples: samples, sampleRate: mfccExtractor.sampleRate)
        if !quality.isSufficientForEnrollment {
            let reasons = quality.enrollmentFailureReasons.joined(separator: "\n")
            onLog?("❌ 登録品質不足: \(speaker)\n\(reasons)")
            return (false, "登録品質が不十分です:\n\(reasons)")
        }

        onLog?("📊 登録品質: RMS=\(String(format: "%.4f", quality.averageRMS)) 有声率=\(String(format: "%.0f%%", quality.voicedRatio * 100)) 有効\(String(format: "%.1f", quality.effectiveDuration))秒")

        if mode == .neural {
            if let consistency = AudioQualityEvaluator.evaluateEmbeddingConsistency(
                samples: samples,
                sampleRate: mfccExtractor.sampleRate,
                extractEmbedding: { [weak self] window in
                    self?.embeddingModel.extractEmbedding(from: window, sampleRate: self?.mfccExtractor.sampleRate ?? 44100)
                }
            ) {
                onLog?("📊 埋め込み一貫性: 平均=\(String(format: "%.3f", consistency.meanSimilarity)) 最小=\(String(format: "%.3f", consistency.minSimilarity)) (\(consistency.windowCount)窓)")

                if consistency.meanSimilarity < 0.75 {
                    onLog?("⚠️ 登録品質警告: 埋め込みの一貫性が低い（複数話者混入の疑い）")
                    return (false, "録音の一貫性が低く、登録品質が不安定です（平均類似度: \(String(format: "%.2f", consistency.meanSimilarity))）")
                }
                if consistency.minSimilarity < 0.50 {
                    onLog?("⚠️ 登録品質警告: 一部区間の埋め込みが大きく乖離")
                }
            }
        }

        guard let features = embeddingModel.extractEmbedding(from: samples, sampleRate: mfccExtractor.sampleRate) else {
            return (false, "特徴量の抽出に失敗しました")
        }

        enroll(speaker: speaker, features: features)
        enrollPitchStats(speaker: speaker, samples: samples)

        return (true, "登録完了！品質: RMS=\(String(format: "%.3f", quality.averageRMS)) 有声率=\(String(format: "%.0f%%", quality.voicedRatio * 100))")
    }

    func setRawSamplesForNextIdentify(_ samples: [Float]) {
        lastIdentifySamples = samples
    }

    func identify(features: [Float]) -> (speaker: String, confidence: Float)? {
        guard features.count == featureDimension else { return nil }
        guard !profileStore.profiles.isEmpty else { return nil }

        switch mode {
        case .neural:
            return identifyNeural(features: features)?.result
        case .mfcc:
            return identifyMFCC(features: features)
        }
    }

    func identifyWithConfidence(features: [Float]) -> (speaker: String, confidence: Float, level: IdentifyConfidence)? {
        guard features.count == featureDimension else { return nil }
        guard !profileStore.profiles.isEmpty else { return nil }
        guard mode == .neural else {
            if let r = identifyMFCC(features: features) {
                return (r.speaker, r.confidence, .strict)
            }
            return nil
        }
        guard let r = identifyNeural(features: features) else { return nil }
        return (r.result.speaker, r.result.confidence, r.level)
    }

    // MARK: - 適応学習

    func adaptiveUpdate(speaker: String, features: [Float]) {
        lastAdaptiveRejectedReason = nil
        guard features.count == featureDimension else { return }
        guard var profile = profileStore.profiles[speaker] else { return }
        guard profile.mode == mode else { return }

        if profile.sampleCount > maxAdaptiveUpdates {
            lastAdaptiveRejectedReason = "max_updates_exceeded"
            return
        }

        let shouldUpdate: Bool
        switch mode {
        case .neural:
            let sim = cosineSimilarity(features, profile.features)
            shouldUpdate = sim >= 0.65
            if !shouldUpdate { lastAdaptiveRejectedReason = "low_confidence(\(String(format: "%.3f", sim)))" }
        case .mfcc:
            let dist = euclideanDistance(features, profile.features)
            shouldUpdate = dist <= maxDistance * 0.4
            if !shouldUpdate { lastAdaptiveRejectedReason = "low_confidence" }
        }

        guard shouldUpdate else { return }

        let alpha: Float = 0.05
        var updated = profile.features
        for i in 0..<featureDimension {
            updated[i] = updated[i] * (1 - alpha) + features[i] * alpha
        }
        if mode == .neural { updated = l2Normalize(updated) }

        if mode == .neural {
            for (otherName, otherProfile) in profileStore.profiles where otherName != speaker && otherProfile.mode == .neural {
                let simAfter = cosineSimilarity(updated, otherProfile.features)
                if simAfter > 0.92 {
                    lastAdaptiveRejectedReason = "drift_guard(\(otherName):\(String(format: "%.3f", simAfter)))"
                    onLog?("🛑 ドリフトガード: \(speaker)の更新却下（\(otherName)との類似度が\(String(format: "%.3f", simAfter))に接近）")
                    return
                }
            }
        }

        profile.features = updated
        profile.sampleCount += 1
        profileStore.profiles[speaker] = profile

        if profile.sampleCount % 50 == 0 {
            onLog?("🔄 声紋適応更新: \(speaker)（累計\(profile.sampleCount)サ���プル）")
            profileStore.saveProfiles()
        }
    }

    // MARK: - ニューラル識別

    private func identifyNeural(features: [Float]) -> (result: (speaker: String, confidence: Float), level: IdentifyConfidence)? {
        setupSubcomponentLogs()
        var results: [(name: String, similarity: Float)] = []

        for (name, profile) in profileStore.profiles {
            guard profile.mode == .neural else { continue }
            let sim = cosineSimilarity(features, profile.features)
            results.append((name, sim))
        }

        guard !results.isEmpty else { return nil }
        results.sort { $0.similarity > $1.similarity }

        for r in results {
            voting.updateScoreHistory(speaker: r.name, score: r.similarity)
        }

        let scoreStr = results.map { "\($0.name):\(String(format: "%.3f", $0.similarity))" }.joined(separator: " ")
        onLog?("🔍 声紋照合(neural): \(scoreStr)")

        // スコア正規化
        let speakerNames = results.map { $0.name }
        let hasEnoughHistory = voting.hasEnoughHistory(for: speakerNames)

        var normalizedResults: [(name: String, similarity: Float, rawSimilarity: Float)] = []
        if hasEnoughHistory && results.count >= 2 {
            for r in results {
                let normalizedScore = voting.normalizeScore(speaker: r.name, rawScore: r.similarity)
                normalizedResults.append((r.name, normalizedScore, r.similarity))
            }
            normalizedResults.sort { $0.similarity > $1.similarity }
        } else {
            normalizedResults = results.map { ($0.name, $0.similarity, $0.similarity) }
        }

        let best = normalizedResults[0]
        let second: (name: String, similarity: Float, rawSimilarity: Float)? = normalizedResults.count >= 2 ? normalizedResults[1] : nil
        let margin = second != nil ? best.similarity - second!.similarity : Float(1.0)
        let rawBestSim = best.rawSimilarity

        if hasEnoughHistory && results.count >= 2 && results[0].name != normalizedResults[0].name {
            onLog?("📊 スコア正規化で順位変動: \(results[0].name)→\(normalizedResults[0].name)")
        }

        // 判定ロジック
        var decisionType: String
        var finalDecision: String
        var unknownReason: UnknownReason? = nil
        var returnValue: (result: (speaker: String, confidence: Float), level: IdentifyConfidence)? = nil

        // ピッチ補助判定
        var effectiveBest = best
        var effectiveSecond = second
        var effectiveMargin = margin
        var pitchUsed = false

        if let rawSamples = lastIdentifySamples, normalizedResults.count >= 2, margin < similarityMargin {
            var pitchScores: [String: Float] = [:]
            for r in normalizedResults {
                if let profile = profileStore.profiles[r.name], let pm = profile.pitchMean, let ps = profile.pitchStd {
                    pitchScores[r.name] = mfccExtractor.pitchMatchScore(
                        samples: rawSamples, profilePitchMean: pm, profilePitchStd: ps) ?? 0.5
                }
            }
            if pitchScores.count >= 2 {
                pitchUsed = true
                var combined = normalizedResults.map { r -> (name: String, similarity: Float, rawSimilarity: Float) in
                    let ps = pitchScores[r.name] ?? 0.5
                    return (r.name, r.similarity * 0.8 + ps * 0.2, r.rawSimilarity)
                }
                combined.sort { $0.similarity > $1.similarity }
                effectiveBest = combined[0]
                effectiveSecond = combined.count >= 2 ? combined[1] : nil
                effectiveMargin = effectiveSecond != nil ? effectiveBest.similarity - effectiveSecond!.similarity : 1.0

                let pitchStr = pitchScores.map { "\($0.key):\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
                onLog?("🎵 ピッチ補正: \(pitchStr)")
            }
        }
        lastIdentifySamples = nil

        if rawBestSim < minSimilarity {
            decisionType = "unknown"
            finalDecision = "不明"
            unknownReason = .belowMinSimilarity
            voting.addVote(speaker: "不明", score: 0)
        } else if normalizedResults.count <= 1 || effectiveMargin >= similarityMargin {
            decisionType = pitchUsed ? "strict+pitch" : (hasEnoughHistory && results[0].name != normalizedResults[0].name ? "strict+norm" : "strict")
            finalDecision = effectiveBest.name
            voting.addVote(speaker: effectiveBest.name, score: rawBestSim)
            returnValue = ((effectiveBest.name, rawBestSim), (pitchUsed || hasEnoughHistory && results[0].name != normalizedResults[0].name) ? .estimated : .strict)
        } else if effectiveMargin >= softMargin {
            decisionType = "soft"
            voting.addVote(speaker: effectiveBest.name, score: rawBestSim)
            onLog?("⚠️ マージン不足: \(effectiveBest.name)(\(String(format: "%.3f", effectiveBest.similarity))) vs \(effectiveSecond!.name)(\(String(format: "%.3f", effectiveSecond!.similarity))) margin=\(String(format: "%.3f", effectiveMargin))")

            if let voted = voting.resolveByVoting() {
                decisionType = "voted"
                finalDecision = voted.speaker
                onLog?("🗳 多数決で判定: \(voted.speaker)（\(voted.count)/\(voting.votingWindowSize)票）")
                returnValue = ((voted.speaker, rawBestSim), .estimated)
            } else {
                finalDecision = "不明"
                unknownReason = .voteNotConverged
            }
        } else {
            decisionType = "unknown"
            finalDecision = "不明"
            unknownReason = .belowMargin
            voting.addVote(speaker: "不明", score: 0)
            onLog?("⚠️ マージン不足: \(effectiveBest.name)(\(String(format: "%.3f", effectiveBest.similarity))) vs \(effectiveSecond!.name)(\(String(format: "%.3f", effectiveSecond!.similarity))) margin=\(String(format: "%.3f", effectiveMargin))")
        }

        // 構造化ログ
        if profileStore.diagnosticsEnabled {
            let event = IdentificationDebugEvent(
                timestamp: Date(),
                mode: "neural",
                topSpeaker: best.name,
                topSimilarity: best.similarity,
                secondSpeaker: second?.name,
                secondSimilarity: second?.similarity,
                margin: margin,
                decisionType: decisionType,
                recentVotes: voting.recentVotes.map { $0.speaker },
                finalDecision: finalDecision,
                unknownReason: unknownReason?.rawValue,
                adaptiveUpdated: false,
                adaptiveRejectedReason: nil,
                inputQuality: nil
            )
            profileStore.writeDiagnosticEvent(event)
        }

        return returnValue
    }

    // MARK: - MFCCモード識別

    private func identifyMFCC(features: [Float]) -> (speaker: String, confidence: Float)? {
        var results: [(name: String, distance: Float)] = []

        for (name, profile) in profileStore.profiles {
            let dist = euclideanDistance(features, profile.features)
            results.append((name, dist))
        }

        results.sort { $0.distance < $1.distance }

        let scoreStr = results.map { "\($0.name):\(String(format: "%.2f", $0.distance))" }.joined(separator: " ")
        onLog?("🔍 声紋照合(mfcc): \(scoreStr)")

        guard let best = results.first, best.distance <= maxDistance else { return nil }

        if results.count >= 2 {
            let ratio = results[1].distance / max(best.distance, 0.001)
            if ratio < marginRatio {
                onLog?("⚠️ マージン比不足: \(best.name)(\(String(format: "%.2f", best.distance))) vs \(results[1].name)(\(String(format: "%.2f", results[1].distance))) ratio=\(String(format: "%.3f", ratio))")
                return nil
            }
        }

        let confidence = max(0, 1.0 - best.distance / maxDistance)
        return (best.name, confidence)
    }

    // MARK: - ピッチ統計

    func enrollPitchStats(speaker: String, samples: [Float]) {
        guard var profile = profileStore.profiles[speaker] else { return }

        if let stats = mfccExtractor.computePitchStats(from: samples) {
            if let existingMean = profile.pitchMean {
                let alpha: Float = 0.3
                profile.pitchMean = existingMean * (1 - alpha) + stats.mean * alpha
                profile.pitchStd = (profile.pitchStd ?? stats.std) * (1 - alpha) + stats.std * alpha
            } else {
                profile.pitchMean = stats.mean
                profile.pitchStd = stats.std
            }
            profileStore.profiles[speaker] = profile
            onLog?("   🎵 ピッチ: 平均\(String(format: "%.0f", profile.pitchMean!))Hz, 標準偏差\(String(format: "%.0f", profile.pitchStd!))Hz")
            profileStore.saveProfiles()
        }
    }

    // MARK: - プロファイル管理（委譲）

    func clearProfile(for speaker: String) { profileStore.clearProfile(for: speaker) }
    func clearAllProfiles() {
        profileStore.clearAllProfiles()
        voting.clearVotingHistory()
    }
    func clearVotingHistory() { voting.clearVotingHistory() }
    func saveProfiles() { profileStore.saveProfiles() }
    func loadProfiles() { profileStore.loadProfiles(currentMode: mode, featureDimension: featureDimension) }
    func resetAdaptiveLearning(for speaker: String) { profileStore.resetAdaptiveLearning(for: speaker) }

    // MARK: - プロファイル診断

    func diagnoseProfiles() {
        guard mode == .neural else { return }
        let names = Array(profileStore.profiles.keys).sorted()
        guard names.count >= 2 else {
            onLog?("📊 プロファイル診断: 登録者\(names.count)���（比較不要）")
            return
        }

        onLog?("📊 === プロファイル間類似度診断 ===")
        for i in 0..<names.count {
            for j in (i+1)..<names.count {
                guard let p1 = profileStore.profiles[names[i]], let p2 = profileStore.profiles[names[j]] else { continue }
                let sim = cosineSimilarity(p1.features, p2.features)
                let status: String
                if sim > 0.90 {
                    status = "🔴 危険（プロファイル収束の疑い）"
                } else if sim > 0.80 {
                    status = "🟡 要注意"
                } else {
                    status = "🟢 正常"
                }
                onLog?("   \(names[i]) ↔ \(names[j]): \(String(format: "%.4f", sim)) \(status)")
            }
            if let p = profileStore.profiles[names[i]] {
                let pitchStr = p.pitchMean != nil ? ", ピッチ=\(String(format: "%.0f", p.pitchMean!))Hz±\(String(format: "%.0f", p.pitchStd ?? 0))Hz" : ""
                onLog?("   \(names[i]): サンプル数=\(p.sampleCount), 適応学習残り=\(max(0, maxAdaptiveUpdates - p.sampleCount))回\(pitchStr)")
            }
        }
        onLog?("📊 ========================")
    }

    func profileHealthSummary() -> [(speaker: String, sampleCount: Int, nearestOther: String?, nearestSimilarity: Float?)] {
        var summary: [(speaker: String, sampleCount: Int, nearestOther: String?, nearestSimilarity: Float?)] = []
        for (name, profile) in profileStore.profiles {
            var nearest: (String, Float)? = nil
            for (otherName, otherProfile) in profileStore.profiles where otherName != name {
                let sim = mode == .neural
                    ? cosineSimilarity(profile.features, otherProfile.features)
                    : 1.0 / (1.0 + euclideanDistance(profile.features, otherProfile.features))
                if nearest == nil || sim > nearest!.1 {
                    nearest = (otherName, sim)
                }
            }
            summary.append((speaker: name, sampleCount: profile.sampleCount,
                            nearestOther: nearest?.0, nearestSimilarity: nearest?.1))
        }
        return summary.sorted { $0.speaker < $1.speaker }
    }

    // MARK: - 距離・類似度計算

    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    func l2Normalize(_ vec: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, vDSP_Length(vec.count))
        norm = sqrtf(norm)
        guard norm > 1e-8 else { return vec }
        var result = vec
        var divisor = norm
        vDSP_vsdiv(result, 1, &divisor, &result, 1, vDSP_Length(vec.count))
        return result
    }

    private func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return Float.greatestFiniteMagnitude }
        var sumSq: Float = 0
        for i in 0..<a.count {
            let diff = a[i] - b[i]
            sumSq += diff * diff
        }
        return sqrtf(sumSq)
    }
}
