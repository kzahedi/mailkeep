import Foundation

/// Protocol defining IMAP service operations for testability
protocol IMAPServiceProtocol {
    /// Connect to the IMAP server
    func connect() async throws

    /// Disconnect from the server
    func disconnect() async

    /// Login with password or OAuth
    func login(password: String?) async throws

    /// Logout and disconnect
    func logout() async throws

    /// List all folders on the server
    func listFolders() async throws -> [IMAPFolder]

    /// Select a folder for operations
    func selectFolder(_ folder: String) async throws -> FolderStatus

    /// Fetch complete email data by UID
    func fetchEmail(uid: UInt32) async throws -> Data

    /// Get size of an email before downloading
    func fetchEmailSize(uid: UInt32) async throws -> Int

    /// Stream large email directly to file
    func streamEmailToFile(uid: UInt32, destinationURL: URL) async throws -> Int64

    /// Search for all email UIDs in selected folder
    func searchAll() async throws -> [UInt32]

    /// Fetch UIDs of messages that arrived after lastUID
    func fetchNewUIDs(after lastUID: UInt32) async throws -> [UInt32]

    /// Return the highest UID in the currently selected folder
    func fetchLastUID() async throws -> UInt32

    /// Wait for an IMAP IDLE notification or timeout
    func waitForIDLENotification(timeout: TimeInterval) async throws -> IDLENotification
}

// MARK: - IMAPService conformance

extension IMAPService: IMAPServiceProtocol {}
