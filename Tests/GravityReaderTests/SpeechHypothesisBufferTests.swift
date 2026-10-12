import XCTest
@testable import GravityReader

final class SpeechHypothesisBufferTests: XCTestCase {
    func testRevisionsReplaceRatherThanAppend() {
        var buffer = SpeechHypothesisBuffer()
        for text in ["続いてその久方", "続いてその久方方の方の", "続いてその久方のに答答え", "続いてその久方のに答えて", "続いてその久方のに答えて欲しい"] {
            buffer.update(text, speaker: "もりけん")
        }
        XCTAssertEqual(buffer.text, "続いてその久方のに答えて欲しい")
        XCTAssertEqual(buffer.segments, [.init(speaker: "もりけん", text: buffer.text)])
    }

    func testRetractionRemovesSupersededText() {
        var buffer = SpeechHypothesisBuffer()
        buffer.update("今日は東京に行きました", speaker: "A")
        buffer.update("今日は京都", speaker: "B")
        XCTAssertEqual(buffer.text, "今日は京都")
        XCTAssertEqual(buffer.segments, [.init(speaker: "A", text: "今日は京都")])
    }

    func testSpeakerOrderAndSessionReset() {
        var buffer = SpeechHypothesisBuffer()
        buffer.update("こんにちは", speaker: "A")
        buffer.update("こんにちはおはよう", speaker: "B")
        buffer.update("こんにちはおはようまたね", speaker: "A")
        XCTAssertEqual(buffer.segments.map { $0.speaker }, ["A", "B", "A"])
        buffer.reset()
        buffer.update("新しい会話", speaker: "C")
        XCTAssertEqual(buffer.segments, [.init(speaker: "C", text: "新しい会話")])
    }

    func testFragmentsAreNotActionableButShortRepliesAre() {
        XCTAssertFalse(VoiceInputPolicy.isActionable("おじ"))
        XCTAssertFalse(VoiceInputPolicy.isActionable("ゃじゃあ"))
        XCTAssertTrue(VoiceInputPolicy.isActionable("夏は？"))
        XCTAssertTrue(VoiceInputPolicy.isActionable("やめて"))
        XCTAssertTrue(VoiceInputPolicy.isActionable("その続きに答えてほしい"))
    }
}
