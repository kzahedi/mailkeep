import Foundation

/// Outcome of a lightweight credential probe (connect + login + logout, no mail).
enum ProbeOutcome: Equatable {
    case ok
    /// The server rejected our credentials — user action needed.
    case credentialFailure(String)
    /// Network or other non-credential problem — retry silently later.
    case transient(String)
}

/// Probes an account's stored credentials with a real IMAP login so dead
/// passwords/tokens surface within a day instead of at the next backup
/// failure. The IONOS password that silently failed for 7 weeks (June–July
/// 2026) is the motivating case.
@MainActor
final class CredentialProbeService {
    static let shared = CredentialProbeService()

    init() {}

    /// Injection seam for tests (MockIMAPService).
    var makeIMAPService: (EmailAccount) -> any IMAPServiceProtocol = { IMAPService(account: $0) }

    func probe(_ account: EmailAccount) async -> ProbeOutcome {
        let service = makeIMAPService(account)
        do {
            try await service.connect()
            try await service.login(password: nil)
            try? await service.logout()
            await service.disconnect()
            logInfo("Credential probe OK for \(account.email)")
            return .ok
        } catch let error as IMAPError {
            await service.disconnect()
            switch error {
            case .authenticationFailed, .oauthFailed:
                logWarning("Credential probe FAILED (credentials) for \(account.email): \(error.localizedDescription)")
                return .credentialFailure(error.localizedDescription)
            default:
                logInfo("Credential probe transient error for \(account.email): \(error.localizedDescription)")
                return .transient(error.localizedDescription)
            }
        } catch {
            await service.disconnect()
            return .transient(error.localizedDescription)
        }
    }
}
