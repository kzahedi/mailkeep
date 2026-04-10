import SwiftUI
import AppKit

struct EmailBrowserView: View {
    @EnvironmentObject var backupManager: BackupManager
    @StateObject private var browserService = EmailBrowserService()

    @State private var selectedAccount: String?
    @State private var selectedFolder: String?
    @State private var selectedEmail: EmailFileInfo?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            // Sidebar - Accounts and Folders
            List(selection: $selectedFolder) {
                ForEach(browserService.accounts, id: \.self) { account in
                    Section(header: Text(account)) {
                        ForEach(browserService.folders(for: account), id: \.self) { folder in
                            Label(folder, systemImage: folderIcon(for: folder))
                                .tag("\(account)/\(folder)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200)
        } content: {
            // Email list
            if let selection = selectedFolder {
                emailListView(for: selection)
            } else {
                ContentUnavailableView(
                    "Select a Folder",
                    systemImage: "folder",
                    description: Text("Choose a folder from the sidebar to view emails")
                )
            }
        } detail: {
            // Email preview
            if let email = selectedEmail {
                EmailPreviewView(email: email)
            } else {
                ContentUnavailableView(
                    "Select an Email",
                    systemImage: "envelope",
                    description: Text("Choose an email to preview its contents")
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search emails...")
        .task {
            await browserService.loadAccounts(from: backupManager.backupLocation)
        }
        .onChange(of: selectedFolder) { _, newValue in
            selectedEmail = nil
            if let selection = newValue {
                let parts = selection.split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    let account = String(parts[0])
                    let folder = String(parts[1])
                    Task {
                        await browserService.loadEmails(account: account, folder: folder, from: backupManager.backupLocation)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { refreshEmails() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: { openInFinder() }) {
                    Image(systemName: "folder")
                }
                .help("Open in Finder")
                .disabled(selectedEmail == nil)
            }
        }
    }

    @ViewBuilder
    private func emailListView(for selection: String) -> some View {
        let filteredEmails = browserService.emails.filter { email in
            searchText.isEmpty ||
            email.subject.localizedCaseInsensitiveContains(searchText) ||
            email.sender.localizedCaseInsensitiveContains(searchText)
        }

        if browserService.isLoading {
            ProgressView("Loading emails...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredEmails.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No Emails" : "No Results",
                systemImage: "envelope",
                description: Text(searchText.isEmpty ? "This folder is empty" : "No emails match your search")
            )
        } else {
            List(filteredEmails, selection: $selectedEmail) { email in
                EmailRowView(email: email)
                    .tag(email)
            }
            .listStyle(.inset)
        }
    }

    private func folderIcon(for folder: String) -> String {
        let lower = folder.lowercased()
        if lower.contains("inbox") { return "tray.fill" }
        if lower.contains("sent") { return "paperplane.fill" }
        if lower.contains("draft") { return "doc.fill" }
        if lower.contains("trash") || lower.contains("deleted") { return "trash.fill" }
        if lower.contains("spam") || lower.contains("junk") { return "xmark.shield.fill" }
        if lower.contains("archive") { return "archivebox.fill" }
        return "folder.fill"
    }

    private func refreshEmails() {
        Task {
            await browserService.loadAccounts(from: backupManager.backupLocation)
            if let selection = selectedFolder {
                let parts = selection.split(separator: "/", maxSplits: 1)
                if parts.count == 2 {
                    await browserService.loadEmails(
                        account: String(parts[0]),
                        folder: String(parts[1]),
                        from: backupManager.backupLocation
                    )
                }
            }
        }
    }

    private func openInFinder() {
        guard let email = selectedEmail else { return }
        NSWorkspace.shared.selectFile(email.filePath, inFileViewerRootedAtPath: "")
    }
}

// MARK: - Email Row View

struct EmailRowView: View {
    let email: EmailFileInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(email.subject)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(email.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(email.sender)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(email.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Email Preview View

struct EmailPreviewView: View {
    let email: EmailFileInfo
    @State private var emailContent: String = ""
    @State private var isLoading = true
    @State private var headers: EmailHeaders?
    @State private var attachments: [EmailAttachmentInfo] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text(email.subject)
                    .font(.title2)
                    .fontWeight(.semibold)

                if let headers = headers {
                    HStack {
                        Text("From:")
                            .foregroundStyle(.secondary)
                        Text(headers.from)
                    }
                    .font(.subheadline)

                    if !headers.to.isEmpty {
                        HStack {
                            Text("To:")
                                .foregroundStyle(.secondary)
                            Text(headers.to)
                                .lineLimit(2)
                        }
                        .font(.subheadline)
                    }

                    HStack {
                        Text("Date:")
                            .foregroundStyle(.secondary)
                        Text(email.date, format: .dateTime)
                    }
                    .font(.subheadline)
                }

                // Attachments
                if !attachments.isEmpty {
                    Divider()
                    AttachmentsView(attachments: attachments, emailPath: email.filePath)
                }

                Divider()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            // Content
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(emailContent)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }

            Divider()

            // Actions
            HStack {
                Button(action: openEmail) {
                    Label("Open in Mail", systemImage: "envelope")
                }

                Button(action: revealInFinder) {
                    Label("Show in Finder", systemImage: "folder")
                }

                Spacer()

                Text(email.filePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .task {
            await loadEmailContent()
        }
    }

    private func loadEmailContent() async {
        isLoading = true

        // Read email file
        guard let data = FileManager.default.contents(atPath: email.filePath),
              let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            emailContent = "Unable to read email content"
            isLoading = false
            return
        }

        // Parse headers
        headers = parseHeaders(from: content)

        // Parse attachments
        attachments = parseAttachments(from: content)

        // Check for extracted attachments folder
        let emailURL = URL(fileURLWithPath: email.filePath)
        let folderName = emailURL.deletingPathExtension().lastPathComponent + "_attachments"
        let attachmentFolder = emailURL.deletingLastPathComponent().appendingPathComponent(folderName)

        // Also check the older naming convention
        let parts = emailURL.deletingPathExtension().lastPathComponent.components(separatedBy: "_")
        if parts.count >= 3 {
            let altFolderName = "\(parts[1])_\(parts[2])__\(parts.dropFirst(3).joined(separator: "_"))_attachments"
            let altAttachmentFolder = emailURL.deletingLastPathComponent().appendingPathComponent(altFolderName)
            if FileManager.default.fileExists(atPath: altAttachmentFolder.path) {
                let extractedAttachments = loadExtractedAttachments(from: altAttachmentFolder)
                attachments.append(contentsOf: extractedAttachments)
            }
        }

        if FileManager.default.fileExists(atPath: attachmentFolder.path) {
            let extractedAttachments = loadExtractedAttachments(from: attachmentFolder)
            attachments.append(contentsOf: extractedAttachments)
        }

        // Extract body (simplified - just show plain text portion)
        emailContent = extractBody(from: content)
        isLoading = false
    }

    private func loadExtractedAttachments(from folder: URL) -> [EmailAttachmentInfo] {
        var result: [EmailAttachmentInfo] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else {
            return result
        }

        for url in contents {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            result.append(EmailAttachmentInfo(
                filename: url.lastPathComponent,
                mimeType: mimeType(for: url.pathExtension),
                size: Int64(size),
                isExtracted: true,
                extractedPath: url.path
            ))
        }

        return result
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "zip": return "application/zip"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }

    private func parseAttachments(from content: String) -> [EmailAttachmentInfo] {
        var result: [EmailAttachmentInfo] = []

        // Look for Content-Disposition: attachment patterns
        let lines = content.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i].lowercased()

            if line.contains("content-disposition:") && line.contains("attachment") {
                var filename = ""
                var contentType = "application/octet-stream"

                // Check for filename in same line
                if let filenameMatch = lines[i].range(of: "filename=\"", options: .caseInsensitive) ??
                                       lines[i].range(of: "filename=", options: .caseInsensitive) {
                    let afterFilename = lines[i][filenameMatch.upperBound...]
                    if let endQuote = afterFilename.firstIndex(of: "\"") {
                        filename = String(afterFilename[..<endQuote])
                    } else if let endSemi = afterFilename.firstIndex(of: ";") {
                        filename = String(afterFilename[..<endSemi])
                    } else {
                        filename = String(afterFilename).trimmingCharacters(in: .whitespaces)
                    }
                }

                // Look backwards for Content-Type
                for j in stride(from: i - 1, through: max(0, i - 5), by: -1) {
                    if lines[j].lowercased().hasPrefix("content-type:") {
                        contentType = String(lines[j].dropFirst(13)).trimmingCharacters(in: .whitespaces)
                        if let semiIndex = contentType.firstIndex(of: ";") {
                            contentType = String(contentType[..<semiIndex])
                        }
                        break
                    }
                }

                if !filename.isEmpty {
                    // Decode RFC 2047 encoded filename if needed
                    let decodedFilename = decodeRFC2047(filename)
                    result.append(EmailAttachmentInfo(
                        filename: decodedFilename,
                        mimeType: contentType,
                        size: 0,  // Size not easily determinable from raw content
                        isExtracted: false,
                        extractedPath: nil
                    ))
                }
            }

            i += 1
        }

        return result
    }

    private func decodeRFC2047(_ text: String) -> String {
        // Basic RFC 2047 decoding for common cases
        var result = text

        // Pattern: =?charset?encoding?encoded_text?=
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]+)\?="#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: range)

            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let encodingRange = Range(match.range(at: 2), in: result),
                      let textRange = Range(match.range(at: 3), in: result) else { continue }

                let encoding = result[encodingRange].uppercased()
                let encodedText = String(result[textRange])

                var decoded = encodedText
                if encoding == "B" {
                    // Base64
                    if let data = Data(base64Encoded: encodedText),
                       let str = String(data: data, encoding: .utf8) {
                        decoded = str
                    }
                } else if encoding == "Q" {
                    // Quoted-printable
                    decoded = encodedText
                        .replacingOccurrences(of: "_", with: " ")
                        .replacingOccurrences(of: "=", with: "%")
                    if let unescaped = decoded.removingPercentEncoding {
                        decoded = unescaped
                    }
                }

                result.replaceSubrange(fullRange, with: decoded)
            }
        }

        return result
    }

    private func parseHeaders(from content: String) -> EmailHeaders {
        var from = ""
        var to = ""
        var subject = ""

        let lines = content.components(separatedBy: .newlines)
        var currentHeader = ""

        for line in lines {
            if line.isEmpty { break } // End of headers

            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                // Continuation of previous header
                currentHeader += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colonIndex = line.firstIndex(of: ":") {
                let headerName = String(line[..<colonIndex]).lowercased()
                let headerValue = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

                switch headerName {
                case "from": from = headerValue
                case "to": to = headerValue
                case "subject": subject = headerValue
                default: break
                }
                currentHeader = headerValue
            }
        }

        return EmailHeaders(from: from, to: to, subject: subject)
    }

    private func extractBody(from content: String) -> String {
        // Find the blank line that separates headers from body
        if let headerEnd = content.range(of: "\r\n\r\n") ?? content.range(of: "\n\n") {
            var body = String(content[headerEnd.upperBound...])

            // If it's multipart, try to find plain text part
            if body.contains("Content-Type: text/plain") {
                if let plainStart = body.range(of: "Content-Type: text/plain"),
                   let bodyStart = body[plainStart.upperBound...].range(of: "\n\n") ?? body[plainStart.upperBound...].range(of: "\r\n\r\n") {
                    let remainingContent = body[bodyStart.upperBound...]
                    // Find next boundary or end
                    if let boundaryEnd = remainingContent.range(of: "\n--") {
                        body = String(remainingContent[..<boundaryEnd.lowerBound])
                    } else {
                        body = String(remainingContent)
                    }
                }
            }

            // Basic cleanup
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)

            // Limit preview size
            if body.count > 10000 {
                body = String(body.prefix(10000)) + "\n\n[Content truncated...]"
            }

            return body
        }

        return "Unable to parse email body"
    }

    private func openEmail() {
        let url = URL(fileURLWithPath: email.filePath)
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder() {
        NSWorkspace.shared.selectFile(email.filePath, inFileViewerRootedAtPath: "")
    }
}

struct EmailHeaders {
    let from: String
    let to: String
    let subject: String
}

// MARK: - Attachment Info

struct EmailAttachmentInfo: Identifiable, Hashable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let size: Int64
    let isExtracted: Bool
    let extractedPath: String?

    var formattedSize: String {
        size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : ""
    }

    var icon: String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo.fill"
        case "doc", "docx": return "doc.text.fill"
        case "xls", "xlsx": return "tablecells.fill"
        case "ppt", "pptx": return "play.rectangle.fill"
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        case "mp3", "wav", "m4a", "aac": return "music.note"
        case "mp4", "mov", "avi", "mkv": return "video.fill"
        case "txt": return "doc.plaintext"
        case "html", "htm": return "globe"
        default: return "doc.fill"
        }
    }
}

