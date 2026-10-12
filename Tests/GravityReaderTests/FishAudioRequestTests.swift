import XCTest
@testable import GravityReader

final class FishAudioRequestTests: XCTestCase {
    func testRequestUsesFishCredentialsAndVoice() throws {
        let request = try FishAudioRequest.make(text: "こんにちは & Hello", apiKey: "test-key", referenceID: " voice-id \n", model: "s1")
        XCTAssertEqual(request.url?.absoluteString, "https://api.fish.audio/v1/tts")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "model"), "s1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "こんにちは & Hello")
        XCTAssertEqual(body["reference_id"] as? String, "voice-id")
        XCTAssertEqual(body["format"] as? String, "mp3")
        XCTAssertNil(body["api_key"])
    }

    func testUnknownModelDoesNotFallBackToPaidServerDefault() throws {
        let request = try FishAudioRequest.make(text: "test", apiKey: "fake", referenceID: " ", model: "unknown")
        XCTAssertEqual(request.value(forHTTPHeaderField: "model"), "s2.1-pro-free")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["reference_id"])
    }

    func testFailureMessagesAreActionable() {
        XCTAssertTrue(FishAudioRequest.failureMessage(status: 401).contains("APIキー"))
        XCTAssertTrue(FishAudioRequest.failureMessage(status: 402).contains("残高"))
        XCTAssertTrue(FishAudioRequest.failureMessage(status: 429).contains("上限"))
        XCTAssertTrue(FishAudioRequest.failureMessage(status: nil).contains("接続"))
    }
}
