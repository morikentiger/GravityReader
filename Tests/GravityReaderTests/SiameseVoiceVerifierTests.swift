import XCTest
@testable import GravityReader

final class SiameseVoiceVerifierTests: XCTestCase {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("siamese.json") }
    private func model(_ dimension: Int) -> SiameseSpeakerMetric.Model {
        .init(version: 1, dimension: dimension, scales: Array(repeating: 1, count: dimension), similarityThreshold: 0.8, similarityMargin: 0.06,
              validation: .init(trainingSessions: 4, validationSessions: 4, positivePairs: 2, negativePairs: 4,
                                falseAcceptRate: 0, falseRejectRate: 0, baselineFalseAcceptRate: 0, baselineFalseRejectRate: 0,
                                contrastiveLoss: 0.01, baselineContrastiveLoss: 0.1))
    }
    private func addExamples(_ verifier: SiameseVoiceVerifier, dimension: Int) {
        for speaker in 0..<2 {
            for i in 0..<4 {
                var vector = Array(repeating: Float(0), count: dimension)
                vector[speaker] = 1
                vector[1 - speaker] = Float(i + 1) * 0.01
                XCTAssertTrue(verifier.recordEnrollment(speaker: speaker == 0 ? "A" : "B", embedding: vector, sessionID: "\(speaker)-\(i)"))
            }
        }
    }
    func testExplicitRecordingsPersistAndUnknownDoesNotFallBack() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let expectedModel = model(2)
        let verifier = SiameseVoiceVerifier(url: url, dimension: 2, train: { _, _ in .ready(expectedModel) })
        let ready = expectation(description: "background learning")
        verifier.onStatusChanged = { _ in if verifier.model != nil { ready.fulfill() } }
        addExamples(verifier, dimension: 2)
        wait(for: [ready], timeout: 3)
        XCTAssertEqual(verifier.identify([1, 0], speakers: ["A", "B"])?.speaker, "A")
        XCTAssertNil(verifier.identify([1, 1], speakers: ["A", "B"]))
        XCTAssertNil(verifier.identify([-1, -1], speakers: ["A", "B"]))
        XCTAssertFalse(verifier.canUseModel(for: ["A", "B", "C"]))
        let loaded = SiameseVoiceVerifier(url: url, dimension: 2)
        XCTAssertEqual(loaded.enrollmentCounts, ["A": 4, "B": 4])
        XCTAssertNotNil(loaded.model)
        loaded.removeSpeaker("A")
        XCTAssertNil(loaded.model)
        XCTAssertNil(SiameseVoiceVerifier(url: url, dimension: 2).enrollmentCounts["A"])
    }
    func testRepeatedSessionAndInvalidVectorsCannotBecomeTrainingEvidence() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let verifier = SiameseVoiceVerifier(url: url, dimension: 2)
        XCTAssertTrue(verifier.recordEnrollment(speaker: "A", embedding: [1, 0], sessionID: "one"))
        XCTAssertFalse(verifier.recordEnrollment(speaker: "B", embedding: [0, 1], sessionID: "one"))
        XCTAssertFalse(verifier.recordEnrollment(speaker: "A", embedding: [2, 0], sessionID: "two"))
        XCTAssertFalse(verifier.recordEnrollment(speaker: "A", embedding: [.nan, 0]))
        XCTAssertFalse(verifier.recordEnrollment(speaker: "A", embedding: [0, 0]))
        XCTAssertEqual(verifier.enrollmentCounts, ["A": 1])
        XCTAssertNil(verifier.model)
    }
    func testClearInvalidatesTrainingAlreadyInFlight() {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let training = expectation(description: "training started")
        let completed = expectation(description: "training callback drained")
        let release = DispatchSemaphore(value: 0)
        let expectedModel = model(2)
        let verifier = SiameseVoiceVerifier(url: url, dimension: 2, train: { _, _ in
            training.fulfill()
            _ = release.wait(timeout: .now() + 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { completed.fulfill() }
            return .ready(expectedModel)
        })
        addExamples(verifier, dimension: 2)
        wait(for: [training], timeout: 3)
        verifier.removeAll()
        release.signal()
        wait(for: [completed], timeout: 3)
        XCTAssertNil(verifier.model)
        XCTAssertTrue(verifier.observations.isEmpty)
        XCTAssertTrue(SiameseVoiceVerifier(url: url, dimension: 2).observations.isEmpty)
    }
    func testCorruptArchiveIsNotOverwrittenOnEnrollment() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("broken".utf8)
        try bytes.write(to: url)
        let verifier = SiameseVoiceVerifier(url: url, dimension: 2)
        XCTAssertFalse(verifier.recordEnrollment(speaker: "A", embedding: [1, 0]))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testDiarizerUsesStrictSiameseAndDoesNotSelfTrain() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let expectedModel = model(192)
        let verifier = SiameseVoiceVerifier(url: url, train: { _, _ in .ready(expectedModel) })
        let ready = expectation(description: "ready")
        verifier.onStatusChanged = { _ in if verifier.model != nil { ready.fulfill() } }
        addExamples(verifier, dimension: 192)
        wait(for: [ready], timeout: 3)
        let store = VoiceProfileStore(profilesURL: url.deletingLastPathComponent().appendingPathComponent("profiles.json"))
        let diarizer = VoiceDiarizer(profileStore: store, siameseVerifier: verifier)
        diarizer.siameseEnabled = true
        diarizer.diagnosticsEnabled = false
        diarizer.switchToNeuralMode()
        var a = Array(repeating: Float(0), count: 192); a[0] = 1
        var b = Array(repeating: Float(0), count: 192); b[1] = 1
        diarizer.enroll(speaker: "A", features: a)
        diarizer.enroll(speaker: "B", features: b)
        XCTAssertTrue(diarizer.isUsingSiamese)
        XCTAssertEqual(diarizer.identify(features: a)?.speaker, "A")
        for _ in 0..<5 { diarizer.voting.addVote(speaker: "A", score: 1) }
        var ambiguous = a; ambiguous[1] = 1
        XCTAssertNil(diarizer.identify(features: ambiguous))
        let count = store.profiles["A"]?.sampleCount
        diarizer.adaptiveUpdate(speaker: "A", features: a)
        XCTAssertEqual(store.profiles["A"]?.sampleCount, count)
        XCTAssertEqual(verifier.enrollmentCounts["A"], 4)
    }
}
