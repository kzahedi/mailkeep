import XCTest
@testable import MailKeep

final class KeychainServiceTests: XCTestCase {

    func testDecodeStoreResultReturnsDictOnSuccess() throws {
        let data = try JSONEncoder().encode(["ABC": "secret"])
        let store = try KeychainService.decodeStoreResult(status: errSecSuccess, data: data)
        XCTAssertEqual(store, ["ABC": "secret"])
    }

    func testDecodeStoreResultReturnsEmptyOnNotFound() throws {
        let store = try KeychainService.decodeStoreResult(status: errSecItemNotFound, data: nil)
        XCTAssertTrue(store.isEmpty)
    }

    func testDecodeStoreResultThrowsOnInteractionNotAllowed() {
        XCTAssertThrowsError(
            try KeychainService.decodeStoreResult(status: errSecInteractionNotAllowed, data: nil)
        ) { error in
            guard case KeychainError.readFailed(let status) = error else {
                return XCTFail("Expected readFailed, got \(error)")
            }
            XCTAssertEqual(status, errSecInteractionNotAllowed)
        }
    }

    func testDecodeStoreResultThrowsOnCorruptData() {
        XCTAssertThrowsError(
            try KeychainService.decodeStoreResult(status: errSecSuccess, data: Data("not json".utf8))
        )
    }
}
