import XCTest
@testable import MailKeep

/// Tests for BackupManager account persistence (saveAccounts / loadAccounts).
///
/// Accounts are now stored in the Keychain (not UserDefaults). Each test cleans up
/// the Keychain entry before and after to avoid cross-test pollution.
@MainActor
final class BackupManagerAccountsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? KeychainService.shared.deleteAccountList()
        UserDefaults.standard.removeObject(forKey: "EmailAccounts")
    }

    override func tearDown() {
        try? KeychainService.shared.deleteAccountList()
        UserDefaults.standard.removeObject(forKey: "EmailAccounts")
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
        UserDefaults.standard.set(data, forKey: "EmailAccounts")

        // loadAccounts should migrate to Keychain and remove UserDefaults entry
        let manager = BackupManager()
        manager.loadAccounts()

        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.accounts.first?.email, "legacy@example.com")
        XCTAssertNil(UserDefaults.standard.data(forKey: "EmailAccounts"), "UserDefaults entry must be removed after migration")
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
