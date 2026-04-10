import Foundation
import Combine

/// Rate limit configuration for an account
struct RateLimitSettings: Codable, Hashable {
    /// Minimum delay between requests in milliseconds
    var requestDelayMs: Int = 100

    /// Maximum concurrent connections (not used yet, for future)
    var maxConcurrentRequests: Int = 5

    /// Whether rate limiting is enabled
    var isEnabled: Bool = true

    /// Backoff multiplier when throttled
    var throttleBackoffMultiplier: Double = 2.0

    /// Maximum delay after throttling (in milliseconds)
    var maxThrottleDelayMs: Int = 30000

    static let `default` = RateLimitSettings()

    /// Preset for conservative rate limiting (slow but safe)
    static let conservative = RateLimitSettings(
        requestDelayMs: 500,
        maxConcurrentRequests: 2,
        isEnabled: true,
        throttleBackoffMultiplier: 3.0,
        maxThrottleDelayMs: 60000
    )

    /// Preset for aggressive rate limiting (fast but may hit limits)
    static let aggressive = RateLimitSettings(
        requestDelayMs: 50,
        maxConcurrentRequests: 10,
        isEnabled: true,
        throttleBackoffMultiplier: 1.5,
        maxThrottleDelayMs: 10000
    )
}

/// Tracks throttling state for a connection
actor ThrottleTracker {
    private var currentDelayMs: Int
    private var baseDelayMs: Int
    private var maxDelayMs: Int
    private var backoffMultiplier: Double
    private var consecutiveThrottles: Int = 0
    private var lastRequestTime: Date?

    init(settings: RateLimitSettings) {
        self.baseDelayMs = settings.requestDelayMs
        self.currentDelayMs = settings.requestDelayMs
        self.maxDelayMs = settings.maxThrottleDelayMs
        self.backoffMultiplier = settings.throttleBackoffMultiplier
    }

    /// Wait for rate limit before proceeding
    func waitForRateLimit() async {
        // Calculate time since last request
        if let lastTime = lastRequestTime {
            let elapsed = Date().timeIntervalSince(lastTime) * 1000  // in ms
            let remainingDelay = Double(currentDelayMs) - elapsed

            if remainingDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(remainingDelay) * Constants.nanosecondsPerMillisecond)
                } catch {
                    // Task cancelled, just continue
                }
            }
        }

        lastRequestTime = Date()
    }

    /// Called when server indicates throttling
    func recordThrottle() {
        consecutiveThrottles += 1

        // Exponential backoff
        let newDelay = Double(currentDelayMs) * backoffMultiplier
        currentDelayMs = min(Int(newDelay), maxDelayMs)

        logWarning("Rate limit throttle detected. Increasing delay to \(currentDelayMs)ms (throttle count: \(consecutiveThrottles))")
    }

    /// Called on successful request
    func recordSuccess() {
        // Gradually reduce delay after successful requests
        if consecutiveThrottles > 0 {
            consecutiveThrottles = max(0, consecutiveThrottles - 1)
        }

        // Slowly return to base delay
        if currentDelayMs > baseDelayMs && consecutiveThrottles == 0 {
            currentDelayMs = max(baseDelayMs, Int(Double(currentDelayMs) * 0.9))
        }
    }

    /// Reset throttle state
    func reset() {
        consecutiveThrottles = 0
        currentDelayMs = baseDelayMs
    }

    /// Get current effective delay
    func getCurrentDelay() -> Int {
        return currentDelayMs
    }

    /// Update settings
    func updateSettings(_ settings: RateLimitSettings) {
        self.baseDelayMs = settings.requestDelayMs
        self.maxDelayMs = settings.maxThrottleDelayMs
        self.backoffMultiplier = settings.throttleBackoffMultiplier

        // Don't reduce current delay below new base
        if currentDelayMs < baseDelayMs {
            currentDelayMs = baseDelayMs
        }
    }
}

/// Notification sent when rate limit settings change
struct RateLimitSettingsChange {
    /// The account ID affected, or nil for global settings
    let accountId: UUID?
    /// The new settings
    let settings: RateLimitSettings
}

/// Service for managing rate limits across accounts
@MainActor
class RateLimitService: ObservableObject {
    static let shared = RateLimitService()

    /// Publisher for settings changes - BackupManager can observe this
    let settingsDidChange = PassthroughSubject<RateLimitSettingsChange, Never>()

    /// Global default settings
    @Published var globalSettings: RateLimitSettings {
        didSet {
            saveSettings()
            // Notify observers of global settings change
            settingsDidChange.send(RateLimitSettingsChange(accountId: nil, settings: globalSettings))
        }
    }

    /// Per-account settings (keyed by account ID)
    @Published var accountSettings: [UUID: RateLimitSettings] = [:] {
        didSet { saveSettings() }
    }

