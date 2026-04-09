# MailKeep Migration & OAuth Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename all "IMAPBackup" file system paths to "MailKeep", migrate existing user data, and add a Re-authorize button for Gmail OAuth accounts.

**Architecture:** A new `migrateFileSystemIfNeeded()` phase is added to the existing `MigrationService` and called synchronously at app launch before `BackupManager` initializes, guaranteeing the correct paths are in place before any reads or writes occur. Hardcoded path strings in production code are updated in a separate commit. The OAuth fix is a self-contained UI change in `EditAccountView`.

**Tech Stack:** Swift, SwiftUI, FileManager, UserDefaults, XCTest, `GoogleOAuthService` (existing)

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `IMAPBackup/Services/MigrationService.swift` | Modify | Add `migrateFileSystemIfNeeded()` and `migrateDirectory(from:to:)` |
| `IMAPBackup/App/IMAPBackupApp.swift` | Modify | Call `migrateFileSystemIfNeeded()` before `BackupManager()` init |
| `IMAPBackupTests/MigrationServiceTests.swift` | Create | TDD tests for `migrateDirectory` and backup location update logic |
| `IMAPBackup/Services/LoggingService.swift` | Modify | Update 2 hardcoded `IMAPBackup` strings |
| `IMAPBackup/Services/BackupManager.swift` | Modify | Update 5 hardcoded `IMAPBackup` strings |
| `IMAPBackup/Services/StorageService.swift` | Modify | Update 1 hardcoded `IMAPBackup` string |
| `IMAPBackup/App/AppDelegate.swift` | Modify | Update 1 hardcoded `IMAPBackup` string |
| `IMAPBackup/Views/Settings/AccountsSettingsView.swift` | Modify | Add Re-authorize button and state to `EditAccountView` |

---

## Task 1: TDD — `migrateDirectory` helper

**Files:**
- Create: `IMAPBackupTests/MigrationServiceTests.swift`
- Modify: `IMAPBackup/Services/MigrationService.swift`

- [ ] **Step 1: Create the test file**

Create `IMAPBackupTests/MigrationServiceTests.swift` with this content — it will fail to compile until `migrateDirectory` exists:

```swift
import XCTest
@testable import IMAPBackup

final class MigrationServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - migrateDirectory

    func test_migrateDirectory_movesSourceToDestWhenDestDoesNotExist() throws {
        let source = tempDir.appendingPathComponent("IMAPBackup")
        let dest   = tempDir.appendingPathComponent("MailKeep")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "hello".write(to: source.appendingPathComponent("test.log"),
                          atomically: true, encoding: .utf8)

        let ok = MigrationService.migrateDirectory(from: source, to: dest)

        XCTAssertTrue(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "Source should be gone after move")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("test.log").path),
                      "File should exist in destination")
    }

    func test_migrateDirectory_mergesContentsWhenBothExist() throws {
        let source = tempDir.appendingPathComponent("IMAPBackup")
        let dest   = tempDir.appendingPathComponent("MailKeep")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest,   withIntermediateDirectories: true)
        try "old".write(to: source.appendingPathComponent("old.log"),
                        atomically: true, encoding: .utf8)
        try "existing".write(to: dest.appendingPathComponent("existing.log"),
                             atomically: true, encoding: .utf8)

        let ok = MigrationService.migrateDirectory(from: source, to: dest)

        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("old.log").path),
                      "Moved file should be in destination")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("existing.log").path),
                      "Pre-existing file should be untouched")
    }

    func test_migrateDirectory_succeedsWhenSourceDoesNotExist() {
        let source = tempDir.appendingPathComponent("IMAPBackup")
        let dest   = tempDir.appendingPathComponent("MailKeep")
        // source not created intentionally

        let ok = MigrationService.migrateDirectory(from: source, to: dest)

        XCTAssertTrue(ok, "No source is a no-op, should return true")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "Dest should not be created when source absent")
    }
}
```

