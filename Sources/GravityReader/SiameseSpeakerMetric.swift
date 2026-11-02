import Foundation

/// A locally trained Siamese metric head on top of the frozen ECAPA encoder.
/// Both branches share f(x) = normalize(diag(scales) * x). Only explicit,
/// human-labelled enrollment sessions may be supplied; predictions are not labels.
enum SiameseSpeakerMetric {
    struct Observation: Codable, Equatable {
        let speaker: String
        let sessionID: String
        let embedding: [Float]
    }

    struct Validation: Codable, Equatable {
        let trainingSessions: Int
        let validationSessions: Int
        let positivePairs: Int
        let negativePairs: Int
        let falseAcceptRate: Float
        let falseRejectRate: Float
        let baselineFalseAcceptRate: Float
        let baselineFalseRejectRate: Float
        let contrastiveLoss: Float
        let baselineContrastiveLoss: Float
    }

    struct Model: Codable, Equatable {
        let version: Int
        let dimension: Int
        let scales: [Float]
        let similarityThreshold: Float
        let similarityMargin: Float
        let validation: Validation

        var isValid: Bool {
            version == 1 && (2...192).contains(dimension) && scales.count == dimension
                && scales.allSatisfy { $0.isFinite && (0.25...4).contains($0) }
                && similarityThreshold.isFinite && (0.45...0.98).contains(similarityThreshold)
                && similarityMargin.isFinite && (0.06...0.15).contains(similarityMargin)
                && validation.trainingSessions >= 4 && validation.validationSessions >= 4
                && validation.positivePairs >= 2 && validation.negativePairs >= 4
                && [validation.falseAcceptRate, validation.falseRejectRate,
                    validation.baselineFalseAcceptRate, validation.baselineFalseRejectRate].allSatisfy { $0.isFinite && (0...1).contains($0) }
                && validation.contrastiveLoss.isFinite && validation.contrastiveLoss >= 0
                && validation.baselineContrastiveLoss.isFinite && validation.baselineContrastiveLoss >= 0
                && validation.falseAcceptRate == 0
                && validation.falseRejectRate <= validation.baselineFalseRejectRate
                && validation.contrastiveLoss + 0.001 < validation.baselineContrastiveLoss
        }

        func similarity(_ a: [Float], _ b: [Float]) -> Float? {
            guard isValid, let a = normalized(a, dimension: dimension),
                  let b = normalized(b, dimension: dimension) else { return nil }
            return score(a, b, scales: scales)
        }
    }

    enum TrainingResult {
        case ready(Model)
        case notReady(String)
        case rejected(String)
    }

    private struct Session {
        let speaker: String
        let id: String
        let vector: [Float]
    }
    private struct Pair {
        let a: [Float]
        let b: [Float]
        let same: Bool
    }

