import XCTest
@testable import GravityReader

final class PhoneticSpamGuardTests: XCTestCase {
    func testVoiceInputAlsoRejectsLongRepeatedSyllables() {
        XCTAssertTrue(YUiSpamFilter.isRepetitiveSpam("もりけん: あいうえおあいうえおあいうえおあいうえお"))
        XCTAssertFalse(YUiSpamFilter.isRepetitiveSpam("あいうえおの発音を教えて"))
    }

    func testLongSentenceRepetitionFromRoomIsSuppressed() {
        let sentence = "やったーどれだけ長い音を繰り返しとみるんだろう"
        let comment = String(repeating: sentence, count: 4)
        XCTAssertGreaterThan(sentence.count, 20)
        XCTAssertNotNil(CommentReadoutGuard().suppressionReason(comment, speaker: "viewer"))
        XCTAssertTrue(YUiSpamFilter.isRepetitiveSpam("もりけん: " + comment))
        XCTAssertNotNil(PhoneticSpamGuard.suppressionReason(original: comment, reading: comment))
        XCTAssertNil(PhoneticSpamGuard.suppressionReason(original: sentence, reading: sentence))
        XCTAssertNil(PhoneticSpamGuard.suppressionReason(original: sentence + sentence, reading: sentence + sentence))
    }

    func testRepetitionHasNoFixedPeriodLimit() {
        // Distinct characters make this a genuinely long period, not a short
        // repeating pattern hidden inside a long string.
        let unit = String((0..<120).compactMap { UnicodeScalar(0x4E00 + $0).map(Character.init) })
        let repeated = String(repeating: unit, count: 3)
        XCTAssertNotNil(PhoneticSpamGuard.suppressionReason(original: repeated, reading: repeated))
        XCTAssertNil(PhoneticSpamGuard.suppressionReason(original: unit, reading: unit))
        let embedded = "前置き" + String(repeating: unit + "、", count: 4) + "終わり"
        XCTAssertTrue(CommentReadoutGuard.hasRepeatedRun(embedded))
        XCTAssertNotNil(PhoneticSpamGuard.suppressionReason(original: embedded, reading: embedded))
    }

    func testNearRepeatsDoNotCountAsIdenticalSentences() {
        let text = "今日は公園で赤い花を見つけたので写真を撮りました。"
            + "今日は公園で白い花を見つけたので写真を撮りました。"
            + "今日は公園で黄色い花を見つけたので写真を撮りました。"
        XCTAssertNil(CommentReadoutGuard().suppressionReason(text, speaker: "viewer"))
    }

    func testMixedSpellingsCollapseToRepeatedSound() {
        XCTAssertNotNil(PhoneticSpamGuard.suppressionReason(original: "Mushi 虫 無視 ムシ", reading: "むし むし むし ムシ"))
        XCTAssertNotNil(PhoneticSpamGuard.suppressionReason(original: "25nicoにこniko", reading: "25にこにこにこ"))
        XCTAssertNotNil(PhoneticSpamGuard.suppressionReason(original: "25nicoにこniko", reading: "にこ にこ にこ にこ"))
        XCTAssertNotNil(PhoneticSpamGuard.suppressionReason(original: "25nicoにこniko", reading: "にじゅうごにこにこにこ"))
    }

    func testExplanationsAndOrdinaryConversationAreNotHardBlocked() {
        XCTAssertNil(PhoneticSpamGuard.suppressionReason(original: "虫と無視は同じ読み方です", reading: "むしとむしはおなじよみかたです"))
        XCTAssertNil(PhoneticSpamGuard.suppressionReason(original: "Mushi 虫 無視 ムシの発音を説明して", reading: "むしむしむしむしのはつおんをせつめいして"))
        XCTAssertNil(PhoneticSpamGuard.suppressionReason(original: "にこにこしてるね", reading: "にこにこしてるね"))
        XCTAssertNil(PhoneticSpamGuard.suppressionReason(original: "25個ください", reading: "にじゅうごこください"))
        XCTAssertNil(PhoneticSpamGuard.suppressionReason(original: "Hello, how are you?", reading: "Hello, how are you?"))
    }

    func testNormalizationPrecedesJevAndExactReadingIsDeliveredOnce() {
        var normalizeCalls = 0
        var delivered = ""
        let gate = JevCommentGate { original, reading, _, done in
            XCTAssertEqual(original, "虫の読み方を教えて")
            XCTAssertEqual(reading, "むしのよみかたをおしえて")
            done(.allow)
        }
        gate.mode = { 2 }
        gate.normalize = { _, done in normalizeCalls += 1; done("むしのよみかたをおしえて") }
        gate.submitPrepared("虫の読み方を教えて") { delivered = $0 }
        XCTAssertEqual(normalizeCalls, 1)
        XCTAssertEqual(delivered, "むしのよみかたをおしえて")
    }

    func testSoundSpamNeverReachesJevOrConversationEvenWhenJevIsOff() {
        for mode in [0, 1, 2] {
            let gate = JevCommentGate { _, _, _, _ in XCTFail("local sound guard must run first") }
            gate.mode = { mode }
            gate.normalize = { _, done in done("むしむしむしむし") }
            gate.submitPrepared("Mushi 虫 無視 ムシ") { _ in XCTFail("spam must not be delivered") }
        }
    }

    func testResetIgnoresLateNormalization() {
        var finish: ((String) -> Void)?
        let gate = JevCommentGate { _, _, _, _ in XCTFail("must not evaluate after reset") }
        gate.normalize = { _, done in finish = done }
        gate.submitPrepared("test") { _ in XCTFail("must not deliver after reset") }
        gate.reset()
        finish?("test")
    }

    func testRequestIncludesOriginalAndReadingSeparately() throws {
        let request = try JevCommentGate.makeRequest(text: "Mushi 虫", context: [], key: "fake", reading: "むし むし")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let state = try XCTUnwrap(json["state"] as? [String: Any])
        XCTAssertEqual(state["comment"] as? String, "Mushi 虫")
        XCTAssertEqual(state["tts_reading"] as? String, "むし むし")
    }
}
