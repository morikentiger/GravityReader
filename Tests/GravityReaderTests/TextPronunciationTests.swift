import XCTest
@testable import GravityReader

final class TextPronunciationTests: XCTestCase {
    func testEnglishIsNotConvertedToJapaneseRomaji() {
        XCTAssertEqual(TextPronunciation.prepare("Hello world, how are you?").language, "en-US")
        XCTAssertEqual(TextPronunciation.prepare("I like sushi").text, "I like sushi")
    }
    func testJapaneseRomajiUsesKana() {
        XCTAssertEqual(TextPronunciation.prepare("konnichiwa").text, "こんにちは")
        let result = TextPronunciation.prepare("watashi wa nihongo ga suki desu")
        XCTAssertEqual(result.language, "ja-JP")
        XCTAssertEqual(result.text, "わたし わ にほんご が すき です")
    }
    func testDisabledRomajiAndMixedJapanese() {
        XCTAssertEqual(TextPronunciation.prepare("konnichiwa", romajiEnabled: false).text, "konnichiwa")
        XCTAssertEqual(TextPronunciation.prepare("今日はSwiftの話").language, "ja-JP")
        XCTAssertEqual(TextPronunciation.prepare("https://example.com/watashi").text, "https://example.com/watashi")
    }
}