// MARK: - Attachments View

struct AttachmentsView: View {
    let attachments: [EmailAttachmentInfo]
    let emailPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                Text("\(attachments.count) Attachment\(attachments.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(attachments) { attachment in
                        AttachmentItemView(attachment: attachment, emailPath: emailPath)
                    }
                }
            }
        }
    }
}

struct AttachmentItemView: View {
    let attachment: EmailAttachmentInfo
    let emailPath: String
    @State private var isHovering = false
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 80, height: 60)

                Image(systemName: attachment.icon)
                    .font(.title)
                    .foregroundStyle(attachment.isExtracted ? .blue : .secondary)
            }
            .overlay(alignment: .topTrailing) {
                if attachment.isExtracted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .offset(x: 4, y: -4)
                }
            }

            Text(attachment.filename)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)

            if !attachment.formattedSize.isEmpty {
                Text(attachment.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color(nsColor: .selectedControlColor).opacity(0.3) : Color.clear)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            openAttachment()
        }
        .contextMenu {
            if attachment.isExtracted {
                Button("Open") {
                    openAttachment()
                }

                Button("Show in Finder") {
                    if let path = attachment.extractedPath {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                }

                Divider()

                Button("Quick Look") {
                    if let path = attachment.extractedPath {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                }
            } else {
                Button("Save to Downloads...") {
                    saveAttachment()
                }

                Button("Open Email in Mail") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: emailPath))
                }
            }
        }
    }

    private func openAttachment() {
        if attachment.isExtracted, let path = attachment.extractedPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            // Open the email file - Mail.app will show attachments
            NSWorkspace.shared.open(URL(fileURLWithPath: emailPath))
        }
    }

    private func saveAttachment() {
        guard !attachment.isExtracted else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            // Extract attachment from email and save
            Task {
                await extractAndSave(to: url)
            }
        }
    }

    private func extractAndSave(to destinationURL: URL) async {
        // Read the email file
        guard let data = FileManager.default.contents(atPath: emailPath),
              let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return
        }

        // Find this attachment in the MIME content and extract it
        let attachmentData = extractAttachmentData(filename: attachment.filename, from: content)

        if let attachmentData = attachmentData {
            try? attachmentData.write(to: destinationURL)
            NSWorkspace.shared.selectFile(destinationURL.path, inFileViewerRootedAtPath: "")
        }
    }

    private func extractAttachmentData(filename: String, from content: String) -> Data? {
        // Find the MIME part for this attachment
        let lines = content.components(separatedBy: .newlines)
        var inAttachment = false
        var foundFilename = false
        var base64Content = ""
        var isBase64 = false

        for i in 0..<lines.count {
            let line = lines[i]
            let lowerLine = line.lowercased()

            if lowerLine.contains("content-disposition:") && lowerLine.contains("attachment") {
                if line.contains(filename) || lines[safe: i + 1]?.contains(filename) == true {
                    foundFilename = true
                }
            }

            if foundFilename && lowerLine.contains("content-transfer-encoding:") && lowerLine.contains("base64") {
                isBase64 = true
            }

            if foundFilename && isBase64 && line.isEmpty {
                inAttachment = true
                continue
            }

            if inAttachment {
                if line.hasPrefix("--") {
                    // End of MIME part
                    break
                }
                base64Content += line
            }
        }

        if !base64Content.isEmpty {
            return Data(base64Encoded: base64Content, options: .ignoreUnknownCharacters)
        }

        return nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Email File Info

struct EmailFileInfo: Identifiable, Hashable {
    let id: String
    let filePath: String
    let subject: String
    let sender: String
    let date: Date
    let size: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - Email Browser Service

@MainActor
class EmailBrowserService: ObservableObject {
    @Published var accounts: [String] = []
    @Published var foldersByAccount: [String: [String]] = [:]
    @Published var emails: [EmailFileInfo] = []
    @Published var isLoading = false

    private let fileManager = FileManager.default

    func folders(for account: String) -> [String] {
        foldersByAccount[account] ?? []
    }

    func loadAccounts(from backupLocation: URL) async {
        let contents = (try? fileManager.contentsOfDirectory(at: backupLocation, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        var loadedAccounts: [String] = []
        var loadedFolders: [String: [String]] = [:]

        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let accountName = url.lastPathComponent
                loadedAccounts.append(accountName)
                loadedFolders[accountName] = scanFolders(at: url)
            }
        }

        accounts = loadedAccounts.sorted()
        foldersByAccount = loadedFolders
    }

    private func scanFolders(at accountURL: URL, prefix: String = "") -> [String] {
        var folders: [String] = []

        guard let contents = try? fileManager.contentsOfDirectory(at: accountURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return folders
        }

        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir && !url.lastPathComponent.hasPrefix(".") {
                let folderName = prefix.isEmpty ? url.lastPathComponent : "\(prefix)/\(url.lastPathComponent)"

                // Check if this folder has .eml files
                let hasEmails = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                    .contains { $0.pathExtension == "eml" } ?? false

                if hasEmails {
                    folders.append(folderName)
                }

                // Recursively scan subfolders
                folders.append(contentsOf: scanFolders(at: url, prefix: folderName))
            }
        }

        return folders.sorted()
    }

    func loadEmails(account: String, folder: String, from backupLocation: URL) async {
        isLoading = true
        emails = []

        let folderURL = backupLocation
            .appendingPathComponent(account)
            .appendingPathComponent(folder)

        guard let contents = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            isLoading = false
            return
        }

        var loadedEmails: [EmailFileInfo] = []

        for url in contents where url.pathExtension == "eml" {
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(attrs?.fileSize ?? 0)
            let modDate = attrs?.contentModificationDate ?? Date()

            // Parse filename for metadata: <UID>_<timestamp>_<sender>.eml
            let filename = url.deletingPathExtension().lastPathComponent
            let parts = filename.components(separatedBy: "_")

            var subject = "(No Subject)"
            var sender = "Unknown"
            var emailDate = modDate

            if parts.count >= 3 {
                // Try to parse date from filename
                let dateStr = "\(parts[1])_\(parts[2])"
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                if let parsedDate = formatter.date(from: dateStr) {
                    emailDate = parsedDate
                }

                // Sender is everything after the second underscore
                sender = parts.dropFirst(3).joined(separator: "_").replacingOccurrences(of: "_", with: " ")
                if sender.isEmpty { sender = "Unknown" }
            }

            // Try to read subject from file headers (first few KB)
            if let handle = FileHandle(forReadingAtPath: url.path) {
                let headerData = handle.readData(ofLength: 4096)
                try? handle.close()

                if let headerStr = String(data: headerData, encoding: .utf8) ?? String(data: headerData, encoding: .ascii) {
                    // Extract subject
                    if let subjectRange = headerStr.range(of: "Subject: ", options: .caseInsensitive) {
                        let afterSubject = headerStr[subjectRange.upperBound...]
                        if let endOfLine = afterSubject.firstIndex(of: "\r") ?? afterSubject.firstIndex(of: "\n") {
                            subject = String(afterSubject[..<endOfLine])
                        }
                    }

                    // Extract from
                    if let fromRange = headerStr.range(of: "From: ", options: .caseInsensitive) {
                        let afterFrom = headerStr[fromRange.upperBound...]
                        if let endOfLine = afterFrom.firstIndex(of: "\r") ?? afterFrom.firstIndex(of: "\n") {
                            sender = String(afterFrom[..<endOfLine])
                        }
                    }
                }
            }

            loadedEmails.append(EmailFileInfo(
                id: url.path,
                filePath: url.path,
                subject: subject,
                sender: sender,
                date: emailDate,
                size: size
            ))
        }

        // Sort by date, newest first
        emails = loadedEmails.sorted { $0.date > $1.date }
        isLoading = false
    }
}

#Preview {
    EmailBrowserView()
        .environmentObject(BackupManager())
        .frame(width: 1000, height: 600)
}