- [ ] **Step 2: Add `MigrationServiceTests.swift` to the Xcode test target**

In Xcode: File navigator → right-click `IMAPBackupTests` group → "Add Files" → select `MigrationServiceTests.swift`. Ensure target membership is `IMAPBackupTests` only.

- [ ] **Step 3: Run the tests to confirm compile failure**

In Xcode: select the `IMAPBackupTests` scheme → ⌘U.  
Expected: build error — `type 'MigrationService' has no member 'migrateDirectory'`.

- [ ] **Step 4: Add `migrateDirectory` and `mergeDirectory` to `MigrationService.swift`**

Add the following block at the end of `MigrationService.swift`, **before** the closing brace of `enum MigrationService`:

```swift
    // MARK: - File System Migration Helpers

    /// Move `oldURL` to `newURL`. If both exist, merges contents (skips conflicts).
    /// Returns true on success or when source doesn't exist (no-op).
    /// Marked internal (not private) so tests can reach it via @testable import.
    static func migrateDirectory(from oldURL: URL, to newURL: URL,
                                 fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: oldURL.path) else {
            return true  // nothing to migrate
        }

        if !fileManager.fileExists(atPath: newURL.path) {
            do {
                try fileManager.moveItem(at: oldURL, to: newURL)
                print("[Migration] Renamed \(oldURL.lastPathComponent) → \(newURL.lastPathComponent)")
                return true
            } catch {
                print("[Migration] Failed to rename \(oldURL.path): \(error)")
                return false
            }
        } else {
            return mergeDirectory(from: oldURL, to: newURL, fileManager: fileManager)
        }
    }

    private static func mergeDirectory(from oldURL: URL, to newURL: URL,
                                       fileManager: FileManager) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: oldURL, includingPropertiesForKeys: nil) else { return true }

        var allSucceeded = true
        for item in contents {
            let dest = newURL.appendingPathComponent(item.lastPathComponent)
            guard !fileManager.fileExists(atPath: dest.path) else { continue }
            do {
                try fileManager.moveItem(at: item, to: dest)
            } catch {
                print("[Migration] Failed to move \(item.lastPathComponent): \(error)")
                allSucceeded = false
            }
        }
        return allSucceeded
    }
```

- [ ] **Step 5: Run tests — expect all 3 to pass**

In Xcode: ⌘U.  
Expected: `MigrationServiceTests` — 3 tests pass, 0 failures.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/Eregion/projects/mailkeep
git add IMAPBackupTests/MigrationServiceTests.swift IMAPBackup/Services/MigrationService.swift
git commit -m "$(cat <<'EOF'
Add migrateDirectory helper to MigrationService with tests

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Implement `migrateFileSystemIfNeeded` and wire up

**Files:**
- Modify: `IMAPBackup/Services/MigrationService.swift`
- Modify: `IMAPBackup/App/IMAPBackupApp.swift`

- [ ] **Step 1: Add the new completion key constant to `MigrationService.swift`**

After the existing `private static let migrationCompletedKey = "MigrationFromIMAPBackupCompleted"` line (line 7), add:

```swift
    private static let fileSystemMigrationKey = "MigrationFileSystemToMailKeepCompleted"
    private static let backupLocationDefaultsKey = "BackupLocation"
```

- [ ] **Step 2: Add `migrateFileSystemIfNeeded()` to `MigrationService.swift`**

Add this public method after `migrateIfNeeded()` (after line ~41), before the `// MARK: - UserDefaults Migration` section:

