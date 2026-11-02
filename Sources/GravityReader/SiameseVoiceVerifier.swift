import Foundation

/// Access from the main queue, like VoiceDiarizer. Training uses an immutable
/// snapshot on a private queue. Only explicit, quality-checked enrollments enter it.
final class SiameseVoiceVerifier {
    private struct Archive: Codable {
        var version = 2
        var extractor = SpeakerEmbeddingModel.extractorIdentifier
        var observations: [SiameseSpeakerMetric.Observation]
        var model: SiameseSpeakerMetric.Model?
        var lastEvaluation: String?
    }
    struct Match {
        let speaker: String
        let similarity: Float
        let margin: Float
    }
    private(set) var observations: [SiameseSpeakerMetric.Observation] = []
    private(set) var model: SiameseSpeakerMetric.Model?
    private(set) var status = "登録音声の追加待ち"
    private var lastEvaluation: String?
    var onStatusChanged: ((String) -> Void)?
    private let url: URL
    private let trainingQueue = DispatchQueue(label: "GravityReader.siamese-training", qos: .utility)
    private var revision = UUID()
    private var storageCompatible = true
    private var workerRunning = false
    private var trainingRequested = false
    private let dimension: Int
    private let train: ([SiameseSpeakerMetric.Observation], Int) -> SiameseSpeakerMetric.TrainingResult

