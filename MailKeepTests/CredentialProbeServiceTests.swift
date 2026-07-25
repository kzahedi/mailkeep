import XCTest
@testable import MailKeep

@MainActor
final class CredentialProbeServiceTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialProbeServiceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        CredentialStore.testFileOverride = tempDir.appendingPathComponent("credentials.json")
        BackupManager.testAccountsFileOverride = tempDir.appendingPathComponent("accounts.json")
        KeychainService.testServiceOverride = "com.kzahedi.MailKeep.accounts.test-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? KeychainService.shared.deleteAccountList()
        KeychainService.testServiceOverride = nil
        CredentialStore.testFileOverride = nil
        BackupManager.testAccountsFileOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func account() -> EmailAccount {
        EmailAccount(email: "probe@example.com", imapServer: "imap.example.com")
    }

    func testProbeSucceedsAndLogsOut() async {
        let mock = MockIMAPService()
        let service = CredentialProbeService()
        service.makeIMAPService = { _ in mock }
        let outcome = await service.probe(account())
        XCTAssertEqual(outcome, .ok)
        let logins = await mock.loginCallCount
        let logouts = await mock.logoutCallCount
        XCTAssertEqual(logins, 1)
        XCTAssertEqual(logouts, 1)
    }

    func testLoginFailureIsCredentialFailure() async {
        let mock = MockIMAPService()
        await mock.setShouldFailLogin(true)
        let service = CredentialProbeService()
        service.makeIMAPService = { _ in mock }
        let outcome = await service.probe(account())
        guard case .credentialFailure = outcome else {
            return XCTFail("Expected credentialFailure, got \(outcome)")
        }
    }

    func testConnectFailureIsTransient() async {
        let mock = MockIMAPService()
        await mock.setShouldFailConnect(true)
        let service = CredentialProbeService()
        service.makeIMAPService = { _ in mock }
        let outcome = await service.probe(account())
        guard case .transient = outcome else {
            return XCTFail("Expected transient, got \(outcome)")
        }
    }

    // MARK: - Scheduling / merge into missing-credentials sheet

    func testProbeIsDueSemantics() {
        let now = Date()
        XCTAssertTrue(BackupManager.probeIsDue(lastProbe: nil, now: now))
        XCTAssertFalse(BackupManager.probeIsDue(lastProbe: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(BackupManager.probeIsDue(lastProbe: now.addingTimeInterval(-90_000), now: now))
    }

    func testCredentialFailureLandsInMissingCredentialsList() async {
        let manager = BackupManager()
        let broken = EmailAccount(email: "dead@example.com", imapServer: "imap.example.com")
        manager.accounts = [broken]
        let mock = MockIMAPService()
        await mock.setShouldFailLogin(true)
        CredentialProbeService.shared.makeIMAPService = { _ in mock }
        defer { CredentialProbeService.shared.makeIMAPService = { IMAPService(account: $0) } }

        let notifyKey = "TestProbeNotify-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: notifyKey) }
        await manager.runCredentialProbe(notificationDefaultsKey: notifyKey)

        XCTAssertEqual(manager.accountsWithMissingPasswords.map(\.email), ["dead@example.com"])
    }

    func testTransientFailureDoesNotFlagAccount() async {
        let manager = BackupManager()
        let flaky = EmailAccount(email: "flaky@example.com", imapServer: "imap.example.com")
        manager.accounts = [flaky]
        let mock = MockIMAPService()
        await mock.setShouldFailConnect(true)
        CredentialProbeService.shared.makeIMAPService = { _ in mock }
        defer { CredentialProbeService.shared.makeIMAPService = { IMAPService(account: $0) } }

        let notifyKey = "TestProbeNotify-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: notifyKey) }
        await manager.runCredentialProbe(notificationDefaultsKey: notifyKey)

        XCTAssertTrue(manager.accountsWithMissingPasswords.isEmpty)
    }
}
