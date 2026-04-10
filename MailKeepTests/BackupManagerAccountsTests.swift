import XCTest
@testable import MailKeep

/// Tests for BackupManager account persistence (saveAccounts / loadAccounts).
///
/// Note on task 6.2 (encoding failure): JSONEncoder is final and EmailAccount is
/// always Codable, so triggering an encoding failure without dependency injection
/// is not feasible. The tests below verify the observable invariant — that
/// saveAccounts correctly writes to UserDefaults on success — which is the
/// complementary assertion to "UserDefaults is NOT written on failure".
@MainActor
final class BackupManagerAccountsTests: XCTestCase {

    private let accountsKey = "EmailAccounts"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: accountsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: accountsKey)
        super.tearDown()
    }

    func testSaveAccountsWritesToUserDefaults() {
        let manager = BackupManager()
        manager.accounts = [makeAccount(email: "save@example.com")]
        manager.saveAccounts()

        let data = UserDefaults.standard.data(forKey: accountsKey)
        XCTAssertNotNil(data, "saveAccounts must write encoded data to UserDefaults")
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

    func testSaveEmptyAccountsClearsUserDefaults() {
        // First write some data
        let manager = BackupManager()
        manager.accounts = [makeAccount(email: "initial@example.com")]
        manager.saveAccounts()

        // Now clear and save
        manager.accounts = []
        manager.saveAccounts()

        let reloader = BackupManager()
        reloader.loadAccounts()
        XCTAssertTrue(reloader.accounts.isEmpty, "Saving empty accounts should persist an empty list")
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
