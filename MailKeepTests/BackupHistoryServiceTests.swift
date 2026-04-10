import XCTest
@testable import MailKeep

@MainActor
final class BackupHistoryServiceTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupHistoryServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - Task 7.6: Round-trip

    func testRoundTripSaveAndReload() throws {
        let service = BackupHistoryService(directory: tempDirectory)
        let id = service.startEntry(for: "roundtrip@example.com")
        service.completeEntry(id: id, status: .completed)
        XCTAssertEqual(service.entries.count, 1)

        // Reload from the same directory — a fresh instance reads the file
        let reloaded = BackupHistoryService(directory: tempDirectory)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.accountEmail, "roundtrip@example.com")
        XCTAssertEqual(reloaded.entries.first?.status, .completed)
    }

    func testRoundTripPreservesMultipleEntries() throws {
        let service = BackupHistoryService(directory: tempDirectory)
        let id1 = service.startEntry(for: "a@example.com")
        service.completeEntry(id: id1, status: .completed)
        let id2 = service.startEntry(for: "b@example.com")
        service.completeEntry(id: id2, status: .failed)

        let reloaded = BackupHistoryService(directory: tempDirectory)
        XCTAssertEqual(reloaded.entries.count, 2)
    }

    // MARK: - Task 7.7: One-time migration from UserDefaults

    func testMigrationFromUserDefaultsCopiesEntriesAndClearsKey() throws {
        let legacyKey = "BackupHistory"
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }

        let entry = BackupHistoryEntry(accountEmail: "migrate@example.com")
        let data = try JSONEncoder().encode([entry])
        UserDefaults.standard.set(data, forKey: legacyKey)

        // File must not exist yet for migration to trigger
        let fileURL = tempDirectory.appendingPathComponent("backup_history.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        let service = BackupHistoryService(directory: tempDirectory)

        XCTAssertEqual(service.entries.count, 1)
        XCTAssertEqual(service.entries.first?.accountEmail, "migrate@example.com")
        XCTAssertNil(
            UserDefaults.standard.data(forKey: legacyKey),
            "Legacy UserDefaults key must be removed after migration"
        )
    }

    func testMigrationDoesNotOverwriteExistingFile() throws {
        let legacyKey = "BackupHistory"
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }

        // Establish the file store with a known entry first (no UserDefaults seed yet)
        let firstService = BackupHistoryService(directory: tempDirectory)
        _ = firstService.startEntry(for: "existing@example.com")
        // File now exists at tempDirectory/backup_history.json

        // Seed UserDefaults with a legacy entry AFTER the file is established
        let legacyEntry = BackupHistoryEntry(accountEmail: "legacy@example.com")
        UserDefaults.standard.set(try JSONEncoder().encode([legacyEntry]), forKey: legacyKey)

        // A second init should skip migration because the file already exists
        let secondService = BackupHistoryService(directory: tempDirectory)
        XCTAssertFalse(
            secondService.entries.contains(where: { $0.accountEmail == "legacy@example.com" }),
            "Migration must not run when the file store already exists"
        )
        XCTAssertTrue(
            secondService.entries.contains(where: { $0.accountEmail == "existing@example.com" }),
            "Pre-existing file store entries must be preserved"
        )
    }

    // MARK: - Task 7.8: Corrupt/missing file → empty entries

    func testMissingFileResultsInEmptyEntries() {
        // tempDirectory exists but backup_history.json was never written
        let service = BackupHistoryService(directory: tempDirectory)
        XCTAssertTrue(service.entries.isEmpty, "Missing file should start with empty entries")
    }

    func testCorruptFileResultsInEmptyEntries() throws {
        let fileURL = tempDirectory.appendingPathComponent("backup_history.json")
        try "NOT VALID JSON {{ garbage".data(using: .utf8)!.write(to: fileURL)

        let service = BackupHistoryService(directory: tempDirectory)
        XCTAssertTrue(service.entries.isEmpty, "Corrupt JSON should result in empty entries, not a crash")
    }
}
