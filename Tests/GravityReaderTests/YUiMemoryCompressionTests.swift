import XCTest
@testable import GravityReader

final class YUiMemoryCompressionTests: XCTestCase {
    private final class StubClient: YUiAPIClient {
        var result: String?
        var calls = 0
        override func callRaw(systemPrompt: String, userMessage: String, completion: @escaping (String?) -> Void) {
            calls += 1
            completion(result)
        }
    }

    func testFailurePreservesConversationAndAvoidsImmediateRetry() {
        let memory = YUiMemoryManager()
        let client = StubClient(apiKey: "test-placeholder")
        memory.conversationMemory = (0..<30).map { (Date().addingTimeInterval(Double($0)), "A: " + String(repeating: "会話", count: 80)) }
        memory.compressMemory(apiClient: client)
        let done = expectation(description: "callback")
        DispatchQueue.main.async {
            XCTAssertEqual(memory.conversationMemory.count, 30)
            memory.compressMemory(apiClient: client)
            XCTAssertEqual(client.calls, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}
