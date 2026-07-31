import Foundation

/// Centralized constants for the application
enum Constants {

    // MARK: - File Size Thresholds

    /// Default threshold for streaming large emails to disk (10 MB)
    static let defaultStreamingThresholdBytes = 10 * 1024 * 1024

    /// Maximum email size to download (50 MB)
    static let maxEmailSizeBytes = 50 * 1024 * 1024

    /// Maximum header size to read for search optimization (32 KB)
    static let maxHeaderSizeForSearch = 32 * 1024

    // MARK: - Logging

    /// Maximum log file size before rotation (10 MB)
    static let maxLogFileSizeBytes: Int64 = 10 * 1024 * 1024

    /// Maximum number of rotated log files to keep
    static let maxLogFileCount = 5

    // MARK: - Timing

    /// Nanoseconds in one second (for Task.sleep calculations)
    static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    /// Nanoseconds in one millisecond
    static let nanosecondsPerMillisecond: UInt64 = 1_000_000

    // MARK: - Retry Configuration

    /// Maximum number of retry attempts for failed operations
    static let maxRetryAttempts = 3

    /// Base delay for exponential backoff (1 second)
    static let baseRetryDelaySeconds: Double = 1.0

    // MARK: - IMAP Configuration

    /// Default IMAP port for TLS connections
    static let defaultIMAPPort = 993

    /// UID validity value for mock testing
    static let mockUIDValidity: UInt32 = 12345

    /// Default watchdog timeout for IMAP read operations (readResponse and raw
    /// receive loops) — if a pending read never completes within this window,
    /// the connection is force-cancelled so the awaiting continuation resumes
    /// with an error instead of hanging the backup task forever.
    static let imapReadTimeoutSeconds: TimeInterval = 120

    /// Default watchdog timeout for the initial IMAP connect() handshake.
    static let imapConnectTimeoutSeconds: TimeInterval = 30
}
