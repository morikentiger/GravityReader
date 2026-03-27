import Foundation
import Accelerate
import AVFoundation

/// 声の特徴量で話者を識別するクラス。
/// ニューラルモード（ECAPA-TDNN 192次元）とMFCCフォールバック（39次元）をサポート。
class VoiceDiarizer {

    // MARK: - 型定義

    enum Mode {
        /// ECAPA-TDNN ニューラル埋め込み（192次元、コサイン類似度）
        case neural
        /// MFCC + ピッチ（39次元、ユークリッド距離）— フォールバック
        case mfcc
    }

    /// 話者ごとの声紋プロファイル
    struct VoiceProfile {
        let name: String
        /// 特徴ベクトル
        var features: [Float]
        /// 蓄積したサンプル数（加重平均用）
        var sampleCount: Int
        /// プロファイルのモード（neural or mfcc）
        var mode: Mode
        /// ピッチ統計（複合判定用）: 平均F0(Hz)
        var pitchMean: Float?
        /// ピッチ統計: F0標準偏差(Hz)
        var pitchStd: Float?
    }

    /// 識別の確信度レベル
    enum IdentifyConfidence {
        /// 厳格マージンを満たした確定判定（適応学習OK）
        case strict
        /// 多数決やソフトマージンによる推定判定（適応学習NG）
        case estimated
    }

    /// unknown 判定の理由（P2-1）
    enum UnknownReason: String, Codable {
        case insufficientQuality = "insufficient_quality"
        case belowMinSimilarity = "below_min_similarity"
        case belowMargin = "below_margin"
        case voteNotConverged = "vote_not_converged"
        case modeUnavailable = "mode_unavailable"
        case noProfiles = "no_profiles"
        case featureMismatch = "feature_mismatch"
    }

    /// 構造化デバッグイベント（P0-1）
    struct IdentificationDebugEvent: Codable {
        let timestamp: Date
        let mode: String               // "neural" or "mfcc"
        let topSpeaker: String?
        let topSimilarity: Float?
        let secondSpeaker: String?
        let secondSimilarity: Float?
        let margin: Float?
        let decisionType: String       // "strict", "soft", "unknown", "voted"
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

    // MARK: - プロパティ

    /// 登録済みの声紋プロファイル
    private var profiles: [String: VoiceProfile] = [:]

    /// 現在の識別モード
    private(set) var mode: Mode = .mfcc

    /// ニューラル埋め込みモデル
    let embeddingModel = SpeakerEmbeddingModel()

    // --- ニューラルモード用パラメータ ---
    var minSimilarity: Float = 0.45
    var similarityMargin: Float = 0.06   // 厳格マージン（0.08→0.06に緩和）
    var softMargin: Float = 0.01          // ソフトマージン（0.02→0.01に緩和、多数決でカバー）

    // --- 時間的多数決（temporal voting）---
    private var recentVotes: [(speaker: String, score: Float)] = []
    private let votingWindowSize = 5
    private let votingMinCount = 3

    // --- MFCCモード用パラメータ ---
    var maxDistance: Float = 30.0
    var marginRatio: Float = 1.10

    /// ログコールバック
    var onLog: ((String) -> Void)?

    /// 構造化診断ログの有効化フラグ
    var diagnosticsEnabled = true

    // MARK: - MFCC パラメータ (フォールバック用)

    private let sampleRate: Float = 44100
    private let fftSize: Int = 2048
    private let hopSize: Int = 512
    private let numMelBands: Int = 40
    private let numMFCCRaw: Int = 13
    private let mfccStart: Int = 1
    private var numMFCC: Int { numMFCCRaw - mfccStart }

    private let pitchMinFreq: Float = 85
    private let pitchMaxFreq: Float = 400
    private let pitchNormMin: Float = 85
    private let pitchNormMax: Float = 400

    private let melLowFreq: Float = 80
    private let melHighFreq: Float = 7600

    /// 特徴ベクトルの次元数
    var featureDimension: Int {
        switch mode {
        case .neural: return SpeakerEmbeddingModel.embeddingDim
        case .mfcc:   return numMFCC * 3 + 3
        }
    }

    private lazy var melFilterBank: [[Float]] = buildMelFilterBank()
    private lazy var dctMatrix: [[Float]] = buildDCTMatrix()
    private lazy var fftSetup: FFTSetup? = {
        let log2n = vDSP_Length(log2f(Float(fftSize)))
        return vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }()

