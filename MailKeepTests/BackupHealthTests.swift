import XCTest
@testable import MailKeep

@MainActor
final class BackupHealthTests: XCTestCase {
    var tempDir: URL!
    var service: BackupHistoryService!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupHealthTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = BackupHistoryService(directory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func record(_ email: String, _ status: BackupHistoryStatus) {
        let id = service.startEntry(for: email)
        service.completeEntry(id: id, status: status)
    }

    func testHealthWithNoEntriesIsCleanSlate() {
        let health = service.health(for: "nobody@example.com")
        XCTAssertNil(health.lastSuccess)
        XCTAssertEqual(health.consecutiveFailures, 0)
    }

    func testConsecutiveFailuresCountFromNewestUntilLastSuccess() {
        record("a@example.com", .completed)   // older
        record("a@example.com", .failed)
        record("a@example.com", .failed)      // newest
        let health = service.health(for: "a@example.com")
        XCTAssertEqual(health.consecutiveFailures, 2)
        XCTAssertNotNil(health.lastSuccess)
    }

    func testSuccessResetsFailureCount() {
        record("a@example.com", .failed)
        record("a@example.com", .completedWithErrors)  // newest — counts as success
        let health = service.health(for: "a@example.com")
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertNotNil(health.lastSuccess)
    }

    func testCancelledAndInProgressAreIgnored() {
        record("a@example.com", .failed)
        record("a@example.com", .cancelled)
        _ = service.startEntry(for: "a@example.com")   // stays .inProgress
        let health = service.health(for: "a@example.com")
        XCTAssertEqual(health.consecutiveFailures, 1)
    }

    func testHealthIsPerAccount() {
        record("a@example.com", .failed)
        record("b@example.com", .completed)
        XCTAssertEqual(service.health(for: "a@example.com").consecutiveFailures, 1)
        XCTAssertEqual(service.health(for: "b@example.com").consecutiveFailures, 0)
    }

    // MARK: - Health Notification Gate Tests

    func testHealthNotificationGateAllowsFirstSend() {
        XCTAssertTrue(NotificationService.shouldSendHealthNotification(
            lastSent: nil, now: Date(), minInterval: 86_400))
    }

    func testHealthNotificationGateBlocksWithin24h() {
        let now = Date()
        XCTAssertFalse(NotificationService.shouldSendHealthNotification(
            lastSent: now.addingTimeInterval(-3_600), now: now, minInterval: 86_400))
    }

    func testHealthNotificationGateAllowsAfter24h() {
        let now = Date()
        XCTAssertTrue(NotificationService.shouldSendHealthNotification(
            lastSent: now.addingTimeInterval(-90_000), now: now, minInterval: 86_400))
    }

    func testNotifyRepeatedFailuresRecordsSendTime() {
        let key = "TestHealthNotify-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        NotificationService.shared.notifyRepeatedFailures(
            account: "a@example.com", consecutiveFailures: 2, lastError: "auth failed",
            defaultsKey: key)
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
        XCTAssertNotNil(dict?["a@example.com"])
    }
}
