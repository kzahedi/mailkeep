import XCTest
@testable import MailKeep

final class StorageServiceTests: XCTestCase {

    var tempDirectory: URL!
    var storageService: StorageService!

    override func setUp() async throws {
        try await super.setUp()

        // Create a temporary directory for each test
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        storageService = StorageService(baseURL: tempDirectory)
    }

    override func tearDown() async throws {
        // Clean up temporary directory
        try? FileManager.default.removeItem(at: tempDirectory)

        try await super.tearDown()
    }

    // MARK: - Directory Creation Tests

    func testCreateAccountDirectory() async throws {
        let accountURL = try await storageService.createAccountDirectory(email: "test@example.com")

        XCTAssertTrue(FileManager.default.fileExists(atPath: accountURL.path))
        XCTAssertTrue(accountURL.lastPathComponent.contains("testexamplecom"))
    }

    func testCreateAccountDirectoryWithSpecialCharacters() async throws {
        let accountURL = try await storageService.createAccountDirectory(email: "test+special@example.com")

        XCTAssertTrue(FileManager.default.fileExists(atPath: accountURL.path))
    }

    func testCreateAccountDirectoryIdempotent() async throws {
        let accountURL1 = try await storageService.createAccountDirectory(email: "test@example.com")
        let accountURL2 = try await storageService.createAccountDirectory(email: "test@example.com")

        // Compare standardized paths since URL equality can be strict
        XCTAssertEqual(accountURL1.standardized.path, accountURL2.standardized.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountURL1.path))
    }

    func testCreateFolderDirectory() async throws {
        let folderURL = try await storageService.createFolderDirectory(
            accountEmail: "test@example.com",
            folderPath: "INBOX"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testCreateNestedFolderDirectory() async throws {
        let folderURL = try await storageService.createFolderDirectory(
            accountEmail: "test@example.com",
            folderPath: "Work/Projects/Alpha"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertTrue(folderURL.path.contains("Work"))
        XCTAssertTrue(folderURL.path.contains("Projects"))
        XCTAssertTrue(folderURL.path.contains("Alpha"))
    }

    // MARK: - Email Storage Tests

    func testSaveEmail() async throws {
        let emailData = "Test email content".data(using: .utf8)!
        let email = Email(
            messageId: "<test@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Test Subject",
            sender: "John Doe",
            senderEmail: "john@example.com",
            date: Date()
        )

        let fileURL = try await storageService.saveEmail(
            emailData,
            email: email,
            accountEmail: "test@example.com",
            folderPath: "INBOX"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(fileURL.pathExtension, "eml")

        let savedData = try Data(contentsOf: fileURL)
        XCTAssertEqual(savedData, emailData)
    }

    func testSaveEmailWithDuplicateFilename() async throws {
        let emailData1 = "Email 1".data(using: .utf8)!
        let emailData2 = "Email 2".data(using: .utf8)!

        let email1 = Email(
            messageId: "<test1@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Test Subject",
            sender: "John Doe",
            senderEmail: "john@example.com",
            date: Date()
        )

        let email2 = Email(
            messageId: "<test2@example.com>",
            uid: 2,
            folder: "INBOX",
            subject: "Test Subject",
            sender: "John Doe",
            senderEmail: "john@example.com",
            date: Date() // Same date, so same filename initially
        )

        let fileURL1 = try await storageService.saveEmail(
            emailData1,
            email: email1,
            accountEmail: "test@example.com",
            folderPath: "INBOX"
        )

        let fileURL2 = try await storageService.saveEmail(
            emailData2,
            email: email2,
            accountEmail: "test@example.com",
            folderPath: "INBOX"
        )

        XCTAssertNotEqual(fileURL1, fileURL2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL2.path))
    }

    // MARK: - Attachment Storage Tests

    func testSaveAttachment() async throws {
        let attachmentData = "Attachment content".data(using: .utf8)!
        let email = Email(
            messageId: "<test@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Test Subject",
            sender: "John Doe",
            senderEmail: "john@example.com",
            date: Date()
        )

        let fileURL = try await storageService.saveAttachment(
            attachmentData,
            filename: "document.pdf",
            email: email,
            accountEmail: "test@example.com",
            folderPath: "INBOX"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        // Filename is sanitized, which removes dots - so "document.pdf" becomes "documentpdf"
        XCTAssertTrue(fileURL.lastPathComponent.contains("document"))
    }

    func testSaveAttachmentWithSpecialCharacters() async throws {
        let attachmentData = "Attachment content".data(using: .utf8)!
        let email = Email(
            messageId: "<test@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Test Subject",
            sender: "John Doe",
            senderEmail: "john@example.com",
            date: Date()
        )

        let fileURL = try await storageService.saveAttachment(
            attachmentData,
            filename: "file with spaces & special <chars>.pdf",
            email: email,
            accountEmail: "test@example.com",
            folderPath: "INBOX"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        // Filename should be sanitized
        XCTAssertFalse(fileURL.lastPathComponent.contains("<"))
        XCTAssertFalse(fileURL.lastPathComponent.contains(">"))
    }

    // MARK: - Statistics Tests

    func testGetBackupSize() async throws {
        // Create some test files
        let emailData = String(repeating: "X", count: 1000).data(using: .utf8)!
        let email = Email(
            messageId: "<test@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Test",
            sender: "Test",
            senderEmail: "test@example.com",
            date: Date()
        )

        _ = try await storageService.saveEmail(
            emailData,
            email: email,
            accountEmail: "test@example.com",
            folderPath: "INBOX"
        )

        let size = try await storageService.getBackupSize(for: "test@example.com")
        XCTAssertGreaterThan(size, 0)
        XCTAssertGreaterThanOrEqual(size, 1000)
    }

    func testGetEmailCount() async throws {
        let email1 = Email(
            messageId: "<test1@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Test 1",
            sender: "Test",
            senderEmail: "test@example.com",
            date: Date()
        )

        let email2 = Email(
            messageId: "<test2@example.com>",
            uid: 2,
            folder: "INBOX",
            subject: "Test 2",
            sender: "Test",
            senderEmail: "test@example.com",
            date: Date().addingTimeInterval(1)
        )

        _ = try await storageService.saveEmail(
            "Email 1".data(using: .utf8)!,
            email: email1,
            accountEmail: "test@example.com",
            folderPath: "INBOX"
        )

        _ = try await storageService.saveEmail(
            "Email 2".data(using: .utf8)!,
            email: email2,
            accountEmail: "test@example.com",
            folderPath: "INBOX"
        )

        let count = try await storageService.getEmailCount(for: "test@example.com")
        XCTAssertEqual(count, 2)
    }

    func testGetEmailCountForEmptyAccount() async throws {
        _ = try await storageService.createAccountDirectory(email: "empty@example.com")

        let count = try await storageService.getEmailCount(for: "empty@example.com")
        XCTAssertEqual(count, 0)
    }

    // MARK: - Edge Cases

    func testSaveEmailWithEmptyData() async throws {
        let emailData = Data()
        let email = Email(
            messageId: "<empty@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Empty",
            sender: "Test",
            senderEmail: "test@example.com",
            date: Date()
        )

        let fileURL = try await storageService.saveEmail(
            emailData,
            email: email,
            accountEmail: "test@example.com",
            folderPath: "INBOX"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let savedData = try Data(contentsOf: fileURL)
        XCTAssertTrue(savedData.isEmpty)
    }

    func testSaveEmailWithLargeData() async throws {
        // 10 MB of data
        let emailData = Data(count: 10 * 1024 * 1024)
        let email = Email(
            messageId: "<large@example.com>",
            uid: 1,
            folder: "INBOX",
            subject: "Large",
            sender: "Test",
            senderEmail: "test@example.com",
            date: Date()
        )

        let fileURL = try await storageService.saveEmail(
            emailData,
            email: email,
            accountEmail: "test@example.com",
            folderPath: "INBOX"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFolderWithManyFiles() async throws {
        // Create many files in the same folder
        for i in 1...100 {
            let email = Email(
                messageId: "<test\(i)@example.com>",
                uid: UInt32(i),
                folder: "INBOX",
                subject: "Test \(i)",
                sender: "Test",
                senderEmail: "test@example.com",
                date: Date().addingTimeInterval(Double(i))
            )

            _ = try await storageService.saveEmail(
                "Email \(i)".data(using: .utf8)!,
                email: email,
                accountEmail: "test@example.com",
                folderPath: "INBOX"
            )
        }

        let count = try await storageService.getEmailCount(for: "test@example.com")
        XCTAssertEqual(count, 100)
    }

    // MARK: - Concurrent Tests

    func testConcurrentSaves() async throws {
        await withTaskGroup(of: URL?.self) { group in
            for i in 1...50 {
                group.addTask {
                    let email = Email(
                        messageId: "<concurrent\(i)@example.com>",
                        uid: UInt32(i),
                        folder: "INBOX",
                        subject: "Concurrent \(i)",
                        sender: "Test",
                        senderEmail: "test@example.com",
                        date: Date().addingTimeInterval(Double(i))
                    )

                    return try? await self.storageService.saveEmail(
                        "Email \(i)".data(using: .utf8)!,
                        email: email,
                        accountEmail: "test@example.com",
                        folderPath: "INBOX"
                    )
                }
            }

            var successCount = 0
            for await url in group {
                if url != nil {
                    successCount += 1
                }
            }
            XCTAssertEqual(successCount, 50)
        }

        let count = try await storageService.getEmailCount(for: "test@example.com")
        XCTAssertEqual(count, 50)
    }
}
