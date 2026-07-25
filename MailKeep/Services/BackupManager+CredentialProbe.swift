import Foundation

extension BackupManager {

    static let lastProbeDateKey = "LastCredentialProbeDate"

    /// Account IDs the probe has flagged as credential-dead. This survives
    /// re-checks of `checkForMissingPasswords()` (restart, sheet save for
    /// another account, etc.) which only scans for *presence* of a stored
    /// credential and would otherwise silently erase probe findings for a
    /// credential that is present but no longer accepted by the server.
    static let probeFlaggedIDsKey = "ProbeFlaggedAccountIDs"
    var probeFlaggedAccountIDs: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: Self.probeFlaggedIDsKey) ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: Self.probeFlaggedIDsKey) }
    }

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
            switch outcome {
            case .credentialFailure(let reason):
                probeFlaggedAccountIDs.insert(account.id)

                if !accountsWithMissingPasswords.contains(where: { $0.id == account.id }) {
                    accountsWithMissingPasswords.append(account)
                }
                NotificationService.shared.notifyCredentialProblem(
                    account: account.email, reason: reason,
                    defaultsKey: notificationDefaultsKey)
            case .ok:
                probeFlaggedAccountIDs.remove(account.id)
            case .transient:
                break
            }
        }
        // Recompute the presence-based list now that probe flags have settled,
        // so a `.ok` outcome can actually clear an account that no longer has
        // a live credential problem.
        checkForMissingPasswords()
    }
}
