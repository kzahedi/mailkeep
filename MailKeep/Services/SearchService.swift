import Foundation
import PDFKit

/// Search scope options for filtering
enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All Fields"
    case subject = "Subject Only"
    case sender = "From/Sender"
    case recipient = "To/Recipient"
    case body = "Body Only"
    case attachments = "Attachments"

    var id: String { rawValue }
}

/// Filter options for enhanced search
struct SearchFilter {
    /// Accounts to search (empty = all accounts)
    var accounts: Set<String> = []

    /// Folders to search (empty = all folders)
    var folders: Set<String> = []

    /// Search scope
    var scope: SearchScope = .all

    /// Start date for date range filter (nil = no start limit)
    var startDate: Date?

    /// End date for date range filter (nil = no end limit)
    var endDate: Date?

    /// Default filter (no restrictions)
    static let `default` = SearchFilter()

    /// Check if any filters are active
    var hasActiveFilters: Bool {
        !accounts.isEmpty || !folders.isEmpty || scope != .all || startDate != nil || endDate != nil
    }
}

/// Search result from file-based search
struct SearchResult: Identifiable {
    let id = UUID()
    let accountId: String
    let mailbox: String
    let messageId: String
    let sender: String
    let senderEmail: String
    let subject: String
    let date: Date
    let filePath: String
    let matchType: MatchType
    let snippet: String

    enum MatchType: String {
        case sender = "Sender"
        case subject = "Subject"
        case body = "Body"
        case attachment = "Attachment"
        case attachmentContent = "Attachment Content"
    }
}

