import Foundation

/// Result of verifying a single folder
struct FolderVerificationResult {
    let folderName: String
    let serverUIDs: Set<UInt32>
    let localUIDs: Set<UInt32>

    /// UIDs on server but not backed up locally
    var missingLocally: Set<UInt32> {
        serverUIDs.subtracting(localUIDs)
    }

    /// UIDs backed up locally but no longer on server (deleted or moved)
    var deletedOnServer: Set<UInt32> {
        localUIDs.subtracting(serverUIDs)
    }

    /// UIDs that exist both locally and on server
    var synced: Set<UInt32> {
        serverUIDs.intersection(localUIDs)
    }

    var isFullySynced: Bool {
        missingLocally.isEmpty && deletedOnServer.isEmpty
    }

    var summary: String {
        if isFullySynced {
            return "✓ Fully synced (\(synced.count) emails)"
        } else {
            var parts: [String] = []
            if !missingLocally.isEmpty {
                parts.append("\(missingLocally.count) missing locally")
            }
            if !deletedOnServer.isEmpty {
                parts.append("\(deletedOnServer.count) deleted on server")
            }
            return "⚠ " + parts.joined(separator: ", ")
        }
    }
}

/// Result of verifying an entire account
struct AccountVerificationResult: Identifiable {
    let id = UUID()
    let accountEmail: String
    let folderResults: [FolderVerificationResult]
    let verifiedAt: Date

    var totalServerEmails: Int {
        folderResults.reduce(0) { $0 + $1.serverUIDs.count }
    }

    var totalLocalEmails: Int {
        folderResults.reduce(0) { $0 + $1.localUIDs.count }
    }

    var totalMissingLocally: Int {
        folderResults.reduce(0) { $0 + $1.missingLocally.count }
    }

    var totalDeletedOnServer: Int {
        folderResults.reduce(0) { $0 + $1.deletedOnServer.count }
    }

    var isFullySynced: Bool {
        folderResults.allSatisfy { $0.isFullySynced }
    }

    var summary: String {
        if isFullySynced {
            return "✓ All \(folderResults.count) folders fully synced"
        } else {
            var parts: [String] = []
            if totalMissingLocally > 0 {
                parts.append("\(totalMissingLocally) emails missing locally")
            }
            if totalDeletedOnServer > 0 {
                parts.append("\(totalDeletedOnServer) emails deleted on server")
            }
            return "⚠ " + parts.joined(separator: ", ")
        }
    }
}

/// Progress tracking for repair operation
struct RepairProgress {
    var totalMissing: Int = 0
    var downloaded: Int = 0
    var failed: Int = 0
    var currentFolder: String = ""
    var currentEmail: String = ""
    var bytesDownloaded: Int64 = 0

    var progress: Double {
        guard totalMissing > 0 else { return 0 }
        return Double(downloaded + failed) / Double(totalMissing)
    }
}

/// Result of a repair operation
struct RepairResult: Identifiable {
    let id = UUID()
    let accountEmail: String
    let totalMissing: Int
    let downloaded: Int
    let failed: Int
    let errors: [String]
    let repairedAt: Date

    var summary: String {
        if totalMissing == 0 {
            return "✓ No missing emails to repair"
        } else if failed == 0 {
            return "✓ Repaired \(downloaded) missing email(s)"
        } else {
            return "⚠ Downloaded \(downloaded), failed \(failed) of \(totalMissing)"
        }
    }
}

/// Service for verifying backup integrity against server state
@MainActor
class VerificationService: ObservableObject {
    static let shared = VerificationService()

    @Published var isVerifying = false
    @Published var currentAccount: String?
    @Published var currentFolder: String?
    @Published var lastResults: [AccountVerificationResult] = []

    // Repair state
    @Published var isRepairing = false
    @Published var repairProgress = RepairProgress()
    @Published var lastRepairResults: [RepairResult] = []

    private init() {}

    /// Verify all accounts
    func verifyAll(accounts: [EmailAccount], backupLocation: URL) async -> [AccountVerificationResult] {
        isVerifying = true
        var results: [AccountVerificationResult] = []

        for account in accounts where account.isEnabled {
            if let result = await verifyAccount(account, backupLocation: backupLocation) {
                results.append(result)
            }
        }

        lastResults = results
        isVerifying = false
        currentAccount = nil
        currentFolder = nil

        return results
    }

    /// Verify a single account
    func verifyAccount(_ account: EmailAccount, backupLocation: URL) async -> AccountVerificationResult? {
        currentAccount = account.email
        logInfo("Starting verification for account: \(account.email)")

        let imapService = IMAPService(account: account)
        let storageService = StorageService(baseURL: backupLocation)

        do {
            // Connect to server
            try await imapService.connect()
            try await imapService.login()

            // Get folder list
            let folders = try await imapService.listFolders()
            let selectableFolders = folders.filter { $0.isSelectable }

            var folderResults: [FolderVerificationResult] = []

            for folder in selectableFolders {
                currentFolder = folder.name

                // Get server UIDs
                _ = try await imapService.selectFolder(folder.name)
                let serverUIDs = try await imapService.searchAll()

                // Get local UIDs
                let localUIDs = (try? await storageService.getExistingUIDs(
                    accountEmail: account.email,
                    folderPath: folder.path
                )) ?? []

                let result = FolderVerificationResult(
                    folderName: folder.name,
                    serverUIDs: Set(serverUIDs),
                    localUIDs: localUIDs
                )

                folderResults.append(result)

                if !result.isFullySynced {
                    logDebug("Folder \(folder.name): \(result.summary)")
                }
            }

            try await imapService.logout()

            let accountResult = AccountVerificationResult(
                accountEmail: account.email,
                folderResults: folderResults,
                verifiedAt: Date()
            )

            logInfo("Verification complete for \(account.email): \(accountResult.summary)")

            return accountResult

        } catch {
            logError("Verification failed for \(account.email): \(error.localizedDescription)")
            return nil
        }
    }

