import Foundation
import os.log

/// Log levels for filtering log output
enum LogLevel: Int, Comparable, Codable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    var prefix: String {
        switch self {
        case .debug: return "[DEBUG]"
        case .info: return "[INFO]"
        case .warning: return "[WARN]"
        case .error: return "[ERROR]"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Service for writing detailed logs to file
actor LoggingService {
    static let shared = LoggingService()

    private let fileManager = FileManager.default
    private let maxLogSize: Int64 = Constants.maxLogFileSizeBytes
    private let maxLogFiles = Constants.maxLogFileCount
    private var logFileHandle: FileHandle?
    private let dateFormatter: DateFormatter
    private let osLog = OSLog(subsystem: "com.kzahedi.MailKeep", category: "app")

    @MainActor
    var logLevel: LogLevel {
        get { LogLevel(rawValue: UserDefaults.standard.integer(forKey: "LogLevel")) ?? .info }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "LogLevel") }
    }

    private var logDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MailKeep/Logs")
    }

    private var currentLogFile: URL {
        logDirectory.appendingPathComponent("imap-backup.log")
    }

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        Task {
            await setupLogDirectory()
        }
    }

    // MARK: - Setup

    private func setupLogDirectory() {
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            openLogFile()
        } catch {
            os_log("Failed to create log directory: %{public}@", log: osLog, type: .error, error.localizedDescription)
        }
    }

    private func openLogFile() {
        let logFile = currentLogFile

        if !fileManager.fileExists(atPath: logFile.path) {
            fileManager.createFile(atPath: logFile.path, contents: nil)
        }

        do {
            logFileHandle = try FileHandle(forWritingTo: logFile)
            logFileHandle?.seekToEndOfFile()
        } catch {
            os_log("Failed to open log file: %{public}@", log: osLog, type: .error, error.localizedDescription)
        }
    }

    // MARK: - Logging

    func log(_ message: String, level: LogLevel = .info, file: String = #file, function: String = #function, line: Int = #line) async {
        let currentLevel = await MainActor.run { logLevel }

        guard level >= currentLevel else { return }

        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "\(timestamp) \(level.prefix) [\(fileName):\(line)] \(function): \(message)\n"

        // Write to file
        if let data = logMessage.data(using: .utf8) {
            logFileHandle?.write(data)

            // Check if rotation needed
            await checkRotation()
        }

        // Also log to system console
        switch level {
        case .debug:
            os_log("%{public}@", log: osLog, type: .debug, message)
        case .info:
            os_log("%{public}@", log: osLog, type: .info, message)
        case .warning:
            os_log("%{public}@", log: osLog, type: .default, message)
        case .error:
            os_log("%{public}@", log: osLog, type: .error, message)
        }
    }

    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(message, level: .debug, file: file, function: function, line: line)
    }

    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(message, level: .info, file: file, function: function, line: line)
    }

    func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(message, level: .warning, file: file, function: function, line: line)
    }

    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(message, level: .error, file: file, function: function, line: line)
    }

    // MARK: - Log Rotation

    private func checkRotation() async {
        guard let attributes = try? fileManager.attributesOfItem(atPath: currentLogFile.path),
              let fileSize = attributes[.size] as? Int64,
              fileSize > maxLogSize else {
            return
        }

        await rotateLog()
    }

    private func rotateLog() async {
        logFileHandle?.closeFile()
        logFileHandle = nil

        // Rename current log to timestamped version
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let rotatedName = "imap-backup-\(timestamp).log"
        let rotatedURL = logDirectory.appendingPathComponent(rotatedName)

        do {
            try fileManager.moveItem(at: currentLogFile, to: rotatedURL)
        } catch {
            os_log("Failed to rotate log: %{public}@", log: osLog, type: .error, error.localizedDescription)
        }

        // Clean up old logs
        await cleanupOldLogs()

        // Open new log file
        openLogFile()
    }

    private func cleanupOldLogs() async {
        do {
            let logFiles = try fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.pathExtension == "log" && $0.lastPathComponent != "imap-backup.log" }
                .sorted { url1, url2 in
                    let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return date1 > date2
                }

            // Keep only maxLogFiles - 1 rotated logs (plus current)
            if logFiles.count >= maxLogFiles {
                for oldLog in logFiles.dropFirst(maxLogFiles - 1) {
                    try fileManager.removeItem(at: oldLog)
                }
            }
        } catch {
            os_log("Failed to cleanup old logs: %{public}@", log: osLog, type: .error, error.localizedDescription)
        }
    }

    // MARK: - Utility

    func getLogContents() async -> String {
        logFileHandle?.synchronizeFile()

        guard let data = fileManager.contents(atPath: currentLogFile.path),
              let contents = String(data: data, encoding: .utf8) else {
            return ""
        }
        return contents
    }

    func getLogFileURL() -> URL {
        currentLogFile
    }

    func getLogDirectoryURL() -> URL {
        logDirectory
    }

    func clearLogs() async {
        logFileHandle?.closeFile()
        logFileHandle = nil

        do {
            let logFiles = try fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "log" }

            for logFile in logFiles {
                try fileManager.removeItem(at: logFile)
            }
        } catch {
            os_log("Failed to clear logs: %{public}@", log: osLog, type: .error, error.localizedDescription)
        }

        openLogFile()
    }
}

// MARK: - Convenience global functions

func logDebug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    Task {
        await LoggingService.shared.debug(message, file: file, function: function, line: line)
    }
}

func logInfo(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    Task {
        await LoggingService.shared.info(message, file: file, function: function, line: line)
    }
}

func logWarning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    Task {
        await LoggingService.shared.warning(message, file: file, function: function, line: line)
    }
}

func logError(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    Task {
        await LoggingService.shared.error(message, file: file, function: function, line: line)
    }
}
