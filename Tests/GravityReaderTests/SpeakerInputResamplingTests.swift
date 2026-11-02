import XCTest
@testable import GravityReader

final class SpeakerInputResamplingTests: XCTestCase {
    func test48kMicrophoneKeepsDurationAndPitchAt44100() {
        let model = SpeakerEmbeddingModel()
        let input = (0..<48000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48000)) * 0.1 }
        let output = model.resample(input, from: 48000, to: 44100)
        XCTAssertEqual(Double(output.count) / 44100, 1, accuracy: 0.01)
        XCTAssertTrue(output.allSatisfy { $0.isFinite })
        let crossings = zip(output, output.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        XCTAssertEqual(Double(crossings), 1000, accuracy: 12)
    }
    func testNoOpAndInvalidInput() {
        let model = SpeakerEmbeddingModel()
        XCTAssertEqual(model.resample([0.1, -0.1], from: 44100, to: 44100), [0.1, -0.1])
        XCTAssertEqual(model.resample([], from: 48000, to: 44100), [])
        XCTAssertEqual(model.resample([1], from: 0, to: 44100), [])
        XCTAssertEqual(model.resample([1], from: .nan, to: 44100), [])
    }
}
