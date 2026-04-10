import XCTest
@testable import IMAPBackup

/// Tests for the binary-data-safety fixes (C2 + C3).
///
/// `readResponse()` and `performStreamingFetch()` are private methods on
/// `IMAPService` that operate on a live `NWConnection`, so end-to-end unit
/// testing requires a real IMAP server (see IntegrationTests/).
///
/// These tests validate the encoding invariants that the fixes depend on,
/// and serve as executable documentation of those invariants.
final class BinaryEncodingTests: XCTestCase {

    // MARK: - C2: readResponse() non-UTF-8 fallback (tasks 1.3 / 1.4)

    /// The fix: `String(data:encoding:.utf8) ?? String(data:encoding:.isoLatin1)`.
    /// This test confirms that isoLatin1 never returns nil for any byte value,
    /// so readResponse() can never produce "" due to an encoding failure.
    func testISOLatin1NeverFailsForAnyByte() {
        // Full 256-byte range including 0x80–0xFF which are invalid UTF-8
        let allBytes = Data(0x00...0xFF)
        let result = String(data: allBytes, encoding: .isoLatin1)
        XCTAssertNotNil(result, "ISO Latin-1 must decode any byte sequence")
        XCTAssertFalse(result?.isEmpty ?? true, "ISO Latin-1 result must not be empty")
    }

    /// Confirms that a byte sequence containing 0x80–0xFF fails UTF-8 decoding
    /// — establishing that the fallback path in readResponse() is reachable.
    func testNonUTF8BytesFailUTF8Decoding() {
        let binaryBytes = Data([0x80, 0x90, 0xA0, 0xFF])
        XCTAssertNil(
            String(data: binaryBytes, encoding: .utf8),
            "Bytes 0x80–0xFF must not decode as UTF-8"
        )
    }

    /// Confirms that mixed non-UTF-8 + ASCII bytes still produce a string
    /// containing the ASCII portion when decoded via isoLatin1 — matching
    /// the C2 requirement that a tagged response like "A0001 OK" survives
    /// arrival in a chunk that also contains binary attachment bytes.
    func testMixedBinaryAndASCIIPreservesASCIIPortion() {
        // Simulate: binary attachment bytes followed by IMAP tagged response
        var mixed = Data([0x80, 0x9F, 0xC3, 0xFE])   // invalid UTF-8
        mixed.append(Data("A0001 OK\r\n".utf8))

        let utf8Result = String(data: mixed, encoding: .utf8)
        XCTAssertNil(utf8Result, "Mixed chunk should fail UTF-8")

        let isoResult = String(data: mixed, encoding: .isoLatin1)
        XCTAssertNotNil(isoResult, "isoLatin1 must succeed for mixed bytes")
        XCTAssertTrue(
            isoResult?.contains("A0001 OK") ?? false,
            "ASCII tagged response must be preserved in isoLatin1-decoded string"
        )
    }

    // MARK: - C3: performStreamingFetch binary round-trip (tasks 3.1 / 3.2 / 3.3)

    /// The fix relies on .isoLatin1 being a perfect bijection: every byte
    /// encodes to a unique code point and decodes back to the same byte.
    /// This is the invariant that makes the header→body transition safe.
    func testISOLatin1RoundTripPreservesAllBytes() {
        let original = Data(0x00...0xFF)
        guard let encoded = String(data: original, encoding: .isoLatin1),
              let roundTripped = encoded.data(using: .isoLatin1) else {
            XCTFail("isoLatin1 round-trip must not fail for any byte value")
            return
        }
        XCTAssertEqual(
            original, roundTripped,
            "isoLatin1 round-trip must preserve every byte value 0x00–0xFF"
        )
    }

    /// Confirms that a raw Data chunk containing the IMAP tag pattern can be
    /// detected by searching for the ASCII bytes directly in Data — the
    /// mechanism used in Phase 2 of the fixed performStreamingFetch.
    func testTaggedResponseDetectedInRawData() {
        let tag = "A0001"
        var chunk = Data([0xDE, 0xAD, 0xBE, 0xEF])   // trailing binary body bytes
        chunk.append(Data(")\r\n\(tag) OK FETCH completed\r\n".utf8))

        let tagBytes = Data(tag.utf8)
        let okBytes = Data(" OK".utf8)
        XCTAssertNotNil(
            chunk.range(of: tagBytes + okBytes),
            "IMAP tagged response must be detectable by raw byte search in Data"
        )
    }

    /// ASCII email bodies must be unaffected by the fix: bytes that are valid
    /// UTF-8 decode identically under both UTF-8 and isoLatin1 (0x00–0x7F).
    func testASCIIEmailBodyRoundTripUnchanged() {
        let asciiBody = "From: sender@example.com\r\nSubject: Hello\r\n\r\nPlain text body.\r\n"
        let original = Data(asciiBody.utf8)

        guard let isoStr = String(data: original, encoding: .isoLatin1),
              let roundTripped = isoStr.data(using: .isoLatin1) else {
            XCTFail("ASCII data must round-trip through isoLatin1 without error")
            return
        }
        XCTAssertEqual(original, roundTripped, "ASCII email bytes must be identical after isoLatin1 round-trip")
    }
}
