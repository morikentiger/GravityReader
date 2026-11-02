import XCTest
@testable import GravityReader

final class SiameseSpeakerMetricTests: XCTestCase {
    private func observations() -> [SiameseSpeakerMetric.Observation] {
        // Dimension 3 carries nuisance variation shared by different people.
        // Training must suppress it, preserving speaker information in dims 1/2.
        ["A", "B"].flatMap { speaker in
            [Float(2), -2, 1.8, -1.8].enumerated().map { index, nuisance in
                SiameseSpeakerMetric.Observation(speaker: speaker, sessionID: "\(speaker)-\(index)",
                    embedding: speaker == "A" ? [1, 0, nuisance] : [0, 1, nuisance])
            }
        }
    }

    func testActuallyLearnsSharedProjectionAndValidatesSeparateSessions() throws {
        guard case .ready(let model) = SiameseSpeakerMetric.train(observations: observations(), dimension: 3) else {
            return XCTFail("separable synthetic enrollment should learn")
        }
        XCTAssertTrue(model.isValid)
        XCTAssertLessThan(model.scales[2], model.scales[0])
        XCTAssertLessThan(model.validation.contrastiveLoss, model.validation.baselineContrastiveLoss)
        XCTAssertEqual(model.validation.trainingSessions, 4)
        XCTAssertEqual(model.validation.validationSessions, 4)
        XCTAssertEqual(model.validation.falseAcceptRate, 0)
        XCTAssertLessThanOrEqual(model.validation.falseRejectRate, model.validation.baselineFalseRejectRate)
        let same = try XCTUnwrap(model.similarity([1, 0, 1.5], [1, 0, -1.5]))
        let different = try XCTUnwrap(model.similarity([1, 0, 1.5], [0, 1, 1.5]))
        XCTAssertGreaterThan(same, model.similarityThreshold)
        XCTAssertLessThan(different, model.similarityThreshold)
        XCTAssertEqual(try XCTUnwrap(model.similarity([0, 1, 1.5], [1, 0, 1.5])), different, accuracy: 1e-6)
        XCTAssertGreaterThan(same - different, model.similarityMargin)
    }

    func testMultipleWindowsCannotPretendToBeIndependentEnrollmentSessions() {
        var rows = observations()
        rows = rows.map { .init(speaker: $0.speaker, sessionID: $0.speaker, embedding: $0.embedding) }
        guard case .notReady = SiameseSpeakerMetric.train(observations: rows, dimension: 3) else {
            return XCTFail("one recording per speaker must not be split into train and validation")
        }
    }

    func testSingleSpeakerCannotTrainNegativePairs() {
        guard case .notReady = SiameseSpeakerMetric.train(observations: observations().filter { $0.speaker == "A" }, dimension: 3) else {
            return XCTFail("needs at least two speakers")
        }
    }

    func testContradictorySessionLabelsAreRejected() {
        var rows = observations()
        rows.append(.init(speaker: "B", sessionID: "A-0", embedding: [1, 0, 2]))
        guard case .rejected = SiameseSpeakerMetric.train(observations: rows, dimension: 3) else {
            return XCTFail("conflicting session labels must not train")
        }
    }

    func testInvalidVectorsAreRejectedRatherThanPoisonTraining() {
        for vector in [[Float.nan, 0, 1], [Float.infinity, 0, 1], [0, 0, 0], [1, 0]] {
            var rows = observations()
            rows.append(.init(speaker: "A", sessionID: "bad", embedding: vector))
            guard case .rejected = SiameseSpeakerMetric.train(observations: rows, dimension: 3) else {
                return XCTFail("invalid vector should reject")
            }
        }
    }

    func testIndistinguishableSpeakersDoNotReplaceBaseline() {
        let rows = observations().map { SiameseSpeakerMetric.Observation(speaker: $0.speaker, sessionID: $0.sessionID, embedding: [1, 0, 0]) }
        guard case .rejected = SiameseSpeakerMetric.train(observations: rows, dimension: 3) else {
            return XCTFail("no discriminative signal must retain baseline")
        }
    }

