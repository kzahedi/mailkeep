import XCTest
@testable import MailKeep

@MainActor
final class MissingCredentialsTests: XCTestCase {
    var tempDir: URL!
    var backupManager: BackupManager!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingCredentialsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        CredentialStore.testFileOverride = tempDir.appendingPathComponent("credentials.json")
        BackupManager.testAccountsFileOverride = tempDir.appendingPathComponent("accounts.json")
        backupManager = BackupManager()
    }

    override func tearDown() async throws {
        CredentialStore.testFileOverride = nil
        BackupManager.testAccountsFileOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testOAuthAccountWithoutTokenIsFlaggedAsMissing() async throws {
        let withToken = EmailAccount.gmailOAuth(email: "ok@gmail.com")
        let withoutToken = EmailAccount.gmailOAuth(email: "broken@gmail.com")
        try await CredentialStore.shared.saveOAuthTokenString("{\"t\":1}", for: withToken.id)
        backupManager.accounts = [withToken, withoutToken]

        backupManager.checkForMissingPasswords()

        // checkForMissingPasswords updates asynchronously; poll briefly
        for _ in 0..<50 {
            if backupManager.accountsWithMissingPasswords.map(\.email) == ["broken@gmail.com"] {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Expected exactly broken@gmail.com to be flagged, got \(backupManager.accountsWithMissingPasswords.map(\.email))")
    }
}
