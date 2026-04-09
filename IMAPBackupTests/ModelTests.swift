import XCTest
@testable import IMAPBackup

final class ModelTests: XCTestCase {

    // MARK: - Email Tests

    func testEmailInitialization() {
        let date = Date()
        let email = Email(
            messageId: "<test@example.com>",
            uid: 123,
            folder: "INBOX",
            subject: "Test Subject",
            sender: "John Doe",
            senderEmail: "john@example.com",
            date: date
        )

        XCTAssertEqual(email.messageId, "<test@example.com>")
        XCTAssertEqual(email.uid, 123)
        XCTAssertEqual(email.folder, "INBOX")
        XCTAssertEqual(email.subject, "Test Subject")
        XCTAssertEqual(email.sender, "John Doe")
        XCTAssertEqual(email.senderEmail, "john@example.com")
        XCTAssertEqual(email.date, date)
        XCTAssertFalse(email.hasAttachments)
        XCTAssertEqual(email.attachmentCount, 0)
        XCTAssertEqual(email.size, 0)
    }

    func testEmailWithAttachments() {
        let email = Email(
            messageId: "<test@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "With Attachments",
            sender: "Test",
            senderEmail: "test@example.com",
            date: Date(),
            hasAttachments: true,
            attachmentCount: 3,
            size: 1024000
        )

        XCTAssertTrue(email.hasAttachments)
        XCTAssertEqual(email.attachmentCount, 3)
        XCTAssertEqual(email.size, 1024000)
    }

    func testEmailFilename() {
        let date = Date(timeIntervalSince1970: 1705320000) // 2024-01-15 10:00:00 UTC
        let email = Email(
            messageId: "<test@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Test",
            sender: "John Doe",
            senderEmail: "john@example.com",
            date: date
        )

        let filename = email.filename()
        XCTAssertTrue(filename.hasSuffix(".eml"))
        XCTAssertTrue(filename.contains("John_Doe") || filename.contains("John") || filename.contains("Doe"))
    }

    func testEmailFilenameWithSpecialCharacters() {
        let email = Email(
            messageId: "<test@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Test",
            sender: "O'Brien <test>",
            senderEmail: "test@example.com",
            date: Date()
        )

        let filename = email.filename()
        XCTAssertFalse(filename.contains("<"))
        XCTAssertFalse(filename.contains(">"))
        XCTAssertFalse(filename.contains("'"))
    }

    func testEmailAttachmentFolderName() {
        let date = Date(timeIntervalSince1970: 1705320000)
        let email = Email(
            messageId: "<test@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Test",
            sender: "Test User",
            senderEmail: "test@example.com",
            date: date
        )

        let folderName = email.attachmentFolderName()
        XCTAssertTrue(folderName.contains("_attachments"))
    }

    func testEmailHashable() {
        let email1 = Email(
            messageId: "<test@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Test",
            sender: "Test",
            senderEmail: "test@example.com",
            date: Date()
        )

        let email2 = Email(
            id: email1.id,
            messageId: "<test@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Test",
            sender: "Test",
            senderEmail: "test@example.com",
            date: email1.date
        )

        XCTAssertEqual(email1.hashValue, email2.hashValue)
    }

    // MARK: - String Sanitization Tests

    func testSanitizeSimpleString() {
        let result = "Hello World".sanitizedForFilename()
        XCTAssertEqual(result, "Hello_World")
    }

    func testSanitizeSpecialCharacters() {
        let result = "Hello/World:Test*File?".sanitizedForFilename()
        XCTAssertFalse(result.contains("/"))
        XCTAssertFalse(result.contains(":"))
        XCTAssertFalse(result.contains("*"))
        XCTAssertFalse(result.contains("?"))
    }

    func testSanitizeQuotesAndBrackets() {
        let result = "\"File\" <name>".sanitizedForFilename()
        XCTAssertFalse(result.contains("\""))
        XCTAssertFalse(result.contains("<"))
        XCTAssertFalse(result.contains(">"))
    }

