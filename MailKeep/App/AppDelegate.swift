import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // App initialization
        print("MailKeep started")

        // Validate and repair UID caches in background
        Task.detached(priority: .background) {
            await self.validateUIDCaches()
        }
    }

    /// Validate and repair UID caches on startup
    private func validateUIDCaches() async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let backupURL = documentsURL.appendingPathComponent("MailKeep")

        let storageService = StorageService(baseURL: backupURL)
        let repairedCount = await storageService.validateAndRepairAllCaches()

        if repairedCount > 0 {
            print("MailKeep: Repaired \(repairedCount) UID cache(s) on startup")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in menubar when window is closed
        return false
    }

    @objc func openSearchWindow() {
        // Find and activate the search window
        for window in NSApp.windows {
            if window.title == "Search Emails" {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }

        // If search window doesn't exist, open it via the scene
        if let url = URL(string: "mailkeep://search") {
            NSWorkspace.shared.open(url)
        }
    }
}
