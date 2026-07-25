import Foundation

/// File-backed credential store — the primary backend for IMAP passwords and
/// OAuth tokens.
///
/// Why not the Keychain: this app is built with an unpaid Apple account, so every
/// rebuild is ad-hoc signed with a new identity. Legacy-Keychain ACLs are bound to
/// the signing identity, causing permission prompts on manual launches and silent
/// errSecInteractionNotAllowed failures at Login Item startup. Same rationale as
/// accounts.json (commit 988c522), now applied to credentials.
///
/// Storage: ~/Library/Application Support/MailKeep/credentials.json,
/// POSIX 0600, atomic writes. FileVault provides at-rest encryption.
actor CredentialStore {
    static let shared = CredentialStore()

    /// Override the credentials file URL in tests. Reset to nil in tearDown.
    nonisolated(unsafe) static var testFileOverride: URL? = nil

    /// Lock serializing all file reads and writes to prevent TOCTOU races
    /// between actor methods (synchronous, no suspension) and nonisolated importIfAbsent.
    private static let fileLock = NSLock()

    private struct FileContents: Codable {
        var passwords: [String: String] = [:]
        var oauthTokens: [String: String] = [:]
    }

    nonisolated static var fileURL: URL {
        if let override = testFileOverride { return override }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MailKeep/credentials.json")
    }

    // MARK: - File I/O

    private static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        fileLock.lock()
        defer { fileLock.unlock() }
        return try body()
    }

    private nonisolated static func load() throws -> FileContents {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return FileContents() }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(FileContents.self, from: data)
        } catch {
            // Corrupt file: preserve for manual recovery, start fresh. The user can
            // re-enter credentials via the missing-credentials prompt.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            logError("credentials.json is corrupt — moved to \(backup.lastPathComponent), starting fresh")
            return FileContents()
        }
    }

    private nonisolated static func save(_ contents: FileContents) throws {
        let url = fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(contents)
        // Write to a private temp file (0600 from creation), then atomically swap in —
        // the credentials file is never observable with wider permissions.
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".credentials.json.tmp-\(UUID().uuidString)")
        FileManager.default.createFile(
            atPath: tempURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600])
        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            try handle.write(contentsOf: data)
            try handle.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        // replaceItemAt preserves the destination's existing permissions in some cases;
        // enforce 0600 on the final path as a belt-and-braces invariant.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Passwords

    func savePassword(_ password: String, for accountId: UUID) throws {
        try Self.withLock {
            var contents = try Self.load()
            contents.passwords[accountId.uuidString] = password
            try Self.save(contents)
        }
    }

    func getPassword(for accountId: UUID) throws -> String {
        try Self.withLock {
            guard let password = try Self.load().passwords[accountId.uuidString] else {
                throw CredentialStoreError.notFound
            }
            return password
        }
    }

    func deletePassword(for accountId: UUID) throws {
        try Self.withLock {
            var contents = try Self.load()
            contents.passwords.removeValue(forKey: accountId.uuidString)
            try Self.save(contents)
        }
    }

    func hasPassword(for accountId: UUID) -> Bool {
        (try? Self.withLock {
            (try Self.load()).passwords[accountId.uuidString] != nil
        }) ?? false
    }

    // MARK: - OAuth tokens (JSON-encoded GoogleOAuthTokens strings)

    func saveOAuthTokenString(_ token: String, for accountId: UUID) throws {
        try Self.withLock {
            var contents = try Self.load()
            contents.oauthTokens[accountId.uuidString] = token
            try Self.save(contents)
        }
    }

    func getOAuthTokenString(for accountId: UUID) throws -> String {
        try Self.withLock {
            guard let token = try Self.load().oauthTokens[accountId.uuidString] else {
                throw CredentialStoreError.notFound
            }
            return token
        }
    }

    func deleteOAuthTokenString(for accountId: UUID) throws {
        try Self.withLock {
            var contents = try Self.load()
            contents.oauthTokens.removeValue(forKey: accountId.uuidString)
            try Self.save(contents)
        }
    }

    func hasOAuthToken(for accountId: UUID) -> Bool {
        (try? Self.withLock {
            (try Self.load()).oauthTokens[accountId.uuidString] != nil
        }) ?? false
    }

    // MARK: - Migration import

    /// Merge credentials read from the legacy Keychain into the file store.
    /// Existing file entries always win (post-migration edits live in the file).
    /// Serialization is enforced by fileLock to prevent TOCTOU races with actor methods.
    nonisolated static func importIfAbsent(
        passwords: [String: String], oauthTokens: [String: String]) throws {
        try withLock {
            var contents = try load()
            for (key, value) in passwords where contents.passwords[key] == nil {
                contents.passwords[key] = value
            }
            for (key, value) in oauthTokens where contents.oauthTokens[key] == nil {
                contents.oauthTokens[key] = value
            }
            try save(contents)
        }
    }
}

enum CredentialStoreError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Credential not found — re-enter it in Settings → Accounts"
        }
    }
}
