import XCTest
@testable import IMAPBackup

@MainActor
final class BackupManagerIDLETests: XCTestCase {

    override func setUp() async throws {
        await IDLEManager.shared.stopAll()
        UserDefaults.standard.removeObject(forKey: "idleEnabled")
    }

    func testIDLEEnabledKeyExists() {
        let manager = BackupManager()
        XCTAssertEqual(manager.idleEnabledKey, "idleEnabled")
    }

    func testSetIDLEEnabledPersistsToUserDefaults() {
        let manager = BackupManager()
        manager.setIDLEEnabled(true)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "idleEnabled"))
        manager.setIDLEEnabled(false)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "idleEnabled"))
    }

    func testStartIDLEMonitoringDoesNothingWhenGlobalToggleOff() async {
        let manager = BackupManager()
        manager.startIDLEMonitoring()
        let count = await IDLEManager.shared.monitorCount
        XCTAssertEqual(count, 0)
    }
}
