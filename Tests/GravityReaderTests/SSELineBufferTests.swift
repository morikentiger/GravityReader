import XCTest
@testable import GravityReader

final class SSELineBufferTests: XCTestCase {
    func testEveryByteSplitPreservesJapaneseAndEventBoundaries() {
        let source = "data: {\"content\":\"夏は夜🙂\"}\r\n\r\ndata: [DONE]\n"
        let data = Data(source.utf8)
        let expected = ["data: {\"content\":\"夏は夜🙂\"}", "", "data: [DONE]"]
        for split in 0...data.count {
            var buffer = SSELineBuffer()
            let lines = buffer.append(Data(data.prefix(split))) + buffer.append(Data(data.dropFirst(split)))
            XCTAssertEqual(lines, expected, "split \(split)")
            XCTAssertNil(buffer.finish())
        }
    }
    func testSingleByteChunksAndMissingFinalNewline() {
        var buffer = SSELineBuffer()
        var lines: [String] = []
        for byte in "data: 夏は夜\ndata: [DONE]".utf8 { lines += buffer.append(Data([byte])) }
        XCTAssertEqual(lines, ["data: 夏は夜"])
        XCTAssertEqual(buffer.finish(), "data: [DONE]")
        XCTAssertNil(buffer.finish())
    }
}