    static func train(observations: [Observation], dimension: Int = 192) -> TrainingResult {
        guard (2...192).contains(dimension) else { return .rejected("埋め込み次元が不正です") }
        guard observations.count <= 2048 else { return .rejected("学習サンプルの上限を超えています") }
        guard observations.allSatisfy({ !$0.speaker.isEmpty && !$0.sessionID.isEmpty && normalized($0.embedding, dimension: dimension) != nil }) else {
            return .rejected("空のラベル・不正な埋め込みを含むため学習を中止しました")
        }
        let grouped = Dictionary(grouping: observations, by: \.sessionID)
        guard grouped.values.allSatisfy({ Set($0.map(\.speaker)).count == 1 }) else {
            return .rejected("同じ登録セッションに複数の話者ラベルがあります")
        }
        // Repeated windows in one recording never become independent holdout data.
        var sessions: [Session] = []
        for id in grouped.keys.sorted() {
            let rows = Array(grouped[id]!.prefix(8))
            var centroid = [Float](repeating: 0, count: dimension)
            for row in rows {
                let vector = normalized(row.embedding, dimension: dimension)!
                for i in 0..<dimension { centroid[i] += vector[i] / Float(rows.count) }
            }
            guard let vector = normalized(centroid, dimension: dimension) else { continue }
            sessions.append(Session(speaker: rows[0].speaker, id: id, vector: vector))
        }
        let speakers = Dictionary(grouping: sessions, by: \.speaker)
        guard speakers.count >= 2 else { return .notReady("2人以上の明示的な声紋登録が必要です") }
        guard speakers.count <= 16 else { return .notReady("一度に学習できる話者は16人までです") }
        guard speakers.values.allSatisfy({ $0.count >= 4 }) else {
            return .notReady("各話者につき別々の登録録音が4回必要です（学習2回・検証2回以上）")
        }
        var training: [Session] = []
        var validation: [Session] = []
        for speaker in speakers.keys.sorted() {
            let selected = Array(speakers[speaker]!.sorted { $0.id < $1.id }.suffix(12))
            training += selected.dropLast(2)
            validation += selected.suffix(2)
        }
        let allTrainPairs = pairs(training)
        let trainPositives = allTrainPairs.filter(\.same)
        let trainNegatives = allTrainPairs.filter { !$0.same }
        let pairCount = min(128, trainPositives.count, trainNegatives.count)
        guard pairCount >= 2 else { return .notReady("同一話者・異話者のペアが不足しています") }
        // Equal class counts, sampled across the whole list, not just its first speaker.
        let trainPairs = evenlySample(trainPositives, count: pairCount) + evenlySample(trainNegatives, count: pairCount)
        let validationPairs = pairs(validation)
        let identity = [Float](repeating: 1, count: dimension)
        var logScales = [Float](repeating: 0, count: dimension)
        var scales = identity
        let regularization: Float = 0.002
        // Full-batch gradient descent; fixed seed-free ordering makes persistence and
        // regression tests reproducible. 160 epochs * <=256 pairs * <=192 features.
        for _ in 0..<160 {
            var gradient = [Float](repeating: 0, count: dimension)
            for pair in trainPairs {
                let pairGradient = contrastivePair(a: pair.a, b: pair.b, scales: scales, same: pair.same)!.gradient
                for i in 0..<dimension { gradient[i] += pairGradient[i] / Float(trainPairs.count) }
            }
            for i in 0..<dimension {
                gradient[i] += 2 * regularization * logScales[i] / Float(dimension)
                logScales[i] = min(log(4), max(log(0.25), logScales[i] - 0.6 * gradient[i]))
                scales[i] = exp(logScales[i])
            }
        }
        guard scales.allSatisfy({ $0.isFinite }) else { return .rejected("学習値が不正です") }
        // Thresholds use training sessions only. The held-out sessions never tune
        // weights, epochs, threshold or margin; they are the final acceptance gate.
        let threshold = calibratedThreshold(pairs: allTrainPairs, scales: scales)
        let baselineThreshold = calibratedThreshold(pairs: allTrainPairs, scales: identity)
        let learned = evaluate(validationPairs, scales: scales, threshold: threshold)
        let baseline = evaluate(validationPairs, scales: identity, threshold: baselineThreshold)
        guard threshold <= 0.98, learned.far == 0,
              learned.far <= baseline.far, learned.frr <= baseline.frr,
              learned.loss + 0.001 < baseline.loss else {
            var reasons: [String] = []
            if threshold > 0.98 {
                reasons.append(String(format: "異話者の特徴が近すぎます（学習録音の異話者最大類似度 %.4f、必要閾値 %.4f > 採用上限 0.9800）", threshold - 0.03, threshold))
            }
            if learned.falseAccepts > 0 { reasons.append("検証で別人の声を同一人物として受け入れました") }
            if learned.frr > baseline.frr { reasons.append("検証で同じ人の声を拒否する割合が従来より増えました") }
            if learned.loss + 0.001 >= baseline.loss { reasons.append("検証の損失改善が必要量 0.001 に届きませんでした") }
            let nextStep = threshold > 0.98
                ? "入力音源・録音区間・特徴抽出を確認してください。別人の声がほぼ同じ特徴のままでは、登録回数を増やしても解決しません。"
                : "登録した人と音源が一致しているか確認し、他の声や読み上げが混ざらない状態で別の文章を登録してください。"
            return .rejected(reasons.joined(separator: "／") + "\n" + validationSummary(learned, baseline: baseline) + "\n" + nextStep)
        }
        let margin = calibratedMargin(pairs: allTrainPairs, scales: scales)
        let baselineMargin = calibratedMargin(pairs: allTrainPairs, scales: identity)
        // Exercise the deployed median-ranking rule with held-out queries and
        // training-only references. Good heldout↔heldout pairs alone do not prove
        // that either person's registration references are correctly identified.
        let recognized = identifyHeldOut(validation, references: training, scales: scales, threshold: threshold, margin: margin)
        let baselineRecognized = identifyHeldOut(validation, references: training, scales: identity, threshold: baselineThreshold, margin: baselineMargin)
        guard recognized.wrong == 0, recognized.correct >= baselineRecognized.correct,
              Set(recognized.recognizedSpeakers) == Set(speakers.keys) else {
            let missing = Set(speakers.keys).subtracting(recognized.recognizedSpeakers).sorted().joined(separator: "、")
            let counts = "別録音の話者照合：正解 \(recognized.correct)/\(validation.count)、誤認 \(recognized.wrong)、不明 \(validation.count - recognized.correct - recognized.wrong)（従来の正解 \(baselineRecognized.correct)/\(validation.count)）"
            let unresolved = missing.isEmpty ? "" : "\n正しく照合できた検証録音がない話者：\(missing)"
            return .rejected("別録音を登録話者へ照合する検証に通りませんでした\n" + counts + unresolved
                + "\n" + validationSummary(learned, baseline: baseline)
                + "\n各話者の登録名と入力音源を確認し、他の声が混ざらない別の文章で登録してください。")
        }
        let report = Validation(trainingSessions: training.count, validationSessions: validation.count,
                                positivePairs: validationPairs.filter(\.same).count,
                                negativePairs: validationPairs.filter { !$0.same }.count,
                                falseAcceptRate: learned.far, falseRejectRate: learned.frr,
                                baselineFalseAcceptRate: baseline.far, baselineFalseRejectRate: baseline.frr,
                                contrastiveLoss: learned.loss, baselineContrastiveLoss: baseline.loss)
        let model = Model(version: 1, dimension: dimension, scales: scales,
                          similarityThreshold: threshold, similarityMargin: margin, validation: report)
        guard model.isValid else { return .rejected("学習モデルの検証に失敗しました") }
        return .ready(model)
    }

