import Foundation

enum YUiConversationContext {
    /// 日本語や絵文字を壊さず、APIへ渡す量をUTF-8バイト数で制限する。
    static func clipped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > bytes { break }
            result.append(character)
            used += size
        }
        return result
    }

    static func recent(_ entries: [String], bytes: Int = 8000, count: Int = 20) -> [String] {
        var selected: [String] = []
        var remaining = bytes
        for entry in entries.suffix(count).reversed() {
            let text = clipped(entry, bytes: min(1200, remaining))
            guard !text.isEmpty else { break }
            selected.append(text)
            remaining -= text.utf8.count + 1
            if remaining <= 0 { break }
        }
        return selected.reversed()
    }

    /// 話者と時系列を保ち、最後の人の発言も取りこぼさない。
    static func messages(from entries: [String]) -> [[String: String]] {
        var messages: [[String: String]] = []
        var userBatch: [String] = []
        func flushUsers() {
            if !userBatch.isEmpty {
                messages.append(["role": "user", "content": userBatch.joined(separator: "\n")])
                userBatch.removeAll()
            }
        }
        for text in entries {
            if text.hasPrefix("YUi: ") {
                flushUsers()
                messages.append(["role": "assistant", "content": String(text.dropFirst(5))])
            } else {
                userBatch.append(text)
            }
        }
        flushUsers()
        return messages
    }
}
