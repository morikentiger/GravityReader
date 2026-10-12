import Foundation

/// トリアージ判定へのフィードバック（○△×）を永続保存する
class FeedbackStore {
    struct FeedbackEntry: Codable {
        let text: String
        var rating: Rating
        let timestamp: Date

        enum Rating: String, Codable {
            case ok = "ok"           // ○ 読み上げていい
            case uncertain = "uncertain" // △ どっちか判断つかない
            case ng = "ng"           // × だめ
        }
    }

    private var entries: [FeedbackEntry] = []
    private let storePath: URL

    /// few-shot例として使う最大件数
    private let maxExamples = 30

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GravityReader/feedback")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appendingPathComponent("feedback.json")
        load()
    }

    // MARK: - Public

    /// フィードバックを追加・更新する
    func setFeedback(text: String, rating: FeedbackEntry.Rating) {
        // 同じテキストがあれば更新
        if let idx = entries.firstIndex(where: { $0.text == text }) {
            entries[idx].rating = rating
        } else {
            entries.append(FeedbackEntry(text: text, rating: rating, timestamp: Date()))
        }
        save()
    }

    /// 指定テキストのフィードバックを取得
    func getFeedback(for text: String) -> FeedbackEntry.Rating? {
        entries.first(where: { $0.text == text })?.rating
    }

    /// 全フィードバックを取得
    var allEntries: [FeedbackEntry] { entries }

    /// トリアージプロンプトに挿入するfew-shot例を生成
    func triageExamples() -> String? {
        let okExamples = entries.filter { $0.rating == .ok }.suffix(maxExamples / 2)
        let ngExamples = entries.filter { $0.rating == .ng }.suffix(maxExamples / 2)

        if okExamples.isEmpty && ngExamples.isEmpty { return nil }

        var lines: [String] = []
        lines.append("## 過去のフィードバック（これを参考にして判定してください）")

        for entry in okExamples {
            let preview = String(entry.text.prefix(80))
            lines.append("入力「\(preview)」→ 読み上げOK（RESPOND または ACKNOWLEDGE）")
        }
        for entry in ngExamples {
            let preview = String(entry.text.prefix(80))
            lines.append("入力「\(preview)」→ 読み上げNG（DEFLECT）")
        }

        return lines.joined(separator: "\n")
    }

    /// 古いエントリを整理（最新200件を保持）
    func prune() {
        if entries.count > 200 {
            entries = Array(entries.suffix(200))
            save()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storePath) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([FeedbackEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: storePath)
    }
}
