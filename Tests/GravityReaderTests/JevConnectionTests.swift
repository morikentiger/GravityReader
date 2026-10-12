import XCTest
@testable import GravityReader

final class JevConnectionTests: XCTestCase {
    private final class MockProtocol: URLProtocol {
        static var status = 200
        static var body = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func check(status: Int, body: String, verify: @escaping (JevCommentGate.Verdict, String) -> Void) {
        MockProtocol.status = status
        MockProtocol.body = Data(body.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        let done = expectation(description: "response")
        JevConnection.send(text: "test", context: [], key: "fake-key", session: session) { verdict, message in
            XCTAssertTrue(Thread.isMainThread)
            verify(verdict, message)
            session.invalidateAndCancel()
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testSuccessfulNormalDecisionReportsProbability() {
        check(status: 200, body: #"{"answers":{"moderation":{"type":"choice","choice":"normal","confidence":1,"probabilities":{"spam":0,"normal":1,"uncertain":0}}}}"#) { verdict, message in
            XCTAssertEqual(verdict, .allow)
            XCTAssertTrue(message.contains("判定成功"))
            XCTAssertTrue(message.contains("スパム確率 0%"))
        }
    }

    func testAuthenticationFailureIsSpecificAndDoesNotEchoServerBody() {
        check(status: 401, body: "fake-secret-server-body") { verdict, message in
            XCTAssertEqual(verdict, .unavailable)
            XCTAssertTrue(message.contains("401"))
            XCTAssertFalse(message.contains("fake-secret"))
        }
    }

    func testInvalidSuccessPayloadIsNotTreatedAsNormal() {
        check(status: 200, body: "{}") { verdict, message in
            XCTAssertEqual(verdict, .unavailable)
            XCTAssertTrue(message.contains("応答形式"))
        }
    }

    func testTimeoutAndRateLimitHaveDistinctReasons() {
        XCTAssertTrue(JevConnection.failure(status: nil, error: URLError(.timedOut)).contains("タイムアウト"))
        XCTAssertTrue(JevConnection.failure(status: 429, error: nil).contains("利用上限"))
        XCTAssertEqual(try JevCommentGate.makeRequest(text: "test", context: [], key: "fake").timeoutInterval, 5)
    }

    func testSavingConfigurationClearsFailureCooldown() {
        var calls = 0
        let gate = JevCommentGate { _, _, done in calls += 1; done(.unavailable) }
        gate.mode = { 2 }
        gate.submit("one") {}
        gate.submit("two") {}
        XCTAssertEqual(calls, 1)
        NotificationCenter.default.post(name: JevConnection.configurationChanged, object: nil)
        gate.submit("three") {}
        XCTAssertEqual(calls, 2)
    }
}
