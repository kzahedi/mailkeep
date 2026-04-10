import XCTest
@testable import MailKeep

final class MigrationServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func test_migrateDirectory_movesSourceToDestWhenDestDoesNotExist() throws {
        let source = tempDir.appendingPathComponent("IMAPBackup")
        let dest   = tempDir.appendingPathComponent("MailKeep")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "hello".write(to: source.appendingPathComponent("test.log"),
                          atomically: true, encoding: .utf8)

        let ok = MigrationService.migrateDirectory(from: source, to: dest)

        XCTAssertTrue(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "Source should be gone after move")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("test.log").path),
                      "File should exist in destination")
    }

    func test_migrateDirectory_mergesContentsWhenBothExist() throws {
        let source = tempDir.appendingPathComponent("IMAPBackup")
        let dest   = tempDir.appendingPathComponent("MailKeep")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest,   withIntermediateDirectories: true)
        try "old".write(to: source.appendingPathComponent("old.log"),
                        atomically: true, encoding: .utf8)
        try "existing".write(to: dest.appendingPathComponent("existing.log"),
                             atomically: true, encoding: .utf8)

        let ok = MigrationService.migrateDirectory(from: source, to: dest)

        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("old.log").path),
                      "Moved file should be in destination")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("existing.log").path),
                      "Pre-existing file should be untouched")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("old.log").path),
                       "Moved file should be gone from source")
    }

    func test_migrateDirectory_succeedsWhenSourceDoesNotExist() {
        let source = tempDir.appendingPathComponent("IMAPBackup")
        let dest   = tempDir.appendingPathComponent("MailKeep")

        let ok = MigrationService.migrateDirectory(from: source, to: dest)

        XCTAssertTrue(ok, "No source is a no-op, should return true")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "Dest should not be created when source absent")
    }

    func test_migrateDirectory_skipsFileConflictsDuringMerge() throws {
        let source = tempDir.appendingPathComponent("IMAPBackup")
        let dest   = tempDir.appendingPathComponent("MailKeep")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest,   withIntermediateDirectories: true)
        // Same filename in both — destination version should win
        try "source-version".write(to: source.appendingPathComponent("shared.log"),
                                   atomically: true, encoding: .utf8)
        try "dest-version".write(to: dest.appendingPathComponent("shared.log"),
                                 atomically: true, encoding: .utf8)

        let ok = MigrationService.migrateDirectory(from: source, to: dest)

        XCTAssertTrue(ok)
        let content = try String(contentsOf: dest.appendingPathComponent("shared.log"),
                                 encoding: .utf8)
        XCTAssertEqual(content, "dest-version", "Destination file should not be overwritten")
    }
}
