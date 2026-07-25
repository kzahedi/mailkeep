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

    func testCredentialFailureLandsInMissingCredentialsList() async throws {
        let manager = BackupManager()
        let broken = EmailAccount(email: "dead@example.com", imapServer: "imap.example.com")
        // BackupManager.init fires an async checkForMissingPasswords() scan
        // (fire-and-forget Task) that would otherwise race this test: without
        // a stored password it flags `broken` as missing on its own, making
        // the assertion pass/fail by scheduling luck rather than the probe.
        // Storing a password up front keeps that background scan a no-op.
        try await CredentialStore.shared.savePassword("test-pw", for: broken.id)
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

    func testTransientFailureDoesNotFlagAccount() async throws {
        let manager = BackupManager()
        let flaky = EmailAccount(email: "flaky@example.com", imapServer: "imap.example.com")
        // Same race as above: BackupManager.init's background
        // checkForMissingPasswords() must not independently flag `flaky` for
        // having no stored password, or it would land in
        // accountsWithMissingPasswords regardless of the probe outcome this
        // test is actually checking, making the assertion nondeterministic.
        try await CredentialStore.shared.savePassword("test-pw", for: flaky.id)
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
