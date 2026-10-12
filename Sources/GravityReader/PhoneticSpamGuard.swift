import Foundation

/// This is a comparison key only; never substitute it for the spoken text.
enum PhoneticSpamGuard {
    static func isExplanation(_ original: String) -> Bool {
        let explanation = ["読み方", "と読む", "の読み", "発音", "表記", "pronounc", "spelling", "means"]
        return explanation.contains(where: original.lowercased().contains)
    }

    static func suppressionReason(original: String, reading: String) -> String? {
        if isExplanation(original) { return nil }
        let kana = reading.precomposedStringWithCompatibilityMapping.lowercased()
            .applyingTransform(StringTransform("Latin-Hiragana"), reverse: false) ?? reading
        let folded = kana.applyingTransform(.hiraganaToKatakana, reverse: true) ?? kana
        let chars = Array(folded.filter { $0.isLetter || $0.isNumber })
        guard chars.count >= 6 else { return nil }
        // Three repeated words dominate the utterance, even with a numeric prefix.
        for width in 1...min(20, chars.count / 3) {
            let minimum = width == 1 ? 6 : 3
            guard width * minimum <= chars.count else { continue }
            for start in 0...(chars.count - width * minimum) {
                let unit = Array(chars[start..<start + width])
                var count = 1
                while start + (count + 1) * width <= chars.count,
                      Array(chars[start + count * width..<start + (count + 1) * width]) == unit { count += 1 }
                let numericPrefixWithRepeatedTail = original.first?.isNumber == true && width >= 2 && start + count * width == chars.count
                if count >= minimum, Double(count * width) / Double(chars.count) >= 0.65 || numericPrefixWithRepeatedTail {
                    return "読み方を揃えると同じ音が繰り返される"
                }
            }
        }
        return nil
    }
}
