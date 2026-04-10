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
    let idleEnabledKey = "idleEnabled"

    init() {
        // Load backup location or set default
        if let savedPath = UserDefaults.standard.string(forKey: backupLocationKey) {
            self.backupLocation = URL(fileURLWithPath: savedPath)
        } else {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.backupLocation = documentsURL.appendingPathComponent("MailKeep")
        }

        // Load saved accounts and schedule — must run before startIDLEMonitoring
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

        // Start IDLE monitoring if enabled
        startIDLEMonitoring()
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

}
