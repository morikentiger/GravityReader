import Foundation

/// 音として負担になるコメントを、読み上げキューに入れる前に抑制する。
final class CommentReadoutGuard {
    private var recent: [(time: Date, speaker: String, text: String)] = []

    func suppressionReason(_ text: String, speaker: String, now: Date = Date()) -> String? {
        recent.removeAll { now.timeIntervalSince($0.time) > 30 }
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = folded.count == 1 ? folded : folded.filter { !$0.isWhitespace && !$0.isPunctuation }
        if !PhoneticSpamGuard.isExplanation(text),
           Self.hasRepeatedRun(normalized) || PhoneticSpamGuard.suppressionReason(original: text, reading: text) != nil {
            return "同じ音・語の繰り返し"
        }
        if normalized.isEmpty { return "記号のみ" }
        if text.count > 200 { return "長すぎるコメント" }
        if recent.contains(where: { $0.text == normalized }) { return "直近と同じ内容" }
        if recent.filter({ $0.speaker == speaker && now.timeIntervalSince($0.time) <= 10 }).count >= 3 {
            return "短時間の連投"
        }
        recent.append((now, speaker, normalized))
        return nil
    }

    static func hasRepeatedRun(_ text: String) -> Bool {
        if YUiSpamFilter.isRepetitiveSpam(text) { return true }
        let characters = Array(text)
        // 文の途中や長い語の反復も検出する。通常の「うんうん」等は許容。
        guard characters.count >= 4 else { return false }
        for width in 1...min(20, characters.count / 4) {
            for start in 0...(characters.count - width * 4) {
                let unit = Array(characters[start..<(start + width)])
                if (1..<4).allSatisfy({ repeatIndex in
                    Array(characters[(start + width * repeatIndex)..<(start + width * (repeatIndex + 1))]) == unit
                }) { return true }
            }
        }
        return false
    }
}
