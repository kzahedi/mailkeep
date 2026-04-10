import XCTest
@testable import MailKeep

/// Unit tests for IMAP operations using MockIMAPService
final class IMAPServiceTests: XCTestCase {

    var mockService: MockIMAPService!

    override func setUp() async throws {
        mockService = MockIMAPService()

        // Add some test emails to INBOX
        await mockService.addTestEmail(
            to: "INBOX",
            uid: 1,
            from: "sender@example.com",
            subject: "Test Email 1",
            body: "This is the body of test email 1."
        )
        await mockService.addTestEmail(
            to: "INBOX",
            uid: 2,
            from: "another@example.com",
            subject: "Test Email 2",
            body: "This is the body of test email 2."
        )
        await mockService.addTestEmail(
            to: "INBOX",
            uid: 3,
            from: "third@example.com",
            subject: "Important: Action Required",
            body: "Please review the attached document."
        )
    }

    override func tearDown() async throws {
        await mockService.reset()
        mockService = nil
    }

    // MARK: - Connection Tests

    func testConnectSuccess() async throws {
        try await mockService.connect()
        let callCount = await mockService.connectCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testConnectFailure() async {
        await mockService.reset()
        await setMockShouldFailConnect(true)

        do {
            try await mockService.connect()
            XCTFail("Expected connection to fail")
        } catch {
            XCTAssertTrue(error is IMAPError)
        }
    }

    func testLoginRequiresConnection() async {
        do {
            try await mockService.login(password: "test")
            XCTFail("Expected login to fail without connection")
        } catch {
            XCTAssertTrue(error is IMAPError)
        }
    }

    func testLoginSuccess() async throws {
        try await mockService.connect()
        try await mockService.login(password: "test")

        let callCount = await mockService.loginCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testLoginFailure() async throws {
        try await mockService.connect()
        await setMockShouldFailLogin(true)

        do {
            try await mockService.login(password: "wrong")
            XCTFail("Expected login to fail")
        } catch let error as IMAPError {
            if case .authenticationFailed = error {
                // Expected
            } else {
                XCTFail("Expected authenticationFailed error")
            }
        }
    }

    // MARK: - Folder Tests

    func testListFolders() async throws {
        try await mockService.connect()
        try await mockService.login(password: "test")

        let folders = try await mockService.listFolders()

        XCTAssertTrue(folders.contains { $0.name == "INBOX" })
        XCTAssertTrue(folders.contains { $0.name == "Sent" })
        XCTAssertTrue(folders.contains { $0.name == "Drafts" })
        XCTAssertTrue(folders.contains { $0.name == "Trash" })
    }

    func testSelectFolder() async throws {
        try await mockService.connect()
        try await mockService.login(password: "test")

        let status = try await mockService.selectFolder("INBOX")

        XCTAssertEqual(status.exists, 3) // We added 3 test emails
        XCTAssertEqual(status.uidValidity, Constants.mockUIDValidity)

        let calls = await mockService.selectFolderCalls
        XCTAssertEqual(calls, ["INBOX"])
    }

    func testSelectNonexistentFolder() async throws {
        try await mockService.connect()
        try await mockService.login(password: "test")

        do {
            _ = try await mockService.selectFolder("NonexistentFolder")
            XCTFail("Expected folder not found error")
        } catch let error as IMAPError {
            if case .folderNotFound(let name) = error {
                XCTAssertEqual(name, "NonexistentFolder")
            } else {
                XCTFail("Expected folderNotFound error")
            }
        }
    }

    // MARK: - Email Fetch Tests

    func testSearchAll() async throws {
        try await mockService.connect()
        try await mockService.login(password: "test")
        _ = try await mockService.selectFolder("INBOX")

        let uids = try await mockService.searchAll()

        XCTAssertEqual(uids.sorted(), [1, 2, 3])
    }

    func testFetchEmail() async throws {
        try await mockService.connect()
        try await mockService.login(password: "test")
        _ = try await mockService.selectFolder("INBOX")

        let data = try await mockService.fetchEmail(uid: 1)

        XCTAssertTrue(data.count > 0)

        let content = String(data: data, encoding: .utf8)
        XCTAssertNotNil(content)
        XCTAssertTrue(content!.contains("Test Email 1"))
        XCTAssertTrue(content!.contains("sender@example.com"))
    }

    func testFetchEmailFailure() async throws {
        try await mockService.connect()
        try await mockService.login(password: "test")
        _ = try await mockService.selectFolder("INBOX")

        await setMockShouldFailOnUID(2)

        do {
            _ = try await mockService.fetchEmail(uid: 2)
            XCTFail("Expected fetch to fail")
        } catch {
            XCTAssertTrue(error is IMAPError)
        }

        // Other UIDs should still work
        let data = try await mockService.fetchEmail(uid: 1)
        XCTAssertTrue(data.count > 0)
    }

    func testFetchNonexistentEmail() async throws {
        try await mockService.connect()
        try await mockService.login(password: "test")
        _ = try await mockService.selectFolder("INBOX")

        do {
            _ = try await mockService.fetchEmail(uid: 999)
            XCTFail("Expected fetch to fail for nonexistent UID")
        } catch {
            XCTAssertTrue(error is IMAPError)
        }
    }

    func testFetchEmailSize() async throws {
        try await mockService.connect()
        try await mockService.login(password: "test")
        _ = try await mockService.selectFolder("INBOX")

        let size = try await mockService.fetchEmailSize(uid: 1)
        let data = try await mockService.fetchEmail(uid: 1)

        XCTAssertEqual(size, data.count)
    }

    // MARK: - Full Workflow Test

    func testFullBackupWorkflow() async throws {
        // Connect and login
        try await mockService.connect()
        try await mockService.login(password: "test")

        // List folders
        let folders = try await mockService.listFolders()
        XCTAssertTrue(folders.count > 0)

        // Select INBOX
        let status = try await mockService.selectFolder("INBOX")
        XCTAssertTrue(status.exists > 0)

        // Get UIDs
        let uids = try await mockService.searchAll()
        XCTAssertEqual(uids.count, status.exists)

        // Fetch each email
        var downloadedCount = 0
        for uid in uids {
            let data = try await mockService.fetchEmail(uid: uid)
            XCTAssertTrue(data.count > 0)
            downloadedCount += 1
        }

        XCTAssertEqual(downloadedCount, 3)

        // Logout
        try await mockService.logout()
    }

    // MARK: - Call Tracking Tests

    func testCallTracking() async throws {
        try await mockService.connect()
        try await mockService.login(password: "test")
        _ = try await mockService.listFolders()
        _ = try await mockService.selectFolder("INBOX")
        _ = try await mockService.fetchEmail(uid: 1)
        _ = try await mockService.fetchEmail(uid: 2)
        try await mockService.logout()

        let connectCount = await mockService.connectCallCount
        let loginCount = await mockService.loginCallCount
        let listFoldersCount = await mockService.listFoldersCallCount
        let selectCalls = await mockService.selectFolderCalls
        let fetchCalls = await mockService.fetchEmailCalls
        let logoutCount = await mockService.logoutCallCount

        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(loginCount, 1)
        XCTAssertEqual(listFoldersCount, 1)
        XCTAssertEqual(selectCalls, ["INBOX"])
        XCTAssertEqual(fetchCalls, [1, 2])
        XCTAssertEqual(logoutCount, 1)
    }

    // MARK: - Helpers

    private func setMockShouldFailConnect(_ value: Bool) async {
        await MainActor.run {
            Task {
                await mockService.setShouldFailConnect(value)
            }
        }
        // Give time for the task to complete
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    private func setMockShouldFailLogin(_ value: Bool) async {
        await MainActor.run {
            Task {
                await mockService.setShouldFailLogin(value)
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    private func setMockShouldFailOnUID(_ uid: UInt32) async {
        await MainActor.run {
            Task {
                await mockService.setShouldFailOnUID(uid)
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

// MARK: - MockIMAPService setters

extension MockIMAPService {
    func setShouldFailConnect(_ value: Bool) {
        shouldFailConnect = value
    }

    func setShouldFailLogin(_ value: Bool) {
        shouldFailLogin = value
    }

    func setShouldFailOnUID(_ uid: UInt32?) {
        shouldFailOnUID = uid
    }
}
