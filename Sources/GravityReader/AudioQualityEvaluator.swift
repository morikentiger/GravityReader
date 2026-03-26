import Foundation
import Accelerate

/// 音声品質を評価するユーティリティ（enrollment / inference 共通）
struct AudioQualityEvaluator {

    // MARK: - 品質レポート

    struct QualityReport {
        let averageRMS: Float
        let voicedRatio: Float        // 有声フレーム率 (0.0 〜 1.0)
        let clippingRatio: Float      // クリッピング率 (0.0 〜 1.0)
        let effectiveDuration: Float  // 有効音声の秒数
        let totalDuration: Float      // 全体の秒数

        /// 品質が inference に十分かどうか
        var isSufficientForInference: Bool {
            averageRMS >= 0.005 &&
            voicedRatio >= 0.15 &&
            effectiveDuration >= 0.3
        }

        /// 品質が enrollment に十分かどうか（inference より厳格）
        var isSufficientForEnrollment: Bool {
            averageRMS >= 0.01 &&
            voicedRatio >= 0.25 &&
            effectiveDuration >= 2.0 &&
            clippingRatio <= 0.05
        }

        /// 不合格理由を日本語で返す
        var failureReasons: [String] {
            var reasons: [String] = []
            if averageRMS < 0.005 { reasons.append("音が小さすぎます（RMS: \(String(format: "%.4f", averageRMS))）") }
            if voicedRatio < 0.15 { reasons.append("無声音が多すぎます（有声率: \(String(format: "%.0f%%", voicedRatio * 100))）") }
            if effectiveDuration < 0.3 { reasons.append("有効な音声が短すぎます（\(String(format: "%.1f", effectiveDuration))秒）") }
            if clippingRatio > 0.05 { reasons.append("クリッピングが多すぎます（\(String(format: "%.1f%%", clippingRatio * 100))）") }
            return reasons
        }

        /// enrollment 用の不合格理由（より厳格）
        var enrollmentFailureReasons: [String] {
            var reasons: [String] = []
            if averageRMS < 0.01 { reasons.append("音が小さすぎます（RMS: \(String(format: "%.4f", averageRMS))）") }
            if voicedRatio < 0.25 { reasons.append("無声音が多すぎます（有声率: \(String(format: "%.0f%%", voicedRatio * 100))）") }
            if effectiveDuration < 2.0 { reasons.append("有効な音声が短すぎます（\(String(format: "%.1f", effectiveDuration))秒）") }
            if clippingRatio > 0.05 { reasons.append("クリッピングが多すぎます（\(String(format: "%.1f%%", clippingRatio * 100))）") }
            return reasons
        }
    }

    // MARK: - 評価

    /// 音声サンプルの品質を評価する
    static func evaluate(samples: [Float], sampleRate: Float = 44100) -> QualityReport {
        let totalDuration = Float(samples.count) / sampleRate
        guard !samples.isEmpty else {
            return QualityReport(averageRMS: 0, voicedRatio: 0, clippingRatio: 0,
                                 effectiveDuration: 0, totalDuration: 0)
        }

        // 平均RMS
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

        // クリッピング率（|sample| > 0.99 のサンプル数）
        let clippedCount = samples.filter { abs($0) > 0.99 }.count
        let clippingRatio = Float(clippedCount) / Float(samples.count)

        // フレームごとの有声判定
        let frameSize = Int(sampleRate * 0.025)  // 25ms
        let hopSize = Int(sampleRate * 0.010)    // 10ms
        let numFrames = max(1, (samples.count - frameSize) / hopSize + 1)
        var voicedFrames = 0

        for frameIdx in 0..<numFrames {
            let start = frameIdx * hopSize
            let end = min(start + frameSize, samples.count)
            let frame = Array(samples[start..<end])

            if isVoicedFrame(frame) {
                voicedFrames += 1
            }
        }

        let voicedRatio = Float(voicedFrames) / Float(numFrames)
        let effectiveDuration = totalDuration * voicedRatio

        return QualityReport(
            averageRMS: rms,
            voicedRatio: voicedRatio,
            clippingRatio: clippingRatio,
            effectiveDuration: effectiveDuration,
            totalDuration: totalDuration
        )
    }

    // MARK: - Private

    /// 簡易有声フレーム判定（RMS + ゼロ交差率）
    private static func isVoicedFrame(_ frame: [Float]) -> Bool {
        guard frame.count > 1 else { return false }

        // RMS チェック
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
        guard rms > 0.008 else { return false }

        // ゼロ交差率（有声音は低い、無声摩擦音は高い）
        var zeroCrossings = 0
        for i in 1..<frame.count {
            if (frame[i] >= 0) != (frame[i-1] >= 0) {
                zeroCrossings += 1
            }
        }
        let zcr = Float(zeroCrossings) / Float(frame.count - 1)

        // 有声音: RMS高め + ゼロ交差率低め
        return rms > 0.008 && zcr < 0.3
    }

    // MARK: - Enrollment 品質チェック（embedding 自己一貫性）

    /// 12秒の録音を3秒窓に分割し、各窓の埋め込み間類似度で登録品質を評価
    /// 返り値: (平均類似度, 最小類似度, 窓数)
    static func evaluateEmbeddingConsistency(
        samples: [Float],
        sampleRate: Float = 44100,
        extractEmbedding: ([Float]) -> [Float]?
    ) -> (meanSimilarity: Float, minSimilarity: Float, windowCount: Int)? {

        let windowSamples = Int(sampleRate * 3.0)  // 3秒窓
        let hopSamples = Int(sampleRate * 1.5)     // 1.5秒ホップ（オーバーラップ50%）
        guard samples.count >= windowSamples else { return nil }

        var embeddings: [[Float]] = []

        var start = 0
        while start + windowSamples <= samples.count {
            let window = Array(samples[start..<start + windowSamples])
            if let emb = extractEmbedding(window) {
                embeddings.append(emb)
            }
            start += hopSamples
        }

        guard embeddings.count >= 2 else { return nil }

        // 全ペアのコサイン類似度
        var similarities: [Float] = []
        for i in 0..<embeddings.count {
            for j in (i+1)..<embeddings.count {
                var dot: Float = 0
                vDSP_dotpr(embeddings[i], 1, embeddings[j], 1, &dot, vDSP_Length(embeddings[i].count))
                similarities.append(dot)
            }
        }

        guard !similarities.isEmpty else { return nil }

        let mean = similarities.reduce(0, +) / Float(similarities.count)
        let minSim = similarities.min() ?? 0

        return (meanSimilarity: mean, minSimilarity: minSim, windowCount: embeddings.count)
    }
}
