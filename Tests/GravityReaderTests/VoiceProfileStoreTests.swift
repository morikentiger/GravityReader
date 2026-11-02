import XCTest
@testable import GravityReader

final class VoiceProfileStoreTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-profile-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("profiles.json")
    }

    private func fixture(_ name: String, mode: String, dimension: Int) -> [String: Any] {
        ["name": name, "mode": mode, "features": [Double](repeating: 0.1, count: dimension), "sampleCount": 2]
    }

    private func write(_ records: [[String: Any]], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: records).write(to: url)
    }

    func testSavingNeuralProfilesPreservesMFCCRegistrationsAcrossModeSwitch() throws {
        let url = try temporaryURL()
        try write([fixture("same name", mode: "mfcc", dimension: 39), fixture("same name", mode: "neural", dimension: 192)], to: url)
        let store = VoiceProfileStore(profilesURL: url)
        store.loadProfiles(currentMode: .mfcc, featureDimension: 39)
        XCTAssertEqual(store.profiles["same name"]?.features.count, 39)
        store.loadProfiles(currentMode: .neural, featureDimension: 192)
        XCTAssertEqual(store.profiles["same name"]?.features.count, 192)
        store.profiles["same name"]?.sampleCount = 3
        store.saveProfiles()
        store.loadProfiles(currentMode: .mfcc, featureDimension: 39)
        XCTAssertEqual(store.profiles["same name"]?.sampleCount, 2)
        store.loadProfiles(currentMode: .neural, featureDimension: 192)
        XCTAssertEqual(store.profiles["same name"]?.sampleCount, 3)
    }

    func testEmptyActiveModeDoesNotEraseOtherMode() throws {
        let url = try temporaryURL()
        try write([fixture("neural", mode: "neural", dimension: 192)], to: url)
        let store = VoiceProfileStore(profilesURL: url)
        store.loadProfiles(currentMode: .mfcc, featureDimension: 39)
        XCTAssertTrue(store.profiles.isEmpty)
        store.saveProfiles()
        store.loadProfiles(currentMode: .neural, featureDimension: 192)
        XCTAssertNotNil(store.profiles["neural"])
    }

    func testExplicitClearRemovesBothModesAndCannotResurrect() throws {
        let url = try temporaryURL()
        try write([fixture("Alice", mode: "mfcc", dimension: 39), fixture("Alice", mode: "neural", dimension: 192), fixture("Bob", mode: "neural", dimension: 192)], to: url)
        let store = VoiceProfileStore(profilesURL: url)
        store.loadProfiles(currentMode: .mfcc, featureDimension: 39)
        store.clearProfile(for: "Alice")
        store.loadProfiles(currentMode: .neural, featureDimension: 192)
        XCTAssertNil(store.profiles["Alice"])
        XCTAssertNotNil(store.profiles["Bob"])
        store.clearAllProfiles()
        store.loadProfiles(currentMode: .mfcc, featureDimension: 39)
        XCTAssertTrue(store.profiles.isEmpty)
        store.loadProfiles(currentMode: .neural, featureDimension: 192)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testMalformedAndNonFiniteVectorsDoNotOverwriteSavedData() throws {
        let url = try temporaryURL()
        try write([fixture("Alice", mode: "neural", dimension: 192)], to: url)
        let store = VoiceProfileStore(profilesURL: url)
        store.loadProfiles(currentMode: .neural, featureDimension: 192)
        let original = try Data(contentsOf: url)
        store.profiles["Alice"]?.features[0] = .nan
        store.saveProfiles()
        XCTAssertEqual(try Data(contentsOf: url), original)
        let broken = Data("not json".utf8)
        try broken.write(to: url)
        store.loadProfiles(currentMode: .neural, featureDimension: 192)
        store.saveProfiles()
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testLoadRejectsBadDimensionsOverflowAndCounts() throws {
        let url = try temporaryURL()
        var overflow = fixture("overflow", mode: "neural", dimension: 192)
        overflow["features"] = [Double](repeating: 1e200, count: 192)
        var badCount = fixture("count", mode: "neural", dimension: 192)
        badCount["sampleCount"] = 0
        try write([fixture("good", mode: "neural", dimension: 192), fixture("short", mode: "neural", dimension: 2), overflow, badCount], to: url)
        let store = VoiceProfileStore(profilesURL: url)
        store.loadProfiles(currentMode: .neural, featureDimension: 192)
        XCTAssertEqual(Set(store.profiles.keys), ["good"])
    }
}
