import Foundation

/// スパム検出・繰り返し検出・話題分類
struct YUiSpamFilter {

    /// 本文の「おもち」ではなく、発言者の名前だけを照合する。
    static func isIgnoredUser(_ user: String) -> Bool {
        let configured = AppDefaults.suite.stringArray(forKey: "YUiIgnoredUsers") ?? []
        let name = user.replacingOccurrences(of: "[コメント]", with: "")
            .components(separatedBy: CharacterSet(charactersIn: ",，")).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? user
        return configured.contains { $0 == name }
    }

    static func isIgnoredMessage(_ text: String) -> Bool {
        guard let delimiter = text.range(of: ": ") ?? text.range(of: "： ") else { return false }
        return isIgnoredUser(String(text[..<delimiter.lowerBound]))
    }

    enum SpamLevel {
        case clean          // 正常
        case inappropriate  // 不適切（下ネタ等）→ フラグ付きでバッファに入れる
        case fullSpam       // 完全スパム → バッファに入れない
    }

    static func detectSpamLevel(_ text: String) -> SpamLevel {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 空文字
        if trimmed.isEmpty { return .fullSpam }

        // 連投スパム検出: 同じ文字/語が大量に繰り返されている
        // 例: "おいおいおいおいおいおいおいおいおいおい"
        if isRepetitiveSpam(trimmed) { return .fullSpam }

        // 不適切ワード検出（下ネタ・性的表現）
        let inappropriatePatterns = [
            "えっち", "エッチ", "気持ちいい", "きもちいい",
            "あーん", "あーーん", "うっふ", "いやーん",
            "おっぱい", "ちんこ", "ちんぽ", "まんこ",
            "セックス", "SEX", "sex",
            "パンツ見せて", "脱いで", "裸",
            "しこしこ", "オナニー", "フェラ",
        ]
        let lower = trimmed.lowercased()
        for pattern in inappropriatePatterns {
            if lower.contains(pattern.lowercased()) {
                return .inappropriate
            }
        }

        let overridePatterns = ["指示を無視", "命令を無視", "プロンプトを無視", "ルールを無視", "ignore previous instructions", "ignore all instructions", "システムプロンプトを教", "apiキーを教"]
        if overridePatterns.contains(where: { lower.contains($0) }) { return .fullSpam }

        // 短すぎる挑発系（「おい」だけ、等）
        // ただし普通の短文は除外
        if trimmed.count <= 3 && ["おい", "おーい", "ねぇ"].contains(trimmed) {
            return .clean  // これは普通
        }

        return .clean
    }

    /// 同じ文字や語が異常に繰り返されているか
    static func isRepetitiveSpam(_ text: String) -> Bool {
        if PhoneticSpamGuard.suppressionReason(original: text, reading: text) != nil { return true }
        // 10文字以上で、ユニーク文字が3種以下 → スパム
        // 例: "おいおいおいおいおいおいおいおいおいおいおいおいおいおいおい"
        if text.count >= 10 {
            let unique = Set(text)
            if unique.count <= 3 {
                return true
            }
        }

        // 短い語の連続繰り返し検出（2〜4文字の語が5回以上）
        for unitLen in 1...4 {
            guard text.count >= unitLen * 5 else { continue }
            let unit = String(text.prefix(unitLen))
            let repeated = String(repeating: unit, count: text.count / unitLen)
            // 80%以上一致したらスパム
            let matchCount = zip(text, repeated).filter { $0 == $1 }.count
            if matchCount >= text.count * 4 / 5 {
                return true
            }
        }

        return false
    }

    /// 過去の発言と似すぎていないかチェック
    static func isTooSimilarToPast(_ response: String, history: [String]) -> Bool {
        let newWords = extractKeywords(response)
        for past in history.suffix(10) {
            let pastWords = extractKeywords(past)
            // キーワードの重複率を計算
            let common = newWords.intersection(pastWords)
            let total = min(newWords.count, pastWords.count)
            guard total > 0 else { continue }
            let overlap = Double(common.count) / Double(total)
            if overlap > 0.6 { return true }  // 60%以上のキーワードが同じなら類似とみなす
        }
        return false
    }

