import XCTest
import Security
@testable import MailKeep

final class CredentialMigrationTests: XCTestCase {
    var tempDir: URL!
    var testService: String!
    var testOAuthService: String!
    var testDefaultsKey: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialMigrationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        CredentialStore.testFileOverride = tempDir.appendingPathComponent("credentials.json")
        let suffix = UUID().uuidString
        testService = "com.kzahedi.MailKeep.test-migration-\(suffix)"
        testOAuthService = "com.kzahedi.MailKeep.test-migration-oauth-\(suffix)"
        testDefaultsKey = "TestCredentialsMigration-\(suffix)"
    }

    override func tearDown() {
        CredentialStore.testFileOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        for service in [testService!, testOAuthService!] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            SecItemDelete(query as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: testDefaultsKey)
        super.tearDown()
    }

    private func addKeychainItem(service: String, account: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess, "Failed to seed keychain item")
    }

    func testReadAllExpandsConsolidatedStoreAndLegacyItems() throws {
        let uuidA = UUID().uuidString
        let uuidB = UUID().uuidString
        let consolidated = try JSONEncoder().encode([uuidA: "pw-a"])
        addKeychainItem(service: testService, account: "__credential_store__",
                        value: String(data: consolidated, encoding: .utf8)!)
        addKeychainItem(service: testService, account: uuidB, value: "pw-b")

        let (credentials, complete) = MigrationService.readAllKeychainCredentials(service: testService)
        XCTAssertTrue(complete)
        XCTAssertEqual(credentials[uuidA], "pw-a")
        XCTAssertEqual(credentials[uuidB], "pw-b")
    }

    func testReadAllReturnsCompleteOnEmptyService() {
        let (credentials, complete) = MigrationService.readAllKeychainCredentials(service: testService)
        XCTAssertTrue(complete)
        XCTAssertTrue(credentials.isEmpty)
    }

    func testConsolidatedStoreWinsOverLegacyItemForSameUUID() throws {
        let uuid = UUID().uuidString
        let consolidated = try JSONEncoder().encode([uuid: "newer"])
        addKeychainItem(service: testService, account: "__credential_store__",
                        value: String(data: consolidated, encoding: .utf8)!)
        addKeychainItem(service: testService, account: uuid, value: "older")

        let (credentials, _) = MigrationService.readAllKeychainCredentials(service: testService)
        XCTAssertEqual(credentials[uuid], "newer")
    }

    func testMigrateWritesFileAndSetsFlag() async throws {
        let uuid = UUID()
        addKeychainItem(service: testService, account: uuid.uuidString, value: "migrated-pw")
        addKeychainItem(service: testOAuthService, account: uuid.uuidString, value: "{\"t\":1}")

        MigrationService.migrateCredentialsIfNeeded(
            passwordService: testService, oauthService: testOAuthService,
            defaultsKey: testDefaultsKey)

        XCTAssertTrue(UserDefaults.standard.bool(forKey: testDefaultsKey))
        let pw = try await CredentialStore.shared.getPassword(for: uuid)
        XCTAssertEqual(pw, "migrated-pw")
        let token = try await CredentialStore.shared.getOAuthTokenString(for: uuid)
        XCTAssertEqual(token, "{\"t\":1}")
    }

    func testMigrateIsSkippedWhenFlagAlreadySet() async {
        UserDefaults.standard.set(true, forKey: testDefaultsKey)
        let uuid = UUID()
        addKeychainItem(service: testService, account: uuid.uuidString, value: "should-not-migrate")

        MigrationService.migrateCredentialsIfNeeded(
            passwordService: testService, oauthService: testOAuthService,
            defaultsKey: testDefaultsKey)

        let has = await CredentialStore.shared.hasPassword(for: uuid)
        XCTAssertFalse(has)
    }

    func testMigrationLeavesKeychainItemsInPlace() {
        let uuid = UUID().uuidString
        addKeychainItem(service: testService, account: uuid, value: "keep-me")

        MigrationService.migrateCredentialsIfNeeded(
            passwordService: testService, oauthService: testOAuthService,
            defaultsKey: testDefaultsKey)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService!,
            kSecAttrAccount as String: uuid
        ]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecSuccess)
    }
}
