import XCTest
@testable import MailKeep

final class AttachmentServiceTests: XCTestCase {

    var tempDirectory: URL!
    var attachmentService: AttachmentService!

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        attachmentService = AttachmentService()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - Helper Methods

    private func createMultipartEmail(
        boundary: String = "----=_Part_0_12345",
        attachmentFilename: String = "document.pdf",
        attachmentContent: String = "PDF content here",
        encoding: String = "base64"
    ) -> Data {
        let base64Content = Data(attachmentContent.utf8).base64EncodedString()

        let email = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Email with attachment
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="\(boundary)"

        --\(boundary)
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 7bit

        This is the email body.

        --\(boundary)
        Content-Type: application/pdf; name="\(attachmentFilename)"
        Content-Disposition: attachment; filename="\(attachmentFilename)"
        Content-Transfer-Encoding: \(encoding)

        \(base64Content)
        --\(boundary)--
        """

        return email.data(using: .utf8)!
    }

    // MARK: - Basic Extraction Tests

    func testExtractAttachmentFromMultipartEmail() async {
        let emailData = createMultipartEmail()

        let attachments = await attachmentService.extractAttachments(from: emailData)

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].filename, "document.pdf")
        XCTAssertEqual(attachments[0].contentType, "application/pdf")
    }

    func testExtractAttachmentWithDifferentFilename() async {
        let emailData = createMultipartEmail(attachmentFilename: "report.xlsx")

        let attachments = await attachmentService.extractAttachments(from: emailData)

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].filename, "report.xlsx")
    }

    func testExtractMultipleAttachments() async {
        let boundary = "----=_Part_0_67890"
        let base64Content1 = Data("content1".utf8).base64EncodedString()
        let base64Content2 = Data("content2".utf8).base64EncodedString()

        let email = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Multiple attachments
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="\(boundary)"

        --\(boundary)
        Content-Type: text/plain; charset=utf-8

        Body text.

        --\(boundary)
        Content-Type: application/pdf; name="doc1.pdf"
        Content-Disposition: attachment; filename="doc1.pdf"
        Content-Transfer-Encoding: base64

        \(base64Content1)
        --\(boundary)
        Content-Type: image/png; name="image.png"
        Content-Disposition: attachment; filename="image.png"
        Content-Transfer-Encoding: base64

        \(base64Content2)
        --\(boundary)--
        """

        let emailData = email.data(using: .utf8)!
        let attachments = await attachmentService.extractAttachments(from: emailData)

        XCTAssertEqual(attachments.count, 2)
        XCTAssertTrue(attachments.contains { $0.filename == "doc1.pdf" })
        XCTAssertTrue(attachments.contains { $0.filename == "image.png" })
    }

    // MARK: - Encoding Tests

    func testExtractBase64EncodedAttachment() async {
        let originalContent = "Hello, World!"
        let base64Content = Data(originalContent.utf8).base64EncodedString()

        let boundary = "----=_Part_Base64"
        let email = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Base64 attachment
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="\(boundary)"

        --\(boundary)
        Content-Type: text/plain

        Body.

        --\(boundary)
        Content-Type: text/plain; name="hello.txt"
        Content-Disposition: attachment; filename="hello.txt"
        Content-Transfer-Encoding: base64

        \(base64Content)
        --\(boundary)--
        """

        let emailData = email.data(using: .utf8)!
        let attachments = await attachmentService.extractAttachments(from: emailData)

        XCTAssertEqual(attachments.count, 1)
        let decodedContent = String(data: attachments[0].data, encoding: .utf8)
        XCTAssertEqual(decodedContent, originalContent)
    }

    func testExtractQuotedPrintableAttachment() async {
        let boundary = "----=_Part_QP"
        let email = """
        From: sender@example.com
        To: recipient@example.com
        Subject: QP attachment
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="\(boundary)"

        --\(boundary)
        Content-Type: text/plain

        Body.

        --\(boundary)
        Content-Type: text/plain; name="note.txt"
        Content-Disposition: attachment; filename="note.txt"
        Content-Transfer-Encoding: quoted-printable

        Hello=20World
        --\(boundary)--
        """

        let emailData = email.data(using: .utf8)!
        let attachments = await attachmentService.extractAttachments(from: emailData)

        // QP decoding should convert =20 to space
        XCTAssertEqual(attachments.count, 1)
    }

    // MARK: - Edge Cases

    func testExtractNoAttachments() async {
        let email = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Plain email
        Content-Type: text/plain

        This email has no attachments.
        """

        let emailData = email.data(using: .utf8)!
        let attachments = await attachmentService.extractAttachments(from: emailData)

        XCTAssertTrue(attachments.isEmpty)
    }

