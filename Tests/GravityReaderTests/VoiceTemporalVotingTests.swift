import XCTest
@testable import GravityReader

final class VoiceTemporalVotingTests: XCTestCase {

    // MARK: - Basic voting

    func testInsufficientVotesReturnsNil() {
        let voting = VoiceTemporalVoting()
        voting.addVote(speaker: "Alice", score: 0.9)
        voting.addVote(speaker: "Alice", score: 0.8)
        // Only 2 votes, minimum is 3
        let result = voting.resolveByVoting()
        XCTAssertNil(result)
    }

    func testMajorityVoting() {
        let voting = VoiceTemporalVoting()
        voting.addVote(speaker: "Alice", score: 0.9)
        voting.addVote(speaker: "Alice", score: 0.8)
        voting.addVote(speaker: "Alice", score: 0.85)
        let result = voting.resolveByVoting()
        XCTAssertEqual(result?.speaker, "Alice")
        XCTAssertEqual(result?.count, 3)
    }

    func testMajorityWithMultipleSpeakers() {
        let voting = VoiceTemporalVoting()
        voting.addVote(speaker: "Alice", score: 0.9)
        voting.addVote(speaker: "Alice", score: 0.8)
        voting.addVote(speaker: "Alice", score: 0.85)
        voting.addVote(speaker: "Bob", score: 0.7)
        let result = voting.resolveByVoting()
        XCTAssertEqual(result?.speaker, "Alice")
    }

    func testNoWinnerWhenSplit() {
        let voting = VoiceTemporalVoting()
        voting.addVote(speaker: "Alice", score: 0.9)
        voting.addVote(speaker: "Bob", score: 0.85)
        voting.addVote(speaker: "Charlie", score: 0.8)
        // 3 votes total but no speaker has 3
        let result = voting.resolveByVoting()
        XCTAssertNil(result)
    }

    func testEmptyVotes() {
        let voting = VoiceTemporalVoting()
        let result = voting.resolveByVoting()
        XCTAssertNil(result)
    }

    func testClearVotingHistory() {
        let voting = VoiceTemporalVoting()
        voting.addVote(speaker: "Alice", score: 0.9)
        voting.addVote(speaker: "Alice", score: 0.8)
        voting.addVote(speaker: "Alice", score: 0.85)
        voting.clearVotingHistory()
        let result = voting.resolveByVoting()
        XCTAssertNil(result)
    }

    // MARK: - ASN (Adaptive Score Normalization)

    func testScoreHistoryUpdate() {
        let voting = VoiceTemporalVoting()
        for _ in 0..<20 {
            voting.updateScoreHistory(speaker: "Alice", score: 0.8)
        }
        XCTAssertTrue(voting.hasEnoughHistory(for: ["Alice"]))
    }

    func testHasEnoughHistoryFalseInitially() {
        let voting = VoiceTemporalVoting()
        XCTAssertFalse(voting.hasEnoughHistory(for: ["Alice"]))
    }

    func testNormalizeScoreWithoutHistory() {
        let voting = VoiceTemporalVoting()
        let normalized = voting.normalizeScore(speaker: "Alice", rawScore: 0.8)
        XCTAssertEqual(normalized, 0.8, accuracy: 0.001)
    }

    func testNormalizeScoreWithHistory() {
        let voting = VoiceTemporalVoting()
        for _ in 0..<20 {
            voting.updateScoreHistory(speaker: "Alice", score: 0.8)
        }
        let normalized = voting.normalizeScore(speaker: "Alice", rawScore: 0.8)
        XCTAssertFalse(normalized.isNaN)
    }

    func testScoreHistoryMaxSize() {
        let voting = VoiceTemporalVoting()
        for i in 0..<50 {
            voting.updateScoreHistory(speaker: "Alice", score: Float(i) * 0.02)
        }
        XCTAssertLessThanOrEqual(voting.scoreHistory["Alice"]?.count ?? 0, voting.scoreHistoryMaxSize)
    }
}
