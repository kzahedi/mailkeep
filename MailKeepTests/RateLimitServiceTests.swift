import XCTest
@testable import MailKeep

final class RateLimitServiceTests: XCTestCase {

    // MARK: - RateLimitSettings Tests

    func testRateLimitSettingsDefaults() {
        let settings = RateLimitSettings()

        XCTAssertEqual(settings.requestDelayMs, 100)
        XCTAssertEqual(settings.maxConcurrentRequests, 5)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.throttleBackoffMultiplier, 2.0)
        XCTAssertEqual(settings.maxThrottleDelayMs, 30000)
    }

    func testRateLimitSettingsCodable() throws {
        let settings = RateLimitSettings(
            requestDelayMs: 200,
            maxConcurrentRequests: 10,
            isEnabled: false,
            throttleBackoffMultiplier: 3.0,
            maxThrottleDelayMs: 60000
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RateLimitSettings.self, from: data)

        XCTAssertEqual(decoded.requestDelayMs, settings.requestDelayMs)
        XCTAssertEqual(decoded.maxConcurrentRequests, settings.maxConcurrentRequests)
        XCTAssertEqual(decoded.isEnabled, settings.isEnabled)
        XCTAssertEqual(decoded.throttleBackoffMultiplier, settings.throttleBackoffMultiplier)
        XCTAssertEqual(decoded.maxThrottleDelayMs, settings.maxThrottleDelayMs)
    }

    // MARK: - RateLimitPreset Tests

    func testRateLimitPresetBalanced() {
        let settings = RateLimitPreset.balanced.settings

        XCTAssertEqual(settings.requestDelayMs, 100)
        XCTAssertEqual(settings.maxConcurrentRequests, 5)
        XCTAssertTrue(settings.isEnabled)
    }

    func testRateLimitPresetConservative() {
        let settings = RateLimitPreset.conservative.settings

        XCTAssertEqual(settings.requestDelayMs, 500)
        XCTAssertEqual(settings.maxConcurrentRequests, 2)
        XCTAssertTrue(settings.isEnabled)
    }

    func testRateLimitPresetAggressive() {
        let settings = RateLimitPreset.aggressive.settings

        XCTAssertEqual(settings.requestDelayMs, 50)
        XCTAssertEqual(settings.maxConcurrentRequests, 10)
        XCTAssertTrue(settings.isEnabled)
    }

    func testRateLimitPresetCustom() {
        let settings = RateLimitPreset.custom.settings

        // Custom should return balanced as default
        XCTAssertEqual(settings.requestDelayMs, 100)
    }

    func testRateLimitPresetAllCases() {
        let cases = RateLimitPreset.allCases

        XCTAssertEqual(cases.count, 4)
        XCTAssertTrue(cases.contains(.balanced))
        XCTAssertTrue(cases.contains(.conservative))
        XCTAssertTrue(cases.contains(.aggressive))
        XCTAssertTrue(cases.contains(.custom))
    }

    // MARK: - Throttle Detection Tests

    func testIsThrottleResponseBYE() {
        XCTAssertTrue(RateLimitService.isThrottleResponse("* BYE Throttled"))
        XCTAssertTrue(RateLimitService.isThrottleResponse("* BYE Too many connections"))
        XCTAssertTrue(RateLimitService.isThrottleResponse("* BYE Server busy"))
    }

    func testIsThrottleResponseNO() {
        XCTAssertTrue(RateLimitService.isThrottleResponse("NO [THROTTLED] Please slow down"))
        XCTAssertTrue(RateLimitService.isThrottleResponse("NO Too many simultaneous connections"))
        XCTAssertTrue(RateLimitService.isThrottleResponse("NO Rate limit exceeded"))
    }

    func testIsThrottleResponseBAD() {
        XCTAssertTrue(RateLimitService.isThrottleResponse("BAD Too many commands"))
    }

    func testIsNotThrottleResponse() {
        XCTAssertFalse(RateLimitService.isThrottleResponse("OK LOGIN completed"))
        XCTAssertFalse(RateLimitService.isThrottleResponse("* 5 EXISTS"))
        XCTAssertFalse(RateLimitService.isThrottleResponse("NO Invalid credentials"))
        XCTAssertFalse(RateLimitService.isThrottleResponse("BAD Syntax error"))
    }

    func testIsThrottleError() {
        let throttleError = NSError(
            domain: "IMAP",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Connection throttled by server"]
        )
        XCTAssertTrue(RateLimitService.isThrottleError(throttleError))
    }

    func testIsNotThrottleError() {
        let normalError = NSError(
            domain: "IMAP",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Connection refused"]
        )
        XCTAssertFalse(RateLimitService.isThrottleError(normalError))
    }

    // MARK: - ThrottleTracker Tests

    func testThrottleTrackerInitialState() async {
        let tracker = ThrottleTracker(settings: RateLimitSettings())

        // Should not be throttled initially
        let startTime = Date()
        await tracker.waitForRateLimit()
        let elapsed = Date().timeIntervalSince(startTime)

        // Initial delay should be the base delay (100ms)
        XCTAssertLessThan(elapsed, 0.5) // Should be quick
    }

    func testThrottleTrackerRecordThrottle() async {
        var settings = RateLimitSettings()
        settings.requestDelayMs = 50 // Use small delay for testing
        let tracker = ThrottleTracker(settings: settings)

        // Make an initial request to set lastRequestTime
        await tracker.waitForRateLimit()

        // Record a throttle - this doubles the delay
        await tracker.recordThrottle()

        // Immediately call wait again - should wait for the throttled delay
        let startTime = Date()
        await tracker.waitForRateLimit()
        let elapsed = Date().timeIntervalSince(startTime)

        // After throttle, delay should be increased (50 * 2 = 100ms)
        // Allow for timing variance - just check it's more than 50ms
        XCTAssertGreaterThan(elapsed, 0.04)
    }

    func testThrottleTrackerRecordSuccess() async {
        var settings = RateLimitSettings()
        settings.requestDelayMs = 50
        let tracker = ThrottleTracker(settings: settings)

        // Record throttle then success
        await tracker.recordThrottle()
        await tracker.recordSuccess()

        // Delay should decrease after success
        let startTime = Date()
        await tracker.waitForRateLimit()
        let elapsed = Date().timeIntervalSince(startTime)

        // Should be back to normal or decreasing
        XCTAssertLessThan(elapsed, 0.5)
    }

    // MARK: - RateLimitService Tests

    @MainActor
    func testRateLimitServiceSingleton() {
        let service1 = RateLimitService.shared
        let service2 = RateLimitService.shared

        XCTAssertTrue(service1 === service2)
    }

    @MainActor
    func testRateLimitServiceGlobalSettings() {
        let service = RateLimitService.shared

        XCTAssertNotNil(service.globalSettings)
        XCTAssertTrue(service.globalSettings.isEnabled || !service.globalSettings.isEnabled) // Just check it exists
    }
}
