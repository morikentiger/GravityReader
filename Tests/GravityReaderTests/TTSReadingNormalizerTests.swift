import XCTest
@testable import GravityReader

final class TTSReadingNormalizerTests: XCTestCase {
    private final class Stub: YUiAPIClient {
        var calls = 0
        var output: String? = "{\"reading\":\"こんにちは\"}"
        override func callJSON(systemPrompt: String, userMessage: String, completion: @escaping (String?) -> Void) {
            calls += 1
            XCTAssertTrue(systemPrompt.contains("TTSで読み取れるように"))
            completion(output)
        }
    }
    func testReadingIsCachedAndOriginalDoesNotChange() {
        let client = Stub(apiKey: "test-placeholder")
        let normalizer = TTSReadingNormalizer(apiClient: client)
        let done = expectation(description: "reading")
        let original = "konnichiwa"
        normalizer.normalize(original) { reading in
            XCTAssertEqual(reading, "こんにちは")
            normalizer.normalize(original) { again in
                XCTAssertEqual(again, reading)
                XCTAssertEqual(client.calls, 1)
                XCTAssertEqual(original, "konnichiwa")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)
    }
    func testInvalidNormalizationIsRejected() {
        XCTAssertNil(TTSReadingNormalizer.reading(from: "{}", original: "hi"))
        XCTAssertNil(TTSReadingNormalizer.reading(from: "{\"reading\":\"\"}", original: "hi"))
        XCTAssertNil(TTSReadingNormalizer.reading(from: "{\"reading\":\"" + String(repeating: "あ", count: 100) + "\"}", original: "hi"))
    }
}
