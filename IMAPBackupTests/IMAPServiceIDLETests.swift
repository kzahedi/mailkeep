import XCTest
@testable import IMAPBackup

final class IMAPServiceIDLETests: XCTestCase {

    // Helper: create a service with a dummy account (no network needed for parsing tests)
    private var service: IMAPService {
        IMAPService(account: EmailAccount(
            email: "test@example.com",
            imapServer: "imap.example.com",
            port: 993
        ))
    }

    // MARK: - parseExistsCount

    func testParseExistsCountReturnsCountForExistsLine() {
        XCTAssertEqual(service.parseExistsCount(from: "* 5 EXISTS\r\n"), 5)
    }

    func testParseExistsCountReturnsNilForExpungeLine() {
        XCTAssertNil(service.parseExistsCount(from: "* 3 EXPUNGE\r\n"))
    }

    func testParseExistsCountReturnsNilForTaggedOK() {
        XCTAssertNil(service.parseExistsCount(from: "A0001 OK IDLE terminated\r\n"))
    }

    func testParseExistsCountHandlesMultiLineResponse() {
        let response = "* 2 EXPUNGE\r\n* 10 EXISTS\r\nA0002 OK\r\n"
        XCTAssertEqual(service.parseExistsCount(from: response), 10)
    }

    func testParseExistsCountHandlesLowercaseExists() {
        // RFC 3501 §9: response keywords are case-insensitive
        XCTAssertEqual(service.parseExistsCount(from: "* 3 exists\r\n"), 3)
    }

    func testParseExistsCountReturnsNilForEmptyResponse() {
        XCTAssertNil(service.parseExistsCount(from: ""))
    }

    // MARK: - IDLENotification

    func testIDLENotificationExistsHoldsCount() {
        let n = IDLENotification.exists(42)
        if case .exists(let count) = n {
            XCTAssertEqual(count, 42)
        } else {
            XCTFail("Expected .exists")
        }
    }

    func testIDLENotificationTimeoutIsDistinct() {
        if case .timeout = IDLENotification.timeout {
            // ok
        } else {
            XCTFail("Expected .timeout")
        }
    }
}
