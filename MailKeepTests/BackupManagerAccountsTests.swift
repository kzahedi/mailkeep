import XCTest
@testable import MailKeep

/// Tests for BackupManager account persistence (saveAccounts / loadAccounts).
///
/// Tests save/restore the real Keychain account list so test runs never destroy
/// actual user data. All reads/writes during tests target isolated keys.
@MainActor
final class BackupManagerAccountsTests: XCTestCase {

    private let accountsKey = "EmailAccounts"

    // Snapshots of real data, restored in tearDown
    private var savedKeychainData: Data?
    private var savedUserDefaultsData: Data?

    override func setUp() {
        super.setUp()
        // Snapshot real data before touching anything
        savedKeychainData = KeychainService.shared.loadAccountList()
        savedUserDefaultsData = UserDefaults.standard.data(forKey: accountsKey)
        // Clear for test isolation
        try? KeychainService.shared.deleteAccountList()
        UserDefaults.standard.removeObject(forKey: accountsKey)
    }

    override func tearDown() {
        // Always restore real data regardless of test outcome
        try? KeychainService.shared.deleteAccountList()
        if let data = savedKeychainData {
            try? KeychainService.shared.saveAccountList(data)
        }
        if let data = savedUserDefaultsData {
            UserDefaults.standard.set(data, forKey: accountsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: accountsKey)
        }
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
