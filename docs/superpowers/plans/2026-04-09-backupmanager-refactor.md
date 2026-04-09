# BackupManager Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `BackupManager.swift` (1294 lines) into focused files using Swift extensions and a new types file, with no behavioral changes and no caller modifications.

**Architecture:** Extract the 4 scheduling types to `BackupScheduleTypes.swift`. Split BackupManager into 7 extension files, one per MARK section. All `@Published` state stays in the main `BackupManager.swift`. Private state that must be shared across extension files is changed from `private` to internal (no modifier).

**Tech Stack:** Swift 6, SwiftUI, `@MainActor`, `ObservableObject`

---

## Files

| Action | Path |
|--------|------|
| Modify | `IMAPBackup/Services/BackupManager.swift` |
| Create | `IMAPBackup/Services/BackupScheduleTypes.swift` |
| Create | `IMAPBackup/Services/BackupManager+Accounts.swift` |
| Create | `IMAPBackup/Services/BackupManager+Scheduling.swift` |
| Create | `IMAPBackup/Services/BackupManager+Operations.swift` |
| Create | `IMAPBackup/Services/BackupManager+Execution.swift` |
| Create | `IMAPBackup/Services/BackupManager+Progress.swift` |
| Create | `IMAPBackup/Services/BackupManager+Location.swift` |
| Create | `IMAPBackup/Services/BackupManager+Statistics.swift` |
| Modify | `IMAPBackup.xcodeproj/project.pbxproj` |

---

### Task 1: Baseline verification + access modifier prep

**Files:**
- Modify: `IMAPBackup/Services/BackupManager.swift`

- [ ] **Step 1: Confirm tests pass before touching anything**

```bash
cd /Volumes/Eregion/projects/mailkeep
xcodebuild test -scheme IMAPBackup \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "Test Suite|passed|failed|error:"
```

Expected: `Test Suite ... passed`

- [ ] **Step 2: Change `private var` to `var` for all state shared across extension files**

In `IMAPBackup/Services/BackupManager.swift`, find the private state declarations (lines ~120–153) and change these specific `private var` declarations to `var`:

```swift
// BEFORE (each of these lines starts with `private var`)
private var activeTasks: [UUID: Task<Void, Never>] = [:]
private var activeHistoryIds: [UUID: UUID] = [:]
private var activeIMAPServices: [UUID: IMAPService] = [:]
private var cancellables = Set<AnyCancellable>()
private var scheduleTimer: Timer?
private var pendingProgressUpdates: [UUID: BackupProgress] = [:]
private var progressFlushTask: Task<Void, Never>?
private let progressUpdateInterval: UInt64 = 150_000_000
private var lastSubjectUpdateTime: [UUID: Date] = [:]
private var lastSubjectUpdateCount: [UUID: Int] = [:]
private var statsCache: [UUID: StatsCacheEntry] = [:]
private let statsCacheTTL: TimeInterval = 5.0

// AFTER (remove the `private` keyword from each)
var activeTasks: [UUID: Task<Void, Never>] = [:]
var activeHistoryIds: [UUID: UUID] = [:]
var activeIMAPServices: [UUID: IMAPService] = [:]
var cancellables = Set<AnyCancellable>()
var scheduleTimer: Timer?
var pendingProgressUpdates: [UUID: BackupProgress] = [:]
var progressFlushTask: Task<Void, Never>?
let progressUpdateInterval: UInt64 = 150_000_000
var lastSubjectUpdateTime: [UUID: Date] = [:]
var lastSubjectUpdateCount: [UUID: Int] = [:]
var statsCache: [UUID: StatsCacheEntry] = [:]
let statsCacheTTL: TimeInterval = 5.0
```

Leave `private let accountsKey`, `private let scheduleKey`, `private let scheduleTimeKey`, `private let scheduleConfigKey`, `private let backupLocationKey`, `private let streamingThresholdKey` as-is — these are only used in the Accounts and Scheduling sections and will stay private within their respective extension files.

- [ ] **Step 3: Verify build still passes**

```bash
xcodebuild build -scheme IMAPBackup \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add IMAPBackup/Services/BackupManager.swift
git commit -m "refactor: open BackupManager state for multi-file extension split"
```

---

### Task 2: Extract scheduling types to BackupScheduleTypes.swift

**Files:**
- Create: `IMAPBackup/Services/BackupScheduleTypes.swift`
- Modify: `IMAPBackup/Services/BackupManager.swift`
- Modify: `IMAPBackup.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create `IMAPBackup/Services/BackupScheduleTypes.swift`**

This file contains the 4 types currently at lines 1–100 of `BackupManager.swift`. Create it with this exact content:

```swift
import Foundation

