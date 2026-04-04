import XCTest
@testable import GravityReader

final class MFCCFeatureExtractorTests: XCTestCase {
    let extractor = MFCCFeatureExtractor()

    // MARK: - Mel conversion

    func testHzToMelAndBack() {
        let hz: Float = 1000.0
        let mel = extractor.hzToMel(hz)
        let backHz = extractor.melToHz(mel)
        XCTAssertEqual(backHz, hz, accuracy: 0.1)
    }

    func testHzToMelZero() {
        XCTAssertEqual(extractor.hzToMel(0), 0, accuracy: 0.001)
    }

    func testMelToHzZero() {
        XCTAssertEqual(extractor.melToHz(0), 0, accuracy: 0.001)
    }

    // MARK: - Hamming window

    func testHammingWindowLength() {
        let input: [Float] = Array(repeating: 1.0, count: 256)
        let windowed = extractor.applyHammingWindow(input)
        XCTAssertEqual(windowed.count, input.count)
    }

    func testHammingWindowEdgesAreLow() {
        let input: [Float] = Array(repeating: 1.0, count: 256)
        let windowed = extractor.applyHammingWindow(input)
        XCTAssertLessThan(windowed[0], 0.1)
        XCTAssertLessThan(windowed[255], 0.1)
    }

    func testHammingWindowCenterIsHigh() {
        let input: [Float] = Array(repeating: 1.0, count: 256)
        let windowed = extractor.applyHammingWindow(input)
        XCTAssertGreaterThan(windowed[128], 0.9)
    }

    // MARK: - Power spectrum

    func testPowerSpectrumLength() {
        let input: [Float] = Array(repeating: 0.5, count: 512)
        guard let spectrum = extractor.computePowerSpectrum(input) else {
            XCTFail("Power spectrum should not be nil for valid input")
            return
        }
        XCTAssertEqual(spectrum.count, 256) // N/2
    }

    func testPowerSpectrumNonNegative() {
        let input: [Float] = (0..<512).map { Float(sin(Double($0) * 0.1)) }
        guard let spectrum = extractor.computePowerSpectrum(input) else {
            XCTFail("Power spectrum should not be nil")
            return
        }
        for val in spectrum {
            XCTAssertGreaterThanOrEqual(val, 0)
        }
    }

    // MARK: - Pitch estimation

    func testEstimatePitchWithSineWave() {
        let sampleRate: Float = 16000
        let freq: Float = 200
        let duration: Float = 0.1
        let numSamples = Int(sampleRate * duration)
        let samples: [Float] = (0..<numSamples).map { i in
            sin(2.0 * Float.pi * freq * Float(i) / sampleRate)
        }
        let pitch = extractor.estimatePitch(samples)
        if let pitch = pitch {
            XCTAssertEqual(pitch, freq, accuracy: 100)
        }
    }

    func testEstimatePitchWithSilence() {
        let samples: [Float] = Array(repeating: 0, count: 1600)
        let pitch = extractor.estimatePitch(samples)
        XCTAssertNil(pitch)
    }

    // MARK: - Feature extraction

    func testExtractFullFeaturesWithAudio() {
        let samples: [Float] = (0..<16000).map { Float(sin(Double($0) * 0.05)) }
        let features = extractor.extractFullFeatures(from: samples)
        XCTAssertNotNil(features)
        if let features = features {
            XCTAssertFalse(features.isEmpty)
        }
    }

    func testExtractFullFeaturesWithShortAudio() {
        let samples: [Float] = Array(repeating: 0.1, count: 100)
        // Very short audio - should not crash regardless of result
        _ = extractor.extractFullFeatures(from: samples)
    }

    // MARK: - Pitch match score

    func testPitchMatchScoreWithMatchingPitch() {
        let sampleRate: Float = 16000
        let freq: Float = 150
        let samples: [Float] = (0..<16000).map { i in
            sin(2.0 * Float.pi * freq * Float(i) / sampleRate)
        }
        if let score = extractor.pitchMatchScore(samples: samples, profilePitchMean: 150, profilePitchStd: 10) {
            XCTAssertGreaterThan(Double(score), 0.0)
        }
    }
}
