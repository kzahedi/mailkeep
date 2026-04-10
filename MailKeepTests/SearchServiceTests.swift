import XCTest
@testable import MailKeep

final class SearchServiceTests: XCTestCase {

    var tempDirectory: URL!
    var searchService: SearchService!

    override func setUp() async throws {
        try await super.setUp()

        // Create a temporary directory for each test
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        searchService = SearchService(backupLocation: tempDirectory)
        try await searchService.open()
    }

    override func tearDown() async throws {
        await searchService.close()

        // Clean up temporary directory
        try? FileManager.default.removeItem(at: tempDirectory)

        try await super.tearDown()
    }

    // MARK: - Helper Methods

    private func createTestEmail(
        account: String = "test@example.com",
        folder: String = "INBOX",
        from: String = "John Doe <john@example.com>",
        subject: String = "Test Subject",
        body: String = "This is the email body content.",
        date: String = "Mon, 15 Jan 2024 10:00:00 +0000",
        filename: String? = nil
    ) throws -> URL {
        let emlContent = """
        From: \(from)
        To: recipient@example.com
        Subject: \(subject)
        Date: \(date)
        Message-ID: <\(UUID().uuidString)@example.com>
        Content-Type: text/plain; charset=utf-8

        \(body)
        """

        // Create directory structure
        let accountDir = tempDirectory.appendingPathComponent(account)
        let folderDir = accountDir.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)