/// Days of the week for scheduling
enum Weekday: Int, Codable, CaseIterable, Identifiable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    var shortName: String {
        switch self {
        case .sunday: return "Sun"
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        }
    }

    var fullName: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }
}

/// Custom schedule interval units
enum ScheduleIntervalUnit: String, Codable, CaseIterable {
    case hours = "hours"
    case days = "days"
    case weeks = "weeks"

    var displayName: String {
        rawValue.capitalized
    }

    func toSeconds(_ value: Int) -> TimeInterval {
        switch self {
        case .hours: return TimeInterval(value * 3600)
        case .days: return TimeInterval(value * 86400)
        case .weeks: return TimeInterval(value * 604800)
        }
    }
}

/// Backup schedule configuration
struct ScheduleConfiguration: Codable, Equatable {
    var weekday: Weekday = .monday
    var customInterval: Int = 1
    var customUnit: ScheduleIntervalUnit = .days
}

/// Backup schedule options
enum BackupSchedule: String, Codable, CaseIterable {
    case manual = "Manual"
    case hourly = "Every Hour"
    case daily = "Daily"
    case weekly = "Weekly"
    case custom = "Custom"

    var interval: TimeInterval? {
        switch self {
        case .manual: return nil
        case .hourly: return 3600
        case .daily: return 86400
        case .weekly: return 604800
        case .custom: return nil
        }
    }

    var needsTimeSelection: Bool {
        switch self {
        case .daily, .weekly, .custom: return true
        default: return false
        }
    }

    var needsWeekdaySelection: Bool {
        self == .weekly
    }

    var needsCustomConfiguration: Bool {
        self == .custom
    }
}
```

- [ ] **Step 2: Delete the 4 types from `BackupManager.swift`**

Delete everything from line 1 up to and including the closing `}` of `BackupSchedule` (approximately lines 1–100, ending just before `/// Main backup manager...`). The file should now start with:

```swift
import Foundation
import SwiftUI
import Combine

/// Main backup manager that coordinates backup operations
@MainActor
class BackupManager: ObservableObject {
```

- [ ] **Step 3: Add `BackupScheduleTypes.swift` to `project.pbxproj`**

In `IMAPBackup.xcodeproj/project.pbxproj`, make these 4 additions:

**A. Add PBXBuildFile entry** (in the `/* Begin PBXBuildFile section */` block, near other `B1...` entries):
```
		D100000100000001 /* BackupScheduleTypes.swift in Sources */ = {isa = PBXBuildFile; fileRef = D100000200000001 /* BackupScheduleTypes.swift */; };
```

**B. Add PBXFileReference entry** (in the `/* Begin PBXFileReference section */` block):
```
		D100000200000001 /* BackupScheduleTypes.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BackupScheduleTypes.swift; sourceTree = "<group>"; };
```

**C. Add to Services group children** (find `B10000050000000000000006 /* Services */` and add to its `children` array, near `BackupManager.swift`):
```
				D100000200000001 /* BackupScheduleTypes.swift */,
```

**D. Add to IMAPBackup Sources build phase** (find the `Sources` build phase for the main target, near `B10000010000000000000008 /* BackupManager.swift in Sources */`):
```
				D100000100000001 /* BackupScheduleTypes.swift in Sources */,
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild build -scheme IMAPBackup \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add IMAPBackup/Services/BackupScheduleTypes.swift \
        IMAPBackup/Services/BackupManager.swift \
        IMAPBackup.xcodeproj/project.pbxproj
git commit -m "refactor: extract scheduling types to BackupScheduleTypes.swift"
```

---

### Task 3: Extract account management to BackupManager+Accounts.swift

**Files:**
- Create: `IMAPBackup/Services/BackupManager+Accounts.swift`
- Modify: `IMAPBackup/Services/BackupManager.swift`
- Modify: `IMAPBackup.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create `IMAPBackup/Services/BackupManager+Accounts.swift`**

```swift
import Foundation

extension BackupManager {

    // MARK: - Password Management

    func checkForMissingPasswords() {
        Task {
            var missing: [EmailAccount] = []
            for account in accounts {
                guard account.authType == .password else { continue }
                let hasPassword = await KeychainService.shared.hasPassword(for: account.id)
                if !hasPassword {
                    missing.append(account)
                }
            }
            await MainActor.run {
                self.accountsWithMissingPasswords = missing
            }
        }
    }

    // MARK: - Account Management

