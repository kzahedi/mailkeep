import Foundation

extension BackupManager {

    // MARK: - Statistics

    struct AccountStats {
        var totalEmails: Int = 0
        var totalSize: Int64 = 0
        var folderCount: Int = 0
        var oldestEmail: Date?
        var newestEmail: Date?
    }

    struct GlobalStats {
        var totalEmails: Int = 0
        var totalSize: Int64 = 0
        var accountCount: Int = 0
    }

    /// Get stats for an account with caching (5-second TTL)
    /// Runs file enumeration on a background thread to avoid blocking UI
    func getStats(for account: EmailAccount) async -> AccountStats {
        // Check cache first
        if let cached = statsCache[account.id],
           Date().timeIntervalSince(cached.timestamp) < statsCacheTTL {
            return cached.stats
        }

        // Run file enumeration on background thread
        let accountDir = backupLocation.appendingPathComponent(account.email.sanitizedForFilename())
        let stats = await Task.detached(priority: .utility) {
            return BackupManager.calculateStatsAtDirectory(accountDir)
        }.value

        // Cache the result
        statsCache[account.id] = StatsCacheEntry(stats: stats, timestamp: Date())
        return stats
    }

    /// Get stats synchronously (legacy method for backward compatibility)
    /// Prefer using async getStats(for:) instead
    func getStatsSync(for account: EmailAccount) -> AccountStats {
        let accountDir = backupLocation.appendingPathComponent(account.email.sanitizedForFilename())
        return BackupManager.calculateStatsAtDirectory(accountDir)
    }

    /// Get global stats with caching
    /// Runs file enumeration on background threads to avoid blocking UI
    func getGlobalStats() async -> GlobalStats {
        var global = GlobalStats()
        global.accountCount = accounts.count

        // Fetch all account stats concurrently
        await withTaskGroup(of: AccountStats.self) { group in
            for account in accounts {
                group.addTask {
                    await self.getStats(for: account)
                }
            }

            for await stats in group {
                global.totalEmails += stats.totalEmails
                global.totalSize += stats.totalSize
            }
        }

        return global
    }

    /// Get global stats synchronously (legacy method for backward compatibility)
    /// Prefer using async getGlobalStats() instead
    func getGlobalStatsSync() -> GlobalStats {
        var global = GlobalStats()
        global.accountCount = accounts.count

        for account in accounts {
            let accountDir = backupLocation.appendingPathComponent(account.email.sanitizedForFilename())
            let stats = BackupManager.calculateStatsAtDirectory(accountDir)
            global.totalEmails += stats.totalEmails
            global.totalSize += stats.totalSize
        }

        return global
    }

    /// Invalidate stats cache for an account (call after backup completes)
    func invalidateStatsCache(for accountId: UUID) {
        statsCache.removeValue(forKey: accountId)
    }

    /// Invalidate all stats cache entries
    func invalidateAllStatsCache() {
        statsCache.removeAll()
    }

    /// Calculate stats at a directory (nonisolated static to allow calling from detached tasks)
    private nonisolated static func calculateStatsAtDirectory(_ directory: URL) -> AccountStats {
        var stats = AccountStats()
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return stats
        }

        var folders = Set<String>()

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true,
                  fileURL.pathExtension == "eml" else {
                continue
            }

            stats.totalEmails += 1
            stats.totalSize += Int64(resourceValues.fileSize ?? 0)

            // Track folder
            let folderPath = fileURL.deletingLastPathComponent().path
            folders.insert(folderPath)

            // Track dates from filename (format: YYYYMMDD_HHMMSS_sender.eml)
            let filename = fileURL.deletingPathExtension().lastPathComponent
            if let date = parseDateFromFilename(filename) {
                if stats.oldestEmail == nil || date < stats.oldestEmail! {
                    stats.oldestEmail = date
                }
                if stats.newestEmail == nil || date > stats.newestEmail! {
                    stats.newestEmail = date
                }
            }
        }

        stats.folderCount = folders.count
        return stats
    }

    private nonisolated static func parseDateFromFilename(_ filename: String) -> Date? {
        // Format: YYYYMMDD_HHMMSS_sender
        let parts = filename.components(separatedBy: "_")
        guard parts.count >= 2,
              parts[0].count == 8,
              parts[1].count == 6 else {
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        return dateFormatter.date(from: "\(parts[0])_\(parts[1])")
    }
}
