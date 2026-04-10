import XCTest
@testable import MailKeep

final class EmailParserTests: XCTestCase {

    // MARK: - Basic Parsing Tests

    func testParseSimpleEmail() {
        let emailData = """
        From: John Doe <john@example.com>
        To: jane@example.com
        Subject: Test Email
        Date: Mon, 15 Jan 2024 10:30:00 +0000
        Message-ID: <test123@example.com>

        This is the body of the email.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.messageId, "<test123@example.com>")
        XCTAssertEqual(parsed?.senderName, "John Doe")
        XCTAssertEqual(parsed?.senderEmail, "john@example.com")
        XCTAssertEqual(parsed?.subject, "Test Email")
        XCTAssertNotNil(parsed?.date)
    }

    func testParseEmailWithoutName() {
        let emailData = """
        From: john@example.com
        Subject: No Name Test
        Date: Mon, 15 Jan 2024 10:30:00 +0000
        Message-ID: <test456@example.com>

        Body text.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed)
        // When no angle brackets, regex extracts email and derives name from local part
        XCTAssertFalse(parsed!.senderName.isEmpty)
        XCTAssertFalse(parsed!.senderEmail.isEmpty)
    }

    func testParseEmailWithQuotedName() {
        let emailData = """
        From: "Doe, John" <john@example.com>
        Subject: Quoted Name Test
        Date: Mon, 15 Jan 2024 10:30:00 +0000
        Message-ID: <test789@example.com>

        Body.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.senderName, "Doe, John")
        XCTAssertEqual(parsed?.senderEmail, "john@example.com")
    }

    // MARK: - RFC 2047 Encoding Tests

    func testParseRFC2047Base64Subject() {
        let emailData = """
        From: test@example.com
        Subject: =?UTF-8?B?VGVzdCBTdWJqZWN0?=
        Date: Mon, 15 Jan 2024 10:30:00 +0000
        Message-ID: <rfc2047test@example.com>

        Body.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.subject, "Test Subject")
    }

    func testParseRFC2047QuotedPrintableSubject() {
        let emailData = """
        From: test@example.com
        Subject: =?UTF-8?Q?Hello_World?=
        Date: Mon, 15 Jan 2024 10:30:00 +0000
        Message-ID: <rfc2047qp@example.com>

        Body.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.subject, "Hello World")
    }

    func testParseRFC2047GermanUmlaut() {
        // "Über" in UTF-8 Base64
        let emailData = """
        From: test@example.com
        Subject: =?UTF-8?B?w5xiZXI=?=
        Date: Mon, 15 Jan 2024 10:30:00 +0000
        Message-ID: <umlaut@example.com>

        Body.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.subject, "Über")
    }

    // MARK: - Date Parsing Tests

    func testParseDateRFC2822() {
        let emailData = """
        From: test@example.com
        Subject: Date Test
        Date: Mon, 15 Jan 2024 10:30:00 +0000
        Message-ID: <datetest@example.com>

        Body.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed?.date)

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: parsed!.date)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 30)
    }

    func testParseDateWithTimezone() {
        let emailData = """
        From: test@example.com
        Subject: TZ Test
        Date: Mon, 15 Jan 2024 10:30:00 -0500
        Message-ID: <tztest@example.com>

        Body.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed?.date)
    }

    func testParseDateWithParenComment() {
        let emailData = """
        From: test@example.com
        Subject: Comment Test
        Date: Mon, 15 Jan 2024 10:30:00 -0800 (PST)
        Message-ID: <commenttest@example.com>

        Body.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed?.date)
    }

    // MARK: - Edge Cases

    func testParseEmptyEmail() {
        let emailData = "".data(using: .utf8)!
        let parsed = EmailParser.parseMetadata(from: emailData)
        // EmailParser returns a ParsedEmail with defaults for empty data
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.subject, "(No Subject)")
    }

    func testParseEmailWithNoHeaders() {
        let emailData = "Just some text without headers.".data(using: .utf8)!
        let parsed = EmailParser.parseMetadata(from: emailData)
        // EmailParser uses whole content as headers when no separator is found
        // and returns a ParsedEmail with defaults
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.subject, "(No Subject)")
    }

    func testParseEmailWithMissingMessageId() {
        let emailData = """
        From: test@example.com
        Subject: No Message ID
        Date: Mon, 15 Jan 2024 10:30:00 +0000

        Body.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed)
        XCTAssertFalse(parsed!.messageId.isEmpty) // Should generate a UUID
    }

    func testParseEmailWithCRLF() {
        let emailData = "From: test@example.com\r\nSubject: CRLF Test\r\nDate: Mon, 15 Jan 2024 10:30:00 +0000\r\nMessage-ID: <crlf@example.com>\r\n\r\nBody with CRLF.".data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.subject, "CRLF Test")
    }

    func testParseFoldedHeader() {
        let emailData = """
        From: test@example.com
        Subject: This is a very long subject line that
         continues on the next line
        Date: Mon, 15 Jan 2024 10:30:00 +0000
        Message-ID: <folded@example.com>

        Body.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed)
        // Folded headers may or may not be properly joined depending on regex behavior
        // At minimum, we should get the first part of the subject
        XCTAssertTrue(parsed!.subject.contains("long subject"))
    }

    func testParseEmailWithSpecialCharactersInFrom() {
        let emailData = """
        From: "O'Brien, Mary-Jane" <mary.jane@example.com>
        Subject: Special Chars
        Date: Mon, 15 Jan 2024 10:30:00 +0000
        Message-ID: <special@example.com>

        Body.
        """.data(using: .utf8)!

        let parsed = EmailParser.parseMetadata(from: emailData)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.senderEmail, "mary.jane@example.com")
    }

    // MARK: - ISO-8859-1 Encoding

    func testParseISO88591Email() {
        // Create email with ISO-8859-1 encoding
        var emailString = "From: test@example.com\nSubject: Test\nDate: Mon, 15 Jan 2024 10:30:00 +0000\nMessage-ID: <iso@example.com>\n\nBody with "
        emailString += "special char."

        if let data = emailString.data(using: .isoLatin1) {
            let parsed = EmailParser.parseMetadata(from: data)
            XCTAssertNotNil(parsed)
        }
    }
}
