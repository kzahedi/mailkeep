import XCTest
@testable import MailKeep

final class StatisticsTests: XCTestCase {
    func testParseDateFromRealFilename() {
        let date = BackupManager.parseDateFromFilename("8436_20260711_141521_Talk_der_Nation.eml")
        XCTAssertNotNil(date)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 11)
        XCTAssertEqual(comps.hour, 14)
    }

    func testParseDateFromCollisionSuffixedFilename() {
        XCTAssertNotNil(BackupManager.parseDateFromFilename("8436_20260711_141521_Sender_1.eml"))
    }

    func testParseDateReturnsNilForGarbage() {
        XCTAssertNil(BackupManager.parseDateFromFilename("not-an-email.eml"))
        XCTAssertNil(BackupManager.parseDateFromFilename(".uid_cache"))
    }
}
