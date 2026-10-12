import Foundation

/// Reusable corrections backed by the actual source/answer pair, not inferred emotions.
enum ExperienceApplication {
    static func body(_ message: String) -> String {
        message.components(separatedBy: "\n").map { line in
            guard let range = line.range(of: ": ") ?? line.range(of: "： ") else { return line }
            return String(line[range.upperBound...])
        }.joined(separator: " ")
    }

    static func isQuestion(_ text: String) -> Bool {
        ["?", "？", "教えて", "答えて", "何", "なぜ", "どう", "どこ", "いつ", "which", "what", "why", "how"].contains { text.lowercased().contains($0) }
    }

    static func correction(source: String, response: String, query: String) -> String? {
        let source = body(source), query = body(query)
        guard isQuestion(source), isQuestion(query) else { return nil }
        let echo = ["気になる", "知りたい", "ある？", "ある?", "だっけ", "どう思う", "want to know"].contains { response.lowercased().contains($0) }
        let vague = ["うーん", "かぁ", "いいよね", "わかるよ", "面白い", "そうなんだ"].contains { response.contains($0) }
        guard (echo && (response.contains("？") || response.contains("?"))) || (vague && response.count <= 24) else { return nil }
        return "質問に感想や質問だけを返した経験から、今回は聞かれた内容への具体的な答えを先に一つ示す。不明な部分だけ確認し、知識を作らない。"
    }

    static func grams(_ text: String) -> Set<String> {
        let chars = Array(body(text).lowercased())
        guard chars.count >= 2 else { return [] }
        let noise: Set<String> = ["です", "ます", "した", "して", "こと", "って", "ある", "いる", "それ", "これ", "から", "ので", "だね", "だよ", "たい", "った", "んだ"]
        return Set((0..<(chars.count - 1)).compactMap { i in
            let pair = String(chars[i...i+1])
            return pair.allSatisfy { $0.isLetter || $0.isNumber } && !noise.contains(pair) ? pair : nil
        })
    }
}
