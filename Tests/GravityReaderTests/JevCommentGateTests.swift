import XCTest
@testable import GravityReader

final class JevCommentGateTests: XCTestCase {
    private func answer(_ choice: String, spam: Double, confidence: Double) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["answers": ["moderation": ["type": "choice", "choice": choice, "probabilities": ["spam": spam, "normal": 1-spam, "uncertain": 0], "confidence": confidence]]])
    }

    func testOnlyStrongSpamDecisionSuppresses() throws {
        XCTAssertEqual(JevCommentGate.parse(try answer("spam", spam: 0.98, confidence: 0.96)), .spam)
        XCTAssertEqual(JevCommentGate.parse(try answer("spam", spam: 0.8, confidence: 0.96)), .allow)
        XCTAssertEqual(JevCommentGate.parse(try answer("spam", spam: 0.98, confidence: 0.5)), .allow)
        XCTAssertEqual(JevCommentGate.parse(try answer("uncertain", spam: 0.5, confidence: 0.1)), .allow)
        XCTAssertEqual(JevCommentGate.parse(Data("{}".utf8)), .unavailable)
        XCTAssertEqual(JevCommentGate.parse(try answer("spam", spam: 2, confidence: 1)), .unavailable)
    }

    func testObservationDoesNotDropAndSuppressionDoes() {
        let gate = JevCommentGate { _, _, done in done(.spam) }
        var count = 0
        gate.mode = { 1 }
        gate.submit("test") { count += 1 }
        XCTAssertEqual(count, 1)
        gate.mode = { 2 }
        gate.submit("test2") { count += 1 }
        XCTAssertEqual(count, 1)
    }

    func testOrderResetAndLateCallback() {
        var callbacks: [(JevCommentGate.Verdict) -> Void] = []
        let gate = JevCommentGate { _, _, done in callbacks.append(done) }
        gate.mode = { 2 }
        var delivered: [Int] = []
        gate.submit("first") { delivered.append(1) }
        gate.submit("second") { delivered.append(2) }
        XCTAssertEqual(callbacks.count, 1)
        callbacks[0](.allow)
        XCTAssertEqual(delivered, [1])
        XCTAssertEqual(callbacks.count, 2)
        gate.reset()
        callbacks[1](.allow)
        XCTAssertEqual(delivered, [1])
    }

    func testFailureFallsBackAndStopsRepeatedRequests() {
        var calls = 0
        let gate = JevCommentGate { _, _, done in calls += 1; done(.unavailable) }
        gate.mode = { 2 }
        var delivered = 0
        gate.submit("first") { delivered += 1 }
        gate.submit("second") { delivered += 1 }
        XCTAssertEqual(delivered, 2)
        XCTAssertEqual(calls, 1)
    }

    func testDisableWhileWaitingDoesNotSuppress() {
        var completion: ((JevCommentGate.Verdict) -> Void)?
        let gate = JevCommentGate { _, _, done in completion = done }
        gate.mode = { 2 }
        var delivered = false
        gate.submit("test") { delivered = true }
        gate.mode = { 0 }
        completion?(.spam)
        XCTAssertTrue(delivered)
    }

    func testQueueIsBounded() {
        var callback: ((JevCommentGate.Verdict) -> Void)?
        let gate = JevCommentGate { _, _, done in callback = done }
        gate.mode = { 2 }
        var delivered = 0
        for index in 0..<20 { gate.submit(String(index)) { delivered += 1 } }
        // One active plus eight waiting. Excess comments never reach TTS/YUi.
        gate.mode = { 0 }
        callback?(.allow)
        XCTAssertEqual(delivered, 9)
    }

    func testTimeoutReleasesCommentOnce() {
        let finished = expectation(description: "timeout fallback")
        var late: ((JevCommentGate.Verdict) -> Void)?
        let gate = JevCommentGate(deadlineSeconds: 0.05) { _, _, done in late = done }
        gate.mode = { 2 }
        var delivered = 0
        gate.submit("test") { delivered += 1; finished.fulfill() }
        wait(for: [finished], timeout: 4)
        late?(.allow)
        XCTAssertEqual(delivered, 1)
        withExtendedLifetime(gate) {}
    }

    func testRequestBoundsContextAndPreservesQuotedInput() throws {
        let request = try JevCommentGate.makeRequest(text: String(repeating: "あ", count: 1000), context: Array(repeating: String(repeating: "x", count: 1000), count: 50), key: "fake")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let state = try XCTUnwrap(json["state"] as? [String: Any])
        XCTAssertEqual((state["comment"] as? String)?.count, 200)
        let context = try XCTUnwrap(state["recent_comments"] as? [String])
        XCTAssertEqual(context.count, 3)
        XCTAssertTrue(context.allSatisfy { $0.count == 200 })
        XCTAssertNil(state["speaker"])
        XCTAssertEqual(request.url?.host, "api.typesafe.ai")
    }
}
