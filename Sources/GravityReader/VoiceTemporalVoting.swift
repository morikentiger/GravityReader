import Foundation

/// 時間的多数決（Temporal Voting）と適応的スコア正規化（ASN）を担当
class VoiceTemporalVoting {

    // MARK: - Temporal Voting

    private(set) var recentVotes: [(speaker: String, score: Float)] = []
    let votingWindowSize = 5
    let votingMinCount = 3

    /// 直前の1位話者を追跡
    private var lastTopSpeaker: String = ""
    /// 話者切替候補カウンター（2回連続で確認してからリセット）
    private var switchCandidateCount = 0
    private var switchCandidateSpeaker: String = ""

    var onLog: ((String) -> Void)?

    func addVote(speaker: String, score: Float) {
        if speaker != "不明" && speaker != lastTopSpeaker && !lastTopSpeaker.isEmpty {
            if speaker == switchCandidateSpeaker {
                switchCandidateCount += 1
            } else {
                switchCandidateSpeaker = speaker
                switchCandidateCount = 1
            }

            if switchCandidateCount >= 2 {
                recentVotes.removeAll()
                lastTopSpeaker = speaker
                switchCandidateCount = 0
                switchCandidateSpeaker = ""
                onLog?("🔄 話者交代検出: → \(speaker)")
            }
        } else if speaker != "不明" {
            lastTopSpeaker = speaker
            switchCandidateCount = 0
            switchCandidateSpeaker = ""
        }

        recentVotes.append((speaker: speaker, score: score))
        if recentVotes.count > votingWindowSize {
            recentVotes.removeFirst()
        }
    }

    func resolveByVoting() -> (speaker: String, count: Int)? {
        guard recentVotes.count >= votingMinCount else { return nil }

        var counts: [String: Int] = [:]
        for vote in recentVotes where vote.speaker != "不明" {
            counts[vote.speaker, default: 0] += 1
        }

        guard let winner = counts.max(by: { $0.value < $1.value }),
              winner.value >= votingMinCount else {
            return nil
        }

        return (speaker: winner.key, count: winner.value)
    }

    func clearVotingHistory() {
        recentVotes.removeAll()
        lastTopSpeaker = ""
        switchCandidateCount = 0
        switchCandidateSpeaker = ""
    }

    // MARK: - Adaptive Score Normalization（ASN）

    /// 各話者の直近スコア履歴
    private(set) var scoreHistory: [String: [Float]] = [:]
    let scoreHistoryMaxSize = 30

    /// スコア履歴を更新
    func updateScoreHistory(speaker: String, score: Float) {
        scoreHistory[speaker, default: []].append(score)
        if scoreHistory[speaker]!.count > scoreHistoryMaxSize {
            scoreHistory[speaker]!.removeFirst()
        }
    }

    /// 十分な履歴があるか
    func hasEnoughHistory(for speakers: [String]) -> Bool {
        return speakers.allSatisfy { (scoreHistory[$0]?.count ?? 0) >= 5 }
    }

    /// スコアをZ-score正規化
    func normalizeScore(speaker: String, rawScore: Float) -> Float {
        guard let history = scoreHistory[speaker], history.count >= 5 else {
            return rawScore
        }

        let mean = history.reduce(0, +) / Float(history.count)
        let variance = history.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(history.count)
        let std = max(sqrtf(variance), 0.01)

        let zScore = (rawScore - mean) / std
        return rawScore + zScore * 0.02
    }
}
