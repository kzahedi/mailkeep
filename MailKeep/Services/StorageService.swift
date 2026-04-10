import Foundation
import CryptoKit

/// Service for storing emails and attachments to disk
actor StorageService {
    private let baseURL: URL
    private let fileManager = FileManager.default

    /// Cache file name for storing UIDs (hidden file)
    private let uidCacheFilename = ".uid_cache"

    /// Cache file name for storing content hashes (hidden file)
    private let hashIndexFilename = ".hash_index"

    /// Size of content to hash for deduplication (64KB)
    private let hashContentSize = 64 * 1024

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    // MARK: - UID Cache Management

    /// Get the UID cache file URL for a folder
    nonisolated private func uidCacheURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(uidCacheFilename)
    }

    /// Append a UID to the cache file
    private func appendUIDToCache(_ uid: UInt32, folderURL: URL) {
        let cacheURL = uidCacheURL(for: folderURL)
        let line = "\(uid)\n"

        if let data = line.data(using: .utf8) {
            if fileManager.fileExists(atPath: cacheURL.path) {
                // Append to existing file
                if let handle = try? FileHandle(forWritingTo: cacheURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                // Create new file
                try? data.write(to: cacheURL)
            }
        }
    }

    /// Read UIDs from cache file (O(1) file read instead of O(n) directory scan)
    nonisolated private func readUIDsFromCache(folderURL: URL) -> Set<UInt32>? {
        let cacheURL = uidCacheURL(for: folderURL)

        guard let content = try? String(contentsOf: cacheURL, encoding: .utf8) else {
            return nil
        }

        var uids = Set<UInt32>()
        for line in content.components(separatedBy: .newlines) {
            if let uid = UInt32(line.trimmingCharacters(in: .whitespaces)) {
                uids.insert(uid)
            }
        }
        return uids
    }

    /// Rebuild UID cache from existing files (migration for existing backups)
    func rebuildUIDCache(accountEmail: String, folderPath: String) throws {
        let sanitizedEmail = accountEmail.sanitizedForFilename()
        let sanitizedPath = folderPath
            .components(separatedBy: "/")
            .map { $0.sanitizedForFilename() }
            .joined(separator: "/")

        let folderURL = baseURL
            .appendingPathComponent(sanitizedEmail)
            .appendingPathComponent(sanitizedPath)

        guard fileManager.fileExists(atPath: folderURL.path) else { return }

        // Scan files and build cache
        let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        var uids: [UInt32] = []

        for fileURL in contents where fileURL.pathExtension == "eml" {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            if let firstUnderscore = filename.firstIndex(of: "_"),
               let uid = UInt32(filename[..<firstUnderscore]) {
                uids.append(uid)
            }
        }

        // Write cache file
        let cacheURL = uidCacheURL(for: folderURL)
        let content = uids.map { String($0) }.joined(separator: "\n") + (uids.isEmpty ? "" : "\n")
        try content.write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    /// Validate and repair all UID caches at startup
    /// Returns the number of caches that were repaired
    /// Runs heavy file operations on background queue to avoid blocking
    func validateAndRepairAllCaches() async -> Int {
        let baseURL = self.baseURL
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var repairedCount = 0

            guard fm.fileExists(atPath: baseURL.path) else { return 0 }

            guard let enumerator = fm.enumerator(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }

            var foldersToCheck: [URL] = []
            while let fileURL = enumerator.nextObject() as? URL {
                if fileURL.pathExtension == "eml" {
                    let folderURL = fileURL.deletingLastPathComponent()
                    if !foldersToCheck.contains(folderURL) {
                        foldersToCheck.append(folderURL)
                    }
                }
            }

            for folderURL in foldersToCheck {
                if self.validateAndRepairCacheSync(for: folderURL) {
                    repairedCount += 1
                }
            }

            return repairedCount
        }.value
    }

    /// Validate and repair cache for a single folder (sync version for background queue)
    /// Returns true if cache was repaired
    nonisolated private func validateAndRepairCacheSync(for folderURL: URL) -> Bool {
        let cacheURL = uidCacheURL(for: folderURL)

        // Get actual UIDs from .eml files
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else {
            return false
        }

        var actualUIDs = Set<UInt32>()
        for fileURL in contents where fileURL.pathExtension == "eml" {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            if let firstUnderscore = filename.firstIndex(of: "_"),
               let uid = UInt32(filename[..<firstUnderscore]) {
                actualUIDs.insert(uid)
            }
        }

        // Read cached UIDs
        let cachedUIDs = readUIDsFromCache(folderURL: folderURL) ?? Set<UInt32>()

        // Compare - if they match, no repair needed
        if cachedUIDs == actualUIDs {
            return false
        }

        // Mismatch detected - rebuild cache
        let sortedUIDs = actualUIDs.sorted()
        let content = sortedUIDs.map { String($0) }.joined(separator: "\n") + (sortedUIDs.isEmpty ? "" : "\n")
        try? content.write(to: cacheURL, atomically: true, encoding: .utf8)

        return true
    }

    // MARK: - Content Hash Management

    /// Compute SHA256 hash of normalized email content (first 64KB)
    /// Normalizes line endings to handle different systems
    private func computeContentHash(at url: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: hashContentSize)
        guard !data.isEmpty else { return nil }

        // Normalize line endings: CRLF -> LF, CR -> LF
        guard var content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            // Binary content - hash as-is
            let hash = SHA256.hash(data: data)
            return hash.compactMap { String(format: "%02x", $0) }.joined()
        }

        content = content.replacingOccurrences(of: "\r\n", with: "\n")
        content = content.replacingOccurrences(of: "\r", with: "\n")

        guard let normalizedData = content.data(using: .utf8) else { return nil }
        let hash = SHA256.hash(data: normalizedData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Get the hash index file URL for a folder
    private func hashIndexURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(hashIndexFilename)
    }

    /// Read hash index from file: hash -> relative filename
    private func readHashIndex(folderURL: URL) -> [String: String]? {
        let indexURL = hashIndexURL(for: folderURL)

        guard let content = try? String(contentsOf: indexURL, encoding: .utf8) else {
            return nil
        }

        var index: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "\t")
            if parts.count == 2 {
                index[parts[0]] = parts[1]
            }
        }
        return index
    }

    /// Append a hash entry to the index file
    private func appendHashToIndex(_ hash: String, filename: String, folderURL: URL) {
        let indexURL = hashIndexURL(for: folderURL)
        let line = "\(hash)\t\(filename)\n"

        if let data = line.data(using: .utf8) {
            if fileManager.fileExists(atPath: indexURL.path) {
                if let handle = try? FileHandle(forWritingTo: indexURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: indexURL)
            }
        }
    }

    /// Find existing file with same content hash across all folders
    /// Returns the URL of the existing file if found
    func findExistingByHash(_ hash: String, accountEmail: String) -> URL? {
        let sanitizedEmail = accountEmail.sanitizedForFilename()
        let accountURL = baseURL.appendingPathComponent(sanitizedEmail)

        guard fileManager.fileExists(atPath: accountURL.path) else { return nil }

        // Search all subfolders for the hash
        guard let enumerator = fileManager.enumerator(
            at: accountURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var foldersToCheck: Set<URL> = []
        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.pathExtension == "eml" {
                foldersToCheck.insert(fileURL.deletingLastPathComponent())
            }
        }

        for folderURL in foldersToCheck {
            if let index = readHashIndex(folderURL: folderURL),
               let filename = index[hash] {
                let fileURL = folderURL.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: fileURL.path) {
                    return fileURL
                }
            }
        }

        return nil
    }

    /// Check if a newly saved email is a duplicate (moved email) and handle it
    /// Returns: (isDuplicate: Bool, movedFrom: URL?) - if duplicate, the original location
    func checkAndHandleDuplicate(newFileURL: URL, accountEmail: String) -> (isDuplicate: Bool, movedFrom: URL?) {
        guard let hash = computeContentHash(at: newFileURL) else {
            return (false, nil)
        }

        // Check if this hash exists elsewhere
        if let existingURL = findExistingByHash(hash, accountEmail: accountEmail),
           existingURL != newFileURL {
            // Found duplicate — this email was moved, not new.
            // Use move-then-delete ordering so a filesystem error never loses both copies:
            //   1. Move the existing file to a safe temp path (original is preserved if 2/3 fail)
            //   2. Delete the newly-downloaded copy
            //   3. Rename temp into the new location
            //   On any failure, restore the temp back to the original path.
            let tempPath = existingURL.appendingPathExtension("dedup-tmp")
            do {
                try fileManager.moveItem(at: existingURL, to: tempPath)
                do {
                    try fileManager.removeItem(at: newFileURL)
                    try fileManager.moveItem(at: tempPath, to: newFileURL)
                } catch {
                    try? fileManager.moveItem(at: tempPath, to: existingURL)
                    throw error
                }

                // Update hash index in new location
                let newFolderURL = newFileURL.deletingLastPathComponent()
                appendHashToIndex(hash, filename: newFileURL.lastPathComponent, folderURL: newFolderURL)

                return (true, existingURL)
            } catch {
                // Operation failed — keep the new download as-is
                let folderURL = newFileURL.deletingLastPathComponent()
                appendHashToIndex(hash, filename: newFileURL.lastPathComponent, folderURL: folderURL)
                return (false, nil)
            }
        }

        // Not a duplicate - add to hash index
        let folderURL = newFileURL.deletingLastPathComponent()
        appendHashToIndex(hash, filename: newFileURL.lastPathComponent, folderURL: folderURL)
        return (false, nil)
    }

    /// Rebuild hash index for a folder from existing .eml files
    func rebuildHashIndex(accountEmail: String, folderPath: String) throws {
        let sanitizedEmail = accountEmail.sanitizedForFilename()
        let sanitizedPath = folderPath
            .components(separatedBy: "/")
            .map { $0.sanitizedForFilename() }
            .joined(separator: "/")

        let folderURL = baseURL
            .appendingPathComponent(sanitizedEmail)
            .appendingPathComponent(sanitizedPath)

        guard fileManager.fileExists(atPath: folderURL.path) else { return }

        let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        var hashEntries: [String] = []

        for fileURL in contents where fileURL.pathExtension == "eml" {
            if let hash = computeContentHash(at: fileURL) {
                hashEntries.append("\(hash)\t\(fileURL.lastPathComponent)")
            }
        }

        let indexURL = hashIndexURL(for: folderURL)
        let content = hashEntries.joined(separator: "\n") + (hashEntries.isEmpty ? "" : "\n")
        try content.write(to: indexURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Directory Management

    func createAccountDirectory(email: String) throws -> URL {
        let sanitizedEmail = email.sanitizedForFilename()
        let accountURL = baseURL.appendingPathComponent(sanitizedEmail)

        if !fileManager.fileExists(atPath: accountURL.path) {
            try fileManager.createDirectory(at: accountURL, withIntermediateDirectories: true)
        }

        return accountURL
    }

    func createFolderDirectory(accountEmail: String, folderPath: String) throws -> URL {
        let accountURL = try createAccountDirectory(email: accountEmail)

        // Convert IMAP folder path to filesystem path
        // e.g., "Work/Projects/Alpha" -> "Work/Projects/Alpha"
        let sanitizedPath = folderPath
            .components(separatedBy: "/")
            .map { $0.sanitizedForFilename() }
            .joined(separator: "/")

        let folderURL = accountURL.appendingPathComponent(sanitizedPath)

        if !fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }

        return folderURL
    }

    // MARK: - Email Storage

    /// Save email with atomic write to prevent partial files from interrupted downloads
    func saveEmail(_ emailData: Data, email: Email, accountEmail: String, folderPath: String) throws -> URL {
        let folderURL = try createFolderDirectory(accountEmail: accountEmail, folderPath: folderPath)
        let filename = email.filename()
        let fileURL = folderURL.appendingPathComponent(filename)

        // Check for duplicate filename and increment if needed
        let finalURL = uniqueFileURL(for: fileURL)

        // Write to temp file first, then atomically move to final location
        // This prevents partial files from interrupted downloads
        let tempURL = finalURL.appendingPathExtension("tmp")
        try emailData.write(to: tempURL)
        try fileManager.moveItem(at: tempURL, to: finalURL)

        // Append UID to cache for O(1) lookup on next backup
        appendUIDToCache(email.uid, folderURL: folderURL)

        return finalURL
    }

    /// Prepare a destination URL for streaming large emails directly to disk
    func prepareStreamingDestination(email: Email, accountEmail: String, folderPath: String) throws -> (tempURL: URL, finalURL: URL) {
        let folderURL = try createFolderDirectory(accountEmail: accountEmail, folderPath: folderPath)
        let filename = email.filename()
        let fileURL = folderURL.appendingPathComponent(filename)
        let finalURL = uniqueFileURL(for: fileURL)
        let tempURL = finalURL.appendingPathExtension("tmp")
        return (tempURL, finalURL)
    }

    /// Finalize a streamed file by moving from temp to final location
    func finalizeStreamedFile(tempURL: URL, finalURL: URL, uid: UInt32? = nil) throws {
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: tempURL, to: finalURL)

        // Append UID to cache for O(1) lookup on next backup
        if let uid = uid {
            let folderURL = finalURL.deletingLastPathComponent()
            appendUIDToCache(uid, folderURL: folderURL)
        }
    }

    /// Read headers from a saved .eml file for metadata extraction
    func readEmailHeaders(at url: URL, maxBytes: Int = 32768) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: maxBytes)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
    }

    /// Clean up any orphaned temp files from interrupted downloads
    func cleanupIncompleteDownloads() throws -> Int {
        var cleanedCount = 0
        let enumerator = fileManager.enumerator(at: baseURL, includingPropertiesForKeys: nil)

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension == "tmp" {
                try? fileManager.removeItem(at: fileURL)
                cleanedCount += 1
            }
        }

        return cleanedCount
    }

    func saveAttachment(_ data: Data, filename: String, email: Email, accountEmail: String, folderPath: String) throws -> URL {
        let folderURL = try createFolderDirectory(accountEmail: accountEmail, folderPath: folderPath)
        let attachmentFolderName = email.attachmentFolderName()
        let attachmentFolderURL = folderURL.appendingPathComponent(attachmentFolderName)

        if !fileManager.fileExists(atPath: attachmentFolderURL.path) {
            try fileManager.createDirectory(at: attachmentFolderURL, withIntermediateDirectories: true)
        }

        let sanitizedFilename = filename.sanitizedForFilename()
        let fileURL = attachmentFolderURL.appendingPathComponent(sanitizedFilename)
        let finalURL = uniqueFileURL(for: fileURL)

        // Write to temp file first, then atomically move to final location
        let tempURL = finalURL.appendingPathExtension("tmp")
        try data.write(to: tempURL)
        try fileManager.moveItem(at: tempURL, to: finalURL)

        return finalURL
    }

    // MARK: - Query Methods

    /// Get UIDs of already downloaded emails
    /// Uses cache file for O(1) lookup, falls back to O(n) file scan if cache missing
    func getExistingUIDs(accountEmail: String, folderPath: String) throws -> Set<UInt32> {
        let sanitizedEmail = accountEmail.sanitizedForFilename()
        let sanitizedPath = folderPath
            .components(separatedBy: "/")
            .map { $0.sanitizedForFilename() }
            .joined(separator: "/")

        let folderURL = baseURL
            .appendingPathComponent(sanitizedEmail)
            .appendingPathComponent(sanitizedPath)

        guard fileManager.fileExists(atPath: folderURL.path) else {
            return []
        }

        // Try to read from cache first (fast path)
        if let cachedUIDs = readUIDsFromCache(folderURL: folderURL) {
            return cachedUIDs
        }

        // Cache miss - fall back to file scan (slow path, builds cache)
        let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        var uids = Set<UInt32>()

        for fileURL in contents where fileURL.pathExtension == "eml" {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            // Extract UID from start of filename (before first underscore)
            if let firstUnderscore = filename.firstIndex(of: "_"),
               let uid = UInt32(filename[..<firstUnderscore]) {
                uids.insert(uid)
            }
        }

        // Build cache for next time
        let cacheURL = uidCacheURL(for: folderURL)
        let content = uids.map { String($0) }.joined(separator: "\n") + (uids.isEmpty ? "" : "\n")
        try? content.write(to: cacheURL, atomically: true, encoding: .utf8)

        return uids
    }

    func emailExists(messageId: String, accountEmail: String, folderPath: String) throws -> Bool {
        // This is a simple check - in production, use the database
        let folderURL = try createFolderDirectory(accountEmail: accountEmail, folderPath: folderPath)
        let contents = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        return contents.contains { $0.pathExtension == "eml" }
    }

    func getBackupSize(for accountEmail: String) throws -> Int64 {
        let accountURL = try createAccountDirectory(email: accountEmail)
        return try directorySize(at: accountURL)
    }

    func getEmailCount(for accountEmail: String) throws -> Int {
        let accountURL = try createAccountDirectory(email: accountEmail)
        return try countFiles(at: accountURL, withExtension: "eml")
    }

    // MARK: - Helpers

    private func uniqueFileURL(for url: URL) -> URL {
        var finalURL = url
        var counter = 1

        while fileManager.fileExists(atPath: finalURL.path) {
            let filename = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let newFilename = "\(filename)_\(counter).\(ext)"
            finalURL = url.deletingLastPathComponent().appendingPathComponent(newFilename)
            counter += 1
        }

        return finalURL
    }

    private func directorySize(at url: URL) throws -> Int64 {
        var totalSize: Int64 = 0
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])

        while let fileURL = enumerator?.nextObject() as? URL {
            let attributes = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            totalSize += Int64(attributes.fileSize ?? 0)
        }

        return totalSize
    }

    private func countFiles(at url: URL, withExtension ext: String) throws -> Int {
        var count = 0
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil)

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension == ext {
                count += 1
            }
        }

        return count
    }
}