    /// Loss and derivative with respect to log(scales); shared by both branches.
    static func contrastivePair(a: [Float], b: [Float], scales: [Float], same: Bool) -> (loss: Float, gradient: [Float])? {
        let dimension = scales.count
        guard let a = normalized(a, dimension: dimension), let b = normalized(b, dimension: dimension),
              scales.allSatisfy({ $0.isFinite && (0.25...4).contains($0) }) else { return nil }
        var normA: Float = 0, normB: Float = 0, dot: Float = 0
        for i in 0..<dimension {
            let aa = scales[i] * a[i], bb = scales[i] * b[i]
            normA += aa * aa; normB += bb * bb; dot += aa * bb
        }
        let denominator = sqrt(normA * normB)
        let similarity = dot / denominator
        let residual = same ? similarity - 1 : max(0, similarity - 0.2)
        var gradient = [Float](repeating: 0, count: dimension)
        for i in 0..<dimension {
            let w2 = scales[i] * scales[i]
            let ds = 2 * w2 * a[i] * b[i] / denominator
                - similarity * w2 * (a[i] * a[i] / normA + b[i] * b[i] / normB)
            gradient[i] = 2 * residual * ds
        }
        return (residual * residual, gradient)
    }

    private static func normalized(_ vector: [Float], dimension: Int) -> [Float]? {
        guard vector.count == dimension, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-8 else { return nil }
        return vector.map { $0 / norm }
    }

    private static func score(_ a: [Float], _ b: [Float], scales: [Float]) -> Float {
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in scales.indices {
            let x = a[i] * scales[i], y = b[i] * scales[i]
            dot += x * y; normA += x * x; normB += y * y
        }
        return max(-1, min(1, dot / sqrt(normA * normB)))
    }