    func testHeldOutFailureCannotBeHiddenByGoodTrainingLoss() {
        let rows = observations().map { row -> SiameseSpeakerMetric.Observation in
            if row.sessionID.hasSuffix("2") || row.sessionID.hasSuffix("3") {
                return .init(speaker: row.speaker, sessionID: row.sessionID, embedding: [1, 0, 0])
            }
            return row
        }
        guard case .rejected = SiameseSpeakerMetric.train(observations: rows, dimension: 3) else {
            return XCTFail("validation false accepts must reject candidate")
        }
    }

    func testGoodHeldOutPairsCannotHideWrongTrainingReferenceIdentities() {
        // Each heldout class remains internally consistent, so pair verification
        // alone passes. Its identity is swapped relative to training references.
        let rows = observations().map { row -> SiameseSpeakerMetric.Observation in
            guard row.sessionID.hasSuffix("2") || row.sessionID.hasSuffix("3") else { return row }
            var embedding = row.embedding
            embedding.swapAt(0, 1)
            return .init(speaker: row.speaker, sessionID: row.sessionID, embedding: embedding)
        }
        guard case .rejected = SiameseSpeakerMetric.train(observations: rows, dimension: 3) else {
            return XCTFail("heldout query classification must check real registered identities")
        }
    }

    func testContrastiveGradientMatchesFiniteDifferencesForBothClasses() throws {
        let a: [Float] = [1, 0.2, 1.5], b: [Float] = [0.3, 1, 1.2]
        let logScales: [Float] = [0.2, -0.1, 0.3]
        let epsilon: Float = 0.001
        for same in [true, false] {
            let analytic = try XCTUnwrap(SiameseSpeakerMetric.contrastivePair(a: a, b: b, scales: logScales.map { exp($0) }, same: same))
            for index in logScales.indices {
                var plus = logScales, minus = logScales
                plus[index] += epsilon; minus[index] -= epsilon
                let upper = try XCTUnwrap(SiameseSpeakerMetric.contrastivePair(a: a, b: b, scales: plus.map { exp($0) }, same: same)).loss
                let lower = try XCTUnwrap(SiameseSpeakerMetric.contrastivePair(a: a, b: b, scales: minus.map { exp($0) }, same: same)).loss
                XCTAssertEqual(analytic.gradient[index], (upper - lower) / (2 * epsilon), accuracy: 0.0003)
            }
        }
    }

    func testProductionDimensionWorksAndDataLimitsAreEnforced() {
        let rows = observations().map { SiameseSpeakerMetric.Observation(speaker: $0.speaker, sessionID: $0.sessionID, embedding: $0.embedding + Array(repeating: 0, count: 189)) }
        guard case .ready(let model) = SiameseSpeakerMetric.train(observations: rows) else { return XCTFail("192-dimensional training must work") }
        XCTAssertEqual(model.dimension, 192)
        let tooManySpeakers = (0..<17).flatMap { speaker in
            (0..<4).map { session in SiameseSpeakerMetric.Observation(speaker: "s\(speaker)", sessionID: "s\(speaker)-\(session)", embedding: [1, 0, 0]) }
        }
        guard case .notReady = SiameseSpeakerMetric.train(observations: tooManySpeakers, dimension: 3) else { return XCTFail("must not silently omit speakers") }
        guard case .rejected = SiameseSpeakerMetric.train(observations: Array(repeating: observations()[0], count: 2049), dimension: 3) else { return XCTFail("must bound sample count") }
    }

    func testModelRoundTripAndInvalidInferenceVectors() throws {
        guard case .ready(let model) = SiameseSpeakerMetric.train(observations: observations(), dimension: 3) else { return XCTFail("model required") }
        let reloaded = try JSONDecoder().decode(SiameseSpeakerMetric.Model.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(reloaded, model)
        XCTAssertNil(reloaded.similarity([1, 0], [1, 0]))
        XCTAssertNil(reloaded.similarity([0, 0, 0], [1, 0, 0]))
        XCTAssertNil(reloaded.similarity([.nan, 0, 1], [1, 0, 0]))
        guard case .ready(let repeated) = SiameseSpeakerMetric.train(observations: observations().reversed(), dimension: 3) else { return XCTFail("model required") }
        XCTAssertEqual(repeated, model)
    }
}