    @discardableResult
    func addAccount(_ account: EmailAccount, password: String?) -> Bool {
        if accounts.contains(where: { $0.email.lowercased() == account.email.lowercased() }) {
            logError("Account with email \(account.email) already exists")
            return false
        }

        var mutableAccount = account
        accounts.append(mutableAccount)
        saveAccounts()

        let passwordToSave = password ?? mutableAccount.consumeTemporaryPassword()
        if let passwordToSave = passwordToSave {
            Task {
                do {
                    try await KeychainService.shared.savePassword(passwordToSave, for: account.id)
                    logInfo("Password saved to Keychain for \(account.email)")
                } catch {
                    logError("Failed to save password to Keychain for \(account.email): \(error.localizedDescription)")
                }
            }
        }

        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index].clearTemporaryPassword()
        }

        return true
    }

    func removeAccount(_ account: EmailAccount) {
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
        Task {
            do {
                try await KeychainService.shared.deletePassword(for: account.id)
            } catch {
                logWarning("Failed to delete password from Keychain for \(account.email): \(error.localizedDescription)")
            }
        }
    }

    func updateAccount(_ account: EmailAccount, password: String? = nil) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
            saveAccounts()
            if let password = password {
                Task {
                    do {
                        try await KeychainService.shared.savePassword(password, for: account.id)
                    } catch {
                        logError("Failed to update password in Keychain for \(account.email): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        saveAccounts()
    }

    func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([EmailAccount].self, from: data) {
            accounts = decoded
        }
    }

    func saveAccounts() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: accountsKey)
        }
    }
}
```

Note: `loadAccounts()` and `saveAccounts()` were `private` in the original. They become `internal` here because `init()` in `BackupManager.swift` calls `loadAccounts()`. `saveAccounts()` is called from this extension itself so it can remain accessible within the extension.

- [ ] **Step 2: Delete from `BackupManager.swift`**

Delete the `// MARK: - Password Management` section (the `checkForMissingPasswords()` function) and the entire `// MARK: - Account Management` section (`addAccount`, `removeAccount`, `updateAccount`, `moveAccounts`, `loadAccounts`, `saveAccounts`).

- [ ] **Step 3: Add to `project.pbxproj`** (same 4-location pattern as Task 2)

```
PBXBuildFile:    D100000100000002 /* BackupManager+Accounts.swift in Sources */ = {isa = PBXBuildFile; fileRef = D100000200000002 /* BackupManager+Accounts.swift */; };
PBXFileReference: D100000200000002 /* BackupManager+Accounts.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BackupManager+Accounts.swift; sourceTree = "<group>"; };
Services group:  D100000200000002 /* BackupManager+Accounts.swift */,
Sources phase:   D100000100000002 /* BackupManager+Accounts.swift in Sources */,
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild build -scheme IMAPBackup \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add IMAPBackup/Services/BackupManager+Accounts.swift \
        IMAPBackup/Services/BackupManager.swift \
        IMAPBackup.xcodeproj/project.pbxproj
git commit -m "refactor: extract account management to BackupManager+Accounts.swift"
```

---

### Task 4: Extract scheduling to BackupManager+Scheduling.swift

**Files:**
- Create: `IMAPBackup/Services/BackupManager+Scheduling.swift`
- Modify: `IMAPBackup/Services/BackupManager.swift`
- Modify: `IMAPBackup.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create `IMAPBackup/Services/BackupManager+Scheduling.swift`**

```swift
import Foundation

extension BackupManager {

    // MARK: - Scheduling

    func loadSchedule() {
        if let savedSchedule = UserDefaults.standard.string(forKey: scheduleKey),
           let schedule = BackupSchedule(rawValue: savedSchedule) {
            self.schedule = schedule
        }
        if let savedTimeInterval = UserDefaults.standard.object(forKey: scheduleTimeKey) as? TimeInterval {
            self.scheduledTime = Date(timeIntervalSince1970: savedTimeInterval)
        }
        if let configData = UserDefaults.standard.data(forKey: scheduleConfigKey),
           let config = try? JSONDecoder().decode(ScheduleConfiguration.self, from: configData) {
            self.scheduleConfiguration = config
        }
    }

    func setSchedule(_ newSchedule: BackupSchedule) {
        schedule = newSchedule
        UserDefaults.standard.set(newSchedule.rawValue, forKey: scheduleKey)
        updateScheduler()
    }

    func setScheduledTime(_ time: Date) {
        scheduledTime = time
        UserDefaults.standard.set(time.timeIntervalSince1970, forKey: scheduleTimeKey)
        updateScheduler()
    }