```swift
    /// Migrate file system paths from IMAPBackup naming to MailKeep.
    /// Must be called synchronously before BackupManager is initialized.
    static func migrateFileSystemIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: fileSystemMigrationKey) else { return }

        print("[Migration] Starting file system migration to MailKeep...")
        var success = true
        let fm = FileManager.default

        // 1. Migrate App Support directory (contains Logs)
        let appSupport = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first!
        let oldAppSupport = appSupport.appendingPathComponent("IMAPBackup")
        let newAppSupport = appSupport.appendingPathComponent("MailKeep")
        if !migrateDirectory(from: oldAppSupport, to: newAppSupport, fileManager: fm) {
            success = false
        }

        // 2. Migrate backup storage directory
        if let savedPath = UserDefaults.standard.string(forKey: backupLocationDefaultsKey) {
            let oldURL = URL(fileURLWithPath: savedPath)
            if oldURL.lastPathComponent == "IMAPBackup" {
                let newURL = oldURL.deletingLastPathComponent()
                    .appendingPathComponent("MailKeep")
                // Move directory (or handle already-migrated case)
                if fm.fileExists(atPath: oldURL.path) {
                    if migrateDirectory(from: oldURL, to: newURL, fileManager: fm) {
                        UserDefaults.standard.set(newURL.path,
                                                  forKey: backupLocationDefaultsKey)
                        print("[Migration] Updated BackupLocation → \(newURL.path)")
                    } else {
                        success = false
                    }
                } else {
                    // Source already gone (partial prior run); just update pointer
                    UserDefaults.standard.set(newURL.path,
                                              forKey: backupLocationDefaultsKey)
                    print("[Migration] Source absent, updated BackupLocation pointer")
                }
            }
            // Custom paths (lastPathComponent != "IMAPBackup") are left untouched
        }
        // No saved location → fresh install, new code default handles it

        if success {
            UserDefaults.standard.set(true, forKey: fileSystemMigrationKey)
            UserDefaults.standard.synchronize()
            print("[Migration] File system migration completed successfully")
        } else {
            print("[Migration] File system migration had errors — will retry on next launch")
        }
    }
```

- [ ] **Step 3: Wire up in `IMAPBackupApp.swift`**

In `IMAPBackup/App/IMAPBackupApp.swift`, inside `init()`, add the call immediately after `MigrationService.migrateIfNeeded()`:

```swift
    init() {
        // Run migration synchronously before initializing BackupManager
        // This ensures old data is migrated before the app tries to load it
        MigrationService.migrateIfNeeded()
        MigrationService.migrateFileSystemIfNeeded()   // ← add this line

        // Now initialize BackupManager with migrated data
        _backupManager = StateObject(wrappedValue: BackupManager())
    }
```

- [ ] **Step 4: Build the app to verify no compile errors**

In Xcode: ⌘B.  
Expected: Build Succeeded, 0 errors.

- [ ] **Step 5: Manually verify migration on next launch**

Quit any running MailKeep instance. Build and run (⌘R). Check:
```bash
# These should now be at MailKeep paths:
ls ~/Library/Application\ Support/MailKeep/Logs/
ls ~/Documents/MailKeep/       # or wherever BackupLocation was stored

# Old directories should be gone:
ls ~/Library/Application\ Support/IMAPBackup/   # should fail / not exist
ls ~/Documents/IMAPBackup/                      # should fail / not exist
```

- [ ] **Step 6: Verify idempotency**

Quit and relaunch the app. Check console output — `[Migration] Starting file system migration` should NOT appear (completion key prevents re-run).

- [ ] **Step 7: Commit**

