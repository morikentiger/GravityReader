import XCTest
@testable import GravityReader

final class ConversationStatisticsTests: XCTestCase {
    func testEmptyIsUnmeasuredRatherThanZeroPercent() {
        let s = ConversationStatistics().snapshot()
        XCTAssertNil(s.replyShare)
        XCTAssertNil(s.characterShare)
        XCTAssertNil(s.medianLatency)
    }
    func testRollingWindowExpiresButSessionCountsRemain() {
        let stats = ConversationStatistics()
        let now = Date(timeIntervalSince1970: 1000)
        stats.record(.voice, characters: 20, now: now.addingTimeInterval(-300))
        stats.record(.comment, characters: 30, now: now.addingTimeInterval(-61))
        stats.record(.reply, characters: 10, now: now)
        let s = stats.snapshot(now: now)
        XCTAssertEqual(s.voice, 0)
        XCTAssertEqual(s.comments, 1)
        XCTAssertEqual(s.sessionInputs, 2)
        XCTAssertEqual(s.replyShare, 0.5)
        XCTAssertEqual(s.characterShare, 0.25)
        XCTAssertEqual(s.minutes[3].human, 1)
        XCTAssertEqual(s.minutes[4].yui, 1)
        XCTAssertEqual(stats.snapshot(now: now.addingTimeInterval(301)).replies, 0)
    }
    func testSuppressionIsNotCountedAsConversationAndLatencyIsMedian() {
        let stats = ConversationStatistics()
        stats.record(.suppressed, reason: "同じ音の反復")
        stats.record(.latency, latency: 2)
        stats.record(.latency, latency: 20)
        stats.record(.latency, latency: 4)
        let s = stats.snapshot()
        XCTAssertEqual(s.suppressed["同じ音の反復"], 1)
        XCTAssertEqual(s.medianLatency, 4)
        XCTAssertEqual(s.latencySamples, 3)
        XCTAssertNil(s.replyShare)
        XCTAssertEqual(s.sessionInputs, 0)
        XCTAssertEqual(s.sessionReplies, 0)
    }
}
