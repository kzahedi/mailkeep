import XCTest
@testable import MailKeep

final class CredentialStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        CredentialStore.testFileOverride = tempDir.appendingPathComponent("credentials.json")
    }

    override func tearDown() {
        CredentialStore.testFileOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testPasswordRoundTrip() async throws {
        let id = UUID()
        try await CredentialStore.shared.savePassword("s3cret", for: id)
        let loaded = try await CredentialStore.shared.getPassword(for: id)
        XCTAssertEqual(loaded, "s3cret")
    }

    func testGetPasswordThrowsNotFoundWhenMissing() async {
        do {
            _ = try await CredentialStore.shared.getPassword(for: UUID())
            XCTFail("Expected notFound")
        } catch {
            guard case CredentialStoreError.notFound = error else {
                return XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    func testDeletePasswordRemovesOnlyThatEntry() async throws {
        let a = UUID(), b = UUID()
        try await CredentialStore.shared.savePassword("pw-a", for: a)
        try await CredentialStore.shared.savePassword("pw-b", for: b)
        try await CredentialStore.shared.deletePassword(for: a)
        let hasA = await CredentialStore.shared.hasPassword(for: a)
        let hasB = await CredentialStore.shared.hasPassword(for: b)
        XCTAssertFalse(hasA)
        XCTAssertTrue(hasB)
    }

    func testOAuthTokenRoundTrip() async throws {
        let id = UUID()
        try await CredentialStore.shared.saveOAuthTokenString("{\"token\":1}", for: id)
        let loaded = try await CredentialStore.shared.getOAuthTokenString(for: id)
        XCTAssertEqual(loaded, "{\"token\":1}")
        let has = await CredentialStore.shared.hasOAuthToken(for: id)
        XCTAssertTrue(has)
    }

    func testFileHasOwnerOnlyPermissions() async throws {
        try await CredentialStore.shared.savePassword("x", for: UUID())
        let attrs = try FileManager.default.attributesOfItem(
            atPath: CredentialStore.testFileOverride!.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testCorruptFileIsPreservedAndStoreStartsFresh() async throws {
        let url = CredentialStore.testFileOverride!
        try Data("not json".utf8).write(to: url)
        let id = UUID()
        try await CredentialStore.shared.savePassword("new", for: id)
        let loaded = try await CredentialStore.shared.getPassword(for: id)
        XCTAssertEqual(loaded, "new")
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testImportIfAbsentDoesNotOverwriteExisting() async throws {
        let id = UUID()
        try await CredentialStore.shared.savePassword("file-wins", for: id)
        try CredentialStore.importIfAbsent(
            passwords: [id.uuidString: "keychain-value", "OTHER-KEY": "imported"],
            oauthTokens: [:])
        let existing = try await CredentialStore.shared.getPassword(for: id)
        XCTAssertEqual(existing, "file-wins")
        let data = try Data(contentsOf: CredentialStore.testFileOverride!)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let passwords = json["passwords"] as! [String: String]
        XCTAssertEqual(passwords["OTHER-KEY"], "imported")
    }
}