        // Create file
        let senderName = from.components(separatedBy: " ").first ?? "Unknown"
        let actualFilename = filename ?? "20240115_100000_\(senderName).eml"
        let fileURL = folderDir.appendingPathComponent(actualFilename)
        try emlContent.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL
    }

    // MARK: - Basic Tests

    func testOpenAndClose() async throws {
        // Already opened in setUp, just verify it doesn't crash
        await searchService.close()
        try await searchService.open()
    }

    func testGetStatsEmpty() async throws {
        let stats = try await searchService.getStats()
        XCTAssertEqual(stats.emailCount, 0)
    }

    func testGetStatsWithEmails() async throws {
        _ = try createTestEmail(filename: "email1.eml")
        _ = try createTestEmail(subject: "Another email", filename: "email2.eml")

        let stats = try await searchService.getStats()
        XCTAssertEqual(stats.emailCount, 2)
    }

    // MARK: - Search Tests

    func testSearchEmptyQuery() async throws {
        _ = try createTestEmail()

        let results = try await searchService.search(query: "")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchBySender() async throws {
        _ = try createTestEmail(from: "Alice Smith <alice@example.com>", filename: "alice.eml")
        _ = try createTestEmail(from: "Bob Jones <bob@example.com>", filename: "bob.eml")

        let results = try await searchService.search(query: "alice")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].sender.lowercased().contains("alice") || results[0].senderEmail.lowercased().contains("alice"))
    }

    func testSearchBySubject() async throws {
        _ = try createTestEmail(subject: "Important Meeting Tomorrow", filename: "meeting.eml")
        _ = try createTestEmail(subject: "Random Newsletter", filename: "newsletter.eml")

        let results = try await searchService.search(query: "meeting")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].subject.lowercased().contains("meeting"))
    }

    func testSearchByBody() async throws {
        _ = try createTestEmail(body: "Please review the attached document.", filename: "doc.eml")
        _ = try createTestEmail(body: "Thanks for your email.", filename: "thanks.eml")

        let results = try await searchService.search(query: "document")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchMultipleTerms() async throws {
        _ = try createTestEmail(subject: "Project Update", body: "Here is the weekly status report.", filename: "status.eml")
        _ = try createTestEmail(subject: "Project Meeting", body: "Let's discuss the timeline.", filename: "meeting.eml")

        // Both terms must be present
        let results = try await searchService.search(query: "project status")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchCaseInsensitive() async throws {
        _ = try createTestEmail(subject: "IMPORTANT NOTICE")

        let results = try await searchService.search(query: "important")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchNoResults() async throws {
        _ = try createTestEmail(subject: "Hello World")

        let results = try await searchService.search(query: "nonexistent")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchLimit() async throws {
        // Create 10 emails with the same keyword
        for i in 1...10 {
            _ = try createTestEmail(
                subject: "Test email \(i) with keyword",
                filename: "email\(i).eml"
            )
        }

        let results = try await searchService.search(query: "keyword", limit: 5)
        XCTAssertEqual(results.count, 5)
    }

    // MARK: - Path Extraction Tests

    func testSearchResultContainsCorrectAccount() async throws {
        _ = try createTestEmail(account: "user@gmail.com", folder: "INBOX")

        let results = try await searchService.search(query: "test")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].accountId, "user@gmail.com")
    }

    func testSearchResultContainsCorrectMailbox() async throws {
        _ = try createTestEmail(account: "test@example.com", folder: "Work/Projects")

        let results = try await searchService.search(query: "test")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].mailbox, "Work/Projects")
    }

    // MARK: - Match Type Tests

    func testMatchTypeSender() async throws {
        _ = try createTestEmail(from: "UniqueNameHere <unique@example.com>", subject: "Normal Subject", body: "Normal body")

        let results = try await searchService.search(query: "uniquenamehere")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].matchType, .sender)
    }

    func testMatchTypeSubject() async throws {
        _ = try createTestEmail(from: "Normal Name <normal@example.com>", subject: "SpecialKeywordHere", body: "Normal body")

        let results = try await searchService.search(query: "specialkeywordhere")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].matchType, .subject)
    }

    func testMatchTypeBody() async throws {
        _ = try createTestEmail(from: "Normal Name <normal@example.com>", subject: "Normal Subject", body: "UniqueBodyContent here")

        let results = try await searchService.search(query: "uniquebodycontent")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].matchType, .body)
    }

    // MARK: - Snippet Tests

    func testSnippetContainsSearchTerm() async throws {
        _ = try createTestEmail(body: "This is a test with a special keyword in the middle of the text.")

        let results = try await searchService.search(query: "keyword")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].snippet.lowercased().contains("keyword"))
    }

    func testSnippetHighlighting() async throws {
        _ = try createTestEmail(body: "This email contains important information.")

        let results = try await searchService.search(query: "important")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].snippet.contains("<mark>"))
        XCTAssertTrue(results[0].snippet.contains("</mark>"))
    }

    // MARK: - Reindex Tests (No-op for file-based search)

    func testReindexAll() async throws {
        _ = try createTestEmail(filename: "email1.eml")
        _ = try createTestEmail(subject: "Second email", filename: "email2.eml")

        var progressCalled = false
        try await searchService.reindexAll { current, total in
            progressCalled = true
            XCTAssertEqual(current, total)
            XCTAssertEqual(total, 2)
        }

        XCTAssertTrue(progressCalled)
    }

    // MARK: - Edge Cases

    func testSearchWithSpecialCharacters() async throws {
        _ = try createTestEmail(subject: "Test: Special (Characters) [Here]")

        // Search with special characters should not crash
        let results = try await searchService.search(query: "special")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchWithQuotes() async throws {
        _ = try createTestEmail(subject: "He said \"hello world\"")

        let results = try await searchService.search(query: "hello")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchWithUnicode() async throws {
        _ = try createTestEmail(
            from: "日本語名前 <japanese@example.com>",
            subject: "Über die Änderung",
            body: "Body with unicode"
        )

        let stats = try await searchService.getStats()
        XCTAssertEqual(stats.emailCount, 1)
    }

    func testSearchLongBody() async throws {
        let longBody = String(repeating: "This is a test sentence. ", count: 1000)
        _ = try createTestEmail(body: longBody + "UNIQUE_MARKER here")

        let results = try await searchService.search(query: "unique_marker")
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - Concurrent Tests

    func testConcurrentSearches() async throws {
        // Create test emails
        for i in 1...10 {
            _ = try createTestEmail(
                subject: "Searchable Item \(i)",
                filename: "email\(i).eml"
            )
        }

        // Perform concurrent searches
        await withTaskGroup(of: Int.self) { group in
            for _ in 1...10 {
                group.addTask {
                    let results = try? await self.searchService.search(query: "searchable")
                    return results?.count ?? 0
                }
            }

            for await count in group {
                XCTAssertEqual(count, 10)
            }
        }
    }
}