    private static func pairs(_ sessions: [Session]) -> [Pair] {
        guard sessions.count >= 2 else { return [] }
        var result: [Pair] = []
        for i in 0..<(sessions.count - 1) {
            for j in (i + 1)..<sessions.count {
                result.append(Pair(a: sessions[i].vector, b: sessions[j].vector, same: sessions[i].speaker == sessions[j].speaker))
            }
        }
        return result
    }

    private static func evenlySample(_ pairs: [Pair], count: Int) -> [Pair] {
        (0..<count).map { pairs[$0 * pairs.count / count] }
    }

    private static func calibratedMargin(pairs: [Pair], scales: [Float]) -> Float {
        let positiveMin = pairs.filter(\.same).map { score($0.a, $0.b, scales: scales) }.min() ?? 1
        let negativeMax = pairs.filter { !$0.same }.map { score($0.a, $0.b, scales: scales) }.max() ?? 1
        return max(0.06, min(0.15, (positiveMin - negativeMax) * 0.2))
    }

    private static func identifyHeldOut(_ queries: [Session], references: [Session], scales: [Float], threshold: Float,
                                       margin: Float) -> (correct: Int, wrong: Int, recognizedSpeakers: [String]) {
        let grouped = Dictionary(grouping: references, by: \.speaker)
        var correct = 0, wrong = 0
        var recognizedSpeakers: [String] = []
        for query in queries {
            var ranked: [(speaker: String, score: Float)] = []
            for (speaker, examples) in grouped {
                let scores: [Float] = examples.map { score(query.vector, $0.vector, scales: scales) }.sorted()
                let lower = scores[(scores.count - 1) / 2]
                let upper = scores[scores.count / 2]
                ranked.append((speaker: speaker, score: (lower + upper) / Float(2)))
            }
            ranked.sort { $0.score == $1.score ? $0.speaker < $1.speaker : $0.score > $1.score }
            guard ranked.count >= 2, ranked[0].score >= threshold, ranked[0].score - ranked[1].score >= margin else { continue }
            if ranked[0].speaker == query.speaker { correct += 1; recognizedSpeakers.append(query.speaker) }
            else { wrong += 1 }
        }
        return (correct, wrong, recognizedSpeakers)
    }

    private static func calibratedThreshold(pairs: [Pair], scales: [Float]) -> Float {
        let maxNegative = pairs.filter { !$0.same }.map { score($0.a, $0.b, scales: scales) }.max() ?? 1
        return max(0.45, maxNegative + 0.03)
    }

    private struct Evaluation {
        let falseAccepts: Int
        let falseRejects: Int
        let positivePairs: Int
        let negativePairs: Int
        let loss: Float
        var far: Float { Float(falseAccepts) / Float(negativePairs) }
        var frr: Float { Float(falseRejects) / Float(positivePairs) }
    }

    private static func validationSummary(_ learned: Evaluation, baseline: Evaluation) -> String {
        String(format: "別録音での検証：誤受入 %d/%d（%.1f%%、従来 %.1f%%）、誤拒否 %d/%d（%.1f%%、従来 %.1f%%）、損失 %.4f（従来 %.4f）",
               learned.falseAccepts, learned.negativePairs, learned.far * 100, baseline.far * 100,
               learned.falseRejects, learned.positivePairs, learned.frr * 100, baseline.frr * 100,
               learned.loss, baseline.loss)
    }

    private static func evaluate(_ pairs: [Pair], scales: [Float], threshold: Float) -> Evaluation {
        let positive = pairs.filter(\.same).map { score($0.a, $0.b, scales: scales) }
        let negative = pairs.filter { !$0.same }.map { score($0.a, $0.b, scales: scales) }
        let posLoss = positive.map { (1 - $0) * (1 - $0) }.reduce(0, +) / Float(positive.count)
        let negLoss = negative.map { max(0, $0 - 0.2) * max(0, $0 - 0.2) }.reduce(0, +) / Float(negative.count)
        return Evaluation(falseAccepts: negative.filter { $0 >= threshold }.count,
                          falseRejects: positive.filter { $0 < threshold }.count,
                          positivePairs: positive.count, negativePairs: negative.count,
                          loss: (posLoss + negLoss) / 2)
    }
}
