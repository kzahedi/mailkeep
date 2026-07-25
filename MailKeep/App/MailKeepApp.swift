import SwiftUI

@main
struct MailKeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var backupManager: BackupManager

    /// True when this process is an XCTest host (unit tests run hosted inside
    /// the real app via TEST_HOST). Startup side effects must not run then:
    /// app-hosted test runs must never mutate production data — the real
    /// credential migration once executed during a unit-test run.
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    init() {
        // Run migration synchronously before initializing BackupManager
        // This ensures old data is migrated before the app tries to load it
        if !Self.isRunningTests {
            MigrationService.migrateIfNeeded()
            MigrationService.migrateFileSystemIfNeeded()
            MigrationService.migrateCredentialsIfNeeded()
        }

        // Now initialize BackupManager with migrated data
        _backupManager = StateObject(wrappedValue: BackupManager())
    }

    var body: some Scene {
        // Main window
        WindowGroup {
            MainWindowView()
                .environmentObject(backupManager)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 800, height: 600)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Search Emails...") {
                    NSApp.sendAction(#selector(AppDelegate.openSearchWindow), to: nil, from: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        // Search window
        Window("Search Emails", id: "search") {
            SearchView()
                .environmentObject(backupManager)
        }
        .defaultSize(width: 700, height: 500)
        .keyboardShortcut("f", modifiers: [.command, .shift])

        // Email browser window
        Window("Email Browser", id: "browser") {
            EmailBrowserView()
                .environmentObject(backupManager)
        }
        .defaultSize(width: 1000, height: 700)

        // Menubar
        MenuBarExtra {
            MenubarView()
                .environmentObject(backupManager)
        } label: {
            Image(systemName: backupManager.isBackingUp ? "envelope.badge.shield.half.filled" : "envelope.fill")
        }
        .menuBarExtraStyle(.window)

        // Settings
        Settings {
            SettingsView()
                .environmentObject(backupManager)
        }
    }
}
