import Foundation

extension BackupManager {

    static let lastProbeDateKey = "LastCredentialProbeDate"

    /// Pure gate: probe at most once per 24 h.
    nonisolated static func probeIsDue(lastProbe: Date?, now: Date = Date()) -> Bool {
        guard let lastProbe else { return true }
        return now.timeIntervalSince(lastProbe) >= 86_400
    }

    /// Start the hourly check timer. Call once from init; not under XCTest.
    func startCredentialProbeTimer() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        probeTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runCredentialProbeIfDue() }
        }
        timer.tolerance = 300
        probeTimer = timer
        Task { @MainActor in self.runCredentialProbeIfDue() }
    }

    func runCredentialProbeIfDue() {
        guard !isBackingUp else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastProbeDateKey) as? Date
        guard Self.probeIsDue(lastProbe: last) else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastProbeDateKey)
        Task { await runCredentialProbe() }
    }

    /// Probe every enabled account; credential failures join the
    /// missing-credentials sheet and fire a rate-limited notification.
    func runCredentialProbe(notificationDefaultsKey: String = "HealthNotificationLastSent") async {
        logInfo("Running daily credential probe for \(accounts.count) account(s)")
        for account in accounts where account.isEnabled {
            let outcome = await CredentialProbeService.shared.probe(account)
            if case .credentialFailure(let reason) = outcome {
                if !accountsWithMissingPasswords.contains(where: { $0.id == account.id }) {
                    accountsWithMissingPasswords.append(account)
                }
                NotificationService.shared.notifyRepeatedFailures(
                    account: account.email, consecutiveFailures: 1,
                    lastError: reason, defaultsKey: notificationDefaultsKey)
            }
        }
    }
}