    init(url: URL? = nil, dimension: Int = 192,
         train: @escaping ([SiameseSpeakerMetric.Observation], Int) -> SiameseSpeakerMetric.TrainingResult = { SiameseSpeakerMetric.train(observations: $0, dimension: $1) }) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GravityReader/siamese_voice_v2.json")
        self.dimension = dimension
        self.train = train
        load()
        if !FileManager.default.fileExists(atPath: self.url.path),
           FileManager.default.fileExists(atPath: self.url.deletingLastPathComponent().appendingPathComponent("siamese_voice_v1.json").path) {
            status = "旧方式の登録データは保持済み。特徴抽出の修正に伴い、各話者の声紋を再登録してください"
        }
    }

    var enrollmentCounts: [String: Int] {
        Dictionary(grouping: observations, by: { $0.speaker }).mapValues { Set($0.map { $0.sessionID }).count }
    }
    var summary: String {
        let counts = enrollmentCounts.sorted { $0.key < $1.key }.map { "\($0.key)：\($0.value)回" }.joined(separator: "\n")
        let validation = model.map {
            String(format: "検証ペア：同一話者 %d・異話者 %d\n誤受入率 %.1f%%・誤拒否率 %.1f%%（少数の登録録音での値）", $0.validation.positivePairs, $0.validation.negativePairs, $0.validation.falseAcceptRate * 100, $0.validation.falseRejectRate * 100)
        } ?? "検証済みモデル：なし"
        return """
            \(status)
            \(validation)

            \(counts.isEmpty ? "新方式の登録録音はまだありません。" : counts)

            学習には2人以上、それぞれ4回以上の別録音が必要です。
            「声紋を登録」で同じ名前を選び、毎回別の文章を話してください。
            同じ録音を分割して回数を増やすことはしません。
            検証に通るまで従来のECAPA照合を使います。
            声の特徴量と学習モデルはこのMac内に保存します。Siamese学習では録音自体は保存・送信しません。
            """
    }

    @discardableResult
    func recordEnrollment(speaker: String, embedding: [Float], sessionID: String = UUID().uuidString) -> Bool {
        let name = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storageCompatible, !name.isEmpty, !sessionID.isEmpty, let vector = normalized(embedding),
              !observations.contains(where: { $0.sessionID == sessionID }),
              enrollmentCounts[name] != nil || enrollmentCounts.count < 16 else { return false }
        // Re-submitting exactly the same recording must not create independent evidence.
        guard !observations.contains(where: { $0.speaker == name && zip($0.embedding, vector).allSatisfy { abs($0 - $1) < 1e-6 } }) else { return false }
        observations.append(.init(speaker: name, sessionID: sessionID, embedding: vector))
        while observations.filter({ $0.speaker == name }).count > 12 {
            if let index = observations.firstIndex(where: { $0.speaker == name }) { observations.remove(at: index) }
        }
        invalidateModel()
        guard save() else { return true }
        requestTraining()
        return true
    }

    func removeSpeaker(_ speaker: String) {
        observations.removeAll { $0.speaker == speaker }
        invalidateModel()
        if save() { requestTraining() }
    }
    func removeAll() {
        storageCompatible = true
        observations.removeAll()
        invalidateModel()
        _ = save()
        publish("登録音声の追加待ち")
    }

    func canUseModel(for speakers: Set<String>) -> Bool {
        guard let model = model, model.isValid, !speakers.isEmpty else { return false }
        return speakers == Set(observations.map { $0.speaker })
    }

    /// Returns nil for ambiguous/unknown voices. The caller must NOT fall back to
    /// a more permissive legacy vote after this learned verifier has rejected one.
    func identify(_ embedding: [Float], speakers: Set<String>) -> Match? {
        guard canUseModel(for: speakers), let model = model, let query = normalized(embedding) else { return nil }
        let grouped = Dictionary(grouping: observations, by: { $0.speaker })
        let ranked = grouped.compactMap { name, examples -> (String, Float)? in
            let scores = examples.compactMap { model.similarity(query, $0.embedding) }.sorted()
            guard scores.count >= 4 else { return nil }
            // Median agreement across distinct recordings, not the most convenient match.
            let score = (scores[(scores.count - 1) / 2] + scores[scores.count / 2]) / 2
            return (name, score)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        guard ranked.count == speakers.count, ranked.count >= 2, let best = ranked.first else { return nil }
        let margin = best.1 - ranked[1].1
        guard best.1 >= model.similarityThreshold, margin >= model.similarityMargin else { return nil }
        return Match(speaker: best.0, similarity: best.1, margin: margin)
    }

    private func invalidateModel() {
        revision = UUID()
        model = nil
        lastEvaluation = nil
        trainingRequested = false
    }
    private func requestTraining() {
        let counts = enrollmentCounts
        guard counts.count >= 2, counts.values.allSatisfy({ $0 >= 4 }) else {
            publish("学習材料待ち（2人以上・各4回の別録音が必要）")
            return
        }
        trainingRequested = true
        startWorkerIfNeeded()
    }
    private func startWorkerIfNeeded() {
        guard !workerRunning, trainingRequested else { return }
        trainingRequested = false
        workerRunning = true
        let token = revision
        let snapshot = observations
        let dimension = dimension
        let trainer = train
        publish("Siamese学習と別録音での検証中…")
        trainingQueue.async { [weak self] in
            let result = trainer(snapshot, dimension)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.workerRunning = false
                if self.revision == token {
                    switch result {
                    case .ready(let model):
                        if model.isValid, model.dimension == self.dimension {
                            self.model = model
                            self.lastEvaluation = nil
                            if self.save() { self.publish("Siamese照合を利用可能（学習に使わない登録録音で検証済み・実環境の精度は未測定）") }
                        } else { self.publish("学習結果が不正なため従来方式を継続") }
                    case .notReady(let reason), .rejected(let reason):
                        let message = "Siamese採用見送り：\(reason)"
                        self.lastEvaluation = message
                        if self.save() { self.publish(message) }
                    }
                }
                self.startWorkerIfNeeded()
            }
        }
    }
    private func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == dimension, vector.allSatisfy({ $0.isFinite }) else { return nil }
        let norm = sqrt(vector.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-8 else { return nil }
        return vector.map { Float(Double($0) / norm) }
    }
    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            guard archive.version == 2, archive.extractor == SpeakerEmbeddingModel.extractorIdentifier,
                  archive.observations.count <= 192,
                  Set(archive.observations.map { $0.sessionID }).count == archive.observations.count,
                  archive.observations.allSatisfy({ !$0.speaker.isEmpty && !$0.sessionID.isEmpty && normalized($0.embedding) != nil }) else {
                storageCompatible = false
                publish("保存された学習データに互換性がないため従来方式を使用")
                return
            }
            observations = archive.observations
            lastEvaluation = archive.lastEvaluation
            if let candidate = archive.model, candidate.isValid, candidate.dimension == dimension,
               enrollmentCounts.count >= 2, enrollmentCounts.count <= 16,
               enrollmentCounts.values.allSatisfy({ (4...12).contains($0) }) {
                model = candidate
                status = "保存済みSiameseモデルを利用可能（実環境の精度は未測定）"
            } else { status = lastEvaluation ?? "学習材料を読み込み済み・追加登録時に再評価" }
        } catch { storageCompatible = false; publish("学習データを読み込めないため従来方式を使用（既存ファイルは保持）") }
    }
    @discardableResult private func save() -> Bool {
        guard storageCompatible else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Archive(observations: observations, model: model, lastEvaluation: lastEvaluation))
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            model = nil
            publish("Siamese学習データの保存に失敗・従来方式を使用")
            return false
        }
    }
    private func publish(_ message: String) { status = message; onStatusChanged?(message) }
}
