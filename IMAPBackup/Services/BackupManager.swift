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
    private let accountsKey = "EmailAccounts"
    private let scheduleKey = "BackupSchedule"
    private let scheduleTimeKey = "BackupScheduleTime"
    private let scheduleConfigKey = "BackupScheduleConfig"
    private let backupLocationKey = "BackupLocation"
    private let streamingThresholdKey = "StreamingThresholdBytes"

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

    // MARK: - Password Management

    /// Check all accounts for missing passwords
    func checkForMissingPasswords() {
        Task {
            var missing: [EmailAccount] = []
            for account in accounts {
                // Only check password-based accounts, not OAuth
                guard account.authType == .password else { continue }

                let hasPassword = await KeychainService.shared.hasPassword(for: account.id)
                if !hasPassword {
                    missing.append(account)
                }
            }

            await MainActor.run {
                self.accountsWithMissingPasswords = missing
            }
        }
    }

    // MARK: - Account Management

    @discardableResult
    func addAccount(_ account: EmailAccount, password: String?) -> Bool {
        // Check for duplicate email address
        if accounts.contains(where: { $0.email.lowercased() == account.email.lowercased() }) {
            logError("Account with email \(account.email) already exists")
            return false
        }

        var mutableAccount = account
        accounts.append(mutableAccount)
        saveAccounts()

        // Save password to Keychain (only for non-OAuth accounts)
        // Use consumeTemporaryPassword to clear the password from the account struct
        let passwordToSave = password ?? mutableAccount.consumeTemporaryPassword()
        if let passwordToSave = passwordToSave {
            Task {
                do {
                    try await KeychainService.shared.savePassword(passwordToSave, for: account.id)
                    logInfo("Password saved to Keychain for \(account.email)")
                } catch {
                    logError("Failed to save password to Keychain for \(account.email): \(error.localizedDescription)")
                }
            }
        }

        // Clear the temporary password from the stored account
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index].clearTemporaryPassword()
        }

        return true
    }

    func removeAccount(_ account: EmailAccount) {
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
        // Remove password from Keychain
        Task {
            do {
                try await KeychainService.shared.deletePassword(for: account.id)
            } catch {
                logWarning("Failed to delete password from Keychain for \(account.email): \(error.localizedDescription)")
            }
        }
    }

    func updateAccount(_ account: EmailAccount, password: String? = nil) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
            saveAccounts()
            // Update password in Keychain if provided
            if let password = password {
                Task {
                    do {
                        try await KeychainService.shared.savePassword(password, for: account.id)
                    } catch {
                        logError("Failed to update password in Keychain for \(account.email): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        saveAccounts()
    }

    private func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([EmailAccount].self, from: data) {
            accounts = decoded
        }

        // Uncomment to add a test account for development
        // #if DEBUG
        // if accounts.isEmpty {
        //     let testAccount = EmailAccount.gmail(
        //         email: "your-email@gmail.com",
        //         appPassword: "your-app-password"
        //     )
        //     accounts.append(testAccount)
        // }
        // #endif
    }

    private func saveAccounts() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: accountsKey)
        }
    }

    // MARK: - Scheduling

    private func loadSchedule() {
        if let savedSchedule = UserDefaults.standard.string(forKey: scheduleKey),
           let schedule = BackupSchedule(rawValue: savedSchedule) {
            self.schedule = schedule
        }

        if let savedTimeInterval = UserDefaults.standard.object(forKey: scheduleTimeKey) as? TimeInterval {
            self.scheduledTime = Date(timeIntervalSince1970: savedTimeInterval)
        }

        if let configData = UserDefaults.standard.data(forKey: scheduleConfigKey),
           let config = try? JSONDecoder().decode(ScheduleConfiguration.self, from: configData) {
            self.scheduleConfiguration = config
        }
    }

    func setSchedule(_ newSchedule: BackupSchedule) {
        schedule = newSchedule
        UserDefaults.standard.set(newSchedule.rawValue, forKey: scheduleKey)
        updateScheduler()
    }

    func setScheduledTime(_ time: Date) {
        scheduledTime = time
        UserDefaults.standard.set(time.timeIntervalSince1970, forKey: scheduleTimeKey)
        updateScheduler()
    }

    func setScheduleConfiguration(_ config: ScheduleConfiguration) {
        scheduleConfiguration = config
        if let encoded = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(encoded, forKey: scheduleConfigKey)
        }
        updateScheduler()
    }

    var scheduledTimeFormatted: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: scheduledTime)
    }

    private func updateScheduler() {
        // Cancel existing timer
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        nextScheduledBackup = nil

        guard schedule != .manual else { return }

        // Calculate next backup time
        nextScheduledBackup = calculateNextBackupTime()

        // Set up timer to check every minute if it's time to backup
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkScheduledBackup()
            }
        }
    }

    private func calculateNextBackupTime() -> Date? {
        let calendar = Calendar.current
        let now = Date()

        switch schedule {
        case .manual:
            return nil

        case .hourly:
            // Next hour
            return calendar.date(byAdding: .hour, value: 1, to: now)

        case .daily:
            // Today or tomorrow at scheduled time
            let hour = calendar.component(.hour, from: scheduledTime)
            let minute = calendar.component(.minute, from: scheduledTime)

            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0

            if let todayBackup = calendar.date(from: components), todayBackup > now {
                return todayBackup
            } else {
                // Tomorrow
                components.day! += 1
                return calendar.date(from: components)
            }

        case .weekly:
            // Next occurrence of the selected weekday at scheduled time
            let hour = calendar.component(.hour, from: scheduledTime)
            let minute = calendar.component(.minute, from: scheduledTime)
            let targetWeekday = scheduleConfiguration.weekday.rawValue

            // Find the next occurrence of the target weekday
            var components = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
            let currentWeekday = components.weekday!

            var daysUntilTarget = targetWeekday - currentWeekday
            if daysUntilTarget < 0 {
                daysUntilTarget += 7
            }

            // If it's the target day, check if the time has passed
            if daysUntilTarget == 0 {
                var todayComponents = calendar.dateComponents([.year, .month, .day], from: now)
                todayComponents.hour = hour
                todayComponents.minute = minute
                todayComponents.second = 0

                if let todayBackup = calendar.date(from: todayComponents), todayBackup > now {
                    return todayBackup
                } else {
                    // Same day but time passed, schedule for next week
                    daysUntilTarget = 7
                }
            }

            if let targetDate = calendar.date(byAdding: .day, value: daysUntilTarget, to: now) {
                var targetComponents = calendar.dateComponents([.year, .month, .day], from: targetDate)
                targetComponents.hour = hour
                targetComponents.minute = minute
                targetComponents.second = 0
                return calendar.date(from: targetComponents)
            }
            return nil

        case .custom:
            // Calculate based on custom interval
            let interval = scheduleConfiguration.customUnit.toSeconds(scheduleConfiguration.customInterval)

            // For custom schedules, we calculate from the scheduled time today
            let hour = calendar.component(.hour, from: scheduledTime)
            let minute = calendar.component(.minute, from: scheduledTime)

            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0

            if let baseDate = calendar.date(from: components) {
                if baseDate > now {
                    return baseDate
                } else {
                    // Add one interval
                    return baseDate.addingTimeInterval(interval)
                }
            }
            return nil
        }
    }

    private func checkScheduledBackup() {
        guard !isBackingUp,
              let nextBackup = nextScheduledBackup,
              Date() >= nextBackup else { return }

        startBackupAll()

        // Calculate next backup time
        nextScheduledBackup = calculateNextBackupTime()
    }

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

    private func updateIsBackingUp() {
        isBackingUp = !activeTasks.isEmpty
    }

    private func checkAllBackupsComplete() {
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

    // MARK: - Backup Execution

    private func performBackup(for account: EmailAccount) async {
        let imapService = IMAPService(account: account)
        let storageService = StorageService(baseURL: backupLocation)

        // Configure rate limiting with shared server tracker
        let rateLimitSettings = RateLimitService.shared.getSettings(for: account.id)
        let sharedTracker = RateLimitService.shared.getTracker(forServer: account.imapServer, accountId: account.id)
        await imapService.configureRateLimit(settings: rateLimitSettings, sharedTracker: sharedTracker)

        // Track active IMAP service for real-time settings propagation
        activeIMAPServices[account.id] = imapService

        // Start history entry
        let historyId = BackupHistoryService.shared.startEntry(for: account.email)
        activeHistoryIds[account.id] = historyId

        logInfo("Starting backup for account: \(account.email)")

        do {
            // Connect
            updateProgressImmediate(for: account.id) { $0.status = .connecting }
            try await imapService.connect()
            try await imapService.login()
            logInfo("Connected and authenticated to \(account.imapServer)")

            // Fetch folders
            updateProgressImmediate(for: account.id) { $0.status = .fetchingFolders }
            let folders = try await imapService.listFolders()
            let selectableFolders = folders.filter { $0.isSelectable }

            updateProgress(for: account.id) {
                $0.totalFolders = selectableFolders.count
            }

            // Phase 1: Count all emails that need to be downloaded
            updateProgressImmediate(for: account.id) { $0.status = .counting }
            var folderNewUIDs: [(IMAPFolder, [UInt32])] = []
            var totalNewEmails = 0

            for (index, folder) in selectableFolders.enumerated() {
                guard !Task.isCancelled else { break }

                updateProgress(for: account.id) {
                    $0.currentFolder = folder.name
                }

                let newUIDs = try await countNewEmails(
                    in: folder,
                    account: account,
                    imapService: imapService,
                    storageService: storageService
                )

                if !newUIDs.isEmpty {
                    folderNewUIDs.append((folder, newUIDs))
                    totalNewEmails += newUIDs.count
                }
            }

            // Set total count before downloading
            updateProgress(for: account.id) {
                $0.totalEmails = totalNewEmails
            }

            logInfo("Found \(totalNewEmails) new emails to download across \(folderNewUIDs.count) folders")

            // Phase 2: Download emails from each folder
            for (index, (folder, newUIDs)) in folderNewUIDs.enumerated() {
                guard !Task.isCancelled else { break }

                updateProgress(for: account.id) {
                    $0.currentFolder = folder.name
                    $0.processedFolders = index
                }

                try await downloadEmails(
                    uids: newUIDs,
                    from: folder,
                    account: account,
                    imapService: imapService,
                    storageService: storageService
                )
            }

            // Complete
            updateProgressImmediate(for: account.id) {
                $0.status = .completed
                $0.processedFolders = folderNewUIDs.count
            }

            // Update last backup date
            var updatedAccount = account
            updatedAccount.lastBackupDate = Date()
            updateAccount(updatedAccount)

            // Invalidate stats cache since backup added new emails
            invalidateStatsCache(for: account.id)

            try await imapService.logout()

            // Update and complete history entry
            if let finalProgress = progress[account.id] {
                logInfo("Backup completed for \(account.email): \(finalProgress.downloadedEmails) emails downloaded, \(finalProgress.errors.count) errors")

                BackupHistoryService.shared.updateEntry(
                    id: historyId,
                    emailsDownloaded: finalProgress.downloadedEmails,
                    totalEmails: finalProgress.totalEmails,
                    bytesDownloaded: finalProgress.bytesDownloaded,
                    foldersProcessed: finalProgress.processedFolders
                )

                let historyStatus: BackupHistoryStatus = finalProgress.errors.isEmpty ? .completed : .completedWithErrors
                for error in finalProgress.errors {
                    logWarning("Backup error for \(account.email): \(error.message)")
                    BackupHistoryService.shared.updateEntry(id: historyId, error: error.message)
                }
                BackupHistoryService.shared.completeEntry(id: historyId, status: historyStatus)

                // Send completion notification
                NotificationService.shared.notifyBackupCompleted(
                    account: account.email,
                    emailsDownloaded: finalProgress.downloadedEmails,
                    totalEmails: finalProgress.totalEmails,
                    errors: finalProgress.errors.count
                )
            }

        } catch {
            logError("Backup failed for \(account.email): \(error.localizedDescription)")

            updateProgressImmediate(for: account.id) {
                $0.status = .failed
                $0.errors.append(BackupError(message: error.localizedDescription))
            }

            // Complete history entry with failure
            BackupHistoryService.shared.updateEntry(id: historyId, error: error.localizedDescription)
            BackupHistoryService.shared.completeEntry(id: historyId, status: .failed)

            // Send failure notification
            NotificationService.shared.notifyBackupFailed(
                account: account.email,
                error: error.localizedDescription
            )
        }

        activeTasks.removeValue(forKey: account.id)
        activeHistoryIds.removeValue(forKey: account.id)
        activeIMAPServices.removeValue(forKey: account.id)
        updateIsBackingUp()

        // Check if all backups are complete for summary notification
        checkAllBackupsComplete()
    }

    /// Phase 1: Count new emails in a folder without downloading
    private func countNewEmails(
        in folder: IMAPFolder,
        account: EmailAccount,
        imapService: IMAPService,
        storageService: StorageService
    ) async throws -> [UInt32] {
        // Select folder
        let status = try await imapService.selectFolder(folder.name)

        guard status.exists > 0 else { return [] }

        // Search for all emails
        let allUIDs = try await imapService.searchAll()

        // Get already backed up UIDs by scanning existing files
        let backedUpUIDs = (try? await storageService.getExistingUIDs(
            accountEmail: account.email,
            folderPath: folder.path
        )) ?? []

        // Return only new UIDs
        return allUIDs.filter { !backedUpUIDs.contains($0) }
    }

    /// Phase 2: Download emails with pre-calculated UIDs
    private func downloadEmails(
        uids: [UInt32],
        from folder: IMAPFolder,
        account: EmailAccount,
        imapService: IMAPService,
        storageService: StorageService
    ) async throws {
        guard !uids.isEmpty else { return }

        // Re-select folder (may have been deselected during counting phase)
        _ = try await imapService.selectFolder(folder.name)

        updateProgressImmediate(for: account.id) { $0.status = .downloading }

        for uid in uids {
            guard !Task.isCancelled else { break }

            // Retry with exponential backoff (max 3 attempts)
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    // Check email size first to decide whether to stream
                    let emailSize = try await imapService.fetchEmailSize(uid: uid)
                    let useStreaming = emailSize > streamingThresholdBytes

                    var bytesDownloaded: Int64 = 0
                    var email: Email
                    var parsed: ParsedEmail?

                    if useStreaming {
                        // Stream large email directly to disk
                        logInfo("Streaming large email (UID: \(uid), size: \(ByteCountFormatter.string(fromByteCount: Int64(emailSize), countStyle: .file)))")

                        // Create placeholder email for filename
                        email = Email(
                            messageId: UUID().uuidString,
                            uid: uid,
                            folder: folder.path,
                            subject: "(Streaming)",
                            sender: "Unknown",
                            senderEmail: "",
                            date: Date()
                        )

                        let (tempURL, finalURL) = try await storageService.prepareStreamingDestination(
                            email: email,
                            accountEmail: account.email,
                            folderPath: folder.path
                        )

                        // Stream directly to disk
                        bytesDownloaded = try await imapService.streamEmailToFile(uid: uid, destinationURL: tempURL)

                        // Move to final location and update UID cache
                        try await storageService.finalizeStreamedFile(tempURL: tempURL, finalURL: finalURL, uid: uid)

                        // Check for moved emails (deduplication)
                        let dupResult = await storageService.checkAndHandleDuplicate(
                            newFileURL: finalURL,
                            accountEmail: account.email
                        )
                        if dupResult.isDuplicate, let movedFrom = dupResult.movedFrom {
                            logDebug("Detected moved email: \(movedFrom.lastPathComponent) -> \(finalURL.lastPathComponent)")
                        }

                        // Read headers from saved file for metadata
                        if let headerContent = await storageService.readEmailHeaders(at: finalURL) {
                            if let headerData = headerContent.data(using: .utf8) {
                                parsed = EmailParser.parseMetadata(from: headerData)
                            }
                        }

                        // Update email with parsed metadata (file is already saved with placeholder name)
                        // In streaming mode, we keep the placeholder filename but log the actual subject
                        if let p = parsed {
                            logDebug("Streamed email: \(p.subject ?? "(No Subject)") from \(p.senderEmail ?? "unknown")")
                        }

                    } else {
                        // Normal in-memory download for smaller emails
                        let emailData = try await imapService.fetchEmail(uid: uid)
                        bytesDownloaded = Int64(emailData.count)

                        // Verify download - check for valid email structure
                        // Try progressively smaller chunks until string conversion succeeds
                        // (some emails have invalid bytes in the middle that break full conversion)
                        var content: String? = nil
                        for chunkSize in [8192, 4096, 2048, 1024, 512] {
                            let headerCheckData = emailData.prefix(chunkSize)
                            if let str = String(data: headerCheckData, encoding: .utf8) ?? String(data: headerCheckData, encoding: .ascii) {
                                content = str
                                break
                            }
                        }
                        // Case-insensitive header check (some servers use lowercase headers)
                        let contentLower = content?.lowercased() ?? ""
                        let hasValidHeaders = !contentLower.isEmpty && (contentLower.contains("from:") || contentLower.contains("date:") || contentLower.contains("subject:") || contentLower.contains("received:") || contentLower.contains("return-path:"))

                        guard emailData.count > 0, hasValidHeaders else {
                            // Write debug file for first failed email
                            let debugPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                                .appendingPathComponent("MailKeep_debug_\(uid).txt")
                            let hexPreview = emailData.prefix(500).map { String(format: "%02x", $0) }.joined(separator: " ")
                            let debugInfo = """
                            UID: \(uid)
                            Size: \(emailData.count) bytes
                            First 500 bytes (hex): \(hexPreview)
                            String preview (first 1000 chars): \(content?.prefix(1000) ?? "(nil)")
                            """
                            try? debugInfo.write(to: debugPath, atomically: true, encoding: .utf8)

                            logError("Invalid email data for UID \(uid): size=\(emailData.count) bytes, debug written to \(debugPath.path)")
                            throw BackupManagerError.invalidEmailData
                        }

                        // Parse email headers to get metadata
                        parsed = EmailParser.parseMetadata(from: emailData)

                        let messageId = parsed?.messageId ?? UUID().uuidString
                        email = Email(
                            messageId: messageId,
                            uid: uid,
                            folder: folder.path,
                            subject: parsed?.subject ?? "(No Subject)",
                            sender: parsed?.senderName ?? "Unknown",
                            senderEmail: parsed?.senderEmail ?? "",
                            date: parsed?.date ?? Date()
                        )

                        // Save to disk (file existence = backup record, no database needed)
                        let savedURL = try await storageService.saveEmail(
                            emailData,
                            email: email,
                            accountEmail: account.email,
                            folderPath: folder.path
                        )

                        // Check for moved emails (deduplication)
                        let dupResult = await storageService.checkAndHandleDuplicate(
                            newFileURL: savedURL,
                            accountEmail: account.email
                        )
                        if dupResult.isDuplicate, let movedFrom = dupResult.movedFrom {
                            logDebug("Detected moved email: \(movedFrom.lastPathComponent) -> \(savedURL.lastPathComponent)")
                        }

                        // Extract attachments if enabled
                        if AttachmentExtractionManager.shared.settings.isEnabled {
                            await extractAttachments(
                                from: emailData,
                                emailURL: savedURL,
                                accountEmail: account.email,
                                folderPath: folder.path,
                                storageService: storageService
                            )
                        }
                    }

                    // Get current count to check if we should update subject
                    let currentDownloaded = (pendingProgressUpdates[account.id]?.downloadedEmails ?? progress[account.id]?.downloadedEmails ?? 0) + 1

                    updateProgress(for: account.id) {
                        $0.downloadedEmails += 1
                        $0.bytesDownloaded += bytesDownloaded
                        // Only update subject every 10 emails or 500ms to reduce UI updates
                        if self.shouldUpdateSubject(for: account.id, currentCount: currentDownloaded) {
                            $0.currentEmailSubject = parsed?.subject ?? "(No Subject)"
                        }
                    }

                    lastError = nil
                    break // Success, exit retry loop

                } catch {
                    lastError = error
                    if attempt < Constants.maxRetryAttempts {
                        // Exponential backoff: 1s, 2s, 4s
                        let delay = UInt64(pow(2.0, Double(attempt - 1))) * Constants.nanosecondsPerSecond
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }
            }

            // Record error after all retries failed
            if let error = lastError {
                updateProgress(for: account.id) {
                    $0.errors.append(BackupError(
                        message: "Failed after 3 attempts: \(error.localizedDescription)",
                        folder: folder.name,
                        email: "UID: \(uid)"
                    ))
                }
            }
        }
    }

    // MARK: - Attachment Extraction

    private func extractAttachments(
        from emailData: Data,
        emailURL: URL,
        accountEmail: String,
        folderPath: String,
        storageService: StorageService
    ) async {
        let attachmentService = AttachmentService()
        let attachments = await attachmentService.extractAttachments(from: emailData)

        guard !attachments.isEmpty else { return }

        // Create attachment folder (same name as email file without extension)
        let emailFilename = emailURL.deletingPathExtension().lastPathComponent
        let attachmentFolderURL = emailURL.deletingLastPathComponent().appendingPathComponent("\(emailFilename)_attachments")

        do {
            let savedURLs = try await attachmentService.saveAttachments(attachments, to: attachmentFolderURL)
            if !savedURLs.isEmpty {
                logDebug("Extracted \(savedURLs.count) attachment(s) from \(emailFilename)")
            }
        } catch {
            logWarning("Failed to extract attachments from \(emailFilename): \(error.localizedDescription)")
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

    /// Update progress with throttling to prevent UI flooding
    /// Updates are accumulated and flushed to UI every 150ms
    private func updateProgress(for accountId: UUID, update: (inout BackupProgress) -> Void) {
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
    private func flushProgressUpdates() {
        for (accountId, pendingProgress) in pendingProgressUpdates {
            progress[accountId] = pendingProgress
        }
        pendingProgressUpdates.removeAll()
        progressFlushTask = nil
    }

    /// Update progress immediately without throttling (for status changes)
    private func updateProgressImmediate(for accountId: UUID, update: (inout BackupProgress) -> Void) {
        if var current = progress[accountId] {
            update(&current)
            progress[accountId] = current
            // Also update pending to keep in sync
            pendingProgressUpdates[accountId] = current
        }
    }

    /// Check if subject should be updated (every 10 emails or every 500ms)
    private func shouldUpdateSubject(for accountId: UUID, currentCount: Int) -> Bool {
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

    // MARK: - Backup Location

    var isUsingICloud: Bool {
        backupLocation.path.contains("Mobile Documents") ||
        backupLocation.path.contains("iCloud")
    }

    var iCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    var iCloudDriveURL: URL? {
        // iCloud Drive location for documents
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            return iCloudURL.appendingPathComponent("Documents").appendingPathComponent("MailKeep")
        }
        // Fallback to ~/Library/Mobile Documents/com~apple~CloudDocs/
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let iCloudDocs = homeDir.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/MailKeep")
        return iCloudDocs
    }

    func setBackupLocation(_ url: URL) {
        backupLocation = url
        UserDefaults.standard.set(url.path, forKey: backupLocationKey)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func useICloudDrive() {
        guard let iCloudURL = iCloudDriveURL else { return }
        setBackupLocation(iCloudURL)
    }

    func useLocalStorage() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localURL = documentsURL.appendingPathComponent("MailKeep")
        setBackupLocation(localURL)
    }

    /// Set the streaming threshold for large attachments
    func setStreamingThreshold(_ bytes: Int) {
        streamingThresholdBytes = bytes
        UserDefaults.standard.set(bytes, forKey: streamingThresholdKey)
    }

    func selectBackupLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose backup location"

        if panel.runModal() == .OK, let url = panel.url {
            setBackupLocation(url)
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