    func testSanitizeLongString() {
        let longString = String(repeating: "A", count: 100)
        let result = longString.sanitizedForFilename()
        XCTAssertLessThanOrEqual(result.count, 50)
    }

    func testSanitizeEmptyString() {
        let result = "".sanitizedForFilename()
        XCTAssertEqual(result, "unknown")
    }

    func testSanitizeOnlySpecialChars() {
        // "<>:*?\"" after sanitization:
        // - : becomes -
        // - <, >, *, ?, " are removed
        // Result is "-" which is allowed
        let result = "<>:*?\"".sanitizedForFilename()
        XCTAssertEqual(result, "-")
    }

    func testSanitizeUnicodeCharacters() {
        let result = "日本語".sanitizedForFilename()
        // Unicode alphanumeric characters should be preserved
        XCTAssertFalse(result.isEmpty)
    }

    func testSanitizeBackslash() {
        let result = "path\\to\\file".sanitizedForFilename()
        XCTAssertFalse(result.contains("\\"))
    }

    func testSanitizePipe() {
        let result = "file|name".sanitizedForFilename()
        XCTAssertFalse(result.contains("|"))
    }

    // MARK: - Attachment Tests

    func testAttachmentInitialization() {
        let attachment = Attachment(
            filename: "document.pdf",
            mimeType: "application/pdf",
            size: 1024
        )

        XCTAssertEqual(attachment.filename, "document.pdf")
        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertEqual(attachment.size, 1024)
        XCTAssertFalse(attachment.isDownloaded)
    }

    func testAttachmentDownloaded() {
        var attachment = Attachment(
            filename: "document.pdf",
            mimeType: "application/pdf",
            size: 1024,
            isDownloaded: true
        )

        XCTAssertTrue(attachment.isDownloaded)

        attachment.isDownloaded = false
        XCTAssertFalse(attachment.isDownloaded)
    }

    func testAttachmentHashable() {
        let attachment1 = Attachment(
            filename: "doc.pdf",
            mimeType: "application/pdf",
            size: 100
        )

        let attachment2 = Attachment(
            id: attachment1.id,
            filename: "doc.pdf",
            mimeType: "application/pdf",
            size: 100
        )

        XCTAssertEqual(attachment1.hashValue, attachment2.hashValue)
    }

    // MARK: - EmailAccount Tests

    func testEmailAccountInitialization() async {
        let account = EmailAccount(
            email: "test@example.com",
            imapServer: "imap.example.com",
            port: 993,
            password: "secret"
        )

        XCTAssertEqual(account.email, "test@example.com")
        XCTAssertEqual(account.imapServer, "imap.example.com")
        XCTAssertEqual(account.port, 993)
        XCTAssertEqual(account.username, "test@example.com") // defaults to email
        // Password is stored in Keychain, check via getPassword()
        let password = await account.getPassword()
        XCTAssertEqual(password, "secret")
        XCTAssertTrue(account.useSSL)
        XCTAssertTrue(account.isEnabled)
        XCTAssertNil(account.lastBackupDate)
    }

    func testEmailAccountWithCustomUsername() {
        let account = EmailAccount(
            email: "test@example.com",
            imapServer: "imap.example.com",
            username: "customuser",
            password: "secret"
        )

        XCTAssertEqual(account.username, "customuser")
    }

    func testEmailAccountGmailFactory() async {
        let account = EmailAccount.gmail(
            email: "user@gmail.com",
            appPassword: "app-password"
        )

        XCTAssertEqual(account.email, "user@gmail.com")
        XCTAssertEqual(account.imapServer, "imap.gmail.com")
        XCTAssertEqual(account.port, 993)
        // Password is stored in Keychain, check via getPassword()
        let password = await account.getPassword()
        XCTAssertEqual(password, "app-password")
        XCTAssertTrue(account.useSSL)
    }

