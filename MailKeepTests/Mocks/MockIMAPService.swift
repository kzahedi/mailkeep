import Foundation
@testable import MailKeep

/// Mock IMAP service for unit testing without a real server
actor MockIMAPService: IMAPServiceProtocol {

    // MARK: - Configuration

    /// Simulated folders on the server
    var folders: [IMAPFolder] = [
        IMAPFolder(name: "INBOX", delimiter: "/", flags: [], path: "INBOX"),
        IMAPFolder(name: "Sent", delimiter: "/", flags: [], path: "Sent"),
        IMAPFolder(name: "Drafts", delimiter: "/", flags: [], path: "Drafts"),
        IMAPFolder(name: "Trash", delimiter: "/", flags: ["\\Trash"], path: "Trash")
    ]

    /// Simulated emails per folder (folder name -> [UID: email data])
    var emails: [String: [UInt32: Data]] = [:]

    /// Currently selected folder
    private var selectedFolder: String?

    /// Connection state
    private var isConnected = false
    private var isLoggedIn = false

    // MARK: - Error simulation

    var shouldFailConnect = false
    var shouldFailLogin = false
    var shouldFailOnUID: UInt32? = nil
    var connectionDelay: TimeInterval = 0
    var fetchDelay: TimeInterval = 0

    // MARK: - Call tracking for assertions

    private(set) var connectCallCount = 0
    private(set) var loginCallCount = 0
    private(set) var logoutCallCount = 0
    private(set) var listFoldersCallCount = 0
    private(set) var selectFolderCalls: [String] = []
    private(set) var fetchEmailCalls: [UInt32] = []

    // MARK: - Setup helpers

    func addEmail(to folder: String, uid: UInt32, data: Data) {
        if emails[folder] == nil {
            emails[folder] = [:]
        }
        emails[folder]?[uid] = data
    }

    func addEmail(to folder: String, uid: UInt32, content: String) {
        addEmail(to: folder, uid: uid, data: content.data(using: .utf8) ?? Data())
    }

    /// Create a simple test email
    func addTestEmail(to folder: String, uid: UInt32, from: String, subject: String, body: String) {
        let email = """
        From: \(from)
        To: test@example.com
        Subject: \(subject)
        Date: Mon, 20 Jan 2026 10:00:00 +0000
        Message-ID: <test-\(uid)@example.com>
        Content-Type: text/plain; charset=utf-8

        \(body)
        """
        addEmail(to: folder, uid: uid, content: email)
    }

    func reset() {
        isConnected = false
        isLoggedIn = false
        selectedFolder = nil
        connectCallCount = 0
        loginCallCount = 0
        logoutCallCount = 0
        listFoldersCallCount = 0
        selectFolderCalls = []
        fetchEmailCalls = []
        shouldFailConnect = false
        shouldFailLogin = false
        shouldFailOnUID = nil
    }

    // MARK: - IMAPServiceProtocol

    func connect() async throws {
        connectCallCount += 1

        if connectionDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(connectionDelay * 1_000_000_000))
        }

        if shouldFailConnect {
            throw IMAPError.connectionFailed("Mock connection failure")
        }

        isConnected = true
    }

    func disconnect() async {
        isConnected = false
        isLoggedIn = false
        selectedFolder = nil
    }

    func login(password: String? = nil) async throws {
        loginCallCount += 1

        guard isConnected else {
            throw IMAPError.notConnected
        }

        if shouldFailLogin {
            throw IMAPError.authenticationFailed
        }

        isLoggedIn = true
    }

    func logout() async throws {
        logoutCallCount += 1
        await disconnect()
    }

    func listFolders() async throws -> [IMAPFolder] {
        listFoldersCallCount += 1

        guard isLoggedIn else {
            throw IMAPError.notConnected
        }

        return folders
    }

    func selectFolder(_ folder: String) async throws -> FolderStatus {
        selectFolderCalls.append(folder)

        guard isLoggedIn else {
            throw IMAPError.notConnected
        }

        guard folders.contains(where: { $0.name == folder }) else {
            throw IMAPError.folderNotFound(folder)
        }

        selectedFolder = folder

        let folderEmails = emails[folder] ?? [:]
        let maxUID = folderEmails.keys.max() ?? 0

        return FolderStatus(
            exists: folderEmails.count,
            recent: 0,
            uidNext: maxUID + 1,
            uidValidity: Constants.mockUIDValidity
        )
    }

    func fetchEmailHeaders(uids: ClosedRange<UInt32>) async throws -> [EmailHeader] {
        guard let folder = selectedFolder else {
            throw IMAPError.notConnected
        }

        let folderEmails = emails[folder] ?? [:]
        var headers: [EmailHeader] = []

        for uid in uids {
            if let data = folderEmails[uid],
               let content = String(data: data, encoding: .utf8) {
                // Parse basic headers
                let subject = extractHeader(named: "Subject", from: content) ?? "(No Subject)"
                let from = extractHeader(named: "From", from: content) ?? "Unknown"

                headers.append(EmailHeader(
                    uid: uid,
                    flags: [],
                    subject: subject,
                    from: from,
                    date: Date(),
                    messageId: "test-\(uid)@example.com",
                    hasAttachments: false,
                    size: data.count
                ))
            }
        }

        return headers
    }

    func fetchEmail(uid: UInt32) async throws -> Data {
        fetchEmailCalls.append(uid)

        if fetchDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(fetchDelay * 1_000_000_000))
        }

        if shouldFailOnUID == uid {
            throw IMAPError.fetchFailed("Mock fetch failure for UID \(uid)")
        }

        guard let folder = selectedFolder else {
            throw IMAPError.notConnected
        }

        guard let data = emails[folder]?[uid] else {
            throw IMAPError.fetchFailed("Email not found: UID \(uid)")
        }

        return data
    }

    func fetchEmailSize(uid: UInt32) async throws -> Int {
        guard let folder = selectedFolder else {
            throw IMAPError.notConnected
        }

        guard let data = emails[folder]?[uid] else {
            throw IMAPError.fetchFailed("Email not found: UID \(uid)")
        }

        return data.count
    }

    func streamEmailToFile(uid: UInt32, destinationURL: URL) async throws -> Int64 {
        let data = try await fetchEmail(uid: uid)
        try data.write(to: destinationURL)
        return Int64(data.count)
    }

    func searchAll() async throws -> [UInt32] {
        guard let folder = selectedFolder else {
            throw IMAPError.notConnected
        }

        let folderEmails = emails[folder] ?? [:]
        return Array(folderEmails.keys).sorted()
    }

    // MARK: - Helper

    private func extractHeader(named name: String, from content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            if line.lowercased().hasPrefix(name.lowercased() + ":") {
                return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break // End of headers
            }
        }
        return nil
    }
}
