import Foundation

/// HTTPの受信単位とSSEの行・UTF-8文字の境界は一致しない。
struct SSELineBuffer {
    private var pending = Data()
    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            lines.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines))
            pending.removeSubrange(...newline)
        }
        return lines
    }
    mutating func finish() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
