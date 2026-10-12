import XCTest
@testable import GravityReader

final class StreamingDelegateTests: XCTestCase {
    func testByteSplitStreamCompletesOnceAndPreservesSentence() {
        let done = expectation(description: "completed")
        var sentences: [String] = []
        var completions = 0
        let delegate = StreamingDelegate(onSentence: { sentences.append($0) }, onComplete: { result in
            completions += 1
            XCTAssertEqual(result, "夏は夜だね。")
            done.fulfill()
        })
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.invalid")!)
        let wire = "data: {\"choices\":[{\"delta\":{\"content\":\"夏は夜だね。\"}}]}\n\ndata: [DONE]\n\n"
        for byte in wire.utf8 { delegate.urlSession(session, dataTask: task, didReceive: Data([byte])) }
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(sentences, ["夏は夜だね。"])
        XCTAssertEqual(completions, 1)
    }

    func testErrorResponseDoesNotRemainInFlight() {
        let done = expectation(description: "failed")
        let delegate = StreamingDelegate(onSentence: { _ in XCTFail("must not speak") }, onComplete: { result in
            XCTAssertNil(result)
            done.fulfill()
        })
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "https://example.invalid")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil)!
        delegate.urlSession(session, dataTask: task, didReceive: response) { disposition in XCTAssertEqual(disposition, .cancel) }
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        wait(for: [done], timeout: 2)
    }
}