    func testEmailAccountIONOSFactory() {
        let account = EmailAccount.ionos(
            email: "user@ionos.de",
            password: "password"
        )

        XCTAssertEqual(account.email, "user@ionos.de")
        XCTAssertEqual(account.imapServer, "imap.ionos.de")
        XCTAssertEqual(account.port, 993)
        XCTAssertTrue(account.useSSL)
    }

    func testEmailAccountCodable() throws {
        let account = EmailAccount(
            email: "test@example.com",
            imapServer: "imap.example.com",
            password: "secret"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(account)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(EmailAccount.self, from: data)

        XCTAssertEqual(decoded.email, account.email)
        XCTAssertEqual(decoded.imapServer, account.imapServer)
        XCTAssertEqual(decoded.port, account.port)
        // Note: password is not included in Codable (stored in Keychain)
        XCTAssertEqual(decoded.id, account.id)
    }

    func testEmailAccountHashable() {
        let account1 = EmailAccount(
            email: "test@example.com",
            imapServer: "imap.example.com",
            password: "secret"
        )

        let account2 = EmailAccount(
            id: account1.id,
            email: "test@example.com",
            imapServer: "imap.example.com",
            password: "secret"
        )

        XCTAssertEqual(account1.hashValue, account2.hashValue)
    }

    // MARK: - BackupProgress Tests

    func testBackupProgressInitialization() {
        let accountId = UUID()
        let progress = BackupProgress(accountId: accountId)

        XCTAssertEqual(progress.accountId, accountId)
        XCTAssertEqual(progress.status, .idle)
        XCTAssertEqual(progress.currentFolder, "")
        XCTAssertEqual(progress.totalFolders, 0)
        XCTAssertEqual(progress.processedFolders, 0)
        XCTAssertEqual(progress.totalEmails, 0)
        XCTAssertEqual(progress.downloadedEmails, 0)
        XCTAssertEqual(progress.bytesDownloaded, 0)
        XCTAssertTrue(progress.errors.isEmpty)
    }

    func testBackupProgressCalculation() {
        var progress = BackupProgress(accountId: UUID())
        progress.totalEmails = 100
        progress.downloadedEmails = 50

        XCTAssertEqual(progress.progress, 0.5)
    }

    func testBackupProgressZeroTotal() {
        let progress = BackupProgress(accountId: UUID())
        XCTAssertEqual(progress.progress, 0)
    }

    func testBackupProgressElapsedTime() {
        var progress = BackupProgress(accountId: UUID())
        progress.startTime = Date().addingTimeInterval(-60) // 60 seconds ago

        XCTAssertGreaterThanOrEqual(progress.elapsedTime, 59)
        XCTAssertLessThanOrEqual(progress.elapsedTime, 61)
    }

    func testBackupProgressEstimatedTimeRemaining() {
        var progress = BackupProgress(accountId: UUID())
        progress.startTime = Date().addingTimeInterval(-60)
        progress.totalEmails = 100
        progress.downloadedEmails = 50

        // 50% done in 60 seconds, so ~60 seconds remaining
        if let remaining = progress.estimatedTimeRemaining {
            XCTAssertGreaterThan(remaining, 50)
            XCTAssertLessThan(remaining, 70)
        } else {
            XCTFail("Expected estimated time remaining")
        }
    }

    func testBackupProgressEstimatedTimeNoProgress() {
        let progress = BackupProgress(accountId: UUID())
        XCTAssertNil(progress.estimatedTimeRemaining)
    }

    func testBackupProgressDownloadSpeed() {
        var progress = BackupProgress(accountId: UUID())
        progress.startTime = Date().addingTimeInterval(-10) // 10 seconds ago
        progress.bytesDownloaded = 10000 // 10KB

        // Should be ~1000 bytes/sec
        XCTAssertGreaterThan(progress.downloadSpeed, 900)
        XCTAssertLessThan(progress.downloadSpeed, 1100)
    }

    func testBackupProgressDownloadSpeedZeroTime() {
        let progress = BackupProgress(accountId: UUID())
        XCTAssertEqual(progress.downloadSpeed, 0)
    }

    // MARK: - BackupStatus Tests

    func testBackupStatusValues() {
        XCTAssertEqual(BackupStatus.idle.rawValue, "Idle")
        XCTAssertEqual(BackupStatus.connecting.rawValue, "Connecting...")
        XCTAssertEqual(BackupStatus.fetchingFolders.rawValue, "Fetching folders...")
        XCTAssertEqual(BackupStatus.scanning.rawValue, "Scanning emails...")
        XCTAssertEqual(BackupStatus.downloading.rawValue, "Downloading...")
        XCTAssertEqual(BackupStatus.completed.rawValue, "Completed")
        XCTAssertEqual(BackupStatus.failed.rawValue, "Failed")
        XCTAssertEqual(BackupStatus.cancelled.rawValue, "Cancelled")
    }

    func testBackupStatusIsActive() {
        XCTAssertFalse(BackupStatus.idle.isActive)
        XCTAssertTrue(BackupStatus.connecting.isActive)
        XCTAssertTrue(BackupStatus.fetchingFolders.isActive)
        XCTAssertTrue(BackupStatus.scanning.isActive)
        XCTAssertTrue(BackupStatus.downloading.isActive)
        XCTAssertFalse(BackupStatus.completed.isActive)
        XCTAssertFalse(BackupStatus.failed.isActive)
        XCTAssertFalse(BackupStatus.cancelled.isActive)
    }

    func testBackupStatusCodable() throws {
        let status = BackupStatus.downloading

        let encoder = JSONEncoder()
        let data = try encoder.encode(status)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(BackupStatus.self, from: data)

        XCTAssertEqual(decoded, status)
    }

    // MARK: - BackupError Tests

    func testBackupErrorInitialization() {
        let error = BackupError(message: "Test error")

        XCTAssertEqual(error.message, "Test error")
        XCTAssertNil(error.folder)
        XCTAssertNil(error.email)
        XCTAssertNotNil(error.timestamp)
    }

    func testBackupErrorWithContext() {
        let error = BackupError(
            message: "Download failed",
            folder: "INBOX",
            email: "test@example.com"
        )

        XCTAssertEqual(error.message, "Download failed")
        XCTAssertEqual(error.folder, "INBOX")
        XCTAssertEqual(error.email, "test@example.com")
    }

    func testBackupErrorTimestamp() {
        let beforeCreation = Date()
        let error = BackupError(message: "Error")
        let afterCreation = Date()

        XCTAssertGreaterThanOrEqual(error.timestamp, beforeCreation)
        XCTAssertLessThanOrEqual(error.timestamp, afterCreation)
    }

    func testBackupErrorIdentifiable() {
        let error1 = BackupError(message: "Error 1")
        let error2 = BackupError(message: "Error 2")

        XCTAssertNotEqual(error1.id, error2.id)
    }

    // MARK: - EmailAccount IDLE Tests

    func testEmailAccountIDLEEnabledDefaultsToNil() {
        let account = EmailAccount(
            email: "test@example.com",
            imapServer: "imap.example.com",
            port: 993
        )
        XCTAssertNil(account.idleEnabled)
    }

    func testEmailAccountIDLEEnabledRoundTrip() throws {
        var account = EmailAccount(
            email: "test@example.com",
            imapServer: "imap.example.com",
            port: 993
        )
        account.idleEnabled = false

        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(EmailAccount.self, from: data)
        XCTAssertEqual(decoded.idleEnabled, false)
    }

    func testEmailAccountIDLEEnabledOmittedInOldJSON() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","email":"a@b.com",
         "imapServer":"imap.example.com","port":993,"username":"a@b.com",
         "useSSL":true,"isEnabled":true,"authType":"password"}
        """.data(using: .utf8)!
        let account = try JSONDecoder().decode(EmailAccount.self, from: json)
        XCTAssertNil(account.idleEnabled)
    }
}
