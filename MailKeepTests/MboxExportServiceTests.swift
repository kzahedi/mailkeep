import XCTest
@testable import MailKeep

final class MboxExportServiceTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MboxExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeEml(_ name: String, _ content: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func writeEmlData(_ name: String, _ content: Data) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try content.write(to: url)
        return url
    }

    func testExportProducesSeparatorPerMessage() async throws {
        let a = try writeEml("1.eml", "Subject: A\r\n\r\nbody A\r\n")
        let b = try writeEml("2.eml", "Subject: B\r\n\r\nbody B\r\n")
        let dest = tempDir.appendingPathComponent("out.mbox")
        let summary = try MboxExportService().export(emlFiles: [a, b], to: dest)
        XCTAssertEqual(summary, MboxExportSummary(exported: 2, skippedUnreadable: 0))
        let text = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\nFrom MAILER-DAEMON ").count
                       + (text.hasPrefix("From MAILER-DAEMON ") ? 0 : 1), 2, "expected 2 separators")
        XCTAssertFalse(text.contains("\r"), "CRLF must be normalized to LF")
    }

    func testFromLinesAreQuoted() async throws {
        let a = try writeEml("1.eml", "Subject: T\n\nFrom here on\n>From quoted already\nnot From\n")
        let dest = tempDir.appendingPathComponent("out.mbox")
        _ = try MboxExportService().export(emlFiles: [a], to: dest)
        let text = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(text.contains("\n>From here on\n"))
        XCTAssertTrue(text.contains("\n>>From quoted already\n"))
        XCTAssertTrue(text.contains("\nnot From\n"))
    }

    func testUnreadableFileIsSkippedNotFatal() async throws {
        let a = try writeEml("1.eml", "Subject: A\n\nok\n")
        let missing = tempDir.appendingPathComponent("gone.eml")
        let dest = tempDir.appendingPathComponent("out.mbox")
        let summary = try MboxExportService().export(emlFiles: [a, missing], to: dest)
        XCTAssertEqual(summary.exported, 1)
        XCTAssertEqual(summary.skippedUnreadable, 1)
    }

    func testProgressCallbackCounts() async throws {
        let a = try writeEml("1.eml", "x\n")
        let b = try writeEml("2.eml", "y\n")
        let dest = tempDir.appendingPathComponent("out.mbox")
        let counter = ProgressCounter()
        _ = try MboxExportService().export(emlFiles: [a, b], to: dest) { done, total in
            Task { await counter.record(done: done, total: total) }
        }
        // allow the async recordings to land
        try await Task.sleep(nanoseconds: 200_000_000)
        let final = await counter.last
        XCTAssertEqual(final?.total, 2)
        XCTAssertEqual(final?.done, 2)
    }

    func testBinaryPayloadSurvivesWithoutStringRoundTrip() async throws {
        let payload = Data([0x48, 0x69, 0xFF, 0xFE, 0x00, 0x0A]) // "Hi" + invalid UTF-8 bytes + LF
        let a = try writeEmlData("1.eml", payload)
        let dest = tempDir.appendingPathComponent("out.mbox")
        _ = try MboxExportService().export(emlFiles: [a], to: dest)
        let output = try Data(contentsOf: dest)
        XCTAssertTrue(output.range(of: payload) != nil,
                      "raw non-UTF8 bytes must survive byte-for-byte (no String round-trip)")
    }

    func testLoneCRLineEndingsNormalizedToLF() async throws {
        let a = try writeEml("1.eml", "a\rb\r")
        let dest = tempDir.appendingPathComponent("out.mbox")
        _ = try MboxExportService().export(emlFiles: [a], to: dest)
        let text = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(text.contains("a\nb\n"))
        XCTAssertFalse(text.contains("\r"))
    }

    func testBodyWithNoTrailingNewlineGetsOne() async throws {
        let a = try writeEml("1.eml", "body")
        let dest = tempDir.appendingPathComponent("out.mbox")
        _ = try MboxExportService().export(emlFiles: [a], to: dest)
        let text = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(text.contains("body\n"))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testCannotCreateDestinationThrows() async throws {
        let a = try writeEml("1.eml", "Subject: A\n\nok\n")
        let badDest = tempDir
            .appendingPathComponent("does-not-exist-dir")
            .appendingPathComponent("out.mbox")
        XCTAssertThrowsError(try MboxExportService().export(emlFiles: [a], to: badDest)) { error in
            guard case MboxExportService.MboxExportError.cannotCreateDestination = error else {
                XCTFail("expected cannotCreateDestination, got \(error)")
                return
            }
        }
    }

    func testDestinationIsTruncatedNotAppended() async throws {
        let a = try writeEml("1.eml", "Subject: A\n\nok\n")
        let dest = tempDir.appendingPathComponent("out.mbox")
        try Data("junk-from-a-previous-run".utf8).write(to: dest)
        _ = try MboxExportService().export(emlFiles: [a], to: dest)
        let text = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertFalse(text.contains("junk-from-a-previous-run"))
        XCTAssertTrue(text.hasPrefix("From MAILER-DAEMON "))
    }
}

private actor ProgressCounter {
    var last: (done: Int, total: Int)?
    func record(done: Int, total: Int) { last = (done, total) }
}
