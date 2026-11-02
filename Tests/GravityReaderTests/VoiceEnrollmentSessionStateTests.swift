import XCTest
@testable import GravityReader

final class VoiceEnrollmentSessionStateTests: XCTestCase {
    func testCancelledTTSCallbackCannotStartLaterRegistration() {
        var state = VoiceEnrollmentSessionState()
        let first = state.begin()
        state.cancel()
        let second = state.begin()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(state.startRecording(first), "delayed first TTS completion must not clear the new buffer or schedule a timer")
        XCTAssertTrue(state.startRecording(second))
        XCTAssertTrue(state.completeRecording(second))
    }

    func testOldTimerCannotConsumeNewRecording() {
        var state = VoiceEnrollmentSessionState()
        let first = state.begin()
        XCTAssertTrue(state.startRecording(first))
        state.cancel()
        let second = state.begin()
        XCTAssertTrue(state.startRecording(second))
        XCTAssertFalse(state.completeRecording(first), "old timer must not label new audio with the previous speaker")
        XCTAssertTrue(state.completeRecording(second))
    }

    func testCallbacksAreSingleUseAndCannotCompleteBeforeRecordingStarts() {
        var state = VoiceEnrollmentSessionState()
        let token = state.begin()
        XCTAssertFalse(state.completeRecording(token))
        XCTAssertTrue(state.startRecording(token))
        XCTAssertFalse(state.startRecording(token), "duplicate TTS callback must not reset the recording")
        XCTAssertTrue(state.completeRecording(token))
        XCTAssertFalse(state.completeRecording(token), "only one enrollment may be recorded")
        XCTAssertFalse(state.startRecording(token))
    }

    func testCancelledSessionCannotResumeWithoutAnotherRegistration() {
        var state = VoiceEnrollmentSessionState()
        let token = state.begin()
        state.cancel()
        XCTAssertFalse(state.startRecording(token))
        XCTAssertFalse(state.completeRecording(token))
    }
}