    func setScheduleConfiguration(_ config: ScheduleConfiguration) {
        scheduleConfiguration = config
        if let encoded = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(encoded, forKey: scheduleConfigKey)
        }
        updateScheduler()
    }

    var scheduledTimeFormatted: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: scheduledTime)
    }

    func updateScheduler() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        nextScheduledBackup = nil

        guard schedule != .manual else { return }

        nextScheduledBackup = calculateNextBackupTime()

        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkScheduledBackup()
            }
        }
    }

    func calculateNextBackupTime() -> Date? {
        let calendar = Calendar.current
        let now = Date()

        switch schedule {
        case .manual:
            return nil

        case .hourly:
            return calendar.date(byAdding: .hour, value: 1, to: now)

        case .daily:
            let hour = calendar.component(.hour, from: scheduledTime)
            let minute = calendar.component(.minute, from: scheduledTime)
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            if let todayBackup = calendar.date(from: components), todayBackup > now {
                return todayBackup
            } else {
                components.day! += 1
                return calendar.date(from: components)
            }

        case .weekly:
            let hour = calendar.component(.hour, from: scheduledTime)
            let minute = calendar.component(.minute, from: scheduledTime)
            let targetWeekday = scheduleConfiguration.weekday.rawValue
            var components = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
            let currentWeekday = components.weekday!
            var daysUntilTarget = targetWeekday - currentWeekday
            if daysUntilTarget < 0 { daysUntilTarget += 7 }
            if daysUntilTarget == 0 {
                var todayComponents = calendar.dateComponents([.year, .month, .day], from: now)
                todayComponents.hour = hour
                todayComponents.minute = minute
                todayComponents.second = 0
                if let todayBackup = calendar.date(from: todayComponents), todayBackup > now {
                    return todayBackup
                } else {
                    daysUntilTarget = 7
                }
            }
            if let targetDate = calendar.date(byAdding: .day, value: daysUntilTarget, to: now) {
                var targetComponents = calendar.dateComponents([.year, .month, .day], from: targetDate)
                targetComponents.hour = hour
                targetComponents.minute = minute
                targetComponents.second = 0
                return calendar.date(from: targetComponents)
            }
            return nil

        case .custom:
            let interval = scheduleConfiguration.customUnit.toSeconds(scheduleConfiguration.customInterval)
            let hour = calendar.component(.hour, from: scheduledTime)
            let minute = calendar.component(.minute, from: scheduledTime)
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            if let baseDate = calendar.date(from: components) {
                return baseDate > now ? baseDate : baseDate.addingTimeInterval(interval)
            }
            return nil
        }
    }

    func checkScheduledBackup() {
        guard !isBackingUp,
              let nextBackup = nextScheduledBackup,
              Date() >= nextBackup else { return }
        startBackupAll()
        nextScheduledBackup = calculateNextBackupTime()
    }
}
```

- [ ] **Step 2: Delete from `BackupManager.swift`**

Delete the entire `// MARK: - Scheduling` section (from `private func loadSchedule()` through `private func checkScheduledBackup()`, ending just before `// MARK: - Backup Operations`).

- [ ] **Step 3: Add to `project.pbxproj`**

```
PBXBuildFile:    D100000100000003 /* BackupManager+Scheduling.swift in Sources */ = {isa = PBXBuildFile; fileRef = D100000200000003 /* BackupManager+Scheduling.swift */; };
PBXFileReference: D100000200000003 /* BackupManager+Scheduling.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BackupManager+Scheduling.swift; sourceTree = "<group>"; };
Services group:  D100000200000003 /* BackupManager+Scheduling.swift */,
Sources phase:   D100000100000003 /* BackupManager+Scheduling.swift in Sources */,
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild build -scheme IMAPBackup \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add IMAPBackup/Services/BackupManager+Scheduling.swift \
        IMAPBackup/Services/BackupManager.swift \
        IMAPBackup.xcodeproj/project.pbxproj
git commit -m "refactor: extract scheduling to BackupManager+Scheduling.swift"
```

---

### Task 5: Extract backup operations to BackupManager+Operations.swift

**Files:**
- Create: `IMAPBackup/Services/BackupManager+Operations.swift`
- Modify: `IMAPBackup/Services/BackupManager.swift`
- Modify: `IMAPBackup.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create `IMAPBackup/Services/BackupManager+Operations.swift`**

```swift
import Foundation

extension BackupManager {

    // MARK: - Backup Operations

    func startBackup(for account: EmailAccount) {
        guard activeTasks[account.id] == nil else { return }
        isBackingUp = true
        progress[account.id] = BackupProgress(accountId: account.id)
        activeTasks[account.id] = Task {
            await performBackup(for: account)
        }
    }

    func startBackupAll() {
        for account in accounts where account.isEnabled {
            startBackup(for: account)
        }
    }

