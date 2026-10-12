import Foundation

/// 認識器の仮説は追記ではなく、訂正を含む全文のスナップショット。
struct SpeechHypothesisBuffer {
    struct Segment: Equatable { var speaker: String; var text: String }
    private var characters: [Character] = []
    private var owners: [String] = []
    var text: String { String(characters) }

    mutating func update(_ text: String, speaker: String) {
        if speaker != "不明" { owners = owners.map { $0 == "不明" ? speaker : $0 } }
        let updated = Array(text)
        var prefix = 0
        while prefix < characters.count && prefix < updated.count && characters[prefix] == updated[prefix] { prefix += 1 }
        // 既存語の訂正は元の話者に帰属させる。単純な伸長だけ新話者へ。
        let owner = prefix < owners.count ? owners[prefix] : speaker
        characters = updated
        owners = Array(owners.prefix(prefix)) + Array(repeating: owner, count: updated.count - prefix)
    }

    var segments: [Segment] {
        var result: [Segment] = []
        for (character, speaker) in zip(characters, owners) {
            if result.last?.speaker == speaker { result[result.count - 1].text.append(character) }
            else { result.append(Segment(speaker: speaker, text: String(character))) }
        }
        return result
    }

    mutating func reset() { characters.removeAll(); owners.removeAll() }
}

/// 誤認識の短い断片を、会話を理解した応答の材料として扱わない。
enum VoiceInputPolicy {
    static func isActionable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownShortUtterances: Set<String> = ["はい", "いいえ", "違う", "やめて", "待って", "なぜ", "何？", "誰？", "夏は？", "夏は", "そう", "うん", "いや", "yes", "no", "why", "who?", "what?", "stop", "wait", "ok"]
        if knownShortUtterances.contains(trimmed.lowercased()) { return true }
        return trimmed.filter { !$0.isWhitespace && !$0.isPunctuation }.count >= 5
    }
}
