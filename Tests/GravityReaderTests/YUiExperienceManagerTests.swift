import XCTest
@testable import GravityReader

final class YUiExperienceManagerTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func manager() -> YUiExperienceManager {
        let manager = YUiExperienceManager(directory: directory)
        manager.loadExperiences()
        return manager
    }
    private final class StubClient: YUiAPIClient {
        var calls = 0
        override func callRaw(systemPrompt: String, userMessage: String, completion: @escaping (String?) -> Void) {
            calls += 1
            completion(nil)
        }
    }

    func testLegacyIsArchivedExactlyOnceAndNotLoaded() throws {
        let original = Data("[{\"event\":\"旧経験\"}]".utf8)
        let legacy = directory.appendingPathComponent("yui_experiences.json")
        try original.write(to: legacy)
        XCTAssertTrue(manager().experienceCache.isEmpty)
        let archives = directory.appendingPathComponent("archives")
        let files = try FileManager.default.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: files[0]), original)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        _ = manager()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil).count, 1)
    }

    func testOwnExperienceRecordsConversationNotBorrowedLife() {
        let manager = manager()
        let client = StubClient(apiKey: "test-placeholder")
        manager.generateExperience(userMessage: "A[コメント]: 失恋した", yuiResponse: "話してくれてありがとう。", apiClient: client)
        let experience = manager.experienceCache[0]
        XCTAssertEqual(experience.kind, .ownConversation)
        XCTAssertEqual(experience.participants, ["A"])
        XCTAssertEqual(experience.source, "A[コメント]: 失恋した")
        XCTAssertFalse(experience.event.contains("私は失恋"))
        XCTAssertEqual(client.calls, 0)
    }

    func testReactionsRequireSamePersonAndRecentConversation() {
        let manager = manager()
        let now = Date()
        manager.addExperience(.init(participants: ["A"], source: "A: 京都へ行った", response: "楽しかった？", event: "Aと京都の話をした", emotion: "未評価", learning: "", weight: 1, timestamp: now.timeIntervalSince1970))
        manager.observeReaction("B: 楽しかった", now: now.addingTimeInterval(1))
        XCTAssertTrue(manager.experienceCache[0].reactions.isEmpty)
        manager.observeReaction("A[コメント]: 楽しかった", now: now.addingTimeInterval(2))
        XCTAssertEqual(manager.experienceCache[0].reactions.count, 1)
        manager.observeReaction("A: また行く", now: now.addingTimeInterval(121))
        XCTAssertEqual(manager.experienceCache[0].reactions.count, 1)
    }

    func testReflectionRejectsInventedOtherExperience() throws {
        let manager = manager()
        manager.addExperience(.init(participants: ["A"], source: "A: 京都に旅行した", response: "お寺は見た？", event: "Aと話した", emotion: "未評価", learning: "", weight: 1))
        let original = manager.experienceCache[0]
        let json: [String: Any] = ["own": [["id": original.id.uuidString, "lesson": "旅行の話では行き先に沿って返す", "emotion": "未評価"]], "others": [
            ["recordId": original.id.uuidString, "speaker": "A", "quote": "京都に旅行した"],
            ["recordId": original.id.uuidString, "speaker": "A", "quote": "失恋して泣いた"],
            ["recordId": original.id.uuidString, "speaker": "B", "quote": "京都に旅行した"]]]
        let output = String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
        manager.applyReflection(output, snapshots: [original])
        XCTAssertEqual(manager.experienceCache.count, 2)
        XCTAssertEqual(manager.experienceCache[0].event, "Aと話した")
        XCTAssertEqual(manager.experienceCache[1].kind, .othersReport)
        XCTAssertTrue(manager.experienceCache[1].event.hasPrefix("Aが"))
        XCTAssertEqual(self.manager().experienceCache.count, 2)
    }

    func testOwnExperienceWinsAndShortQueryIsSafe() {
        let manager = manager()
        manager.addExperience(.init(kind: .othersReport, source: "京都の旅行", event: "京都の旅行の話", emotion: "未評価", learning: "", weight: 10))
        manager.addExperience(.init(source: "京都の旅行", event: "旅行について会話した", emotion: "未評価", learning: "行き先に沿って返す", weight: 1))
        XCTAssertEqual(manager.findRelevantExperiences(query: "京都の旅行").first?.kind, .ownConversation)
        XCTAssertTrue(manager.findRelevantExperiences(query: "").isEmpty)
        XCTAssertTrue(manager.findRelevantExperiences(query: "あ").isEmpty)
    }

    func testReflectionBatchesAndDoesNotImmediatelyRetry() {
        let manager = manager()
        let client = StubClient(apiKey: "test-placeholder")
        for _ in 0..<4 { manager.generateExperience(userMessage: "A: 京都に行った", yuiResponse: "いいね。", apiClient: client) }
        XCTAssertEqual(client.calls, 0)
        manager.generateExperience(userMessage: "A: 京都に行った", yuiResponse: "いいね。", apiClient: client)
        XCTAssertEqual(client.calls, 1)
        let done = expectation(description: "callback")
        DispatchQueue.main.async {
            manager.generateExperience(userMessage: "A: 京都に行った", yuiResponse: "いいね。", apiClient: client)
            XCTAssertEqual(client.calls, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}
