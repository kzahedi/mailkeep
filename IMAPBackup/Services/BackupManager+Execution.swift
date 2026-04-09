import Foundation

extension BackupManager {

    // MARK: - Backup Execution

    func performBackup(for account: EmailAccount) async {
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
    func countNewEmails(
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
    func downloadEmails(
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

    func extractAttachments(
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
}
