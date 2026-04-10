import Foundation

/// Represents the current state of a backup operation
struct BackupProgress: Identifiable {
    let id: UUID
    let accountId: UUID
    var status: BackupStatus
    var currentFolder: String
    var totalFolders: Int
    var processedFolders: Int
    var totalEmails: Int
    var downloadedEmails: Int
    var currentEmailSubject: String
    var bytesDownloaded: Int64
    var startTime: Date
    var errors: [BackupError]

    init(accountId: UUID) {
        self.id = UUID()
        self.accountId = accountId
        self.status = .idle
        self.currentFolder = ""
        self.totalFolders = 0
        self.processedFolders = 0
        self.totalEmails = 0
        self.downloadedEmails = 0
        self.currentEmailSubject = ""
        self.bytesDownloaded = 0
        self.startTime = Date()
        self.errors = []
    }

    var progress: Double {
        guard totalEmails > 0 else { return 0 }
        return Double(downloadedEmails) / Double(totalEmails)
    }

    var elapsedTime: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    var estimatedTimeRemaining: TimeInterval? {
        guard downloadedEmails > 0, progress > 0 else { return nil }
        let elapsed = elapsedTime
        let estimatedTotal = elapsed / progress
        return estimatedTotal - elapsed
    }

    var downloadSpeed: Double {
        guard elapsedTime > 0 else { return 0 }
        return Double(bytesDownloaded) / elapsedTime
    }
}

enum BackupStatus: String, Codable {
    case idle = "Idle"
    case connecting = "Connecting..."
    case fetchingFolders = "Fetching folders..."
    case counting = "Counting emails..."
    case scanning = "Scanning emails..."
    case downloading = "Downloading..."
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"

    var isActive: Bool {
        switch self {
        case .connecting, .fetchingFolders, .counting, .scanning, .downloading:
            return true
        default:
            return false
        }
    }
}

struct BackupError: Identifiable {
    let id: UUID
    let timestamp: Date
    let message: String
    let folder: String?
    let email: String?

    init(message: String, folder: String? = nil, email: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.message = message
        self.folder = folder
        self.email = email
    }
}
