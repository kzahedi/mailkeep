import XCTest
@testable import MailKeep

/// Tests for BackupManager account persistence (saveAccounts / loadAccounts).
///
/// All Keychain operations use an isolated service name
/// ("com.kzahedi.MailKeep.accounts.uitesting") that is completely separate
/// from the production "com.kzahedi.MailKeep.accounts" entry. Tests never
/// read, write, or delete production data regardless of code-signing context.
@MainActor
final class BackupManagerAccountsTests: XCTestCase {

    private let accountsKey = "EmailAccounts"

    override func setUp() {
        super.setUp()
        // Route all Keychain account-list operations to the test namespace.
        // Must be set BEFORE any Keychain call so no production data is touched.
        KeychainService.testServiceOverride = "com.kzahedi.MailKeep.accounts.uitesting"

        // Clear the isolated namespace so each test starts from a clean slate.
        try? KeychainService.shared.deleteAccountList()

        // Clear any UserDefaults test residue (never touches production because
        // "EmailAccounts" key holds test data, not the app's Keychain-migrated state).
        UserDefaults.standard.removeObject(forKey: accountsKey)
    }

    override func tearDown() {
        // Remove the test entry, then restore routing to production.
        try? KeychainService.shared.deleteAccountList()
        KeychainService.testServiceOverride = nil
        UserDefaults.standard.removeObject(forKey: accountsKey)
        super.tearDown()
    }

    func testSaveAccountsWritesToKeychain() {
        let manager = BackupManager()
        manager.accounts = [makeAccount(email: "save@example.com")]
        manager.saveAccounts()

        let data = KeychainService.shared.loadAccountList()
        XCTAssertNotNil(data, "saveAccounts must write encoded data to Keychain")
    }

    func testSaveAccountsRoundTrip() {
        let manager = BackupManager()
        manager.accounts = [makeAccount(email: "roundtrip@example.com")]
        manager.saveAccounts()

        let reloader = BackupManager()
        reloader.loadAccounts()

        XCTAssertEqual(reloader.accounts.count, 1)
        XCTAssertEqual(reloader.accounts.first?.email, "roundtrip@example.com")
    }

    func testSaveEmptyAccountsPersistsEmptyList() {
        let manager = BackupManager()
        manager.accounts = [makeAccount(email: "initial@example.com")]
        manager.saveAccounts()

        manager.accounts = []
        manager.saveAccounts()

        let reloader = BackupManager()
        reloader.loadAccounts()
        XCTAssertTrue(reloader.accounts.isEmpty, "Saving empty accounts should persist an empty list")
    }

    func testMigrationFromUserDefaultsToKeychain() {
        // Seed UserDefaults with legacy data
        let account = makeAccount(email: "legacy@example.com")
        let data = try! JSONEncoder().encode([account])
        UserDefaults.standard.set(data, forKey: accountsKey)

        let manager = BackupManager()
        manager.loadAccounts()

        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.accounts.first?.email, "legacy@example.com")
        XCTAssertNil(UserDefaults.standard.data(forKey: accountsKey), "UserDefaults entry must be removed after migration")
        XCTAssertNotNil(KeychainService.shared.loadAccountList(), "Keychain must contain the migrated data")
    }

    // MARK: - Helpers

    private func makeAccount(email: String) -> EmailAccount {
        EmailAccount(
            email: email,
            imapServer: "imap.example.com",
            port: 993,
            authType: .password
        )
    }
}
