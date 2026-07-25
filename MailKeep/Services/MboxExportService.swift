import Foundation

struct MboxExportSummary: Equatable {
    var exported: Int
    var skippedUnreadable: Int
}

/// Writes stored .eml files into a single mboxrd file (importable by
/// Apple Mail, Thunderbird, mutt, …). A backup you can't restore elsewhere
/// is a hope, not a backup — this is the "get my mail out" path.
actor MboxExportService {

    enum MboxExportError: LocalizedError {
        case cannotCreateDestination(String)
        var errorDescription: String? {
            switch self {
            case .cannotCreateDestination(let path):
                return "Cannot create export file at \(path)"
            }
        }
    }

    func export(emlFiles: [URL], to destination: URL,
                progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) throws -> MboxExportSummary {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw MboxExportError.cannotCreateDestination(destination.path)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var summary = MboxExportSummary(exported: 0, skippedUnreadable: 0)
        let total = emlFiles.count
        let asctime = DateFormatter()
        asctime.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        asctime.locale = Locale(identifier: "en_US_POSIX")

        for (index, file) in emlFiles.enumerated() {
            guard let raw = try? Data(contentsOf: file) else {
                summary.skippedUnreadable += 1
                progress?(index + 1, total)
                continue
            }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date()
            let separator = "From MAILER-DAEMON \(asctime.string(from: mtime))\n"
            try handle.write(contentsOf: Data(separator.utf8))
            try handle.write(contentsOf: Self.mboxrdBody(from: raw))
            summary.exported += 1
            progress?(index + 1, total)
        }
        return summary
    }

    /// Normalize CRLF/CR to LF, quote ^>*From_ lines, guarantee trailing
    /// newline plus one blank separator line. Operates on bytes so binary
    /// attachment payloads survive untouched apart from line endings.
    ///
    /// Splitting on 0x0A with `omittingEmptySubsequences: false` yields one
    /// element per line, including a trailing empty element when the data
    /// already ends in "\n" (that empty element re-emits as a bare newline,
    /// which becomes the message's terminating newline). We then append a
    /// second newline to create the blank line mbox uses to separate
    /// messages. Net effect versus the raw input: exactly one extra blank
    /// line after each message — legal mbox, and what the tests assert.
    static func mboxrdBody(from raw: Data) -> Data {
        var normalized = Data(capacity: raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            let byte = raw[i]
            if byte == 0x0D {                       // CR or CRLF → LF
                normalized.append(0x0A)
                let next = raw.index(after: i)
                i = (next < raw.endIndex && raw[next] == 0x0A) ? raw.index(after: next) : next
            } else {
                normalized.append(byte)
                i = raw.index(after: i)
            }
        }
        var out = Data(capacity: normalized.count + 64)
        for line in normalized.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var idx = line.startIndex
            while idx < line.endIndex, line[idx] == UInt8(ascii: ">") { idx = line.index(after: idx) }
            let restStartsWithFrom = line[idx...].starts(with: Data("From ".utf8))
            if restStartsWithFrom { out.append(UInt8(ascii: ">")) }
            out.append(contentsOf: line)
            out.append(0x0A)
        }
        if out.last != 0x0A { out.append(0x0A) }
        out.append(0x0A)
        return out
    }
}
