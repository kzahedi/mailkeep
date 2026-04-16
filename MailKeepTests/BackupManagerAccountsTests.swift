import XCTest
@testable import MailKeep

/// Tests for BackupManager account persistence (saveAccounts / loadAccounts).
///
/// Accounts are stored as a JSON file in Application Support.
/// Tests redirect both the accounts file (via testAccountsFileOverride) and the
/// Keychain account-list (via testServiceOverride) to isolated namespaces so no
/// production data is read, written, or deleted during test runs.
@MainActor
final class BackupManagerAccountsTests: XCTestCase {

    private let accountsKey = "EmailAccounts"
    private var tempDir: URL!

    override func setUp() {
        super.setUp()

        // Isolated temp directory for the accounts file
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailKeepTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        BackupManager.testAccountsFileOverride = tempDir.appendingPathComponent("accounts.json")

        // Isolated Keychain namespace for migration tests
        KeychainService.testServiceOverride = "com.kzahedi.MailKeep.accounts.uitesting"
        try? KeychainService.shared.deleteAccountList()

        // Clear any UserDefaults residue
        UserDefaults.standard.removeObject(forKey: accountsKey)
    }

    override func tearDown() {
        // Remove temp dir (accounts file)
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        BackupManager.testAccountsFileOverride = nil

        // Remove isolated Keychain entry and restore routing to production
        try? KeychainService.shared.deleteAccountList()
        KeychainService.testServiceOverride = nil

        UserDefaults.standard.removeObject(forKey: accountsKey)
        super.tearDown()
    }

    func testSaveAccountsWritesToFile() {
        let manager = BackupManager()
        manager.accounts = [makeAccount(email: "save@example.com")]
        manager.saveAccounts()

        let fileURL = BackupManager.testAccountsFileOverride!
        let data = try? Data(contentsOf: fileURL)
        XCTAssertNotNil(data, "saveAccounts must write encoded data to the accounts file")
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

    func testMigrationFromUserDefaultsToFile() {
        // Seed UserDefaults with legacy data
        let account = makeAccount(email: "legacy@example.com")
        let data = try! JSONEncoder().encode([account])
        UserDefaults.standard.set(data, forKey: accountsKey)

        // BackupManager.init() calls loadAccounts() which migrates and saves to file
        let manager = BackupManager()

        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.accounts.first?.email, "legacy@example.com")
        XCTAssertNil(UserDefaults.standard.data(forKey: accountsKey),
                     "UserDefaults entry must be removed after migration")

        // Verify the data is now in the file
        let fileURL = BackupManager.testAccountsFileOverride!
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "Accounts file must exist after migration from UserDefaults")
    }

    func testMigrationFromKeychainToFile() {
        // Seed the Keychain (test namespace) to simulate an existing install
        // where accounts were saved to Keychain before the file-storage switch
        let account = makeAccount(email: "keychain@example.com")
        let data = try! JSONEncoder().encode([account])
        try? KeychainService.shared.saveAccountList(data)

        // BackupManager.init() calls loadAccounts() which migrates from Keychain to file
        let manager = BackupManager()

        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.accounts.first?.email, "keychain@example.com")

        // Verify the data is now in the file
        let fileURL = BackupManager.testAccountsFileOverride!
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "Accounts file must exist after migration from Keychain")

        // A second load must read from the file (not the Keychain again)
        let reloader = BackupManager()
        XCTAssertEqual(reloader.accounts.count, 1)
        XCTAssertEqual(reloader.accounts.first?.email, "keychain@example.com")
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
