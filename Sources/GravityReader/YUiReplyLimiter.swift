import Foundation

/// 生成モデルの長さ指示違反を、読み上げ前に抑える。
enum YUiReplyLimiter {
    static func firstSentence(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = text.firstIndex(where: { "。！？!?\n".contains($0) }) {
            return String(text[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
