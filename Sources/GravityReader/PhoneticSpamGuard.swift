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
        if containsRepetition(chars, minimumRepeats: 3, singleCharacterMinimum: 6,
                              minimumCoverage: 0.65, allowRepeatedTail: original.first?.isNumber == true) {
            return "読み方を揃えると同じ音が繰り返される"
        }
        return nil
    }

    /// Compare characters one period apart. A matching run of two periods means
    /// three adjacent copies. Scan every possible period without allocating slices
    /// for every starting position: O(n²) time, O(1) additional space.
    static func containsRepetition(_ characters: [Character], minimumRepeats: Int,
                                   singleCharacterMinimum: Int, minimumCoverage: Double = 0,
                                   allowRepeatedTail: Bool = false) -> Bool {
        guard characters.count >= min(minimumRepeats, singleCharacterMinimum) else { return false }
        for width in 1...max(1, characters.count / minimumRepeats) {
            let minimum = width == 1 ? singleCharacterMinimum : minimumRepeats
            guard width * minimum <= characters.count else { continue }
            var matching = 0
            for index in width..<characters.count {
                matching = characters[index] == characters[index - width] ? matching + 1 : 0
                guard matching >= width * (minimum - 1) else { continue }
                let repeatedLength = (matching / width + 1) * width
                if Double(repeatedLength) / Double(characters.count) >= minimumCoverage
                    || (allowRepeatedTail && width >= 2 && index == characters.count - 1) {
                    return true
                }
            }
        }
        return false
    }
}
