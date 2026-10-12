import Foundation

/// Session-only numeric telemetry. Does not retain conversation text or names.
final class ConversationStatistics {
    enum Kind { case voice, comment, reply, latency, suppressed }
    struct Event {
        let time: Date
        let kind: Kind
        let characters: Int
        let latency: TimeInterval?
        let reason: String?
    }
    struct Snapshot {
        let voice: Int
        let comments: Int
        let replies: Int
        let replyShare: Double?
        let characterShare: Double?
        let medianLatency: TimeInterval?
        let latencySamples: Int
        let suppressed: [String: Int]
        let minutes: [(human: Int, yui: Int)]
        let sessionInputs: Int
        let sessionReplies: Int
        let sessionSuppressed: Int
        let lastInput: Date?
        let lastReply: Date?
    }
    private var events: [Event] = []
    private var sessionInputs = 0
    private var sessionReplies = 0
    private var sessionSuppressed = 0
    private var lastInput: Date?
    private var lastReply: Date?

    func record(_ kind: Kind, characters: Int = 0, latency: TimeInterval? = nil,
                reason: String? = nil, now: Date = Date()) {
        switch kind {
        case .voice, .comment: sessionInputs += 1; lastInput = now
        case .reply: sessionReplies += 1; lastReply = now
        case .suppressed: sessionSuppressed += 1
        case .latency: break
        }
        events.removeAll { now.timeIntervalSince($0.time) >= 300 }
        events.append(Event(time: now, kind: kind, characters: characters, latency: latency, reason: reason))
    }

    func snapshot(now: Date = Date()) -> Snapshot {
        events.removeAll { now.timeIntervalSince($0.time) >= 300 }
        let recent = events.filter { $0.time <= now }
        let inputs = recent.filter { $0.kind == .voice || $0.kind == .comment }
        let replies = recent.filter { $0.kind == .reply }
        let total = inputs.count + replies.count
        let ownChars = replies.reduce(0) { $0 + $1.characters }
        let totalChars = ownChars + inputs.reduce(0) { $0 + $1.characters }
        let latencies = recent.compactMap { $0.latency }.filter { $0.isFinite && $0 >= 0 }.sorted()
        let median: Double? = latencies.isEmpty ? nil : (latencies[(latencies.count - 1) / 2] + latencies[latencies.count / 2]) / 2
        var reasons: [String: Int] = [:]
        for event in recent where event.kind == .suppressed { reasons[event.reason ?? "その他", default: 0] += 1 }
        let minutes = (0..<5).reversed().map { minute -> (human: Int, yui: Int) in
            let bucket = recent.filter { Int(now.timeIntervalSince($0.time) / 60) == minute }
            return (bucket.filter { $0.kind == .voice || $0.kind == .comment }.count,
                    bucket.filter { $0.kind == .reply }.count)
        }
        return Snapshot(voice: inputs.filter { $0.kind == .voice }.count,
                        comments: inputs.filter { $0.kind == .comment }.count, replies: replies.count,
                        replyShare: total == 0 ? nil : Double(replies.count) / Double(total),
                        characterShare: totalChars == 0 ? nil : Double(ownChars) / Double(totalChars),
                        medianLatency: median, latencySamples: latencies.count, suppressed: reasons, minutes: minutes,
                        sessionInputs: sessionInputs, sessionReplies: sessionReplies, sessionSuppressed: sessionSuppressed,
                        lastInput: lastInput, lastReply: lastReply)
    }
}
