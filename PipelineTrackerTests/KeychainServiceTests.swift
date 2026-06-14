import XCTest
@testable import PipelineTracker

final class KeychainServiceTests: XCTestCase {

    private let testId = UUID()

    override func tearDown() {
        super.tearDown()
        KeychainService.shared.deleteToken(for: testId)
    }

    func test_saveAndLoad_roundtrip() throws {
        try KeychainService.shared.saveToken("my-secret-token", for: testId)
        let loaded = KeychainService.shared.loadToken(for: testId)
        XCTAssertEqual(loaded, "my-secret-token")
    }

    func test_overwriteToken() throws {
        try KeychainService.shared.saveToken("first-token", for: testId)
        try KeychainService.shared.saveToken("second-token", for: testId)
        let loaded = KeychainService.shared.loadToken(for: testId)
        XCTAssertEqual(loaded, "second-token")
    }

    func test_loadMissingToken_returnsNil() {
        let nonExistentId = UUID()
        XCTAssertNil(KeychainService.shared.loadToken(for: nonExistentId))
    }

    func test_deleteToken_removesFromKeychain() throws {
        try KeychainService.shared.saveToken("to-delete", for: testId)
        KeychainService.shared.deleteToken(for: testId)
        XCTAssertNil(KeychainService.shared.loadToken(for: testId))
    }

    func test_deleteMissingToken_doesNotThrow() {
        // Should not throw or crash
        KeychainService.shared.deleteToken(for: UUID())
    }

    func test_saveEmptyToken() throws {
        try KeychainService.shared.saveToken("", for: testId)
        let loaded = KeychainService.shared.loadToken(for: testId)
        XCTAssertEqual(loaded, "")
    }

    func test_saveTokenWithSpecialCharacters() throws {
        let special = "glpat-xÄÖÜ/=+!@#$%^&*"
        try KeychainService.shared.saveToken(special, for: testId)
        XCTAssertEqual(KeychainService.shared.loadToken(for: testId), special)
    }

    func test_multipleAccountsStoredIndependently() throws {
        let id1 = UUID(), id2 = UUID()
        defer {
            KeychainService.shared.deleteToken(for: id1)
            KeychainService.shared.deleteToken(for: id2)
        }
        try KeychainService.shared.saveToken("token-one", for: id1)
        try KeychainService.shared.saveToken("token-two", for: id2)
        XCTAssertEqual(KeychainService.shared.loadToken(for: id1), "token-one")
        XCTAssertEqual(KeychainService.shared.loadToken(for: id2), "token-two")
    }

    func test_keychainErrorSaveFailedDescription() {
        let err = KeychainError.saveFailed(-25300)
        XCTAssertNotNil(err.errorDescription)
        XCTAssertTrue(err.errorDescription!.contains("-25300"))
    }

    func test_keychainErrorUnexpectedDataDescription() {
        let err = KeychainError.unexpectedData
        XCTAssertNotNil(err.errorDescription)
    }
}