/// Service for searching emails directly from .eml files
actor SearchService {
    private let backupLocation: URL

    init(backupLocation: URL) {
        self.backupLocation = backupLocation
    }

    // MARK: - Public API

    func open() throws {
        // No database to open - this is a no-op for compatibility
    }

    func close() {
        // No database to close - this is a no-op for compatibility
    }

    /// Get stats about indexed emails (counts .eml files)
    func getStats() throws -> (emailCount: Int, attachmentCount: Int) {
        let fileManager = FileManager.default
        var emailCount = 0

        guard fileManager.fileExists(atPath: backupLocation.path) else {
            return (0, 0)
        }

        let enumerator = fileManager.enumerator(
            at: backupLocation,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "eml" {
                emailCount += 1
            }
        }

        return (emailCount, 0)
    }

    /// Search emails by query string with optional filters
    func search(query: String, filter: SearchFilter = .default, limit: Int = 100) throws -> [SearchResult] {
        let searchTerms = query.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !searchTerms.isEmpty else { return [] }

        var results: [SearchResult] = []
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: backupLocation.path) else {
            return []
        }

        let enumerator = fileManager.enumerator(
            at: backupLocation,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "eml" else { continue }
            guard results.count < limit else { break }

            // Apply account and folder filters before reading file
            let (accountId, mailbox) = extractPathInfo(from: url)

            if !filter.accounts.isEmpty && !filter.accounts.contains(accountId) {
                continue
            }

            if !filter.folders.isEmpty && !filter.folders.contains(where: { mailbox.contains($0) }) {
                continue
            }

            if let result = searchEmailFile(url: url, searchTerms: searchTerms, filter: filter) {
                // Apply date filter
                if let startDate = filter.startDate, result.date < startDate {
                    continue
                }
                if let endDate = filter.endDate, result.date > endDate {
                    continue
                }

                results.append(result)
            }
        }

        // Sort by date descending
        return results.sorted { $0.date > $1.date }
    }

    /// Get list of available accounts for filter UI (runs on background thread)
    func getAvailableAccounts() async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fileManager = FileManager.default

                guard fileManager.fileExists(atPath: self.backupLocation.path) else {
                    continuation.resume(returning: [])
                    return
                }

                do {
                    let contents = try fileManager.contentsOfDirectory(at: self.backupLocation, includingPropertiesForKeys: [.isDirectoryKey])
                    let accounts = contents
                        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                        .map { $0.lastPathComponent }
                        .sorted()
                    continuation.resume(returning: accounts)
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Get list of available folders for a specific account (or all accounts) - runs on background thread
    func getAvailableFolders(forAccount account: String? = nil) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fileManager = FileManager.default
                var folders = Set<String>()

                guard fileManager.fileExists(atPath: self.backupLocation.path) else {
                    continuation.resume(returning: [])
                    return
                }

                let searchRoot: URL
                if let account = account {
                    searchRoot = self.backupLocation.appendingPathComponent(account)
                } else {
                    searchRoot = self.backupLocation
                }

                guard let enumerator = fileManager.enumerator(
                    at: searchRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                ) else {
                    continuation.resume(returning: [])
                    return
                }

                // Only get top-level folders, not all descendants
                while let url = enumerator.nextObject() as? URL {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        let folderName = url.lastPathComponent
                        // Add common folder names without checking for .eml files (faster)
                        folders.insert(folderName)
                    }
                }

                continuation.resume(returning: folders.sorted())
            }
        }
    }

    /// Reindex all - this is a no-op for file-based search
    func reindexAll(progressCallback: @escaping (Int, Int) -> Void) throws {
        // Count files for progress
        let stats = try getStats()
        progressCallback(stats.emailCount, stats.emailCount)
    }

    // MARK: - Private Methods

    /// Maximum header size to read for search optimization
    private let maxHeaderSize = Constants.maxHeaderSizeForSearch

    private func searchEmailFile(url: URL, searchTerms: [String], filter: SearchFilter = .default) -> SearchResult? {
        // Step 1: Read only headers first (memory efficient)
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }

        let headerData = handle.readData(ofLength: maxHeaderSize)
        guard let headerContent = String(data: headerData, encoding: .utf8)
              ?? String(data: headerData, encoding: .isoLatin1) else {
            return nil
        }

        // Extract headers portion (up to first blank line)
        let headerEndPatterns = ["\r\n\r\n", "\n\n"]
        var headers = headerContent
        for pattern in headerEndPatterns {
            if let range = headerContent.range(of: pattern) {
                headers = String(headerContent[..<range.lowerBound])
                break
            }
        }

        // Parse headers
        let (sender, senderEmail) = extractSender(from: headers)
        let subject = extractHeader(named: "Subject", from: headers) ?? "No Subject"
        let messageId = extractHeader(named: "Message-ID", from: headers) ?? UUID().uuidString
        let date = extractDate(from: headers)
        let (accountId, mailbox) = extractPathInfo(from: url)
        let recipient = extractHeader(named: "To", from: headers) ?? ""

        let subjectLower = subject.lowercased()
        let senderLower = "\(sender) \(senderEmail)".lowercased()
        let recipientLower = recipient.lowercased()

        // Apply scope-based search
        switch filter.scope {
        case .subject:
            // Only search subject
            for term in searchTerms {
                if !subjectLower.contains(term) { return nil }
            }
            return SearchResult(
                accountId: accountId, mailbox: mailbox, messageId: messageId,
                sender: sender, senderEmail: senderEmail, subject: subject,
                date: date, filePath: url.path, matchType: .subject,
                snippet: createSnippet(from: subject, searchTerms: searchTerms)
            )

        case .sender:
            // Only search sender
            for term in searchTerms {
                if !senderLower.contains(term) { return nil }
            }
            return SearchResult(
                accountId: accountId, mailbox: mailbox, messageId: messageId,
                sender: sender, senderEmail: senderEmail, subject: subject,
                date: date, filePath: url.path, matchType: .sender,
                snippet: createSnippet(from: "\(sender) <\(senderEmail)>", searchTerms: searchTerms)
            )

        case .recipient:
            // Only search recipient
            for term in searchTerms {
                if !recipientLower.contains(term) { return nil }
            }
            return SearchResult(
                accountId: accountId, mailbox: mailbox, messageId: messageId,
                sender: sender, senderEmail: senderEmail, subject: subject,
                date: date, filePath: url.path, matchType: .body,
                snippet: createSnippet(from: "To: \(recipient)", searchTerms: searchTerms)
            )

        case .body:
            // Only search body - must read full content
            handle.seek(toFileOffset: 0)
            guard let fullData = try? handle.readToEnd(),
                  let fullContent = String(data: fullData, encoding: .utf8)
                  ?? String(data: fullData, encoding: .isoLatin1) else {
                return nil
            }
            let body = extractBodyText(from: fullContent)
            let bodyLower = body.lowercased()
            for term in searchTerms {
                if !bodyLower.contains(term) { return nil }
            }
            return SearchResult(
                accountId: accountId, mailbox: mailbox, messageId: messageId,
                sender: sender, senderEmail: senderEmail, subject: subject,
                date: date, filePath: url.path, matchType: .body,
                snippet: createSnippet(from: body, searchTerms: searchTerms)
            )

        case .attachments:
            // Search for attachment filenames in Content-Disposition headers
            handle.seek(toFileOffset: 0)
            guard let fullData = try? handle.readToEnd(),
                  let fullContent = String(data: fullData, encoding: .utf8)
                  ?? String(data: fullData, encoding: .isoLatin1) else {
                return nil
            }
            let attachmentNames = extractAttachmentNames(from: fullContent)
            let attachmentText = attachmentNames.joined(separator: " ").lowercased()
            for term in searchTerms {
                if !attachmentText.contains(term) { return nil }
            }
            return SearchResult(
                accountId: accountId, mailbox: mailbox, messageId: messageId,
                sender: sender, senderEmail: senderEmail, subject: subject,
                date: date, filePath: url.path, matchType: .attachment,
                snippet: "Attachments: " + attachmentNames.joined(separator: ", ")
            )

        case .all:
            // Search all fields (original behavior)
            let headersLower = headers.lowercased()

            // Step 2: Check headers first (fast path - no body read needed)
            var allTermsInHeaders = true
            var matchedInSender = false
            var matchedInSubject = false

            for term in searchTerms {
                let inSender = senderLower.contains(term)
                let inSubject = subjectLower.contains(term)

                if inSender { matchedInSender = true }
                if inSubject { matchedInSubject = true }

                if !inSender && !inSubject && !headersLower.contains(term) {
                    allTermsInHeaders = false
                    break
                }
            }

            if allTermsInHeaders {
                // All terms found in headers - no need to read body
                let matchType: SearchResult.MatchType = matchedInSender ? .sender : (matchedInSubject ? .subject : .body)
                let snippetSource = matchedInSender ? senderLower : (matchedInSubject ? subject : headers)
                return SearchResult(
                    accountId: accountId,
                    mailbox: mailbox,
                    messageId: messageId,
                    sender: sender,
                    senderEmail: senderEmail,
                    subject: subject,
                    date: date,
                    filePath: url.path,
                    matchType: matchType,
                    snippet: createSnippet(from: snippetSource, searchTerms: searchTerms)
                )
            }

            // Step 3: Need to search body - read full file (slow path)
            handle.seek(toFileOffset: 0)
            guard let fullData = try? handle.readToEnd(),
                  let fullContent = String(data: fullData, encoding: .utf8)
                  ?? String(data: fullData, encoding: .isoLatin1) else {
                return nil
            }

            return searchEmailContent(content: fullContent, url: url, searchTerms: searchTerms)
        }
    }

    /// Extract attachment filenames from email content
    private func extractAttachmentNames(from content: String) -> [String] {
        var names: [String] = []

        // Match Content-Disposition: attachment; filename="..."
        let pattern = #"filename[*]?=(?:\"([^\"]+)\"|([^\s;]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return names
        }

        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        for match in matches {
            if let range = Range(match.range(at: 1), in: content) {
                names.append(String(content[range]))
            } else if let range = Range(match.range(at: 2), in: content) {
                names.append(String(content[range]))
            }
        }

        return names
    }

    private func searchEmailContent(content: String, url: URL, searchTerms: [String]) -> SearchResult? {
        let contentLower = content.lowercased()

        // Check if all search terms are present
        for term in searchTerms {
            if !contentLower.contains(term) {
                return nil
            }
        }

        // Parse email headers
        let (sender, senderEmail) = extractSender(from: content)
        let subject = extractHeader(named: "Subject", from: content) ?? "No Subject"
        let messageId = extractHeader(named: "Message-ID", from: content) ?? UUID().uuidString
        let date = extractDate(from: content)

        // Determine match type and create snippet
        let (matchType, snippet) = determineMatchType(content: content, contentLower: contentLower, searchTerms: searchTerms)

        // Extract account and mailbox from path
        let (accountId, mailbox) = extractPathInfo(from: url)

        return SearchResult(
            accountId: accountId,
            mailbox: mailbox,
            messageId: messageId,
            sender: sender,
            senderEmail: senderEmail,
            subject: subject,
            date: date,
            filePath: url.path,
            matchType: matchType,
            snippet: snippet
        )
    }

    private func extractSender(from content: String) -> (name: String, email: String) {
        guard let fromLine = extractHeader(named: "From", from: content) else {
            return ("Unknown", "")
        }

        // Parse "Name <email>" or just "email"
        if let match = fromLine.range(of: #"([^<]+)?<?([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})>?"#, options: .regularExpression) {
            let matched = String(fromLine[match])

            if let angleBracket = matched.firstIndex(of: "<") {
                let name = String(matched[..<angleBracket]).trimmingCharacters(in: .whitespaces)
                let emailStart = matched.index(after: angleBracket)
                if let emailEnd = matched.firstIndex(of: ">") {
                    let email = String(matched[emailStart..<emailEnd])
                    return (name.isEmpty ? email : name.replacingOccurrences(of: "\"", with: ""), email)
                }
            }

            return (matched, matched)
        }

        return (fromLine, fromLine)
    }

    private func extractHeader(named name: String, from content: String) -> String? {
        let pattern = "(?m)^\(name):\\s*(.+?)(?=\\r?\\n[^ \\t]|\\r?\\n\\r?\\n)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else {
            // Try simpler single-line extraction
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                if line.lowercased().hasPrefix(name.lowercased() + ":") {
                    let value = String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
                    return decodeRFC2047(value)
                }
                // Stop at empty line (end of headers)
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    break
                }
            }
            return nil
        }

        let value = String(content[range]).replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\n ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return decodeRFC2047(value)
    }

    private func extractDate(from content: String) -> Date {
        guard let dateString = extractHeader(named: "Date", from: content) else {
            return Date()
        }

        let formatters: [DateFormatter] = [
            {
                let df = DateFormatter()
                df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
                df.locale = Locale(identifier: "en_US_POSIX")
                return df
            }(),
            {
                let df = DateFormatter()
                df.dateFormat = "dd MMM yyyy HH:mm:ss Z"
                df.locale = Locale(identifier: "en_US_POSIX")
                return df
            }(),
            {
                let df = DateFormatter()
                df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss ZZZZZ"
                df.locale = Locale(identifier: "en_US_POSIX")
                return df
            }()
        ]

        for formatter in formatters {
            if let date = formatter.date(from: dateString) {
                return date
            }
        }

        return Date()
    }

    private func determineMatchType(content: String, contentLower: String, searchTerms: [String]) -> (SearchResult.MatchType, String) {
        let firstTerm = searchTerms[0]

        // Check sender
        if let from = extractHeader(named: "From", from: content)?.lowercased(), from.contains(firstTerm) {
            return (.sender, createSnippet(from: from, searchTerms: searchTerms))
        }

        // Check subject
        if let subject = extractHeader(named: "Subject", from: content)?.lowercased(), subject.contains(firstTerm) {
            return (.subject, createSnippet(from: subject, searchTerms: searchTerms))
        }

        // Check body
        let body = extractBodyText(from: content)
        if body.lowercased().contains(firstTerm) {
            return (.body, createSnippet(from: body, searchTerms: searchTerms))
        }

        // Default to body match
        return (.body, createSnippet(from: content, searchTerms: searchTerms))
    }

    private func extractBodyText(from content: String) -> String {
        // Find the body (after empty line in headers)
        let parts = content.components(separatedBy: "\r\n\r\n")
        if parts.count > 1 {
            let body = parts.dropFirst().joined(separator: "\r\n\r\n")
            return stripHTMLAndDecode(body)
        }

        let parts2 = content.components(separatedBy: "\n\n")
        if parts2.count > 1 {
            let body = parts2.dropFirst().joined(separator: "\n\n")
            return stripHTMLAndDecode(body)
        }

        return content
    }

    private func stripHTMLAndDecode(_ text: String) -> String {
        var result = text
        // Remove HTML tags
        result = result.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode HTML entities
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        // Decode quoted-printable common patterns
        result = result.replacingOccurrences(of: "=20", with: " ")
        result = result.replacingOccurrences(of: "=\r\n", with: "")
        result = result.replacingOccurrences(of: "=\n", with: "")
        // Clean up whitespace
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createSnippet(from text: String, searchTerms: [String], maxLength: Int = 200) -> String {
        let textLower = text.lowercased()

        // Find position of first search term
        guard let firstTerm = searchTerms.first,
              let range = textLower.range(of: firstTerm) else {
            return String(text.prefix(maxLength))
        }

        // Get context around the match
        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let snippetStart = max(0, matchStart - 50)
        let snippetEnd = min(text.count, matchStart + maxLength - 50)

        let startIndex = text.index(text.startIndex, offsetBy: snippetStart)
        let endIndex = text.index(text.startIndex, offsetBy: snippetEnd)

        var snippet = String(text[startIndex..<endIndex])

        // Add ellipsis if needed
        if snippetStart > 0 {
            snippet = "..." + snippet
        }
        if snippetEnd < text.count {
            snippet = snippet + "..."
        }

        // Highlight search terms
        for term in searchTerms {
            snippet = snippet.replacingOccurrences(
                of: term,
                with: "<mark>\(term)</mark>",
                options: .caseInsensitive
            )
        }

        return snippet
    }

    private func extractPathInfo(from url: URL) -> (accountId: String, mailbox: String) {
        let resolvedBase = backupLocation.resolvingSymlinksInPath().path
        let resolvedPath = url.resolvingSymlinksInPath().path
        let relativePath = resolvedPath.replacingOccurrences(of: resolvedBase + "/", with: "")
        let components = relativePath.components(separatedBy: "/")

        guard components.count >= 2 else {
            return ("Unknown", "Unknown")
        }

        let accountId = components[0]
        let mailbox = components.dropFirst().dropLast().joined(separator: "/")

        return (accountId, mailbox.isEmpty ? "INBOX" : mailbox)
    }

    private func decodeRFC2047(_ text: String) -> String {
        var result = text

        // Match =?charset?encoding?text?= pattern
        let pattern = #"=\?([^?]+)\?([BQbq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: text),
                  let charsetRange = Range(match.range(at: 1), in: text),
                  let encodingRange = Range(match.range(at: 2), in: text),
                  let encodedRange = Range(match.range(at: 3), in: text) else {
                continue
            }

            let charset = String(text[charsetRange])
            let encoding = String(text[encodingRange]).uppercased()
            let encoded = String(text[encodedRange])

            var decoded: String?

            if encoding == "B" {
                // Base64
                if let data = Data(base64Encoded: encoded) {
                    decoded = String(data: data, encoding: encodingFromCharset(charset)) ?? String(data: data, encoding: .utf8)
                }
            } else if encoding == "Q" {
                // Quoted-printable
                let qpDecoded = encoded.replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "=([0-9A-Fa-f]{2})", with: "", options: .regularExpression)
                decoded = qpDecoded
            }

            if let decoded = decoded {
                result.replaceSubrange(fullRange, with: decoded)
            }
        }

        return result
    }

    private func encodingFromCharset(_ charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1": return .isoLatin1
        case "iso-8859-2", "latin2": return .isoLatin2
        case "us-ascii", "ascii": return .ascii
        case "windows-1252", "cp1252": return .windowsCP1252
        default: return .utf8
        }
    }
}