    // MARK: - モデル初期化

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
        let hadProfiles = !profiles.isEmpty
        mode = .neural
        onLog?("🧠 声紋識別: ECAPA-TDNN ニューラルモードに切り替え")
        if hadProfiles {
            let names = profiles.keys.joined(separator: ", ")
            profiles.removeAll()
            saveProfiles()
            onLog?("⚠️ \(names) の声紋はニューラルモード用に再登録が必要です")
        }
    }

    // MARK: - Public API

    /// 音声バッファから声の特徴量を抽出
    func extractFeatures(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount >= fftSize else { return nil }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        return extractFeatures(from: samples)
    }

    /// 生のFloat配列から特徴量抽出（品質ゲート付き: P0-3）
    func extractFeatures(from samples: [Float]) -> [Float]? {
        switch mode {
        case .neural:
            guard samples.count >= Int(sampleRate * 0.5) else { return nil }

            // P0-3: 品質ゲート — 音声品質が不十分ならスキップ
            let quality = AudioQualityEvaluator.evaluate(samples: samples, sampleRate: sampleRate)
            if !quality.isSufficientForInference {
                let reasons = quality.failureReasons.joined(separator: ", ")
                onLog?("🔇 音声品質不足でスキップ: \(reasons)")
                return nil
            }

            return embeddingModel.extractEmbedding(from: samples, sampleRate: sampleRate)
        case .mfcc:
            guard samples.count >= fftSize else { return nil }
            return extractFullFeatures(from: samples)
        }
    }

    /// 話者プロファイルを登録/更新（品質検査付き: P0-2）
    func enroll(speaker: String, features: [Float]) {
        guard features.count == featureDimension else { return }

        if var existing = profiles[speaker] {
            let alpha: Float = 2.0 / Float(min(existing.sampleCount + 2, 20))
            var updated = existing.features
            for i in 0..<featureDimension {
                updated[i] = updated[i] * (1 - alpha) + features[i] * alpha
            }

            if mode == .neural {
                updated = l2Normalize(updated)
            }

            existing.features = updated
            existing.sampleCount += 1
            profiles[speaker] = existing
            onLog?("🎤 声紋更新: \(speaker)（サンプル\(existing.sampleCount)）")
        } else {
            profiles[speaker] = VoiceProfile(name: speaker, features: features, sampleCount: 1, mode: mode)
            onLog?("🎤 声紋登録: \(speaker)")
        }

        switch mode {
        case .neural:
            onLog?("   📊 ECAPA-TDNN 埋め込み \(featureDimension)次元")
        case .mfcc:
            let pitchIdx = numMFCC * 3
            let meanF0 = features[pitchIdx] * (pitchNormMax - pitchNormMin) + pitchNormMin
            let stdF0 = features[pitchIdx + 1] * (pitchNormMax - pitchNormMin)
            onLog?("   📊 ピッチ: 平均\(String(format: "%.0f", meanF0))Hz, 標準偏差\(String(format: "%.0f", stdF0))Hz")
        }

        // 登録後に他プロファイルとの距離を警告
        if mode == .neural {
            for (otherName, otherProfile) in profiles where otherName != speaker && otherProfile.mode == .neural {
                let sim = cosineSimilarity(features, otherProfile.features)
                if sim > 0.85 {
                    onLog?("⚠️ 登録警告: \(speaker)と\(otherName)の類似度が\(String(format: "%.3f", sim))で高すぎます")
                }
            }
        }

        saveProfiles()
    }