    /// Clear last results
    func clearResults() {
        lastResults = []
    }

    /// Clear repair results
    func clearRepairResults() {
        lastRepairResults = []
    }

    // MARK: - Repair Operations

    /// Repair all accounts by downloading missing emails
    func repairAll(accounts: [EmailAccount], backupLocation: URL) async -> [RepairResult] {
        guard !lastResults.isEmpty else {
            logWarning("No verification results available. Run verification first.")
            return []
        }

        isRepairing = true
        repairProgress = RepairProgress()
        var results: [RepairResult] = []

        // Calculate total missing across all accounts
        let totalMissing = lastResults.reduce(0) { $0 + $1.totalMissingLocally }
        repairProgress.totalMissing = totalMissing

        for verificationResult in lastResults {
            guard verificationResult.totalMissingLocally > 0 else { continue }

            // Find the matching account
            guard let account = accounts.first(where: { $0.email == verificationResult.accountEmail }) else {
                continue
            }

            let result = await repairAccount(
                account: account,
                verificationResult: verificationResult,
                backupLocation: backupLocation
            )
            results.append(result)
        }

        lastRepairResults = results
        isRepairing = false
        currentAccount = nil
        currentFolder = nil

        return results
    }

    /// Repair a single account by downloading missing emails
    func repairAccount(
        account: EmailAccount,
        verificationResult: AccountVerificationResult,
        backupLocation: URL
    ) async -> RepairResult {
        currentAccount = account.email
        logInfo("Starting repair for account: \(account.email)")

        var downloaded = 0
        var failed = 0
        var errors: [String] = []

        let imapService = IMAPService(account: account)
        let storageService = StorageService(baseURL: backupLocation)

        // Configure rate limiting
        let rateLimitSettings = RateLimitService.shared.getSettings(for: account.id)
        let sharedTracker = RateLimitService.shared.getTracker(forServer: account.imapServer, accountId: account.id)
        await imapService.configureRateLimit(settings: rateLimitSettings, sharedTracker: sharedTracker)

        do {
            try await imapService.connect()
            try await imapService.login()

            // Process each folder with missing emails
            for folderResult in verificationResult.folderResults where !folderResult.missingLocally.isEmpty {
                currentFolder = folderResult.folderName
                repairProgress.currentFolder = folderResult.folderName

                // Select the folder
                _ = try await imapService.selectFolder(folderResult.folderName)

                // Download each missing email
                for uid in folderResult.missingLocally.sorted() {
                    do {
                        let emailData = try await imapService.fetchEmail(uid: uid)

                        // Validate email data
                        guard emailData.count > 0 else {
                            throw VerificationError.emptyEmailData
                        }

                        // Parse email metadata
                        let parsed = EmailParser.parseMetadata(from: emailData)
                        let email = Email(
                            messageId: parsed?.messageId ?? UUID().uuidString,
                            uid: uid,
                            folder: folderResult.folderName,
                            subject: parsed?.subject ?? "(No Subject)",
                            sender: parsed?.senderName ?? "Unknown",
                            senderEmail: parsed?.senderEmail ?? "",
                            date: parsed?.date ?? Date()
                        )

                        repairProgress.currentEmail = email.subject

                        // Save to disk
                        _ = try await storageService.saveEmail(
                            emailData,
                            email: email,
                            accountEmail: account.email,
                            folderPath: folderResult.folderName
                        )

                        downloaded += 1
                        repairProgress.downloaded += 1
                        repairProgress.bytesDownloaded += Int64(emailData.count)

                        logDebug("Repaired: \(email.subject) (UID: \(uid))")

                    } catch {
                        failed += 1
                        repairProgress.failed += 1
                        let errorMsg = "UID \(uid) in \(folderResult.folderName): \(error.localizedDescription)"
                        errors.append(errorMsg)
                        logWarning("Failed to repair email: \(errorMsg)")
                    }
                }
            }

            try await imapService.logout()

        } catch {
            let errorMsg = "Connection error: \(error.localizedDescription)"
            errors.append(errorMsg)
            logError("Repair failed for \(account.email): \(errorMsg)")
        }

        let result = RepairResult(
            accountEmail: account.email,
            totalMissing: verificationResult.totalMissingLocally,
            downloaded: downloaded,
            failed: failed,
            errors: errors,
            repairedAt: Date()
        )

        logInfo("Repair complete for \(account.email): \(result.summary)")

        return result
    }

    /// Check if there are any missing emails that can be repaired
    var hasMissingEmails: Bool {
        lastResults.contains { $0.totalMissingLocally > 0 }
    }

    /// Total count of missing emails across all verified accounts
    var totalMissingEmails: Int {
        lastResults.reduce(0) { $0 + $1.totalMissingLocally }
    }

    enum VerificationError: LocalizedError {
        case emptyEmailData

        var errorDescription: String? {
            switch self {
            case .emptyEmailData:
                return "Downloaded email data was empty"
            }
        }
    }
}