    func testExtractFromEmptyData() async {
        let attachments = await attachmentService.extractAttachments(from: Data())

        XCTAssertTrue(attachments.isEmpty)
    }

    func testExtractWithMalformedBoundary() async {
        let email = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Malformed
        Content-Type: multipart/mixed; boundary="

        Some content without proper boundary
        """

        let emailData = email.data(using: .utf8)!
        let attachments = await attachmentService.extractAttachments(from: emailData)

        XCTAssertTrue(attachments.isEmpty)
    }

    // MARK: - RFC 2047 Filename Tests

    func testExtractAttachmentWithEncodedFilename() async {
        let boundary = "----=_Part_RFC2047"
        let base64Content = Data("content".utf8).base64EncodedString()

        // UTF-8 base64 encoded filename "Über.pdf"
        let encodedFilename = "=?UTF-8?B?w5xiZXIucGRm?="

        let email = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Encoded filename
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="\(boundary)"

        --\(boundary)
        Content-Type: text/plain

        Body.

        --\(boundary)
        Content-Type: application/pdf; name="\(encodedFilename)"
        Content-Disposition: attachment; filename="\(encodedFilename)"
        Content-Transfer-Encoding: base64

        \(base64Content)
        --\(boundary)--
        """

        let emailData = email.data(using: .utf8)!
        let attachments = await attachmentService.extractAttachments(from: emailData)

        XCTAssertEqual(attachments.count, 1)
        // The filename should be decoded
        XCTAssertTrue(attachments[0].filename.contains("ber") || attachments[0].filename.contains("Über"))
    }

    // MARK: - Save Attachments Tests

    func testSaveAttachments() async throws {
        let attachment1 = AttachmentService.Attachment(
            filename: "doc.pdf",
            contentType: "application/pdf",
            data: Data("PDF content".utf8)
        )

        let attachment2 = AttachmentService.Attachment(
            filename: "image.png",
            contentType: "image/png",
            data: Data("PNG content".utf8)
        )

        let savedURLs = try await attachmentService.saveAttachments(
            [attachment1, attachment2],
            to: tempDirectory
        )

        XCTAssertEqual(savedURLs.count, 2)

        for url in savedURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testSaveAttachmentsDuplicateFilename() async throws {
        let attachment1 = AttachmentService.Attachment(
            filename: "doc.pdf",
            contentType: "application/pdf",
            data: Data("Content 1".utf8)
        )

        let attachment2 = AttachmentService.Attachment(
            filename: "doc.pdf",
            contentType: "application/pdf",
            data: Data("Content 2".utf8)
        )

        let savedURLs = try await attachmentService.saveAttachments(
            [attachment1, attachment2],
            to: tempDirectory
        )

        XCTAssertEqual(savedURLs.count, 2)
        XCTAssertNotEqual(savedURLs[0], savedURLs[1])

        // Both files should exist with different names
        for url in savedURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testSaveAttachmentsCreatesDirectory() async throws {
        let nonExistentDir = tempDirectory.appendingPathComponent("newdir")

        let attachment = AttachmentService.Attachment(
            filename: "test.txt",
            contentType: "text/plain",
            data: Data("test".utf8)
        )

        let savedURLs = try await attachmentService.saveAttachments(
            [attachment],
            to: nonExistentDir
        )

        XCTAssertEqual(savedURLs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURLs[0].path))
    }

    // MARK: - AttachmentExtractionSettings Tests

    func testAttachmentExtractionSettingsDefaults() {
        let settings = AttachmentExtractionSettings()

        XCTAssertFalse(settings.isEnabled)
        XCTAssertTrue(settings.createSubfolderPerEmail)
    }

    func testAttachmentExtractionSettingsCodable() throws {
        var settings = AttachmentExtractionSettings()
        settings.isEnabled = true
        settings.createSubfolderPerEmail = false

        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AttachmentExtractionSettings.self, from: data)

        XCTAssertEqual(decoded.isEnabled, settings.isEnabled)
        XCTAssertEqual(decoded.createSubfolderPerEmail, settings.createSubfolderPerEmail)
    }
}
