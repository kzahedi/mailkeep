import XCTest
@testable import MailKeep

final class RetentionServiceTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - RetentionPolicy Tests

    func testRetentionPolicyKeepAll() {
        let policy = RetentionPolicy.keepAll

        XCTAssertEqual(policy.rawValue, "Keep All")
    }

    func testRetentionPolicyByAge() {
        let policy = RetentionPolicy.byAge

        XCTAssertEqual(policy.rawValue, "By Age")
    }

    func testRetentionPolicyByCount() {
        let policy = RetentionPolicy.byCount

        XCTAssertEqual(policy.rawValue, "By Count")
    }

    func testRetentionPolicyAllCases() {
        let allCases = RetentionPolicy.allCases

        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.keepAll))
        XCTAssertTrue(allCases.contains(.byAge))
        XCTAssertTrue(allCases.contains(.byCount))
    }

    func testRetentionPolicyCodable() throws {
        for policy in RetentionPolicy.allCases {
            let encoder = JSONEncoder()
            let data = try encoder.encode(policy)

            let decoder = JSONDecoder()
            let decoded = try decoder.decode(RetentionPolicy.self, from: data)

            XCTAssertEqual(decoded, policy)
        }
    }

    // MARK: - RetentionSettings Tests

    func testRetentionSettingsDefaults() {
        let settings = RetentionSettings.default

        XCTAssertEqual(settings.policy, .keepAll)
        XCTAssertEqual(settings.maxAgeDays, 365)
        XCTAssertEqual(settings.maxCount, 1000)
    }

    func testRetentionSettingsCustomValues() {
        var settings = RetentionSettings()
        settings.policy = .byAge
        settings.maxAgeDays = 90
        settings.maxCount = 500

        XCTAssertEqual(settings.policy, .byAge)
        XCTAssertEqual(settings.maxAgeDays, 90)
        XCTAssertEqual(settings.maxCount, 500)
    }

    func testRetentionSettingsCodable() throws {
        var settings = RetentionSettings()
        settings.policy = .byCount
        settings.maxAgeDays = 180
        settings.maxCount = 2000

        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RetentionSettings.self, from: data)

        XCTAssertEqual(decoded.policy, settings.policy)
        XCTAssertEqual(decoded.maxAgeDays, settings.maxAgeDays)
        XCTAssertEqual(decoded.maxCount, settings.maxCount)
    }

    // MARK: - RetentionService Tests

    @MainActor
    func testRetentionServiceSingleton() {
        let service1 = RetentionService.shared
        let service2 = RetentionService.shared

        XCTAssertTrue(service1 === service2)
    }

    @MainActor
    func testRetentionServiceGlobalSettings() {
        let service = RetentionService.shared

        // Should be able to read global settings
        XCTAssertNotNil(service.globalSettings)
    }

    // MARK: - RetentionResult Tests

    func testRetentionResultInitialization() {
        let result = RetentionResult(filesDeleted: 10, bytesFreed: 1024 * 1024)

        XCTAssertEqual(result.filesDeleted, 10)
        XCTAssertEqual(result.bytesFreed, 1024 * 1024)
    }

    func testRetentionResultBytesFormatted() {
        let result = RetentionResult(filesDeleted: 1, bytesFreed: 1024 * 1024) // 1 MB

        let formatted = result.bytesFreedFormatted
        XCTAssertFalse(formatted.isEmpty)
        // Should contain MB or similar unit
    }

    func testRetentionResultZero() {
        let result = RetentionResult(filesDeleted: 0, bytesFreed: 0)

        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertEqual(result.bytesFreed, 0)
    }

    // MARK: - Preview Tests

    @MainActor
    func testPreviewRetentionKeepAll() {
        let service = RetentionService.shared
        var settings = RetentionSettings()
        settings.policy = .keepAll

        let result = service.previewRetention(at: tempDirectory, settings: settings)

        // Keep all should delete nothing
        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertEqual(result.bytesFreed, 0)
    }

    @MainActor
    func testPreviewRetentionEmptyDirectory() {
        let service = RetentionService.shared
        var settings = RetentionSettings()
        settings.policy = .byCount
        settings.maxCount = 100

        let result = service.previewRetention(at: tempDirectory, settings: settings)

        // Empty directory should have nothing to delete
        XCTAssertEqual(result.filesDeleted, 0)
    }

    // MARK: - Apply Retention Tests

    @MainActor
    func testApplyRetentionKeepAll() async {
        let service = RetentionService.shared
        var settings = RetentionSettings()
        settings.policy = .keepAll

        // Create a test file
        let testFile = tempDirectory.appendingPathComponent("test.eml")
        try? "test content".write(to: testFile, atomically: true, encoding: .utf8)

        let result = await service.applyRetention(to: tempDirectory, settings: settings)

        // Keep all should delete nothing
        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: testFile.path))
    }

    @MainActor
    func testApplyRetentionByCount() async throws {
        let service = RetentionService.shared
        var settings = RetentionSettings()
        settings.policy = .byCount
        settings.maxCount = 2

        // Create 5 test files
        for i in 1...5 {
            let testFile = tempDirectory.appendingPathComponent("email\(i).eml")
            try "test content \(i)".write(to: testFile, atomically: true, encoding: .utf8)

            // Set different modification dates
            let date = Date().addingTimeInterval(Double(-i * 86400)) // i days ago
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: testFile.path
            )
        }

        let result = await service.applyRetention(to: tempDirectory, settings: settings)

        // Should delete 3 oldest files (5 - 2 = 3)
        XCTAssertEqual(result.filesDeleted, 3)

        // Should have 2 files remaining
        let remainingFiles = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "eml" }
        XCTAssertEqual(remainingFiles.count, 2)
    }

    @MainActor
    func testApplyRetentionByAge() async throws {
        let service = RetentionService.shared
        var settings = RetentionSettings()
        settings.policy = .byAge
        settings.maxAgeDays = 30

        // Create a recent file
        let recentFile = tempDirectory.appendingPathComponent("recent.eml")
        try "recent content".write(to: recentFile, atomically: true, encoding: .utf8)

        // Create an old file (45 days ago)
        let oldFile = tempDirectory.appendingPathComponent("old.eml")
        try "old content".write(to: oldFile, atomically: true, encoding: .utf8)
        let oldDate = Date().addingTimeInterval(-45 * 86400)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: oldFile.path
        )

        let result = await service.applyRetention(to: tempDirectory, settings: settings)

        // Should delete the old file
        XCTAssertEqual(result.filesDeleted, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
    }

    // MARK: - Integration Tests

    func testCreateTestFilesForRetention() throws {
        // Create test email files with different dates
        let accountDir = tempDirectory.appendingPathComponent("test@example.com")
        let inboxDir = accountDir.appendingPathComponent("INBOX")
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)

        // Create some test files
        for i in 1...5 {
            let fileURL = inboxDir.appendingPathComponent("email\(i).eml")
            try "Test email content \(i)".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        // Verify files exist
        let files = try FileManager.default.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 5)
    }
}