    func cancelBackup(for accountId: UUID) {
        activeTasks[accountId]?.cancel()
        activeTasks.removeValue(forKey: accountId)
        activeIMAPServices.removeValue(forKey: accountId)
        updateProgressImmediate(for: accountId) { $0.status = .cancelled }
        if let historyId = activeHistoryIds[accountId] {
            BackupHistoryService.shared.completeEntry(id: historyId, status: .cancelled)
            activeHistoryIds.removeValue(forKey: accountId)
        }
        updateIsBackingUp()
    }

    func cancelAllBackups() {
        for (id, task) in activeTasks {
            task.cancel()
            updateProgressImmediate(for: id) { $0.status = .cancelled }
            if let historyId = activeHistoryIds[id] {
                BackupHistoryService.shared.completeEntry(id: historyId, status: .cancelled)
            }
        }
        activeTasks.removeAll()
        activeHistoryIds.removeAll()
        activeIMAPServices.removeAll()
        isBackingUp = false
    }

    func updateIsBackingUp() {
        isBackingUp = !activeTasks.isEmpty
    }

    func checkAllBackupsComplete() {
        guard activeTasks.isEmpty else { return }
        let completedCount = progress.values.filter {
            $0.status == .completed || $0.status == .failed
        }.count
        guard completedCount > 1 else { return }

        var totalDownloaded = 0
        var totalErrors = 0
        for (_, prog) in progress {
            totalDownloaded += prog.downloadedEmails
            totalErrors += prog.errors.count
        }
        NotificationService.shared.notifyAllBackupsCompleted(
            totalAccounts: completedCount,
            totalDownloaded: totalDownloaded,
            totalErrors: totalErrors
        )
        Task {
            let result = await RetentionService.shared.applyRetentionToAll(backupLocation: backupLocation)
            if result.filesDeleted > 0 {
                logInfo("Retention policy applied: deleted \(result.filesDeleted) files, freed \(result.bytesFreedFormatted)")
            }
        }
    }
}
```

- [ ] **Step 2: Delete from `BackupManager.swift`**

Delete the entire `// MARK: - Backup Operations` section (`startBackup`, `startBackupAll`, `cancelBackup`, `cancelAllBackups`, `updateIsBackingUp`, `checkAllBackupsComplete`), ending just before `// MARK: - Backup Execution`.

- [ ] **Step 3: Add to `project.pbxproj`**

```
PBXBuildFile:    D100000100000004 /* BackupManager+Operations.swift in Sources */ = {isa = PBXBuildFile; fileRef = D100000200000004 /* BackupManager+Operations.swift */; };
PBXFileReference: D100000200000004 /* BackupManager+Operations.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BackupManager+Operations.swift; sourceTree = "<group>"; };
Services group:  D100000200000004 /* BackupManager+Operations.swift */,
Sources phase:   D100000100000004 /* BackupManager+Operations.swift in Sources */,
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild build -scheme IMAPBackup \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

```bash
git add IMAPBackup/Services/BackupManager+Operations.swift \
        IMAPBackup/Services/BackupManager.swift \
        IMAPBackup.xcodeproj/project.pbxproj
git commit -m "refactor: extract backup operations to BackupManager+Operations.swift"
```

---

### Task 6: Extract backup execution to BackupManager+Execution.swift

**Files:**
- Create: `IMAPBackup/Services/BackupManager+Execution.swift`
- Modify: `IMAPBackup/Services/BackupManager.swift`
- Modify: `IMAPBackup.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create `IMAPBackup/Services/BackupManager+Execution.swift`**

Create the file with the following structure. The method bodies are moved **verbatim** from `BackupManager.swift` — do not alter any logic:

```swift
import Foundation

extension BackupManager {

    // MARK: - Backup Execution

    func performBackup(for account: EmailAccount) async {
        // Move verbatim from BackupManager.swift: the full performBackup(for:) method body
        // Starts with: let imapService = IMAPService(account: account)
        // Ends with: checkAllBackupsComplete()
    }

    // MARK: - Private helpers

    func countNewEmails(
        in folder: IMAPFolder,
        account: EmailAccount,
        imapService: IMAPService,
        storageService: StorageService
    ) async throws -> [UInt32] {
        // Move verbatim from BackupManager.swift: countNewEmails(in:account:imapService:storageService:)
    }

    func downloadEmails(
        uids: [UInt32],
        from folder: IMAPFolder,
        account: EmailAccount,
        imapService: IMAPService,
        storageService: StorageService
    ) async throws {
        // Move verbatim from BackupManager.swift: downloadEmails(uids:from:account:imapService:storageService:)
    }

    // MARK: - Attachment Extraction

    func extractAttachments(
        from emailData: Data,
        emailURL: URL,
        accountEmail: String,
        folderPath: String,
        storageService: StorageService
    ) async {
        // Move verbatim from BackupManager.swift: extractAttachments(from:emailURL:accountEmail:folderPath:storageService:)
    }
}
```

