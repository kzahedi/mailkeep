import Foundation
import SwiftUI
import Combine

/// Main backup manager that coordinates backup operations
@MainActor
class BackupManager: ObservableObject {
    @Published var accounts: [EmailAccount] = []
    @Published var progress: [UUID: BackupProgress] = [:]
    @Published var isBackingUp = false
    @Published var backupLocation: URL
    @Published var schedule: BackupSchedule = .manual
    @Published var scheduledTime: Date = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date()) ?? Date()
    @Published var scheduleConfiguration: ScheduleConfiguration = ScheduleConfiguration()
    @Published var nextScheduledBackup: Date?

    /// Threshold above which emails are streamed directly to disk (in bytes)
    @Published var streamingThresholdBytes: Int = Constants.defaultStreamingThresholdBytes

    /// Accounts that are missing passwords (e.g., after migration)
    @Published var accountsWithMissingPasswords: [EmailAccount] = []

    var activeTasks: [UUID: Task<Void, Never>] = [:]
    var activeHistoryIds: [UUID: UUID] = [:]  // Account ID -> History Entry ID
    var activeIMAPServices: [UUID: IMAPService] = [:]  // Account ID -> Active IMAP Service
    var cancellables = Set<AnyCancellable>()
    var scheduleTimer: Timer?

    // MARK: - Progress Throttling
    /// Pending progress updates to be flushed to UI
    var pendingProgressUpdates: [UUID: BackupProgress] = [:]
    /// Task that handles throttled progress flushing
    var progressFlushTask: Task<Void, Never>?
    /// Interval for progress UI updates (150ms)
    let progressUpdateInterval: UInt64 = 150_000_000  // nanoseconds
    /// Track last subject update time for each account
    var lastSubjectUpdateTime: [UUID: Date] = [:]
    /// Track email count at last subject update for each account
    var lastSubjectUpdateCount: [UUID: Int] = [:]

    // MARK: - Stats Caching
    /// Cache entry for account stats
    struct StatsCacheEntry {
        let stats: AccountStats
        let timestamp: Date
    }
    /// Cache for account stats with 5-second TTL
    var statsCache: [UUID: StatsCacheEntry] = [:]
    /// TTL for stats cache entries (5 seconds)
    let statsCacheTTL: TimeInterval = 5.0
    let accountsKey = "EmailAccounts"
    let scheduleKey = "BackupSchedule"
    let scheduleTimeKey = "BackupScheduleTime"
    let scheduleConfigKey = "BackupScheduleConfig"
    let backupLocationKey = "BackupLocation"
    let streamingThresholdKey = "StreamingThresholdBytes"

    init() {
        // Load backup location or set default
        if let savedPath = UserDefaults.standard.string(forKey: backupLocationKey) {
            self.backupLocation = URL(fileURLWithPath: savedPath)
        } else {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.backupLocation = documentsURL.appendingPathComponent("MailKeep")
        }

        // Load saved accounts and schedule
        loadAccounts()
        loadSchedule()

        // Load streaming threshold
        if UserDefaults.standard.object(forKey: streamingThresholdKey) != nil {
            streamingThresholdBytes = UserDefaults.standard.integer(forKey: streamingThresholdKey)
        }

        // Create backup directory
        try? FileManager.default.createDirectory(at: backupLocation, withIntermediateDirectories: true)

        // Clean up any incomplete downloads from previous sessions
        Task {
            let storageService = StorageService(baseURL: backupLocation)
            if let cleaned = try? await storageService.cleanupIncompleteDownloads(), cleaned > 0 {
                print("Cleaned up \(cleaned) incomplete download(s)")
            }
        }

        // Initialize notification service
        NotificationService.shared.setupNotificationCategories()

        // Start scheduler if needed
        updateScheduler()

        // Check for accounts missing passwords (e.g., after migration)
        checkForMissingPasswords()

        // Subscribe to rate limit settings changes for real-time propagation
        subscribeToRateLimitChanges()
    }

    /// Subscribe to rate limit settings changes and propagate to active IMAP services
    private func subscribeToRateLimitChanges() {
        RateLimitService.shared.settingsDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                Task { @MainActor in
                    await self?.handleRateLimitSettingsChange(change)
                }
            }
            .store(in: &cancellables)
    }

    /// Handle rate limit settings changes by propagating to active IMAP services
    private func handleRateLimitSettingsChange(_ change: RateLimitSettingsChange) async {
        if let accountId = change.accountId {
            // Account-specific settings changed - update that account's IMAP service
            if let imapService = activeIMAPServices[accountId] {
                await imapService.updateRateLimitSettings(change.settings)
                logInfo("Updated rate limit settings for account \(accountId)")
            }
        } else {
            // Global settings changed - update all accounts that use global settings
            for (accountId, imapService) in activeIMAPServices {
                // Only update if the account doesn't have custom settings
                if !RateLimitService.shared.hasCustomSettings(for: accountId) {
                    await imapService.updateRateLimitSettings(change.settings)
                }
            }
            logInfo("Updated global rate limit settings for \(activeIMAPServices.count) active service(s)")
        }
    }

    // MARK: - Errors

    enum BackupManagerError: LocalizedError {
        case invalidEmailData

        var errorDescription: String? {
            switch self {
            case .invalidEmailData:
                return "Downloaded data does not appear to be a valid email"
            }
        }
    }

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
