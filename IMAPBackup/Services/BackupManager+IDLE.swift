import Foundation

extension BackupManager {

    // MARK: - IDLE Lifecycle

    /// Start IDLE monitoring for all accounts where IDLE is effectively enabled.
    ///
    /// Effective IDLE = global toggle ON && account.isEnabled && (account.idleEnabled ?? true)
    func startIDLEMonitoring() {
        guard UserDefaults.standard.bool(forKey: idleEnabledKey) else { return }
        let idleAccounts = accounts.filter { $0.isEnabled && ($0.idleEnabled ?? true) }
        guard !idleAccounts.isEmpty else { return }

        Task {
            await IDLEManager.shared.startMonitoring(accounts: idleAccounts) { [weak self] accountId in
                guard let self else { return }
                Task { @MainActor in
                    await self.triggerIncrementalBackup(for: accountId)
                }
            }
        }
    }

    /// Stop all IDLE monitors.
    func stopIDLEMonitoring() {
        Task { await IDLEManager.shared.stopAll() }
    }

    /// Restart IDLE monitoring for a specific account after settings changed.
    func restartIDLEMonitoring(for account: EmailAccount) {
        Task { await IDLEManager.shared.stopMonitoring(accountId: account.id) }
        startIDLEMonitoring()
    }

    // MARK: - Global Toggle

    /// Enable or disable IDLE monitoring globally and persist to UserDefaults.
    func setIDLEEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: idleEnabledKey)
        if enabled {
            startIDLEMonitoring()
        } else {
            stopIDLEMonitoring()
        }
    }

    // MARK: - Incremental Backup Trigger

    /// Called by IDLEManager when new mail is detected in INBOX.
    /// No-ops if a full backup is already running for this account.
    private func triggerIncrementalBackup(for accountId: UUID) async {
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }
        guard activeTasks[accountId] == nil else {
            logInfo("IDLE: full backup already running for \(account.email), skipping incremental")
            return
        }
        logInfo("IDLE: triggering incremental backup for \(account.email)")
        await performBackup(for: account)
    }
}