Replace each `// Move verbatim...` comment with the actual method body cut from `BackupManager.swift`. The bodies are at these locations in the current file (after prior tasks have removed content, line numbers will shift — use the method names to find them):
- `performBackup(for:)` — from `let imapService = IMAPService(account: account)` through `checkAllBackupsComplete()`
- `countNewEmails(in:account:imapService:storageService:)` — full body
- `downloadEmails(uids:from:account:imapService:storageService:)` — full body
- `extractAttachments(from:emailURL:accountEmail:folderPath:storageService:)` — full body

Change `private func` to `func` for all four (they must be accessible across files).

- [ ] **Step 2: Delete from `BackupManager.swift`**

Delete the `// MARK: - Backup Execution` and `// MARK: - Attachment Extraction` sections entirely.

- [ ] **Step 3: Add to `project.pbxproj`**

```
PBXBuildFile:    D100000100000005 /* BackupManager+Execution.swift in Sources */ = {isa = PBXBuildFile; fileRef = D100000200000005 /* BackupManager+Execution.swift */; };
PBXFileReference: D100000200000005 /* BackupManager+Execution.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BackupManager+Execution.swift; sourceTree = "<group>"; };
Services group:  D100000200000005 /* BackupManager+Execution.swift */,
Sources phase:   D100000100000005 /* BackupManager+Execution.swift in Sources */,
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild build -scheme IMAPBackup \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

```bash
git add IMAPBackup/Services/BackupManager+Execution.swift \
        IMAPBackup/Services/BackupManager.swift \
        IMAPBackup.xcodeproj/project.pbxproj
git commit -m "refactor: extract backup execution to BackupManager+Execution.swift"
```

---

### Task 7: Extract progress throttling to BackupManager+Progress.swift

**Files:**
- Create: `IMAPBackup/Services/BackupManager+Progress.swift`
- Modify: `IMAPBackup/Services/BackupManager.swift`
- Modify: `IMAPBackup.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create `IMAPBackup/Services/BackupManager+Progress.swift`**

```swift
import Foundation

extension BackupManager {

    // MARK: - Progress Throttling

    /// Accumulates progress updates and flushes to UI every 150ms to prevent flooding
    func updateProgress(for accountId: UUID, update: (inout BackupProgress) -> Void) {
        var current = pendingProgressUpdates[accountId] ?? progress[accountId] ?? BackupProgress(accountId: accountId)
        update(&current)
        pendingProgressUpdates[accountId] = current

        if progressFlushTask == nil {
            progressFlushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.progressUpdateInterval ?? 150_000_000)
                await self?.flushProgressUpdates()
            }
        }
    }

    func flushProgressUpdates() {
        for (accountId, pendingProgress) in pendingProgressUpdates {
            progress[accountId] = pendingProgress
        }
        pendingProgressUpdates.removeAll()
        progressFlushTask = nil
    }

    /// Bypass throttle for status changes (connecting, completed, failed, cancelled)
    func updateProgressImmediate(for accountId: UUID, update: (inout BackupProgress) -> Void) {
        if var current = progress[accountId] {
            update(&current)
            progress[accountId] = current
            pendingProgressUpdates[accountId] = current
        }
    }

    /// Returns true every 10 emails or every 500ms — throttles subject line UI updates
    func shouldUpdateSubject(for accountId: UUID, currentCount: Int) -> Bool {
        let now = Date()
        if let lastTime = lastSubjectUpdateTime[accountId] {
            if now.timeIntervalSince(lastTime) >= 0.5 {
                lastSubjectUpdateTime[accountId] = now
                lastSubjectUpdateCount[accountId] = currentCount
                return true
            }
        } else {
            lastSubjectUpdateTime[accountId] = now
            lastSubjectUpdateCount[accountId] = currentCount
            return true
        }
        let lastCount = lastSubjectUpdateCount[accountId] ?? 0
        if currentCount - lastCount >= 10 {
            lastSubjectUpdateTime[accountId] = now
            lastSubjectUpdateCount[accountId] = currentCount
            return true
        }
        return false
    }
}
```

- [ ] **Step 2: Delete from `BackupManager.swift`**

Delete the four progress methods from the `// MARK: - Errors` section: `updateProgress(for:update:)`, `flushProgressUpdates()`, `updateProgressImmediate(for:update:)`, `shouldUpdateSubject(for:currentCount:)`. Leave `BackupManagerError` in place.

