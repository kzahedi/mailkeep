import Foundation

/// Utility for parsing email headers from raw .eml data
struct EmailParser {

    /// Parse email metadata from raw email data
    static func parseMetadata(from data: Data) -> ParsedEmail? {
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        // Split headers from body (headers end at first empty line)
        let headerSection: String
        if let emptyLineRange = content.range(of: "\r\n\r\n") {
            headerSection = String(content[..<emptyLineRange.lowerBound])
        } else if let emptyLineRange = content.range(of: "\n\n") {
            headerSection = String(content[..<emptyLineRange.lowerBound])
        } else {
            headerSection = content
        }

        // Parse individual headers
        let from = parseHeader("From", in: headerSection)
        let subject = parseHeader("Subject", in: headerSection)
        let date = parseHeader("Date", in: headerSection)
        let messageId = parseHeader("Message-ID", in: headerSection) ?? parseHeader("Message-Id", in: headerSection)

        // Extract sender name from From header
        let senderInfo = parseSender(from: from)

        // Parse date
        let emailDate = parseDate(from: date)

        return ParsedEmail(
            messageId: messageId ?? UUID().uuidString,
            from: from ?? "Unknown",
            senderName: senderInfo.name,
            senderEmail: senderInfo.email,
            subject: subject ?? "(No Subject)",
            date: emailDate ?? Date()
        )
    }

    /// Parse a specific header value
    private static func parseHeader(_ name: String, in headers: String) -> String? {
        // Headers can be folded (continued on next line with whitespace)
        let pattern = "(?m)^\(name):\\s*(.+?)(?=\\r?\\n[^\\s]|\\r?\\n\\r?\\n|$)"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: headers, range: NSRange(headers.startIndex..., in: headers)),
              let valueRange = Range(match.range(at: 1), in: headers) else {
            return nil
        }

        // Clean up folded headers (remove CRLF + whitespace)
        var value = String(headers[valueRange])
        value = value.replacingOccurrences(of: "\r\n ", with: " ")
        value = value.replacingOccurrences(of: "\r\n\t", with: " ")
        value = value.replacingOccurrences(of: "\n ", with: " ")
        value = value.replacingOccurrences(of: "\n\t", with: " ")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // Decode RFC 2047 encoded-word strings (e.g., =?utf-8?q?...?=)
        value = decodeRFC2047(value)

        return value.isEmpty ? nil : value
    }

    /// Decode RFC 2047 encoded-word strings
    /// Format: =?charset?encoding?encoded_text?=
    /// encoding: Q = quoted-printable, B = base64
    private static func decodeRFC2047(_ input: String) -> String {
        let pattern = #"=\?([^?]+)\?([QqBb])\?([^?]*)\?="#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }

        var result = input
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))

        // Process matches in reverse order to preserve string indices
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
                // Quoted-printable decoding
                decodedData = decodeQuotedPrintable(encodedText, isHeader: true)
            } else if encoding == "b" {
                // Base64 decoding
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

        // Remove spaces between adjacent encoded words
        result = result.replacingOccurrences(of: "  ", with: " ")

        return result
    }

    /// Decode quoted-printable encoding
    private static func decodeQuotedPrintable(_ input: String, isHeader: Bool = false) -> Data? {
        var result = Data()
        var index = input.startIndex

        while index < input.endIndex {
            let char = input[index]

            if char == "=" && input.index(index, offsetBy: 2, limitedBy: input.endIndex) != nil {
                let hexStart = input.index(after: index)
                let hexEnd = input.index(hexStart, offsetBy: 2, limitedBy: input.endIndex) ?? input.endIndex
                let hex = String(input[hexStart..<hexEnd])

                if let byte = UInt8(hex, radix: 16) {
                    result.append(byte)
                    index = hexEnd
                    continue
                }
            } else if isHeader && char == "_" {
                // In headers, underscore represents space
                result.append(0x20)
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

    /// Parse sender name and email from From header
    /// Handles formats like:
    /// - "John Doe <john@example.com>"
    /// - "<john@example.com>"
    /// - "john@example.com"
    /// - "\"John Doe\" <john@example.com>"
    private static func parseSender(from: String?) -> (name: String, email: String) {
        guard let from = from else {
            return ("Unknown", "")
        }

        // Try to match "Name <email>" pattern
        let pattern = #"^(?:"?([^"<]+)"?\s*)?<?([^<>\s]+@[^<>\s]+)>?$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: from, range: NSRange(from.startIndex..., in: from)) {

            var name = ""
            var email = ""

            if let nameRange = Range(match.range(at: 1), in: from) {
                name = String(from[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let emailRange = Range(match.range(at: 2), in: from) {
                email = String(from[emailRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // If no name, use the part before @ in email
            if name.isEmpty && !email.isEmpty {
                name = email.components(separatedBy: "@").first ?? "Unknown"
            }

            return (name.isEmpty ? "Unknown" : name, email)
        }

        // Fallback: use the whole From header
        return (from, "")
    }

    /// Parse email date from various formats
    private static func parseDate(from dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }

        let formatters: [DateFormatter] = [
            createFormatter("EEE, d MMM yyyy HH:mm:ss Z"),      // RFC 2822
            createFormatter("EEE, d MMM yyyy HH:mm:ss z"),      // With timezone name
            createFormatter("d MMM yyyy HH:mm:ss Z"),           // Without day name
            createFormatter("EEE, dd MMM yyyy HH:mm:ss Z"),     // With leading zero
            createFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),          // ISO 8601
        ]

        // Clean up the date string
        var cleanDate = dateString
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove comments like (PDT)
        if let parenStart = cleanDate.range(of: "(") {
            cleanDate = String(cleanDate[..<parenStart.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        for formatter in formatters {
            if let date = formatter.date(from: cleanDate) {
                return date
            }
        }

        return nil
    }

    private static func createFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}

/// Parsed email metadata
struct ParsedEmail {
    let messageId: String
    let from: String
    let senderName: String
    let senderEmail: String
    let subject: String
    let date: Date
}
