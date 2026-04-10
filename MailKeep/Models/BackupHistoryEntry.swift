import Foundation

/// A single backup history entry
struct BackupHistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let accountEmail: String
    let startTime: Date
    var endTime: Date?
    var status: BackupHistoryStatus
    var emailsDownloaded: Int
    var totalEmails: Int
    var bytesDownloaded: Int64
    var errors: [String]
    var foldersProcessed: Int

    init(
        id: UUID = UUID(),
        accountEmail: String,
        startTime: Date = Date()
    ) {
        self.id = id
        self.accountEmail = accountEmail
        self.startTime = startTime
        self.endTime = nil
        self.status = .inProgress
        self.emailsDownloaded = 0
        self.totalEmails = 0
        self.bytesDownloaded = 0
        self.errors = []
        self.foldersProcessed = 0
    }

    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    var durationFormatted: String {
        guard let duration = duration else { return "In progress..." }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "\(Int(duration))s"
    }

    var bytesFormatted: String {
        ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
    }
}

enum BackupHistoryStatus: String, Codable {
    case inProgress = "In Progress"
    case completed = "Completed"
    case completedWithErrors = "Completed with Errors"
    case failed = "Failed"
    case cancelled = "Cancelled"

    var icon: String {
        switch self {
        case .inProgress: return "arrow.clockwise.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .completedWithErrors: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .inProgress: return "blue"
        case .completed: return "green"
        case .completedWithErrors: return "orange"
        case .failed: return "red"
        case .cancelled: return "gray"
        }
    }
}