- [ ] **Step 3: Add to `project.pbxproj`**

```
PBXBuildFile:    D100000100000006 /* BackupManager+Progress.swift in Sources */ = {isa = PBXBuildFile; fileRef = D100000200000006 /* BackupManager+Progress.swift */; };
PBXFileReference: D100000200000006 /* BackupManager+Progress.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BackupManager+Progress.swift; sourceTree = "<group>"; };
Services group:  D100000200000006 /* BackupManager+Progress.swift */,
Sources phase:   D100000100000006 /* BackupManager+Progress.swift in Sources */,
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild build -scheme IMAPBackup \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

```bash
git add IMAPBackup/Services/BackupManager+Progress.swift \
        IMAPBackup/Services/BackupManager.swift \
        IMAPBackup.xcodeproj/project.pbxproj
git commit -m "refactor: extract progress throttling to BackupManager+Progress.swift"
```

---

### Task 8: Extract backup location to BackupManager+Location.swift

**Files:**
- Create: `IMAPBackup/Services/BackupManager+Location.swift`
- Modify: `IMAPBackup/Services/BackupManager.swift`
- Modify: `IMAPBackup.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create `IMAPBackup/Services/BackupManager+Location.swift`**

```swift
import Foundation
import AppKit

extension BackupManager {

    // MARK: - Backup Location

    var isUsingICloud: Bool {
        backupLocation.path.contains("Mobile Documents") ||
        backupLocation.path.contains("iCloud")
    }

    var iCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    var iCloudDriveURL: URL? {
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            return iCloudURL.appendingPathComponent("Documents").appendingPathComponent("MailKeep")
        }
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let iCloudDocs = homeDir.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/MailKeep")
        return iCloudDocs
    }

    func setBackupLocation(_ url: URL) {
        backupLocation = url
        UserDefaults.standard.set(url.path, forKey: backupLocationKey)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func useICloudDrive() {
        guard let iCloudURL = iCloudDriveURL else { return }
        setBackupLocation(iCloudURL)
    }

    func useLocalStorage() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localURL = documentsURL.appendingPathComponent("MailKeep")
        setBackupLocation(localURL)
    }

    func setStreamingThreshold(_ bytes: Int) {
        streamingThresholdBytes = bytes
        UserDefaults.standard.set(bytes, forKey: streamingThresholdKey)
    }

    func selectBackupLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose backup location"
        if panel.runModal() == .OK, let url = panel.url {
            setBackupLocation(url)
        }
    }
}
```

- [ ] **Step 2: Delete from `BackupManager.swift`**

Delete the entire `// MARK: - Backup Location` section.

- [ ] **Step 3: Add to `project.pbxproj`**

```
PBXBuildFile:    D100000100000007 /* BackupManager+Location.swift in Sources */ = {isa = PBXBuildFile; fileRef = D100000200000007 /* BackupManager+Location.swift */; };
PBXFileReference: D100000200000007 /* BackupManager+Location.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BackupManager+Location.swift; sourceTree = "<group>"; };
Services group:  D100000200000007 /* BackupManager+Location.swift */,
Sources phase:   D100000100000007 /* BackupManager+Location.swift in Sources */,
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild build -scheme IMAPBackup \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

```bash
git add IMAPBackup/Services/BackupManager+Location.swift \
        IMAPBackup/Services/BackupManager.swift \
        IMAPBackup.xcodeproj/project.pbxproj
git commit -m "refactor: extract backup location to BackupManager+Location.swift"
```

---

### Task 9: Extract statistics to BackupManager+Statistics.swift

**Files:**
- Create: `IMAPBackup/Services/BackupManager+Statistics.swift`
- Modify: `IMAPBackup/Services/BackupManager.swift`
- Modify: `IMAPBackup.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create `IMAPBackup/Services/BackupManager+Statistics.swift`**

