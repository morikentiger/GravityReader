import XCTest
@testable import GravityReader

final class YUiSpamFilterTests: XCTestCase {

    // MARK: - detectSpamLevel

    func testCleanMessage() {
        XCTAssertEqual(YUiSpamFilter.detectSpamLevel("こんにちは"), .clean)
        XCTAssertEqual(YUiSpamFilter.detectSpamLevel("今日はいい天気だね"), .clean)
    }

    func testEmptyIsFullSpam() {
        XCTAssertEqual(YUiSpamFilter.detectSpamLevel(""), .fullSpam)
        XCTAssertEqual(YUiSpamFilter.detectSpamLevel("   "), .fullSpam)
    }

    func testRepetitiveSpam() {
        XCTAssertEqual(YUiSpamFilter.detectSpamLevel("おいおいおいおいおいおいおいおいおいおい"), .fullSpam)
        XCTAssertEqual(YUiSpamFilter.detectSpamLevel("ああああああああああ"), .fullSpam)
    }

    func testInappropriateContent() {
        XCTAssertEqual(YUiSpamFilter.detectSpamLevel("えっちな話しよう"), .inappropriate)
    }

    func testShortNormalMessages() {
        XCTAssertEqual(YUiSpamFilter.detectSpamLevel("おい"), .clean)
        XCTAssertEqual(YUiSpamFilter.detectSpamLevel("ねぇ"), .clean)
    }

    // MARK: - isRepetitiveSpam

    func testIsRepetitiveSpamWithUniqueChars() {
        XCTAssertTrue(YUiSpamFilter.isRepetitiveSpam("ああああああああああ"))
        XCTAssertFalse(YUiSpamFilter.isRepetitiveSpam("こんにちは"))
    }

    func testIsRepetitiveSpamWithRepeatedUnit() {
        XCTAssertTrue(YUiSpamFilter.isRepetitiveSpam("おいおいおいおいおい"))
        XCTAssertFalse(YUiSpamFilter.isRepetitiveSpam("おいしい"))
    }

    // MARK: - isTooSimilarToPast

    func testSimilarResponse() {
        // Same keywords should be detected as similar
        let history = ["今日はいい天気だね散歩に行きたいなラーメン食べたい"]
        XCTAssertTrue(YUiSpamFilter.isTooSimilarToPast("今日は天気がいいから散歩してラーメン食べよう", history: history))
    }

    func testDifferentResponse() {
        let history = ["ラーメン食べたいな"]
        XCTAssertFalse(YUiSpamFilter.isTooSimilarToPast("プログラミングの話をしよう", history: history))
    }

    func testEmptyHistory() {
        XCTAssertFalse(YUiSpamFilter.isTooSimilarToPast("何か話そう", history: []))
    }

    // MARK: - extractKeywords

    func testExtractKeywords() {
        let keywords = YUiSpamFilter.extractKeywords("今日はラーメンが美味しかった")
        XCTAssertTrue(keywords.contains("ラーメン"))
    }

    func testExtractKeywordsEmpty() {
        let keywords = YUiSpamFilter.extractKeywords("a b c")
        XCTAssertTrue(keywords.isEmpty)
    }

    // MARK: - detectTopicType

    func testDetectTechTopic() {
        let messages = ["コードにバグがあってデプロイできない", "APIのエラーが出てる"]
        let topic = YUiSpamFilter.detectTopicType(from: messages)
        XCTAssertNotNil(topic)
        XCTAssertTrue(topic!.contains("技術"))
    }

    func testDetectNegativeTopic() {
        let messages = ["疲れた、もうしんどい", "つらいよなぁ"]
        let topic = YUiSpamFilter.detectTopicType(from: messages)
        XCTAssertNotNil(topic)
        XCTAssertTrue(topic!.contains("ネガティブ"))
    }

    func testDetectNoTopic() {
        let messages = ["おはよう"]
        let topic = YUiSpamFilter.detectTopicType(from: messages)
        XCTAssertNil(topic)
    }
}