```bash
cd /Volumes/Eregion/projects/mailkeep
git add IMAPBackup/Services/MigrationService.swift IMAPBackup/App/IMAPBackupApp.swift
git commit -m "$(cat <<'EOF'
Implement file system migration from IMAPBackup to MailKeep paths

Moves ~/Library/Application Support/IMAPBackup/ and the default backup
storage directory to MailKeep equivalents on first launch. Updates
BackupLocation in UserDefaults so BackupManager reads the new path.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Update all hardcoded "IMAPBackup" path strings

**Files:**
- Modify: `IMAPBackup/Services/LoggingService.swift` (lines 34, 44)
- Modify: `IMAPBackup/Services/BackupManager.swift` (lines 161, 886, 1100, 1104, 1121)
- Modify: `IMAPBackup/Services/StorageService.swift` (line 590)
- Modify: `IMAPBackup/App/AppDelegate.swift` (line 18)

- [ ] **Step 1: Update `LoggingService.swift`**

Line 34 — OS log subsystem:
```swift
// Before:
private let osLog = OSLog(subsystem: "com.kzahedi.IMAPBackup", category: "app")
// After:
private let osLog = OSLog(subsystem: "com.kzahedi.MailKeep", category: "app")
```

Line 44 — log directory path:
```swift
// Before:
return appSupport.appendingPathComponent("IMAPBackup/Logs")
// After:
return appSupport.appendingPathComponent("MailKeep/Logs")
```

- [ ] **Step 2: Update `BackupManager.swift` (5 locations)**

Line 161 — default backup location in `init()`:
```swift
// Before:
self.backupLocation = documentsURL.appendingPathComponent("IMAPBackup")
// After:
self.backupLocation = documentsURL.appendingPathComponent("MailKeep")
```

Line 886 — debug file prefix:
```swift
// Before:
.appendingPathComponent("IMAPBackup_debug_\(uid).txt")
// After:
.appendingPathComponent("MailKeep_debug_\(uid).txt")
```

Line 1100 — iCloud URL via ubiquity container:
```swift
// Before:
return iCloudURL.appendingPathComponent("Documents").appendingPathComponent("IMAPBackup")
// After:
return iCloudURL.appendingPathComponent("Documents").appendingPathComponent("MailKeep")
```

Line 1104 — iCloud hardcoded fallback path:
```swift
// Before:
let iCloudDocs = homeDir.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/IMAPBackup")
// After:
let iCloudDocs = homeDir.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/MailKeep")
```

Line 1121 — `useLocalStorage()` path:
```swift
// Before:
let localURL = documentsURL.appendingPathComponent("IMAPBackup")
// After:
let localURL = documentsURL.appendingPathComponent("MailKeep")
```

- [ ] **Step 3: Update `StorageService.swift`**

Line 590 — default backup URL in `init()`:
```swift
// Before:
self.backupURL = documentsURL.appendingPathComponent("IMAPBackup")
// After:
self.backupURL = documentsURL.appendingPathComponent("MailKeep")
```

- [ ] **Step 4: Update `AppDelegate.swift`**

Line 18 — UID cache validation path:
```swift
// Before:
let backupURL = documentsURL.appendingPathComponent("IMAPBackup")
// After:
let backupURL = documentsURL.appendingPathComponent("MailKeep")
```

- [ ] **Step 5: Build and run tests to verify no regressions**

In Xcode: ⌘U (runs all tests).  
Expected: all existing tests pass, 0 failures.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/Eregion/projects/mailkeep
git add IMAPBackup/Services/LoggingService.swift \
        IMAPBackup/Services/BackupManager.swift \
        IMAPBackup/Services/StorageService.swift \
        IMAPBackup/App/AppDelegate.swift
git commit -m "$(cat <<'EOF'
Update all hardcoded IMAPBackup path strings to MailKeep

Updates 9 locations across 4 files: log directory, OS log subsystem,
default backup storage, iCloud paths, debug file prefix, and local
storage fallback.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: OAuth Re-authorize button in `EditAccountView`

**Files:**
- Modify: `IMAPBackup/Views/Settings/AccountsSettingsView.swift`

The OAuth account edit view (`EditAccountView`, starting at line 101) currently shows a static "Signed in with Google" label with no recovery path when tokens expire. This task adds a Re-authorize button.

- [ ] **Step 1: Add state properties to `EditAccountView`**

Inside `EditAccountView` (after the existing `@State private var testResult: TestResult?` declaration around line 118), add:

```swift
    @State private var isReauthorizing = false
    @State private var reauthorizeResult: ReauthorizeResult?

    enum ReauthorizeResult {
        case success
        case failure(String)
    }