    /// 品質検査付き enrollment（P0-2完全版）
    /// 12秒の生音声から品質チェック → embedding自己一貫性チェック → enroll
    func enrollWithQualityCheck(speaker: String, samples: [Float]) -> (success: Bool, message: String) {
        // Step 1: 基本品質チェック
        let quality = AudioQualityEvaluator.evaluate(samples: samples, sampleRate: sampleRate)
        if !quality.isSufficientForEnrollment {
            let reasons = quality.enrollmentFailureReasons.joined(separator: "\n")
            onLog?("❌ 登録品質不足: \(speaker)\n\(reasons)")
            return (false, "登録品質が不十分です:\n\(reasons)")
        }

        onLog?("📊 登録品質: RMS=\(String(format: "%.4f", quality.averageRMS)) 有声率=\(String(format: "%.0f%%", quality.voicedRatio * 100)) 有効\(String(format: "%.1f", quality.effectiveDuration))秒")

        // Step 2: embedding 自己一貫性チェック（ニューラルモード時）
        if mode == .neural {
            if let consistency = AudioQualityEvaluator.evaluateEmbeddingConsistency(
                samples: samples,
                sampleRate: sampleRate,
                extractEmbedding: { [weak self] window in
                    self?.embeddingModel.extractEmbedding(from: window, sampleRate: self?.sampleRate ?? 44100)
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

        // Step 3: 特徴量抽出 & 登録
        guard let features = embeddingModel.extractEmbedding(from: samples, sampleRate: sampleRate) else {
            return (false, "特徴量の抽出に失敗しました")
        }

        enroll(speaker: speaker, features: features)

        // ピッチ統計も登録（複合判定用）
        enrollPitchStats(speaker: speaker, samples: samples)

        return (true, "登録完了！品質: RMS=\(String(format: "%.3f", quality.averageRMS)) 有声率=\(String(format: "%.0f%%", quality.voicedRatio * 100))")
    }

    /// 直近の識別に使った生音声サンプル（ピッチ複合判定用）
    private var lastIdentifySamples: [Float]?

    /// 識別前に生音声をセットする（ピッチ複合判定で使用）
    func setRawSamplesForNextIdentify(_ samples: [Float]) {
        lastIdentifySamples = samples
    }

    /// 音声特徴量から最も近い話者を推定
    func identify(features: [Float]) -> (speaker: String, confidence: Float)? {
        guard features.count == featureDimension else { return nil }
        guard !profiles.isEmpty else { return nil }

        switch mode {
        case .neural:
            return identifyNeural(features: features)?.result
        case .mfcc:
            return identifyMFCC(features: features)
        }
    }

    /// 確信度レベル付きの識別（ニューラルモード用）
    func identifyWithConfidence(features: [Float]) -> (speaker: String, confidence: Float, level: IdentifyConfidence)? {
        guard features.count == featureDimension else { return nil }
        guard !profiles.isEmpty else { return nil }
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

    private let maxAdaptiveUpdates = 100

    /// 最後の適応学習診断情報（P1-3）
    private(set) var lastAdaptiveRejectedReason: String?

    func adaptiveUpdate(speaker: String, features: [Float]) {
        lastAdaptiveRejectedReason = nil
        guard features.count == featureDimension else { return }
        guard var profile = profiles[speaker] else { return }
        guard profile.mode == mode else { return }

        // 適応学習回数の上限チェック
        if profile.sampleCount > maxAdaptiveUpdates {
            lastAdaptiveRejectedReason = "max_updates_exceeded"
            return
        }

        // 確信度チェック
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

        if mode == .neural {
            updated = l2Normalize(updated)
        }

        // ドリフトガード
        if mode == .neural {
            for (otherName, otherProfile) in profiles where otherName != speaker && otherProfile.mode == .neural {
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
        profiles[speaker] = profile

        if profile.sampleCount % 50 == 0 {
            onLog?("🔄 声紋適応更新: \(speaker)（累計\(profile.sampleCount)サンプル）")
            saveProfiles()
        }
    }

    // MARK: - ニューラル識別（構造化ログ付き）

    private func identifyNeural(features: [Float]) -> (result: (speaker: String, confidence: Float), level: IdentifyConfidence)? {
        var results: [(name: String, similarity: Float)] = []

        for (name, profile) in profiles {
            guard profile.mode == .neural else { continue }
            let sim = cosineSimilarity(features, profile.features)
            results.append((name, sim))
        }

        guard !results.isEmpty else { return nil }
        results.sort { $0.similarity > $1.similarity }

        let scoreStr = results.map { "\($0.name):\(String(format: "%.3f", $0.similarity))" }.joined(separator: " ")
        onLog?("🔍 声紋照合(neural): \(scoreStr)")

        let best = results[0]
        let second: (name: String, similarity: Float)? = results.count >= 2 ? results[1] : nil
        let margin = second != nil ? best.similarity - second!.similarity : Float(1.0)

        // --- 判定ロジック ---
        var decisionType: String
        var finalDecision: String
        var unknownReason: UnknownReason? = nil
        var returnValue: (result: (speaker: String, confidence: Float), level: IdentifyConfidence)? = nil

        // --- ピッチ複合スコアリング ---
        // マージンが不十分な場合、ピッチ一致度でリスコアリング
        var pitchAdjustedResults = results
        var pitchUsed = false
        if let rawSamples = lastIdentifySamples, results.count >= 2, margin < similarityMargin {
            var pitchScores: [String: Float] = [:]
            for r in results {
                if let profile = profiles[r.name], profile.pitchMean != nil {
                    pitchScores[r.name] = pitchMatchScore(samples: rawSamples, profile: profile) ?? 0.5
                }
            }
            // ピッチスコアが取得できた場合、複合スコア = 0.7*embedding + 0.3*pitch
            if pitchScores.count >= 2 {
                pitchUsed = true
                pitchAdjustedResults = results.map { r in
                    let pitchScore = pitchScores[r.name] ?? 0.5
                    let combined = r.similarity * 0.7 + pitchScore * 0.3
                    return (r.name, combined)
                }
                pitchAdjustedResults.sort { $0.similarity > $1.similarity }

                let pitchStr = pitchScores.map { "\($0.key):\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
                onLog?("🎵 ピッチ補正: \(pitchStr)")
            }
        }
        lastIdentifySamples = nil  // 使い終わったらクリア

        // ピッチ補正後のbest/secondを使って判定
        let effectiveBest = pitchUsed ? pitchAdjustedResults[0] : best
        let effectiveSecond: (name: String, similarity: Float)? = pitchAdjustedResults.count >= 2 ? pitchAdjustedResults[1] : nil
        let effectiveMargin = effectiveSecond != nil ? effectiveBest.similarity - effectiveSecond!.similarity : Float(1.0)

        if best.similarity < minSimilarity {
            // 全員低すぎ（元のembeddingスコアで判断）
            decisionType = "unknown"
            finalDecision = "不明"
            unknownReason = .belowMinSimilarity
            addVote(speaker: "不明", score: 0)
        } else if results.count <= 1 || effectiveMargin >= similarityMargin {
            // 厳格マージン OK or 1人のみ（ピッチ補正後のマージンで判断）
            decisionType = pitchUsed ? "strict+pitch" : "strict"
            finalDecision = effectiveBest.name
            addVote(speaker: effectiveBest.name, score: best.similarity)
            returnValue = ((effectiveBest.name, best.similarity), pitchUsed ? .estimated : .strict)
        } else if effectiveMargin >= softMargin {
            // ソフトマージン → 多数決候補
            decisionType = "soft"
            addVote(speaker: effectiveBest.name, score: best.similarity)
            onLog?("⚠️ マージン不足: \(effectiveBest.name)(\(String(format: "%.3f", effectiveBest.similarity))) vs \(effectiveSecond!.name)(\(String(format: "%.3f", effectiveSecond!.similarity))) margin=\(String(format: "%.3f", effectiveMargin))")

            if let voted = resolveByVoting() {
                decisionType = "voted"
                finalDecision = voted.speaker
                onLog?("🗳 多数決で判定: \(voted.speaker)（\(voted.count)/\(votingWindowSize)票）")
                returnValue = ((voted.speaker, best.similarity), .estimated)
            } else {
                finalDecision = "不明"
                unknownReason = .voteNotConverged
            }
        } else {
            // マージンが極めて小さい
            decisionType = "unknown"
            finalDecision = "不明"
            unknownReason = .belowMargin
            addVote(speaker: "不明", score: 0)
            onLog?("⚠️ マージン不足: \(effectiveBest.name)(\(String(format: "%.3f", effectiveBest.similarity))) vs \(effectiveSecond!.name)(\(String(format: "%.3f", effectiveSecond!.similarity))) margin=\(String(format: "%.3f", effectiveMargin))")
        }

        // --- 構造化ログ出力（P0-1）---
        if diagnosticsEnabled {
            let event = IdentificationDebugEvent(
                timestamp: Date(),
                mode: "neural",
                topSpeaker: best.name,
                topSimilarity: best.similarity,
                secondSpeaker: second?.name,
                secondSimilarity: second?.similarity,
                margin: margin,
                decisionType: decisionType,
                recentVotes: recentVotes.map { $0.speaker },
                finalDecision: finalDecision,
                unknownReason: unknownReason?.rawValue,
                adaptiveUpdated: false,  // 呼び出し側で設定
                adaptiveRejectedReason: nil,
                inputQuality: nil
            )
            writeDiagnosticEvent(event)
        }

        return returnValue
    }

    // MARK: - Temporal Voting（P1-2改良版）

    /// 直前の1位話者を追跡
    private var lastTopSpeaker: String = ""
    /// 話者切替候補カウンター（P1-2: 2回連続で確認してからリセット）
    private var switchCandidateCount = 0
    private var switchCandidateSpeaker: String = ""

    private func addVote(speaker: String, score: Float) {
        // P1-2改良: 即座にリセットせず、2回連続で新しい話者が来たらリセット
        if speaker != "不明" && speaker != lastTopSpeaker && !lastTopSpeaker.isEmpty {
            if speaker == switchCandidateSpeaker {
                switchCandidateCount += 1
            } else {
                switchCandidateSpeaker = speaker
                switchCandidateCount = 1
            }

            // 2回連続で異なる話者 → 本当の話者交代と判定してリセット
            if switchCandidateCount >= 2 {
                recentVotes.removeAll()
                lastTopSpeaker = speaker
                switchCandidateCount = 0
                switchCandidateSpeaker = ""
                onLog?("🔄 話者交代検出: → \(speaker)")
            }
        } else if speaker != "不明" {
            lastTopSpeaker = speaker
            switchCandidateCount = 0
            switchCandidateSpeaker = ""
        }

        recentVotes.append((speaker: speaker, score: score))
        if recentVotes.count > votingWindowSize {
            recentVotes.removeFirst()
        }
    }

    private func resolveByVoting() -> (speaker: String, count: Int)? {
        guard recentVotes.count >= votingMinCount else { return nil }

        var counts: [String: Int] = [:]
        for vote in recentVotes where vote.speaker != "不明" {
            counts[vote.speaker, default: 0] += 1
        }

        guard let winner = counts.max(by: { $0.value < $1.value }),
              winner.value >= votingMinCount else {
            return nil
        }

        return (speaker: winner.key, count: winner.value)
    }

    func clearVotingHistory() {
        recentVotes.removeAll()
        lastTopSpeaker = ""
        switchCandidateCount = 0
        switchCandidateSpeaker = ""
    }

    // MARK: - プロファイル診断（P1-4: 任意タイミングで実行可能）

    /// 登録済みプロファイル間のコサイン類似度を診断ログに出力
    func diagnoseProfiles() {
        guard mode == .neural else { return }
        let names = Array(profiles.keys).sorted()
        guard names.count >= 2 else {
            onLog?("📊 プロファイル診断: 登録者\(names.count)名（比較不要）")
            return
        }

        onLog?("📊 === プロファイル間類似度診断 ===")
        for i in 0..<names.count {
            for j in (i+1)..<names.count {
                guard let p1 = profiles[names[i]], let p2 = profiles[names[j]] else { continue }
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
            if let p = profiles[names[i]] {
                let pitchStr = p.pitchMean != nil ? ", ピッチ=\(String(format: "%.0f", p.pitchMean!))Hz±\(String(format: "%.0f", p.pitchStd ?? 0))Hz" : ""
                onLog?("   \(names[i]): サンプル数=\(p.sampleCount), 適応学習残り=\(max(0, maxAdaptiveUpdates - p.sampleCount))回\(pitchStr)")
            }
        }
        onLog?("📊 ========================")
    }

    /// プロファイルの健全性サマリーを返す（UIに表示用）
    func profileHealthSummary() -> [(speaker: String, sampleCount: Int, nearestOther: String?, nearestSimilarity: Float?)] {
        var summary: [(speaker: String, sampleCount: Int, nearestOther: String?, nearestSimilarity: Float?)] = []
        for (name, profile) in profiles {
            var nearest: (String, Float)? = nil
            for (otherName, otherProfile) in profiles where otherName != name {
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

    // MARK: - MFCCモード識別

    private func identifyMFCC(features: [Float]) -> (speaker: String, confidence: Float)? {
        var results: [(name: String, distance: Float)] = []

        for (name, profile) in profiles {
            let dist = euclideanDistance(features, profile.features)
            results.append((name, dist))
        }

        results.sort { $0.distance < $1.distance }

        let scoreStr = results.map { "\($0.name):\(String(format: "%.2f", $0.distance))" }.joined(separator: " ")
        onLog?("🔍 声紋照合(mfcc): \(scoreStr)")

        guard let best = results.first, best.distance <= maxDistance else {
            return nil
        }

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

    // MARK: - プロファイル管理

    var registeredSpeakers: [String] {
        Array(profiles.keys)
    }

    func clearProfile(for speaker: String) {
        profiles.removeValue(forKey: speaker)
        saveProfiles()
    }

    func clearAllProfiles() {
        profiles.removeAll()
        clearVotingHistory()
        saveProfiles()
    }

    // MARK: - 構造化診断ログ出力（P0-1: JSONL）

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

    private func writeDiagnosticEvent(_ event: IdentificationDebugEvent) {
        guard diagnosticsEnabled else { return }
        guard let data = try? diagnosticsEncoder.encode(event),
              let line = String(data: data, encoding: .utf8) else { return }

        let lineWithNewline = line + "\n"
        if let handle = try? FileHandle(forWritingTo: diagnosticsURL) {
            handle.seekToEndOfFile()
            handle.write(lineWithNewline.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? lineWithNewline.write(to: diagnosticsURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 特徴量抽出（MFCC 39次元）— フォールバック用

    private func extractFullFeatures(from samples: [Float]) -> [Float]? {
        let numFrames = (samples.count - fftSize) / hopSize + 1
        guard numFrames > 0 else { return nil }

        var allMFCCs = [[Float]]()
        var pitchValues = [Float]()

        for frameIdx in 0..<numFrames {
            let start = frameIdx * hopSize
            let frame = Array(samples[start..<start + fftSize])

            let windowed = applyHammingWindow(frame)
            guard let powerSpectrum = computePowerSpectrum(windowed) else { continue }
            let melEnergies = applyMelFilterBank(powerSpectrum)
            let logMelEnergies = melEnergies.map { logf(max($0, 1e-10)) }
            let mfccFull = applyDCT(logMelEnergies)
            let mfcc = Array(mfccFull[mfccStart..<numMFCCRaw])
            allMFCCs.append(mfcc)

            if let f0 = estimatePitch(frame) {
                pitchValues.append(f0)
            }
        }

        guard allMFCCs.count >= 2 else { return nil }

        let count = Float(allMFCCs.count)

        var mean = [Float](repeating: 0, count: numMFCC)
        for mfcc in allMFCCs {
            for i in 0..<numMFCC { mean[i] += mfcc[i] }
        }
        for i in 0..<numMFCC { mean[i] /= count }

        var std = [Float](repeating: 0, count: numMFCC)
        for mfcc in allMFCCs {
            for i in 0..<numMFCC {
                let diff = mfcc[i] - mean[i]
                std[i] += diff * diff
            }
        }
        for i in 0..<numMFCC { std[i] = sqrtf(std[i] / count) }

        var deltaMean = [Float](repeating: 0, count: numMFCC)
        for f in 1..<allMFCCs.count {
            for i in 0..<numMFCC { deltaMean[i] += allMFCCs[f][i] - allMFCCs[f - 1][i] }
        }
        let deltaCount = Float(allMFCCs.count - 1)
        for i in 0..<numMFCC { deltaMean[i] /= deltaCount }

        var pitchMean: Float = 0
        var pitchStd: Float = 0
        var pitchRange: Float = 0

        if pitchValues.count >= 2 {
            let pSum = pitchValues.reduce(0, +)
            pitchMean = pSum / Float(pitchValues.count)

            var pVarSum: Float = 0
            for p in pitchValues { pVarSum += (p - pitchMean) * (p - pitchMean) }
            pitchStd = sqrtf(pVarSum / Float(pitchValues.count))

            let pMin = pitchValues.min() ?? 0
            let pMax = pitchValues.max() ?? 0
            pitchRange = pMax - pMin

            pitchMean = (pitchMean - pitchNormMin) / (pitchNormMax - pitchNormMin)
            pitchStd = pitchStd / (pitchNormMax - pitchNormMin)
            pitchRange = pitchRange / (pitchNormMax - pitchNormMin)
        }

        let pitchWeight: Float = 5.0
        let pitchFeatures = [pitchMean * pitchWeight, pitchStd * pitchWeight, pitchRange * pitchWeight]

        return mean + std + deltaMean + pitchFeatures
    }

    // MARK: - ピッチ統計計算（複合判定用）

    /// 音声サンプルからピッチ統計（平均F0, 標準偏差）を計算
    func computePitchStats(from samples: [Float]) -> (mean: Float, std: Float)? {
        let frameSize = 2048
        let hopSize = 512
        var pitches: [Float] = []

        var i = 0
        while i + frameSize <= samples.count {
            let frame = Array(samples[i..<(i + frameSize)])
            if let f0 = estimatePitch(frame) {
                pitches.append(f0)
            }
            i += hopSize
        }

        guard pitches.count >= 3 else { return nil }  // 最低3フレーム必要

        let mean = pitches.reduce(0, +) / Float(pitches.count)
        let variance = pitches.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(pitches.count)
        let std = sqrtf(variance)

        return (mean, std)
    }

    /// 登録時にピッチ統計も保存
    func enrollPitchStats(speaker: String, samples: [Float]) {
        guard var profile = profiles[speaker] else { return }

        if let stats = computePitchStats(from: samples) {
            if let existingMean = profile.pitchMean {
                // EMAでブレンド
                let alpha: Float = 0.3
                profile.pitchMean = existingMean * (1 - alpha) + stats.mean * alpha
                profile.pitchStd = (profile.pitchStd ?? stats.std) * (1 - alpha) + stats.std * alpha
            } else {
                profile.pitchMean = stats.mean
                profile.pitchStd = stats.std
            }
            profiles[speaker] = profile
            onLog?("   🎵 ピッチ: 平均\(String(format: "%.0f", profile.pitchMean!))Hz, 標準偏差\(String(format: "%.0f", profile.pitchStd!))Hz")
            saveProfiles()
        }
    }

    /// リアルタイム音声からピッチスコアを計算（0.0-1.0、高いほど一致）
    private func pitchMatchScore(samples: [Float], profile: VoiceProfile) -> Float? {
        guard let profileMean = profile.pitchMean,
              let profileStd = profile.pitchStd else { return nil }

        guard let currentStats = computePitchStats(from: samples) else { return nil }

        // 平均ピッチの差をプロファイルのstdでスケーリング
        let diff = abs(currentStats.mean - profileMean)
        let tolerance = max(profileStd * 2.0, 30.0)  // 最低30Hz幅の許容

        // ガウシアンスコア: exp(-diff^2 / (2*tolerance^2))
        let score = expf(-(diff * diff) / (2 * tolerance * tolerance))
        return score
    }

    // MARK: - ピッチ推定（自己相関法）

    private func estimatePitch(_ frame: [Float]) -> Float? {
        let n = frame.count

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(n))
        guard rms > 0.01 else { return nil }

        let minLag = Int(sampleRate / pitchMaxFreq)
        let maxLag = Int(sampleRate / pitchMinFreq)
        guard maxLag < n else { return nil }

        var bestLag = 0
        var bestCorr: Float = -1

        for lag in minLag...maxLag {
            let length = n - lag

            var corr: Float = 0
            var n1: Float = 0
            var n2: Float = 0
            frame.withUnsafeBufferPointer { buf1 in
                let ptr1 = buf1.baseAddress!
                let ptr2 = ptr1.advanced(by: lag)
                vDSP_dotpr(ptr1, 1, ptr2, 1, &corr, vDSP_Length(length))
                vDSP_dotpr(ptr1, 1, ptr1, 1, &n1, vDSP_Length(length))
                vDSP_dotpr(ptr2, 1, ptr2, 1, &n2, vDSP_Length(length))
            }

            let denom = sqrtf(n1 * n2)
            guard denom > 0 else { continue }
            let correlation = corr / denom

            if correlation > bestCorr {
                bestCorr = correlation
                bestLag = lag
            }
        }

        guard bestCorr > 0.3, bestLag > 0 else { return nil }

        let f0 = sampleRate / Float(bestLag)
        return f0
    }

    // MARK: - 信号処理ヘルパー

    private func applyHammingWindow(_ frame: [Float]) -> [Float] {
        var result = frame
        let n = Float(frame.count)
        for i in 0..<frame.count {
            let w = 0.54 - 0.46 * cosf(2 * .pi * Float(i) / (n - 1))
            result[i] *= w
        }
        return result
    }

    private func computePowerSpectrum(_ frame: [Float]) -> [Float]? {
        let n = frame.count
        let halfN = n / 2
        let log2n = vDSP_Length(log2f(Float(n)))

        guard let setup = fftSetup else { return nil }

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        frame.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
                vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
            }
        }

        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

        var power = [Float](repeating: 0, count: halfN)
        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfN))

        var scale = Float(n * n)
        vDSP_vsdiv(power, 1, &scale, &power, 1, vDSP_Length(halfN))

        return power
    }

    // MARK: - メルフィルタバンク

    private func hzToMel(_ hz: Float) -> Float {
        return 2595 * log10f(1 + hz / 700)
    }

    private func melToHz(_ mel: Float) -> Float {
        return 700 * (powf(10, mel / 2595) - 1)
    }

    private func buildMelFilterBank() -> [[Float]] {
        let halfN = fftSize / 2
        let melLow = hzToMel(melLowFreq)
        let melHigh = hzToMel(melHighFreq)

        var melPoints = [Float]()
        for i in 0...(numMelBands + 1) {
            let mel = melLow + Float(i) * (melHigh - melLow) / Float(numMelBands + 1)
            melPoints.append(mel)
        }

        let binPoints = melPoints.map { mel -> Int in
            let hz = melToHz(mel)
            return Int(floorf(hz * Float(fftSize) / sampleRate))
        }

        var filterBank = [[Float]]()
        for m in 1...numMelBands {
            var filter = [Float](repeating: 0, count: halfN)
            let left = binPoints[m - 1]
            let center = binPoints[m]
            let right = binPoints[m + 1]

            for k in left..<center where k < halfN {
                filter[k] = Float(k - left) / Float(max(center - left, 1))
            }
            for k in center..<right where k < halfN {
                filter[k] = Float(right - k) / Float(max(right - center, 1))
            }
            filterBank.append(filter)
        }

        return filterBank
    }

    private func applyMelFilterBank(_ powerSpectrum: [Float]) -> [Float] {
        return melFilterBank.map { filter in
            var sum: Float = 0
            vDSP_dotpr(filter, 1, powerSpectrum, 1, &sum, vDSP_Length(min(filter.count, powerSpectrum.count)))
            return sum
        }
    }

    // MARK: - DCT

    private func buildDCTMatrix() -> [[Float]] {
        var matrix = [[Float]]()
        for k in 0..<numMFCCRaw {
            var row = [Float]()
            for n in 0..<numMelBands {
                let val = cosf(.pi * Float(k) * (Float(n) + 0.5) / Float(numMelBands))
                row.append(val)
            }
            matrix.append(row)
        }
        return matrix
    }

    private func applyDCT(_ logMelEnergies: [Float]) -> [Float] {
        return dctMatrix.map { row in
            var sum: Float = 0
            vDSP_dotpr(row, 1, logMelEnergies, 1, &sum, vDSP_Length(min(row.count, logMelEnergies.count)))
            return sum
        }
    }

    // MARK: - 距離・類似度計算

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    private func l2Normalize(_ vec: [Float]) -> [Float] {
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
        if let json = try? JSONSerialization.data(withJSONObject: data),
           let str = String(data: json, encoding: .utf8) {
            try? str.write(to: profilesURL, atomically: true, encoding: .utf8)
        }
    }

    func loadProfiles() {
        guard let data = try? Data(contentsOf: profilesURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        for item in arr {
            guard let name = item["name"] as? String,
                  let count = item["sampleCount"] as? Int else { continue }

            let profileMode: Mode = (item["mode"] as? String) == "neural" ? .neural : .mfcc
            let pitchMean = (item["pitchMean"] as? Double).map { Float($0) }
            let pitchStd = (item["pitchStd"] as? Double).map { Float($0) }

            if let feats = item["features"] as? [Double], feats.count == featureDimension, profileMode == mode {
                profiles[name] = VoiceProfile(
                    name: name,
                    features: feats.map { Float($0) },
                    sampleCount: count,
                    mode: profileMode,
                    pitchMean: pitchMean,
                    pitchStd: pitchStd
                )
            } else {
                onLog?("⚠️ \(name) の声紋は現在のモード(\(mode == .neural ? "neural" : "mfcc"))と互換性がないため再登録が必要です")
            }
        }
        if !profiles.isEmpty {
            onLog?("🎤 声紋プロファイル読み込み(\(mode == .neural ? "neural" : "mfcc")): \(profiles.keys.joined(separator: ", "))")
            diagnoseProfiles()
        }
    }

    func resetAdaptiveLearning(for speaker: String) {
        guard var profile = profiles[speaker] else { return }
        profile.sampleCount = 1
        profiles[speaker] = profile
        saveProfiles()
        onLog?("🔄 \(speaker)の適応学習カウンターをリセット")
    }
}
