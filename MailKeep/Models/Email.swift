import Foundation

struct Email: Identifiable, Hashable {
    let id: UUID
    let messageId: String
    let uid: UInt32
    let folder: String
    let subject: String
    let sender: String
    let senderEmail: String
    let date: Date
    let hasAttachments: Bool
    let attachmentCount: Int
    let size: Int64

    init(
        id: UUID = UUID(),
        messageId: String,
        uid: UInt32,
        folder: String,
        subject: String,
        sender: String,
        senderEmail: String,
        date: Date,
        hasAttachments: Bool = false,
        attachmentCount: Int = 0,
        size: Int64 = 0
    ) {
        self.id = id
        self.messageId = messageId
        self.uid = uid
        self.folder = folder
        self.subject = subject
        self.sender = sender
        self.senderEmail = senderEmail
        self.date = date
        self.hasAttachments = hasAttachments
        self.attachmentCount = attachmentCount
        self.size = size
    }

    /// Generate filename for this email
    /// Format: <UID>_<timestamp>_<sender>.eml
    func filename() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: date)
        let sanitizedSender = sender.sanitizedForFilename()
        return "\(uid)_\(timestamp)_\(sanitizedSender).eml"
    }

    /// Generate attachment folder name for this email
    func attachmentFolderName() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: date)
        let sanitizedSender = sender.sanitizedForFilename()
        return "\(timestamp)__\(sanitizedSender)_attachments"
    }
}

struct Attachment: Identifiable, Hashable {
    let id: UUID
    let filename: String
    let mimeType: String
    let size: Int64
    var isDownloaded: Bool

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        size: Int64,
        isDownloaded: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.isDownloaded = isDownloaded
    }
}

// MARK: - String Extension for Filename Sanitization

extension String {
    func sanitizedForFilename() -> String {
        // Replace common problematic characters
        var result = self
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "|", with: "-")

        // Remove any remaining non-alphanumeric characters except - and _
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        result = result.unicodeScalars.filter { allowedCharacters.contains($0) }.map { String($0) }.joined()

        // Truncate to 50 characters
        if result.count > 50 {
            result = String(result.prefix(50))
        }

        // Ensure not empty
        if result.isEmpty {
            result = "unknown"
        }

        return result
    }
}
