import Foundation

extension BackupManager {

    // MARK: - Backup Operations

    func startBackup(for account: EmailAccount) {
        guard activeTasks[account.id] == nil else { return }

        isBackingUp = true
        progress[account.id] = BackupProgress(accountId: account.id)

        activeTasks[account.id] = Task {
            await performBackup(for: account)
        }
    }

    func startBackupAll() {
        for account in accounts where account.isEnabled {
            startBackup(for: account)
        }
    }

    func cancelBackup(for accountId: UUID) {
        activeTasks[accountId]?.cancel()
        activeTasks.removeValue(forKey: accountId)
        activeIMAPServices.removeValue(forKey: accountId)
        updateProgressImmediate(for: accountId) { $0.status = .cancelled }

        // Mark history entry as cancelled
        if let historyId = activeHistoryIds[accountId] {
            BackupHistoryService.shared.completeEntry(id: historyId, status: .cancelled)
            activeHistoryIds.removeValue(forKey: accountId)
        }

        updateIsBackingUp()
    }

    func cancelAllBackups() {
        for (id, task) in activeTasks {
            task.cancel()
            updateProgressImmediate(for: id) { $0.status = .cancelled }

            // Mark history entry as cancelled
            if let historyId = activeHistoryIds[id] {
                BackupHistoryService.shared.completeEntry(id: historyId, status: .cancelled)
            }
        }
        activeTasks.removeAll()
        activeHistoryIds.removeAll()
        activeIMAPServices.removeAll()
        isBackingUp = false
    }

    func updateIsBackingUp() {
        isBackingUp = !activeTasks.isEmpty
    }

    func checkAllBackupsComplete() {
        // Only send summary if no more active tasks and we had multiple accounts
        guard activeTasks.isEmpty else { return }

        let completedCount = progress.values.filter {
            $0.status == .completed || $0.status == .failed
        }.count

        guard completedCount > 1 else { return }

        var totalDownloaded = 0
        var totalErrors = 0

        for (_, prog) in progress {
            totalDownloaded += prog.downloadedEmails
            totalErrors += prog.errors.count
        }

        NotificationService.shared.notifyAllBackupsCompleted(
            totalAccounts: completedCount,
            totalDownloaded: totalDownloaded,
            totalErrors: totalErrors
        )

        // Apply retention policies after all backups complete
        Task {
            let result = await RetentionService.shared.applyRetentionToAll(backupLocation: backupLocation)
            if result.filesDeleted > 0 {
                logInfo("Retention policy applied: deleted \(result.filesDeleted) files, freed \(result.bytesFreedFormatted)")
            }
        }
    }
}
