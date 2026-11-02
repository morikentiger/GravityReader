import XCTest
@testable import GravityReader

final class SpeakerFrontendTests: XCTestCase {
    func testMatchesIndependentSpeechBrainReferenceIncludingBoundaryFrames() throws {
        var waveform = [Float]()
        for n in 0..<48000 {
            let t = Double(n) / 16000
            let noise = Double((Int64(n) * 1103515245 + 12345) % 65536) / 65535 - 0.5
            let envelope = 0.45 + 0.35 * sin(4 * Double.pi * t)
            let chirp = 0.15 * envelope * sin(2 * Double.pi * (115 * t + 45 * t * t))
            let tone = 0.04 * cos(2 * Double.pi * 1700 * t)
            waveform.append(Float(chirp + tone + 0.015 * noise))
        }
        let features = try XCTUnwrap(SpeakerEmbeddingModel().computeMelFeatures(waveform))
        XCTAssertEqual(features.count, 301 * 80)
        XCTAssertTrue(features.allSatisfy { $0.isFinite })
        for (index, reference) in SpeakerFrontendReference.samples {
            XCTAssertEqual(features[index], reference, accuracy: 0.006, "frame=\(index / 80) band=\(index % 80)")
        }
        let rms = sqrt(features.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(features.count))
        XCTAssertEqual(rms, SpeakerFrontendReference.rms, accuracy: 0.002)
        // This model was trained with mean-only normalization, never unit variance.
        XCTAssertGreaterThan(rms, 3)
        for band in 0..<80 {
            let mean = (0..<301).reduce(0.0) { $0 + Double(features[$1 * 80 + band]) } / 301
            XCTAssertEqual(mean, 0, accuracy: 0.0001)
        }
    }

    func testSilenceAndMalformedFrontendInput() throws {
        let model = SpeakerEmbeddingModel()
        let silent = try XCTUnwrap(model.computeMelFeatures([Float](repeating: 0, count: 48000)))
        XCTAssertTrue(silent.allSatisfy { $0 == 0 })
        XCTAssertNil(model.computeMelFeatures([]))
        XCTAssertNil(model.computeMelFeatures([Float](repeating: 0, count: 47999)))
        var invalid = [Float](repeating: 0.1, count: 48000)
        invalid[120] = .nan
        XCTAssertNil(model.computeMelFeatures(invalid))
        XCTAssertEqual(model.resample([.infinity, 0.2], from: 16000, to: 16000), [])
    }
}
