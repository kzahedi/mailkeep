import Foundation

extension BackupManager {

    // MARK: - Progress Throttling

    /// Accumulates progress updates and flushes to UI every 150ms to prevent flooding
    func updateProgress(for accountId: UUID, update: (inout BackupProgress) -> Void) {
        // Get current progress (from pending or published)
        var current = pendingProgressUpdates[accountId] ?? progress[accountId] ?? BackupProgress(accountId: accountId)
        update(&current)
        pendingProgressUpdates[accountId] = current

        // Start flush task if not already running
        if progressFlushTask == nil {
            progressFlushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.progressUpdateInterval ?? 150_000_000)
                await self?.flushProgressUpdates()
            }
        }
    }

    /// Flush pending progress updates to the published property
    func flushProgressUpdates() {
        for (accountId, pendingProgress) in pendingProgressUpdates {
            progress[accountId] = pendingProgress
        }
        pendingProgressUpdates.removeAll()
        progressFlushTask = nil
    }

    /// Bypass throttle for status changes (connecting, completed, failed, cancelled)
    func updateProgressImmediate(for accountId: UUID, update: (inout BackupProgress) -> Void) {
        if var current = progress[accountId] {
            update(&current)
            progress[accountId] = current
            // Also update pending to keep in sync
            pendingProgressUpdates[accountId] = current
        }
    }

    /// Returns true every 10 emails or every 500ms — throttles subject line UI updates
    func shouldUpdateSubject(for accountId: UUID, currentCount: Int) -> Bool {
        let now = Date()

        // Check time-based threshold (500ms)
        if let lastTime = lastSubjectUpdateTime[accountId] {
            if now.timeIntervalSince(lastTime) >= 0.5 {
                lastSubjectUpdateTime[accountId] = now
                lastSubjectUpdateCount[accountId] = currentCount
                return true
            }
        } else {
            lastSubjectUpdateTime[accountId] = now
            lastSubjectUpdateCount[accountId] = currentCount
            return true
        }

        // Check count-based threshold (every 10 emails)
        let lastCount = lastSubjectUpdateCount[accountId] ?? 0
        if currentCount - lastCount >= 10 {
            lastSubjectUpdateTime[accountId] = now
            lastSubjectUpdateCount[accountId] = currentCount
            return true
        }

        return false
    }
}