    /// Active throttle trackers keyed by server hostname
    /// Multiple accounts on the same server share the same tracker
    private var serverTrackers: [String: ThrottleTracker] = [:]

    private let settingsKey = "RateLimitSettings"
    private let accountSettingsKey = "RateLimitAccountSettings"

    private init() {
        // Load global settings
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let settings = try? JSONDecoder().decode(RateLimitSettings.self, from: data) {
            self.globalSettings = settings
        } else {
            self.globalSettings = RateLimitSettings.default
        }

        // Load per-account settings
        if let data = UserDefaults.standard.data(forKey: accountSettingsKey),
           let settings = try? JSONDecoder().decode([UUID: RateLimitSettings].self, from: data) {
            self.accountSettings = settings
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(globalSettings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
        if let data = try? JSONEncoder().encode(accountSettings) {
            UserDefaults.standard.set(data, forKey: accountSettingsKey)
        }
    }

    // MARK: - Settings Access

    /// Get effective settings for an account (account-specific or global)
    func getSettings(for accountId: UUID) -> RateLimitSettings {
        return accountSettings[accountId] ?? globalSettings
    }

    /// Set account-specific settings
    func setSettings(_ settings: RateLimitSettings, for accountId: UUID) {
        accountSettings[accountId] = settings
        // Notify observers of account-specific settings change
        settingsDidChange.send(RateLimitSettingsChange(accountId: accountId, settings: settings))
    }

    /// Remove account-specific settings (use global)
    func removeSettings(for accountId: UUID) {
        accountSettings.removeValue(forKey: accountId)
    }

    /// Check if account has custom settings
    func hasCustomSettings(for accountId: UUID) -> Bool {
        return accountSettings[accountId] != nil
    }

    // MARK: - Throttle Tracking (Per-Server)

    /// Get or create throttle tracker for a server
    /// Multiple accounts on the same server share the same tracker
    func getTracker(forServer server: String, accountId: UUID) -> ThrottleTracker {
        let serverKey = server.lowercased()

        if let tracker = serverTrackers[serverKey] {
            return tracker
        }

        // Use account settings for initial configuration, fall back to global
        let settings = getSettings(for: accountId)
        let tracker = ThrottleTracker(settings: settings)
        serverTrackers[serverKey] = tracker
        return tracker
    }

    /// Legacy method for backward compatibility - uses global settings
    func getTracker(for accountId: UUID) -> ThrottleTracker {
        // This should not be used anymore, but keep for compatibility
        let settings = getSettings(for: accountId)
        return ThrottleTracker(settings: settings)
    }

    /// Reset throttle state for a server
    func resetThrottle(forServer server: String) async {
        let serverKey = server.lowercased()
        await serverTrackers[serverKey]?.reset()
    }

    /// Reset all throttle states
    func resetAllThrottles() async {
        for tracker in serverTrackers.values {
            await tracker.reset()
        }
    }

    /// Get current delay for a server (for logging/display)
    func getCurrentDelay(forServer server: String) async -> Int? {
        let serverKey = server.lowercased()
        return await serverTrackers[serverKey]?.getCurrentDelay()
    }

    // MARK: - Throttle Detection

    /// Check if a response indicates throttling
    nonisolated static func isThrottleResponse(_ response: String) -> Bool {
        let throttleIndicators = [
            "THROTTLE",
            "OVERQUOTA",
            "TOO MANY",
            "RATE LIMIT",
            "SLOW DOWN",
            "TRY AGAIN LATER",
            "TEMPORARY",
            "BUSY"
        ]

        let upperResponse = response.uppercased()
        return throttleIndicators.contains { upperResponse.contains($0) }
    }

    /// Check if an error indicates throttling
    nonisolated static func isThrottleError(_ error: Error) -> Bool {
        let errorDesc = error.localizedDescription.uppercased()
        return isThrottleResponse(errorDesc)
    }
}

/// Preset names for UI
enum RateLimitPreset: String, CaseIterable {
    case custom = "Custom"
    case balanced = "Balanced"
    case conservative = "Conservative"
    case aggressive = "Aggressive"

    var settings: RateLimitSettings {
        switch self {
        case .custom:
            return RateLimitSettings.default
        case .balanced:
            return RateLimitSettings.default
        case .conservative:
            return RateLimitSettings.conservative
        case .aggressive:
            return RateLimitSettings.aggressive
        }
    }

    var description: String {
        switch self {
        case .custom:
            return "Custom settings"
        case .balanced:
            return "100ms delay, good for most servers"
        case .conservative:
            return "500ms delay, safe for strict servers"
        case .aggressive:
            return "50ms delay, fast but may trigger limits"
        }
    }
}
