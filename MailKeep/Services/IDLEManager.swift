import Foundation

/// Manages persistent IMAP IDLE connections for real-time inbox monitoring.
///
/// Lifecycle:
/// - `startMonitoring(accounts:onNewMail:)` — starts one monitor task per account.
/// - `stopMonitoring(accountId:)` — stops a specific account's monitor.
/// - `stopAll()` — stops all monitors.
///
/// Connection policy:
/// - On new mail (EXISTS): fetches new UIDs, fires `onNewMail` callback.
/// - On keepalive timeout (25 min): disconnects and immediately reconnects.
/// - On any error: waits 30 seconds then reconnects.
actor IDLEManager {
    static let shared = IDLEManager()

    private var monitors: [UUID: Task<Void, Never>] = [:]
    private var onNewMailCallbacks: [UUID: (UUID) -> Void] = [:]

    // MARK: - Public API

    /// Start monitoring the given accounts. Accounts already monitored are skipped.
    func startMonitoring(accounts: [EmailAccount], onNewMail: @escaping (UUID) -> Void) {
        for account in accounts {
            guard monitors[account.id] == nil else { continue }
            onNewMailCallbacks[account.id] = onNewMail
            let task = Task { await self.runMonitor(for: account) }
            monitors[account.id] = task
        }
    }

    /// Stop monitoring a specific account and remove its callback.
    func stopMonitoring(accountId: UUID) {
        monitors[accountId]?.cancel()
        monitors.removeValue(forKey: accountId)
        onNewMailCallbacks.removeValue(forKey: accountId)
    }

    /// Stop all active monitors.
    func stopAll() {
        for task in monitors.values { task.cancel() }
        monitors.removeAll()
        onNewMailCallbacks.removeAll()
    }

    /// Number of currently active monitor tasks.
    var monitorCount: Int { monitors.count }

    // MARK: - Private Monitor Loop

    /// Main reconnect loop for a single account.
    ///
    /// Outer loop: reconnects on error (30s delay) or keepalive timeout (immediate).
    /// Inner loop: sends IDLE, processes notifications, repeats.
    private func runMonitor(for account: EmailAccount) async {
        while !Task.isCancelled {
            let service = IMAPService(account: account)
            let rateLimitSettings = await RateLimitService.shared.getSettings(for: account.id)
            let sharedTracker = await RateLimitService.shared.getTracker(forServer: account.imapServer, accountId: account.id)
            await service.configureRateLimit(settings: rateLimitSettings, sharedTracker: sharedTracker)
            do {
                try await service.connect()
                try await service.login()
                _ = try await service.selectFolder("INBOX")
                var lastUID = try await service.fetchLastUID()

                logInfo("IDLE: monitoring INBOX for \(account.email) (lastUID=\(lastUID))")

                // Inner IDLE loop — stays on same connection until timeout or error
                idleLoop: while !Task.isCancelled {
                    // 25-minute keepalive (RFC 2177 §3: re-IDLE before server's 30-min limit)
                    let notification = try await service.waitForIDLENotification(timeout: 25 * 60)

                    switch notification {
                    case .exists:
                        // Fetch UIDs greater than lastUID
                        let newUIDs = try await service.fetchNewUIDs(after: lastUID)
                        guard !Task.isCancelled else { break idleLoop }
                        if !newUIDs.isEmpty {
                            lastUID = newUIDs.max() ?? lastUID
                            logInfo("IDLE: \(newUIDs.count) new message(s) for \(account.email)")
                            onNewMailCallbacks[account.id]?(account.id)
                        }
                        // Re-enter IDLE (loop continues)

                    case .timeout:
                        // Connection was disconnected by keepalive.
                        // Break inner loop → outer loop reconnects immediately.
                        logInfo("IDLE: keepalive timeout for \(account.email), reconnecting")
                        break idleLoop
                    }
                }

                // Attempt clean logout (will fail silently if connection dropped on .timeout)
                try? await service.logout()

            } catch {
                guard !Task.isCancelled else { break }
                logWarning("IDLE: error for \(account.email): \(error.localizedDescription). Retrying in 30s.")
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    break  // Task cancelled during sleep — exit immediately
                }
            }
        }

        logInfo("IDLE: monitor stopped for \(account.email)")
    }
}
