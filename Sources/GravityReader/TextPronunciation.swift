import Foundation
import NaturalLanguage

/// 英文を無理にローマ字変換せず、日本語として書かれたローマ字だけを読む。
enum TextPronunciation {
    struct Prepared: Equatable { let text: String; let language: String }
    private static let anchors: Set<String> = ["konnichiwa", "konnichiha", "konbanwa", "ohayou", "ohayo", "arigatou", "arigato", "watashi", "boku", "nihongo", "desu", "masu", "suki", "daijoubu", "sumimasen", "onegai", "kudasai"]
    private static let english: Set<String> = ["hello", "world", "the", "this", "is", "are", "you", "please", "thank", "thanks", "can", "would", "my", "to", "and", "your", "one", "of", "for", "i", "like", "it", "we", "a"]
    private static let special = ["konnichiwa": "こんにちは", "konnichiha": "こんにちは", "konbanwa": "こんばんは", "ohayo": "おはよう", "arigato": "ありがとう"]

    static func prepare(_ text: String, romajiEnabled: Bool = true) -> Prepared {
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        let hasJapanese = text.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) || (0x4e00...0x9fff).contains($0.value) }
        let hasAnchor = words.contains { anchors.contains($0) }
        let englishCount = words.filter { english.contains($0) }.count
        if romajiEnabled, hasAnchor, englishCount <= 1, !text.contains("://"), let converted = convertRomaji(text) {
            return Prepared(text: converted, language: "ja-JP")
        }
        if hasJapanese { return Prepared(text: text, language: "ja-JP") }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Prepared(text: text, language: recognizer.dominantLanguage == .english || englishCount > 0 ? "en-US" : "ja-JP")
    }

    private static func convertRomaji(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z]+(?:'[A-Za-z]+)?"#) else { return nil }
        var output = text
        var converted = false
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let token = String(output[range]).lowercased()
            guard !english.contains(token) else { continue }
            let kana = special[token] ?? token.applyingTransform(StringTransform("Latin-Hiragana"), reverse: false) ?? token
            guard kana != token, kana.unicodeScalars.allSatisfy({ (0x3040...0x309f).contains($0.value) || $0 == "ー" }) else { continue }
            output.replaceSubrange(range, with: kana)
            converted = true
        }
        return converted ? output : nil
    }
}
