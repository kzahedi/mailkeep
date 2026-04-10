import XCTest
@testable import MailKeep

final class VerificationServiceTests: XCTestCase {

    // MARK: - FolderVerificationResult Tests

    func testFolderVerificationResultFullySynced() {
        let result = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2, 3, 4, 5]),
            localUIDs: Set([1, 2, 3, 4, 5])
        )

        XCTAssertTrue(result.isFullySynced)
        XCTAssertTrue(result.missingLocally.isEmpty)
        XCTAssertTrue(result.deletedOnServer.isEmpty)
        XCTAssertEqual(result.synced.count, 5)
    }

    func testFolderVerificationResultMissingLocally() {
        let result = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2, 3, 4, 5]),
            localUIDs: Set([1, 2, 3])
        )

        XCTAssertFalse(result.isFullySynced)
        XCTAssertEqual(result.missingLocally, Set([4, 5]))
        XCTAssertTrue(result.deletedOnServer.isEmpty)
        XCTAssertEqual(result.synced.count, 3)
    }

    func testFolderVerificationResultDeletedOnServer() {
        let result = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2, 3]),
            localUIDs: Set([1, 2, 3, 4, 5])
        )

        XCTAssertFalse(result.isFullySynced)
        XCTAssertTrue(result.missingLocally.isEmpty)
        XCTAssertEqual(result.deletedOnServer, Set([4, 5]))
        XCTAssertEqual(result.synced.count, 3)
    }

    func testFolderVerificationResultBothIssues() {
        let result = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2, 3, 6, 7]),
            localUIDs: Set([1, 2, 3, 4, 5])
        )

        XCTAssertFalse(result.isFullySynced)
        XCTAssertEqual(result.missingLocally, Set([6, 7]))
        XCTAssertEqual(result.deletedOnServer, Set([4, 5]))
        XCTAssertEqual(result.synced.count, 3)
    }

    func testFolderVerificationResultEmptySets() {
        let result = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set(),
            localUIDs: Set()
        )

        XCTAssertTrue(result.isFullySynced)
        XCTAssertEqual(result.synced.count, 0)
    }

    func testFolderVerificationResultSummaryFullySynced() {
        let result = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2, 3]),
            localUIDs: Set([1, 2, 3])
        )

        XCTAssertTrue(result.summary.contains("✓"))
        XCTAssertTrue(result.summary.contains("3 emails"))
    }

    func testFolderVerificationResultSummaryMissing() {
        let result = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2, 3, 4, 5]),
            localUIDs: Set([1, 2])
        )

        XCTAssertTrue(result.summary.contains("⚠"))
        XCTAssertTrue(result.summary.contains("3 missing locally"))
    }

    func testFolderVerificationResultSummaryDeleted() {
        let result = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2]),
            localUIDs: Set([1, 2, 3, 4])
        )

        XCTAssertTrue(result.summary.contains("⚠"))
        XCTAssertTrue(result.summary.contains("2 deleted on server"))
    }

    // MARK: - AccountVerificationResult Tests

    func testAccountVerificationResultIdentifiable() {
        let result1 = AccountVerificationResult(
            accountEmail: "test@example.com",
            folderResults: [],
            verifiedAt: Date()
        )

        let result2 = AccountVerificationResult(
            accountEmail: "test@example.com",
            folderResults: [],
            verifiedAt: Date()
        )

        // Each result should have a unique ID
        XCTAssertNotEqual(result1.id, result2.id)
    }

    func testAccountVerificationResultTotals() {
        let folder1 = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2, 3, 4, 5]),
            localUIDs: Set([1, 2, 3])
        )

        let folder2 = FolderVerificationResult(
            folderName: "Sent",
            serverUIDs: Set([10, 11, 12]),
            localUIDs: Set([10, 11, 12, 13, 14])
        )

        let result = AccountVerificationResult(
            accountEmail: "test@example.com",
            folderResults: [folder1, folder2],
            verifiedAt: Date()
        )

        XCTAssertEqual(result.totalServerEmails, 8) // 5 + 3
        XCTAssertEqual(result.totalLocalEmails, 8) // 3 + 5
        XCTAssertEqual(result.totalMissingLocally, 2) // 2 from folder1
        XCTAssertEqual(result.totalDeletedOnServer, 2) // 2 from folder2
    }

    func testAccountVerificationResultFullySynced() {
        let folder1 = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2, 3]),
            localUIDs: Set([1, 2, 3])
        )

        let folder2 = FolderVerificationResult(
            folderName: "Sent",
            serverUIDs: Set([10, 11]),
            localUIDs: Set([10, 11])
        )

        let result = AccountVerificationResult(
            accountEmail: "test@example.com",
            folderResults: [folder1, folder2],
            verifiedAt: Date()
        )

        XCTAssertTrue(result.isFullySynced)
    }

    func testAccountVerificationResultNotFullySynced() {
        let folder1 = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2, 3, 4]),
            localUIDs: Set([1, 2, 3])
        )

        let folder2 = FolderVerificationResult(
            folderName: "Sent",
            serverUIDs: Set([10, 11]),
            localUIDs: Set([10, 11])
        )

        let result = AccountVerificationResult(
            accountEmail: "test@example.com",
            folderResults: [folder1, folder2],
            verifiedAt: Date()
        )

        XCTAssertFalse(result.isFullySynced)
    }

    func testAccountVerificationResultSummaryFullySynced() {
        let folder = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2, 3]),
            localUIDs: Set([1, 2, 3])
        )

        let result = AccountVerificationResult(
            accountEmail: "test@example.com",
            folderResults: [folder],
            verifiedAt: Date()
        )

        XCTAssertTrue(result.summary.contains("✓"))
        XCTAssertTrue(result.summary.contains("1 folders"))
    }

    func testAccountVerificationResultSummaryIssues() {
        let folder = FolderVerificationResult(
            folderName: "INBOX",
            serverUIDs: Set([1, 2, 3, 4, 5]),
            localUIDs: Set([1, 2])
        )

        let result = AccountVerificationResult(
            accountEmail: "test@example.com",
            folderResults: [folder],
            verifiedAt: Date()
        )

        XCTAssertTrue(result.summary.contains("⚠"))
        XCTAssertTrue(result.summary.contains("3 emails missing locally"))
    }

    // MARK: - VerificationService Tests

    @MainActor
    func testVerificationServiceSingleton() {
        let service1 = VerificationService.shared
        let service2 = VerificationService.shared

        XCTAssertTrue(service1 === service2)
    }

    @MainActor
    func testVerificationServiceInitialState() {
        let service = VerificationService.shared

        XCTAssertFalse(service.isVerifying)
        XCTAssertNil(service.currentAccount)
        XCTAssertNil(service.currentFolder)
    }

    @MainActor
    func testVerificationServiceClearResults() {
        let service = VerificationService.shared

        // Manually set some results
        service.clearResults()

        XCTAssertTrue(service.lastResults.isEmpty)
    }
}
