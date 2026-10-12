import XCTest
@testable import GravityReader

final class ConversationSelfReviewTests: XCTestCase {
    func testVagueAnswerIsReviewedWithoutInventingSuccess() {
        let lesson = ConversationSelfReview.lesson(source: "じゃあ一つだけ教えて", response: "うーん、一つだけかぁ。", reactions: [])
        XCTAssertTrue(lesson.contains("具体"))
        XCTAssertTrue(lesson.contains("未確認"))
    }
    func testExplicitCorrectionAndNoFeedbackStayDistinct() {
        XCTAssertTrue(ConversationSelfReview.lesson(source: "夏は？", response: "いいよね。", reactions: ["A: 答えてない"]).contains("答え直す"))
        XCTAssertTrue(ConversationSelfReview.lesson(source: "旅行した", response: "いいね。", reactions: []).contains("成功と決めつけず"))
    }
}
