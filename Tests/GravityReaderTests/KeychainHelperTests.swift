import XCTest
@testable import GravityReader

final class KeychainHelperTests: XCTestCase {
    private let testKey = "GravityReaderTest_\(UUID().uuidString)"

    override func tearDown() {
        super.tearDown()
        KeychainHelper.delete(key: testKey)
    }

    func testSaveAndLoad() {
        let value = "test-api-key-12345"
        let saved = KeychainHelper.save(key: testKey, value: value)
        XCTAssertTrue(saved)

        let loaded = KeychainHelper.load(key: testKey)
        XCTAssertEqual(loaded, value)
    }

    func testLoadNonExistent() {
        let loaded = KeychainHelper.load(key: "nonexistent_key_\(UUID().uuidString)")
        XCTAssertNil(loaded)
    }

    func testDelete() {
        let value = "to-be-deleted"
        _ = KeychainHelper.save(key: testKey, value: value)
        KeychainHelper.delete(key: testKey)
        let loaded = KeychainHelper.load(key: testKey)
        XCTAssertNil(loaded)
    }

    func testOverwrite() {
        _ = KeychainHelper.save(key: testKey, value: "first")
        _ = KeychainHelper.save(key: testKey, value: "second")
        let loaded = KeychainHelper.load(key: testKey)
        XCTAssertEqual(loaded, "second")
    }

    func testEmptyValue() {
        let saved = KeychainHelper.save(key: testKey, value: "")
        XCTAssertTrue(saved)
        let loaded = KeychainHelper.load(key: testKey)
        XCTAssertEqual(loaded, "")
    }
}
