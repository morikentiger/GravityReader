import XCTest
@testable import GravityReader

final class YUiConversationDirectorTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 10_000)
    func plan(_ texts: [String], settings: YUiPersonality = YUiPersonality(), turn: Int = 0) -> YUiConversationDirector.Plan {
        YUiConversationDirector.plan(settings: settings, history: texts.map { (now, $0) }, replyCount: turn, now: now)
    }
    func testAutomaticTargetsDoNotInheritExtremeManualSettings() {
        let extreme = YUiPersonality(responseFrequency: 1, dialogueStance: 1, attitude: 0, autoMode: true)
        XCTAssertEqual(plan(["A: ゲーム楽しいね"], settings: extreme), plan(["A: ゲーム楽しいね"]))
        XCTAssertEqual(extreme.attitude, 0)
        XCTAssertEqual(plan(["A: ゲーム楽しいね"]).move, .playful)
    }
    func testBusyRoomAndRepeatedYUiRepliesReduceFrequency() {
        let quiet = plan(["A: 映画を見た"])
        let busy = plan(Array(repeating: "A: 映画を見た", count: 6))
        let own = plan(["A: 映画を見た", "YUi: いいね", "YUi: そうだね"])
        XCTAssertLessThan(busy.personality.responseFrequency, quiet.personality.responseFrequency)
        XCTAssertGreaterThan(own.minimumInterval, quiet.minimumInterval)
    }
    func testQuestionAndCorrectionTakePriorityOverPlayfulness() {
        let playful = YUiPersonality(responseFrequency: 0, dialogueStance: 1, attitude: 1, autoMode: false)
        let question = plan(["A: ゲームのおすすめを一つだけ教えて"], settings: playful)
        XCTAssertEqual(question.move, .answer)
        XCTAssertEqual(question.minimumInterval, 8)
        XCTAssertEqual(plan(["A: そうじゃない、さっき言った話だよ"], settings: playful).move, .repair)
        XCTAssertEqual(plan(["A: What game do you recommend?"], settings: playful).move, .answer)
    }
    func testSensitiveContextSuppressesForcedJokes() {
        XCTAssertEqual(plan(["A: 仕事がつらい", "A: 本当にね"]).move, .support)
        XCTAssertFalse(plan(["A: 仕事がつらい"]).allowsInitiation)
        XCTAssertLessThan(plan(["A: 仕事がつらい"]).personality.attitude, 0.3)
        XCTAssertEqual(plan(["A: 仕事がつらい", "A: どうすればいい？"]).move, .answer)
    }
    func testOldAndSystemMessagesDoNotDriveCurrentMood() {
        let p = YUiConversationDirector.plan(settings: YUiPersonality(), history: [(now.addingTimeInterval(-91), "A: ゲーム楽しい"), (now, "[システム] 楽しい")], replyCount: 0, now: now)
        XCTAssertEqual(p.move, .waiting)
        XCTAssertFalse(p.allowsInitiation)
    }
    func testManualSettingsArePreservedAndReallyChangeTiming() {
        let low = YUiPersonality(responseFrequency: 0, dialogueStance: 0.9, attitude: 0.2, autoMode: false)
        let high = YUiPersonality(responseFrequency: 1, dialogueStance: 0.9, attitude: 0.2, autoMode: false)
        XCTAssertEqual(plan(["A: 映画の話"], settings: low).personality, low)
        XCTAssertEqual(plan(["A: 映画の話"], settings: low).minimumInterval, 60)
        XCTAssertEqual(plan(["A: 映画の話"], settings: high).minimumInterval, 8)
        XCTAssertGreaterThan(plan(["A: 映画の話"], settings: low).settlingDelay, plan(["A: 映画の話"], settings: high).settlingDelay)
    }
    func testCasualRepliesVaryWithoutChangingTopic() {
        XCTAssertNotEqual(plan(["A: 映画を見た"], turn: 0).move, plan(["A: 映画を見た"], turn: 1).move)
        XCTAssertEqual(plan(["A: 何を見たらいい？"], turn: 0).move, plan(["A: 何を見たらいい？"], turn: 1).move)
    }
    func testSchedulingHonorsListeningAndCannotBeStarvedByNewMessages() {
        let p = plan(["A: 映画を見た"])
        XCTAssertEqual(p.schedulingDelay(now: now, oldestInput: now.addingTimeInterval(-25), lastReply: .distantPast, listenUntil: .distantPast), 0.1)
        XCTAssertEqual(p.schedulingDelay(now: now, oldestInput: now.addingTimeInterval(-25), lastReply: .distantPast, listenUntil: now.addingTimeInterval(8)), 8)
        let question = plan(["A: 教えて？"])
        XCTAssertEqual(question.schedulingDelay(now: now, oldestInput: now, lastReply: now, listenUntil: .distantPast), 8)
    }

    func testPresetMatchesOnlyManualPresetValues() {
        XCTAssertNil(YUiPersonality().manualFrequencyPreset)
        XCTAssertEqual(YUiPersonality(responseFrequency: 0.5, autoMode: false).manualFrequencyPreset, .medium)
        XCTAssertNil(YUiPersonality(responseFrequency: 0.42, autoMode: false).manualFrequencyPreset)
    }

    func testInvalidStoredValuesCannotProduceInvalidDelay() {
        let broken = YUiPersonality(responseFrequency: .nan, dialogueStance: 2, attitude: -1, autoMode: false)
        let p = plan(["A: 映画を見た"], settings: broken)
        XCTAssertTrue(p.minimumInterval.isFinite)
        XCTAssertEqual(p.personality.dialogueStance, 1)
        XCTAssertEqual(p.personality.attitude, 0)
    }
}
