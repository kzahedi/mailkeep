import Foundation

/// Service for extracting attachments from email files
actor AttachmentService {
    private let fileManager = FileManager.default

    /// Extracted attachment info
    struct Attachment {
        let filename: String
        let contentType: String
        let data: Data
    }

    /// Extract attachments from raw email data
    func extractAttachments(from emailData: Data) -> [Attachment] {
        guard let content = String(data: emailData, encoding: .utf8) ?? String(data: emailData, encoding: .isoLatin1) else {
            return []
        }

        var attachments: [Attachment] = []

        // Find the boundary for multipart messages
        guard let boundary = findBoundary(in: content) else {
            return []
        }

        // Split by boundary
        let parts = content.components(separatedBy: "--\(boundary)")

        for part in parts {
            // Skip preamble and epilogue
            if part.isEmpty || part.hasPrefix("--") { continue }

            // Parse headers and body of this part
            if let attachment = parseAttachmentPart(part) {
                attachments.append(attachment)
            }
        }

        return attachments
    }

    /// Extract attachments from an email file on disk
    func extractAttachments(from fileURL: URL) -> [Attachment] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return extractAttachments(from: data)
    }

    /// Save extracted attachments to a folder
    func saveAttachments(_ attachments: [Attachment], to folderURL: URL) throws -> [URL] {
        if !fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }

        var savedURLs: [URL] = []

        for attachment in attachments {
            let sanitizedFilename = attachment.filename.sanitizedForFilename()
            var fileURL = folderURL.appendingPathComponent(sanitizedFilename)

            // Handle duplicate filenames
            var counter = 1
            while fileManager.fileExists(atPath: fileURL.path) {
                let name = (sanitizedFilename as NSString).deletingPathExtension
                let ext = (sanitizedFilename as NSString).pathExtension
                fileURL = folderURL.appendingPathComponent("\(name)_\(counter).\(ext)")
                counter += 1
            }

            // Write to temp file first, then atomically move to final location
            let tempURL = fileURL.appendingPathExtension("tmp")
            try attachment.data.write(to: tempURL)
            try fileManager.moveItem(at: tempURL, to: fileURL)

            savedURLs.append(fileURL)
        }

        return savedURLs
    }

    // MARK: - Private Methods

    /// Find the MIME boundary from Content-Type header
    private func findBoundary(in content: String) -> String? {
        // Look for Content-Type: multipart/... boundary="..."
        let pattern = #"Content-Type:\s*multipart/[^;]+;\s*boundary="?([^"\r\n;]+)"?"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let boundaryRange = Range(match.range(at: 1), in: content) else {
            return nil
        }

        return String(content[boundaryRange]).trimmingCharacters(in: .whitespaces)
    }

    /// Parse a MIME part and extract attachment if it is one
    private func parseAttachmentPart(_ part: String) -> Attachment? {
        // Split headers from body
        let headerBodySplit: String.Index
        if let range = part.range(of: "\r\n\r\n") {
            headerBodySplit = range.upperBound
        } else if let range = part.range(of: "\n\n") {
            headerBodySplit = range.upperBound
        } else {
            return nil
        }

        let headers = String(part[..<headerBodySplit])
        let body = String(part[headerBodySplit...]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if this is an attachment
        let contentDisposition = parseHeader("Content-Disposition", in: headers) ?? ""
        let contentType = parseHeader("Content-Type", in: headers) ?? "application/octet-stream"
        let contentTransferEncoding = parseHeader("Content-Transfer-Encoding", in: headers) ?? ""

        // Extract filename from Content-Disposition or Content-Type
        var filename = extractFilename(from: contentDisposition) ?? extractFilename(from: contentType)

        // If no filename, check if it's explicitly marked as attachment
        if filename == nil || filename!.isEmpty {
            if contentDisposition.lowercased().contains("attachment") {
                filename = "attachment_\(UUID().uuidString.prefix(8))"
            } else {
                return nil
            }
        }

        // Decode the body based on Content-Transfer-Encoding
        guard let decodedData = decodeBody(body, encoding: contentTransferEncoding.lowercased()) else {
            return nil
        }

        return Attachment(
            filename: filename ?? "unknown",
            contentType: contentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? "application/octet-stream",
            data: decodedData
        )
    }

    /// Parse a header value from headers string
    private func parseHeader(_ name: String, in headers: String) -> String? {
        let pattern = "(?m)^\(name):\\s*(.+?)(?=\\r?\\n[^\\s\\t]|\\r?\\n\\r?\\n|$)"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: headers, range: NSRange(headers.startIndex..., in: headers)),
              let valueRange = Range(match.range(at: 1), in: headers) else {
            return nil
        }

        var value = String(headers[valueRange])
        // Unfold headers
        value = value.replacingOccurrences(of: "\r\n ", with: " ")
        value = value.replacingOccurrences(of: "\r\n\t", with: " ")
        value = value.replacingOccurrences(of: "\n ", with: " ")
        value = value.replacingOccurrences(of: "\n\t", with: " ")

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract filename from Content-Disposition or Content-Type header
    private func extractFilename(from header: String) -> String? {
        // Try filename*= (RFC 5987 encoded)
        if let range = header.range(of: #"filename\*\s*=\s*[^;]+"#, options: .regularExpression) {
            let value = String(header[range])
            if let encoded = value.components(separatedBy: "=").last {
                return decodeRFC5987(encoded.trimmingCharacters(in: .whitespaces))
            }
        }

        // Try filename= (regular)
        let patterns = [
            #"filename\s*=\s*"([^"]+)""#,  // filename="value"
            #"filename\s*=\s*'([^']+)'"#,  // filename='value'
            #"filename\s*=\s*([^\s;]+)"#   // filename=value
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
               let valueRange = Range(match.range(at: 1), in: header) {
                var filename = String(header[valueRange])
                // Decode RFC 2047 if present
                filename = decodeRFC2047(filename)
                return filename
            }
        }

        // Try name= in Content-Type
        let namePatterns = [
            #"name\s*=\s*"([^"]+)""#,
            #"name\s*=\s*'([^']+)'"#,
            #"name\s*=\s*([^\s;]+)"#
        ]

        for pattern in namePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
               let valueRange = Range(match.range(at: 1), in: header) {
                var filename = String(header[valueRange])
                filename = decodeRFC2047(filename)
                return filename
            }
        }

        return nil
    }

    /// Decode RFC 5987 encoded filename (charset'language'encoded_value)
    private func decodeRFC5987(_ encoded: String) -> String {
        let parts = encoded.components(separatedBy: "'")
        guard parts.count >= 3 else { return encoded }

        let charset = parts[0].lowercased()
        let encodedValue = parts[2...].joined(separator: "'")

        // URL decode the value
        var decoded = encodedValue.removingPercentEncoding ?? encodedValue

        // Handle charset if not UTF-8
        if charset != "utf-8" && charset != "utf8" {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let data = encodedValue.removingPercentEncoding?.data(using: .isoLatin1),
                   let converted = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                    decoded = converted
                }
            }
        }

        return decoded
    }

    /// Decode RFC 2047 encoded strings
    private func decodeRFC2047(_ input: String) -> String {
        let pattern = #"=\?([^?]+)\?([QqBb])\?([^?]*)\?="#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }

        var result = input
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let charsetRange = Range(match.range(at: 1), in: result),
                  let encodingRange = Range(match.range(at: 2), in: result),
                  let textRange = Range(match.range(at: 3), in: result) else {
                continue
            }

            let charset = String(result[charsetRange]).lowercased()
            let encoding = String(result[encodingRange]).lowercased()
            let encodedText = String(result[textRange])

            var decodedData: Data?

            if encoding == "q" {
                decodedData = decodeQuotedPrintable(encodedText, isHeader: true)
            } else if encoding == "b" {
                decodedData = Data(base64Encoded: encodedText)
            }

            if let data = decodedData {
                let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)

                if let decoded = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                    result.replaceSubrange(fullRange, with: decoded)
                } else if let decoded = String(data: data, encoding: .utf8) {
                    result.replaceSubrange(fullRange, with: decoded)
                }
            }
        }

        return result
    }

    /// Decode quoted-printable encoding
    private func decodeQuotedPrintable(_ input: String, isHeader: Bool = false) -> Data? {
        var result = Data()
        var index = input.startIndex

        while index < input.endIndex {
            let char = input[index]

            if char == "=" {
                let next1 = input.index(after: index)
                if next1 < input.endIndex {
                    let next2 = input.index(after: next1)
                    if next2 <= input.endIndex {
                        let hex = String(input[next1..<next2])
                        if let byte = UInt8(hex, radix: 16) {
                            result.append(byte)
                            index = next2
                            continue
                        }
                    }
                }
            } else if isHeader && char == "_" {
                result.append(0x20)  // Space
                index = input.index(after: index)
                continue
            }

            if let byte = String(char).data(using: .utf8) {
                result.append(byte)
            }
            index = input.index(after: index)
        }

        return result
    }

    /// Decode body based on Content-Transfer-Encoding
    private func decodeBody(_ body: String, encoding: String) -> Data? {
        switch encoding {
        case "base64":
            // Remove whitespace and decode
            let cleaned = body.replacingOccurrences(of: "\r", with: "")
                              .replacingOccurrences(of: "\n", with: "")
                              .replacingOccurrences(of: " ", with: "")
            return Data(base64Encoded: cleaned)

        case "quoted-printable":
            return decodeQuotedPrintable(body)

        case "7bit", "8bit", "binary":
            return body.data(using: .utf8) ?? body.data(using: .isoLatin1)

        default:
            return body.data(using: .utf8) ?? body.data(using: .isoLatin1)
        }
    }
}

/// Settings for attachment extraction
struct AttachmentExtractionSettings: Codable {
    var isEnabled: Bool = false
    var createSubfolderPerEmail: Bool = true

    static let `default` = AttachmentExtractionSettings()
}

/// Global attachment extraction settings manager
@MainActor
class AttachmentExtractionManager: ObservableObject {
    static let shared = AttachmentExtractionManager()

    @Published var settings: AttachmentExtractionSettings {
        didSet { saveSettings() }
    }

    private let settingsKey = "AttachmentExtractionSettings"

    private init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let settings = try? JSONDecoder().decode(AttachmentExtractionSettings.self, from: data) {
            self.settings = settings
        } else {
            self.settings = AttachmentExtractionSettings.default
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }
}
