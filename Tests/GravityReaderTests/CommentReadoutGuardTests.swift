import XCTest
@testable import GravityReader

final class CommentReadoutGuardTests: XCTestCase {
    func testRepeatsInsideSentenceAndLongWords() {
        let guarder = CommentReadoutGuard()
        XCTAssertNotNil(guarder.suppressionReason("ねえ、こんにちは！こんにちは！こんにちは！こんにちは！", speaker: "A"))
        XCTAssertNotNil(guarder.suppressionReason("ああああああああ", speaker: "B"))
        XCTAssertNil(guarder.suppressionReason("うんうん、今日は楽しかったね", speaker: "A"))
    }

    func testDuplicateAcrossNamesAndExpiry() {
        let guarder = CommentReadoutGuard()
        let now = Date()
        XCTAssertNil(guarder.suppressionReason("こんにちは！", speaker: "A", now: now))
        XCTAssertNotNil(guarder.suppressionReason("こんにちは！！！", speaker: "B", now: now.addingTimeInterval(1)))
        XCTAssertNil(guarder.suppressionReason("こんにちは", speaker: "B", now: now.addingTimeInterval(31)))
    }

    func testFloodDoesNotSilenceOtherSpeakers() {
        let guarder = CommentReadoutGuard()
        let now = Date()
        for text in ["今日はいい天気", "散歩したよ", "楽しかった"] {
            XCTAssertNil(guarder.suppressionReason(text, speaker: "A", now: now))
        }
        XCTAssertNotNil(guarder.suppressionReason("次は買い物", speaker: "A", now: now))
        XCTAssertNil(guarder.suppressionReason("それはいいね", speaker: "B", now: now))
    }
}