```

- [ ] **Step 2: Replace the static OAuth note with the Re-authorize button**

In `EditAccountView.body`, find the OAuth section (inside the `if account.authType == .oauth2` block, around line 147–168). Replace:

```swift
                    Text("To change the Google account, delete this account and add a new one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
```

with:

```swift
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            reauthorize()
                        } label: {
                            if isReauthorizing {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Signing in...")
                                }
                            } else {
                                Text("Re-authorize with Google")
                            }
                        }
                        .disabled(isReauthorizing)

                        if let result = reauthorizeResult {
                            switch result {
                            case .success:
                                Label("Re-authorized successfully", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            case .failure(let message):
                                Text(message)
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }

                        Text("To switch to a different Google account, delete this account and add a new one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
```

- [ ] **Step 3: Add `reauthorize()` method to `EditAccountView`**

Add this method inside `EditAccountView`, after `saveChanges()` (around line 312):

```swift
    func reauthorize() {
        isReauthorizing = true
        reauthorizeResult = nil

        Task {
            do {
                let tokens = try await GoogleOAuthService.shared.authorize()
                try await account.saveOAuthTokens(tokens)
                await MainActor.run {
                    reauthorizeResult = .success
                    isReauthorizing = false
                }
            } catch GoogleOAuthError.userCancelled {
                await MainActor.run {
                    isReauthorizing = false  // user cancelled — no error shown
                }
            } catch {
                await MainActor.run {
                    reauthorizeResult = .failure(error.localizedDescription)
                    isReauthorizing = false
                }
            }
        }
    }
```

- [ ] **Step 4: Build the app**

In Xcode: ⌘B.  
Expected: Build Succeeded, 0 errors.

- [ ] **Step 5: Manually test the Re-authorize button**

1. Open Settings → Accounts
2. Click the pencil icon on a Gmail OAuth account
3. Verify the "Re-authorize with Google" button appears in place of the old note
4. Click it — Google sign-in sheet should open in the browser
5. Complete sign-in — verify "Re-authorized successfully" label appears
6. Quit and relaunch the app — verify the next scheduled backup succeeds for that account

- [ ] **Step 6: Commit**

```bash
cd /Volumes/Eregion/projects/mailkeep
git add IMAPBackup/Views/Settings/AccountsSettingsView.swift
git commit -m "$(cat <<'EOF'
Add Re-authorize with Google button to EditAccountView for OAuth accounts

When OAuth refresh tokens expire (Bad Request from Google), the user can
now re-authorize directly from the account edit sheet without deleting
and re-adding the account.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- ✅ File system migration: `migrateFileSystemIfNeeded()` in Task 2 covers app support (logs) and backup storage
- ✅ Migration runs before `BackupManager` init: wired in `IMAPBackupApp.init()` (Task 2, Step 3)
- ✅ Custom backup paths untouched: `lastPathComponent == "IMAPBackup"` guard in Task 2
- ✅ Idempotent: completion key check at top of `migrateFileSystemIfNeeded()`
- ✅ Error handling: failures print + skip completion key so migration retries next launch
- ✅ 9 code path locations updated: all listed in Task 3
- ✅ `@testable import IMAPBackup` module name left unchanged (out of scope, noted in spec)
- ✅ OAuth Re-authorize button: Task 4 covers button, progress state, success/error feedback
- ✅ User-cancelled OAuth flow handled silently (no error shown)

**Placeholder scan:** No TBDs, no "similar to Task N" references, all code is complete.

**Type consistency:**
- `MigrationService.migrateDirectory(from:to:fileManager:)` — defined in Task 1, referenced in Task 2 ✅
- `GoogleOAuthService.shared.authorize()` — existing method, unchanged ✅
- `account.saveOAuthTokens(_:)` — existing method on `EmailAccount`, unchanged ✅
- `ReauthorizeResult` — defined and used within Task 4 only ✅
