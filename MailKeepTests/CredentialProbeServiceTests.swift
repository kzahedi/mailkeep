import XCTest
@testable import MailKeep

@MainActor
final class CredentialProbeServiceTests: XCTestCase {

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
}