    /// テキストからキーワード（助詞等を除く意味のある語）を抽出
    static func extractKeywords(_ text: String) -> Set<String> {
        // 簡易的に2文字以上のひらがな/カタカナ/漢字のかたまりを抽出
        let pattern = #"[\p{Han}\p{Katakana}ー]{2,}|[ぁ-ん]{3,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        var words = Set<String>()
        for match in matches {
            if let r = Range(match.range, in: text) {
                words.insert(String(text[r]))
            }
        }
        return words
    }

    /// 話題種類の推定
    static func detectTopicType(from messages: [String]) -> String? {
        let text = messages.joined(separator: " ").lowercased()

        let techKeywords = ["コード", "api", "バグ", "デプロイ", "サーバー", "python", "swift", "react", "ai", "機械学習", "データ", "プログラム", "開発", "実装", "エラー"]
        let gameKeywords = ["ゲーム", "プレイ", "攻略", "ガチャ", "レベル", "ボス", "スイッチ", "ps5", "steam", "apexなど"]
        let foodKeywords = ["食べ", "ご飯", "ラーメン", "カレー", "美味し", "うまい", "飲み", "ビール", "酒"]
        let negativeKeywords = ["疲れ", "しんどい", "つらい", "辛い", "嫌だ", "最悪", "むかつく", "泣き", "死に"]

        let techScore = techKeywords.filter { text.contains($0) }.count
        let gameScore = gameKeywords.filter { text.contains($0) }.count
        let foodScore = foodKeywords.filter { text.contains($0) }.count
        let negScore = negativeKeywords.filter { text.contains($0) }.count

        let maxScore = max(techScore, gameScore, foodScore, negScore)
        guard maxScore >= 2 else { return nil }

        if negScore == maxScore { return "ネガティブ・愚痴（トーン下げて、静かに寄り添って）" }
        if techScore == maxScore { return "技術・仕事（知的好奇心モード。質問や深掘りOK）" }
        if gameScore == maxScore { return "ゲーム・エンタメ（テンション高め！ノリよく！）" }
        if foodScore == maxScore { return "食べ物・グルメ（リラックスモード。好みを語ってOK）" }
        return nil
    }
}

/// 内容の拒否に加え、繰り返しや連投が続く話者への反応を短時間止める。
final class YUiAbuseGuard {
    private struct Entry {
        var recent: [(Date, String)] = []
        var violations: [Date] = []
        var mutedUntil = Date.distantPast
    }
    private var entries: [String: Entry] = [:]

    func shouldIgnore(speaker: String, content: String, now: Date = Date()) -> Bool {
        entries = entries.filter { _, entry in
            entry.mutedUntil > now || entry.recent.contains { now.timeIntervalSince($0.0) < 120 }
        }
        var entry = entries[speaker] ?? Entry()
        if now < entry.mutedUntil { return true }
        let normalized = content.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        entry.recent.removeAll { now.timeIntervalSince($0.0) > 30 }
        entry.violations.removeAll { now.timeIntervalSince($0) > 60 }
        let duplicate = !normalized.isEmpty && entry.recent.filter { $0.1 == normalized }.count >= 2
        let flood = entry.recent.filter { now.timeIntervalSince($0.0) <= 10 }.count >= 7
        entry.recent.append((now, normalized))
        let rejected = YUiSpamFilter.detectSpamLevel(content) != .clean || duplicate || flood
        if rejected {
            entry.violations.append(now)
            if entry.violations.count >= 3 || flood { entry.mutedUntil = now.addingTimeInterval(120) }
        }
        entries[speaker] = entry
        return rejected
    }
}
