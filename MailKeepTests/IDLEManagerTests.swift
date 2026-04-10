import XCTest
@testable import MailKeep

final class IDLEManagerTests: XCTestCase {

    override func setUp() async throws {
        await IDLEManager.shared.stopAll()
    }

    func testSharedIsAlwaysSameInstance() {
        let a = IDLEManager.shared
        let b = IDLEManager.shared
        XCTAssertTrue(a === b)
    }

    func testMonitorCountIsZeroInitially() async {
        let count = await IDLEManager.shared.monitorCount
        XCTAssertEqual(count, 0)
    }

    func testStopAllIsIdempotent() async {
        await IDLEManager.shared.stopAll()
        await IDLEManager.shared.stopAll()
        let count = await IDLEManager.shared.monitorCount
        XCTAssertEqual(count, 0)
    }

    func testStopMonitoringNonExistentAccountDoesNotCrash() async {
        let fakeId = UUID()
        await IDLEManager.shared.stopMonitoring(accountId: fakeId)
        // No crash = pass
    }
}