```swift
import Foundation

extension BackupManager {

    // MARK: - Statistics

    struct AccountStats {
        var totalEmails: Int = 0
        var totalSize: Int64 = 0
        var folderCount: Int = 0
        var oldestEmail: Date?
        var newestEmail: Date?
    }

    struct GlobalStats {
        var totalEmails: Int = 0
        var totalSize: Int64 = 0
        var accountCount: Int = 0
    }

    /// Get stats for an account with 5-second cache. Runs on background thread.
    func getStats(for account: EmailAccount) async -> AccountStats {
        if let cached = statsCache[account.id],
           Date().timeIntervalSince(cached.timestamp) < statsCacheTTL {
            return cached.stats
        }
        let accountDir = backupLocation.appendingPathComponent(account.email.sanitizedForFilename())
        let stats = await Task.detached(priority: .utility) {
            return BackupManager.calculateStatsAtDirectory(accountDir)
        }.value
        statsCache[account.id] = StatsCacheEntry(stats: stats, timestamp: Date())
        return stats
    }

    func getStatsSync(for account: EmailAccount) -> AccountStats {
        let accountDir = backupLocation.appendingPathComponent(account.email.sanitizedForFilename())
        return BackupManager.calculateStatsAtDirectory(accountDir)
    }

    func getGlobalStats() async -> GlobalStats {
        var global = GlobalStats()
        global.accountCount = accounts.count
        await withTaskGroup(of: AccountStats.self) { group in
            for account in accounts {
                group.addTask { await self.getStats(for: account) }
            }
            for await stats in group {
                global.totalEmails += stats.totalEmails
                global.totalSize += stats.totalSize
            }
        }
        return global
    }

    func getGlobalStatsSync() -> GlobalStats {
        var global = GlobalStats()
        global.accountCount = accounts.count
        for account in accounts {
            let accountDir = backupLocation.appendingPathComponent(account.email.sanitizedForFilename())
            let stats = BackupManager.calculateStatsAtDirectory(accountDir)
            global.totalEmails += stats.totalEmails
            global.totalSize += stats.totalSize
        }
        return global
    }

    func invalidateStatsCache(for accountId: UUID) {
        statsCache.removeValue(forKey: accountId)
    }

    func invalidateAllStatsCache() {
        statsCache.removeAll()
    }

    private nonisolated static func calculateStatsAtDirectory(_ directory: URL) -> AccountStats {
        var stats = AccountStats()
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return stats }

        var folders = Set<String>()
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true,
                  fileURL.pathExtension == "eml" else { continue }
            stats.totalEmails += 1
            stats.totalSize += Int64(resourceValues.fileSize ?? 0)
            folders.insert(fileURL.deletingLastPathComponent().path)
            let filename = fileURL.deletingPathExtension().lastPathComponent
            if let date = parseDateFromFilename(filename) {
                if stats.oldestEmail == nil || date < stats.oldestEmail! { stats.oldestEmail = date }
                if stats.newestEmail == nil || date > stats.newestEmail! { stats.newestEmail = date }
            }
        }
        stats.folderCount = folders.count
        return stats
    }

    private nonisolated static func parseDateFromFilename(_ filename: String) -> Date? {
        let parts = filename.components(separatedBy: "_")
        guard parts.count >= 2, parts[0].count == 8, parts[1].count == 6 else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        return dateFormatter.date(from: "\(parts[0])_\(parts[1])")
    }
}
```

- [ ] **Step 2: Delete from `BackupManager.swift`**

Delete the entire `// MARK: - Statistics` section (from `struct AccountStats` to the end of the file, including the closing `}`  of the class). The class closing `}` will now come after `BackupManagerError`.

- [ ] **Step 3: Add to `project.pbxproj`**

```
PBXBuildFile:    D100000100000008 /* BackupManager+Statistics.swift in Sources */ = {isa = PBXBuildFile; fileRef = D100000200000008 /* BackupManager+Statistics.swift */; };
PBXFileReference: D100000200000008 /* BackupManager+Statistics.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BackupManager+Statistics.swift; sourceTree = "<group>"; };
Services group:  D100000200000008 /* BackupManager+Statistics.swift */,
Sources phase:   D100000100000008 /* BackupManager+Statistics.swift in Sources */,
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild build -scheme IMAPBackup \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

```bash
git add IMAPBackup/Services/BackupManager+Statistics.swift \
        IMAPBackup/Services/BackupManager.swift \
        IMAPBackup.xcodeproj/project.pbxproj
git commit -m "refactor: extract statistics to BackupManager+Statistics.swift"
```

---

### Task 10: Final verification + push

**Files:** None

- [ ] **Step 1: Run full test suite**

```bash
xcodebuild test -scheme IMAPBackup \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "Test Suite|passed|failed|error:"
```

Expected: `Test Suite 'All tests' passed`

- [ ] **Step 2: Verify BackupManager.swift line count**

```bash
wc -l /Volumes/Eregion/projects/mailkeep/IMAPBackup/Services/BackupManager.swift
```

Expected: under 220 lines.

- [ ] **Step 3: Close GitHub issue**

```bash
gh issue close 39 --repo kzahedi/mailkeep \
  --comment "BackupManager split into 8 focused files. BackupManager.swift is now ~200 lines."
```

- [ ] **Step 4: Push to GitHub**

```bash
git push origin main
```
