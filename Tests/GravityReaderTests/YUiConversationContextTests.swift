import XCTest
@testable import GravityReader

final class YUiConversationContextTests: XCTestCase {
    func testBudgetKeepsLatestAndValidUnicode() {
        let entries = (0..<40).map { "話者\($0): " + String(repeating: "日本語🙂", count: 100) }
        let recent = YUiConversationContext.recent(entries, bytes: 2000)
        XCTAssertLessThanOrEqual(recent.joined(separator: "\n").utf8.count, 2000)
        XCTAssertTrue(recent.last!.hasPrefix("話者39:"))
        XCTAssertEqual(YUiConversationContext.clipped("🙂あ", bytes: 4), "🙂")
        XCTAssertEqual(YUiConversationContext.clipped("🙂あ", bytes: 3), "")
    }

    func testTrailingHumanReplyIsKept() {
        let messages = YUiConversationContext.messages(from: ["A: 京都に行った", "YUi: お寺を見た？", "A[コメント]: そう、清水寺！"])
        XCTAssertEqual(messages.map { $0["role"]! }, ["user", "assistant", "user"])
        XCTAssertEqual(messages.last?["content"], "A[コメント]: そう、清水寺！")
        XCTAssertEqual(messages[1]["content"], "お寺を見た？")
    }

    func testVoiceAndCommentsKeepTheirOrder() {
        let entries = ["A: 昨日は大阪", "B[コメント]: 今日は京都？", "A: そうだよ"]
        XCTAssertEqual(YUiConversationContext.messages(from: entries).first?["content"], entries.joined(separator: "\n"))
    }
}
