# Backup Reliability Features — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make backup failures impossible to miss and backups provably recoverable: per-account health tracking with an always-visible menubar badge, escalating failure notifications, a daily credential probe that surfaces dead passwords/tokens within 24 h, corrected storage statistics, and one-click export of any account to a standard `.mbox` file.

**Architecture:** Health is *derived* from the already-persisted `BackupHistoryService` entries (no new store). Notifications escalate through the existing `NotificationService` with a 24-hour per-account dedupe gate. A new `CredentialProbeService` reuses `IMAPServiceProtocol` (injectable, mockable) and feeds auth failures into the existing missing-credentials sheet. Export is a new `MboxExportService` actor writing mboxrd format from the `.eml` tree via a new `StorageService` enumeration API.

**Tech Stack:** Swift (actors, async/await, SwiftUI), XCTest. No new dependencies.

## Global Constraints

- Never log, print, or include in notifications any credential value — account emails, counts, and error descriptions only.
- Tests must be isolated: temp dirs via existing override hooks (`CredentialStore.testFileOverride`, `BackupManager.testAccountsFileOverride`, `BackupHistoryService(directory:)` test init, `StorageService(baseURL:)`); unique per-run names; reset every override in `tearDown`. Never touch production files or UserDefaults keys used by the real app — parameterize keys where needed.
- Test command (unit tests only):
  `xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests 2>&1 | tail -5`
  Focused class: append `/<ClassName>` to `-only-testing:`.
- **Adding a new Swift file to the Xcode project:** `project.pbxproj` uses explicit file references. Every new file needs 4 entries mirroring a sibling (app files → mirror `CredentialStore.swift`'s `B1…`-prefixed entries: PBXBuildFile, PBXFileReference, Services group child, app Sources phase; test files → mirror `GoogleOAuthServiceTests.swift`'s `C1…` entries, MailKeepTests target). Invent unique 24-hex-char ID pairs continuing the existing sequences (test IDs `…0010` are taken; continue at `…0011`). Do not re-indent unrelated pbxproj lines. Verify with a build.
- Work on branch (worktree) created for this plan; one commit per task; commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- The MailKeepTests bundle is app-hosted; `MailKeepApp.init` skips migrations under XCTest (guard exists). New startup side effects added by this plan (probe timer) must be behind the same `Self.isRunningTests` guard style where they could touch production state from tests.
- UI-only steps are verified by `xcodebuild build … | tail -5` → `BUILD SUCCEEDED` (no UI test framework in scope).

## Facts about the current code (verified 2026-07-25 — trust these, don't re-derive)

- `BackupHistoryEntry` (Models/BackupHistoryEntry.swift): fields `accountEmail: String`, `startTime: Date`, `endTime: Date?`, `status: BackupHistoryStatus` (`.inProgress/.completed/.completedWithErrors/.failed/.cancelled`), `errors: [String]`. `BackupHistoryService` (@MainActor, ObservableObject, `shared`, test init `init(directory: URL)` at :23) keeps `@Published private(set) var entries` **newest-first**, trimmed to `maxEntries = 100` (:10), persisted to `backup_history.json`.
- Backup completion call sites: `BackupManager+Execution.swift` — success `completeEntry` :124, failure path `updateEntry(id:error:)` :144 + `completeEntry(status: .failed)` :145, then `NotificationService.shared.notifyBackupFailed` :148.
- `NotificationService` (plain class, `shared`, not actor-isolated): `notifyBackupCompleted` :24, `notifyBackupFailed` :50, `notifyAllBackupsCompleted` :66, categories :94. Per-failure notifications ALREADY fire — the gap is escalation + an in-app indicator that works even when notification permission is denied.
- `MenubarAccountRow` (Views/MenubarView.swift:196-259): `statusColor` :244 derives only from in-memory `progress` + `isEnabled`; shows `Last: <account.lastBackupDate> ago` :235-238. This is where the health badge goes.
- Scheduling: `BackupManager.scheduleTimer` (BackupManager.swift:27), 60-s repeating timer created in `updateScheduler()` (BackupManager+Scheduling.swift:61) — NOT running when schedule == .manual, so the probe needs its own timer property started from `BackupManager.init` (near :92).
- `IMAPServiceProtocol` (Services/IMAPServiceProtocol.swift): `connect()`, `disconnect()`, `login(password: String?)`, `logout()`, folder/fetch members. `IMAPService: IMAPServiceProtocol` conformance :47. `IMAPError` auth cases: `.authenticationFailed` (no payload), `.oauthFailed(String)`.
- `MockIMAPService` (MailKeepTests/Mocks/MockIMAPService.swift) conforms to the protocol; has `shouldFailConnect`/`shouldFailLogin` flags and call counters (`connectCallCount`, `loginCallCount`, `logoutCallCount`). Check what error `shouldFailLogin` throws before writing tests; if it isn't `IMAPError.authenticationFailed`, extend the mock with an injectable `loginError: Error?` rather than changing its default.
- `accountsWithMissingPasswords` (@Published, BackupManager.swift:21) drives the `MissingPasswordsView` sheet via MainWindowView :51-67; producer `checkForMissingPasswords()` (BackupManager+Accounts.swift:23) checks presence only.
- Stats: `BackupManager+Statistics.swift` — `AccountStats` :7 (`totalEmails/totalSize/folderCount/oldestEmail/newestEmail`), `getStats(for:) async` :23 (5 s cache), `calculateStatsAtDirectory` :98, **`parseDateFromFilename(_:)` :142-154 is buggy: it expects `YYYYMMDD_HHMMSS_sender` but real filenames are `UID_YYYYMMDD_HHMMSS_sender.eml`, so `oldestEmail`/`newestEmail` are always nil.**
- On-disk layout: `<backupLocation>/<sanitized email>/<sanitized folder path…>/<UID>_<yyyyMMdd_HHmmss>_<sender>.eml`; hidden sidecars `.uid_cache` and `.hash_index` per folder; attachment subfolders named `<timestamp>__<sender>_attachments`; in-flight files end `.tmp`. `StorageService` (actor, `init(baseURL:)`) has NO API that enumerates .eml files — `getBackupSize(for:)` :522 / `getEmailCount(for:)` :527 aggregate only.
- Export UI home: `AccountDetailView` in Views/MainWindow/MainWindowView.swift, next to "Open in Finder" :168-172. NSSavePanel pattern to copy: Views/EmailBrowser/EmailBrowserView.swift:684-694. App is NOT sandboxed — no entitlement changes needed.
- Stats UI reuse: `StatsSection` MainWindowView.swift:310-396; `AccountRowView` (Views/Components/AccountRowView.swift) loads stats via `.task(id:)` :58.
- `AccountsSettingsView` rows (Views/Settings/AccountsSettingsView.swift:14-64): email/badge/server + edit :36 / delete :43 / toggle :53. No stats today.

---

### Task 1: Account health derived from backup history

**Files:**
- Modify: `MailKeep/Models/BackupHistoryEntry.swift` (append at end)
- Modify: `MailKeep/Services/BackupHistoryService.swift`
- Create: `MailKeepTests/BackupHealthTests.swift` (register in pbxproj, MailKeepTests target)

**Interfaces:**
- Produces (consumed by Tasks 2, 3):
  - `struct AccountHealth: Equatable { var lastSuccess: Date?; var consecutiveFailures: Int }`
  - `BackupHistoryService.health(for accountEmail: String) -> AccountHealth` (@MainActor)
- `maxEntries` raised 100 → 500 (12 accounts × daily runs would evict an account's history within days at 100).

- [ ] **Step 1: Write the failing tests**

Create `MailKeepTests/BackupHealthTests.swift`:

```swift
import XCTest
@testable import MailKeep

@MainActor
final class BackupHealthTests: XCTestCase {
    var tempDir: URL!
    var service: BackupHistoryService!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupHealthTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = BackupHistoryService(directory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func record(_ email: String, _ status: BackupHistoryStatus) {
        let id = service.startEntry(for: email)
        service.completeEntry(id: id, status: status)
    }

    func testHealthWithNoEntriesIsCleanSlate() {
        let health = service.health(for: "nobody@example.com")
        XCTAssertNil(health.lastSuccess)
        XCTAssertEqual(health.consecutiveFailures, 0)
    }

    func testConsecutiveFailuresCountFromNewestUntilLastSuccess() {
        record("a@example.com", .completed)   // older
        record("a@example.com", .failed)
        record("a@example.com", .failed)      // newest
        let health = service.health(for: "a@example.com")
        XCTAssertEqual(health.consecutiveFailures, 2)
        XCTAssertNotNil(health.lastSuccess)
    }

    func testSuccessResetsFailureCount() {
        record("a@example.com", .failed)
        record("a@example.com", .completedWithErrors)  // newest — counts as success
        let health = service.health(for: "a@example.com")
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertNotNil(health.lastSuccess)
    }

    func testCancelledAndInProgressAreIgnored() {
        record("a@example.com", .failed)
        record("a@example.com", .cancelled)
        _ = service.startEntry(for: "a@example.com")   // stays .inProgress
        let health = service.health(for: "a@example.com")
        XCTAssertEqual(health.consecutiveFailures, 1)
    }

    func testHealthIsPerAccount() {
        record("a@example.com", .failed)
        record("b@example.com", .completed)
        XCTAssertEqual(service.health(for: "a@example.com").consecutiveFailures, 1)
        XCTAssertEqual(service.health(for: "b@example.com").consecutiveFailures, 0)
    }
}
```

- [ ] **Step 2: Run to verify failure** — focused class; expect compile FAILURE (`AccountHealth`/`health(for:)` missing).

- [ ] **Step 3: Implement**

Append to `MailKeep/Models/BackupHistoryEntry.swift`:

```swift
// MARK: - Derived Health

/// Per-account backup health derived from history entries. Not persisted —
/// always computed from BackupHistoryService.entries so it can never drift.
struct AccountHealth: Equatable {
    /// endTime (or startTime) of the most recent successful backup, if any.
    var lastSuccess: Date?
    /// Number of failed runs since the last success (cancelled/in-progress ignored).
    var consecutiveFailures: Int
}
```

In `BackupHistoryService`: change `maxEntries` to 500, and add:

```swift
/// Compute health for one account from the (newest-first) entries.
func health(for accountEmail: String) -> AccountHealth {
    var consecutiveFailures = 0
    for entry in entries where entry.accountEmail == accountEmail {
        switch entry.status {
        case .completed, .completedWithErrors:
            return AccountHealth(lastSuccess: entry.endTime ?? entry.startTime,
                                 consecutiveFailures: consecutiveFailures)
        case .failed:
            consecutiveFailures += 1
        case .inProgress, .cancelled:
            continue
        }
    }
    return AccountHealth(lastSuccess: nil, consecutiveFailures: consecutiveFailures)
}
```

- [ ] **Step 4: Run focused class (5 PASS), then full suite (expect all green).**
- [ ] **Step 5: Commit** — `feat: derive per-account backup health from history`

---

### Task 2: Escalating failure notifications with 24 h dedupe

**Files:**
- Modify: `MailKeep/Services/NotificationService.swift`
- Modify: `MailKeep/Services/BackupManager+Execution.swift` (failure path, after :145)
- Modify: `MailKeepTests/BackupHealthTests.swift` (add gate tests)

**Interfaces:**
- Consumes: `BackupHistoryService.health(for:)` (Task 1).
- Produces:
  - `NotificationService.shouldSendHealthNotification(lastSent: Date?, now: Date, minInterval: TimeInterval) -> Bool` (static, pure)
  - `NotificationService.notifyRepeatedFailures(account: String, consecutiveFailures: Int, lastError: String, defaultsKey: String = "HealthNotificationLastSent")` — sends at most one per account per 24 h, records send time in a `[String: Double]` UserDefaults dict under `defaultsKey` (parameterized so tests never touch the production key).

- [ ] **Step 1: Failing tests** — add to `BackupHealthTests.swift`:

```swift
func testHealthNotificationGateAllowsFirstSend() {
    XCTAssertTrue(NotificationService.shouldSendHealthNotification(
        lastSent: nil, now: Date(), minInterval: 86_400))
}

func testHealthNotificationGateBlocksWithin24h() {
    let now = Date()
    XCTAssertFalse(NotificationService.shouldSendHealthNotification(
        lastSent: now.addingTimeInterval(-3_600), now: now, minInterval: 86_400))
}

func testHealthNotificationGateAllowsAfter24h() {
    let now = Date()
    XCTAssertTrue(NotificationService.shouldSendHealthNotification(
        lastSent: now.addingTimeInterval(-90_000), now: now, minInterval: 86_400))
}

func testNotifyRepeatedFailuresRecordsSendTime() {
    let key = "TestHealthNotify-\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: key) }
    NotificationService.shared.notifyRepeatedFailures(
        account: "a@example.com", consecutiveFailures: 2, lastError: "auth failed",
        defaultsKey: key)
    let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
    XCTAssertNotNil(dict?["a@example.com"])
}
```

- [ ] **Step 2: Run — compile FAILURE expected.**

- [ ] **Step 3: Implement** in `NotificationService.swift`:

```swift
// MARK: - Repeated-Failure Escalation

/// Pure gate: at most one health notification per account per minInterval.
static func shouldSendHealthNotification(lastSent: Date?,
                                         now: Date = Date(),
                                         minInterval: TimeInterval = 86_400) -> Bool {
    guard let lastSent else { return true }
    return now.timeIntervalSince(lastSent) >= minInterval
}

/// Escalation for an account that keeps failing: unlike the per-run failure
/// notification, this one names the streak and is rate-limited to one per
/// account per 24 h so a broken account can't be missed OR become noise.
func notifyRepeatedFailures(account: String,
                            consecutiveFailures: Int,
                            lastError: String,
                            defaultsKey: String = "HealthNotificationLastSent") {
    var sent = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double]) ?? [:]
    let last = sent[account].map { Date(timeIntervalSince1970: $0) }
    guard Self.shouldSendHealthNotification(lastSent: last) else { return }
    sent[account] = Date().timeIntervalSince1970
    UserDefaults.standard.set(sent, forKey: defaultsKey)

    let content = UNMutableNotificationContent()
    content.title = "Backups failing for \(account)"
    content.body = "\(consecutiveFailures) backups in a row have failed. Last error: \(lastError)"
    content.sound = .default
    content.categoryIdentifier = "BACKUP_ERROR"
    let request = UNNotificationRequest(identifier: "backup-health-\(UUID().uuidString)",
                                        content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}
```

Wire into `BackupManager+Execution.swift` failure path directly after `completeEntry(id:status:.failed)` (:145):

```swift
let health = BackupHistoryService.shared.health(for: account.email)
if health.consecutiveFailures >= 2 {
    NotificationService.shared.notifyRepeatedFailures(
        account: account.email,
        consecutiveFailures: health.consecutiveFailures,
        lastError: error.localizedDescription)
}
```

- [ ] **Step 4: Run focused class, then full suite — green.** (The `notifyRepeatedFailures` test sends a real UNUserNotification in the test host; that is acceptable — assert only the UserDefaults side effect.)
- [ ] **Step 5: Commit** — `feat: escalate repeated backup failures via rate-limited notification`

---

### Task 3: Menubar health badge

**Files:**
- Modify: `MailKeep/Views/MenubarView.swift` (`MenubarAccountRow`, :196-259)

**Interfaces:** Consumes `BackupHistoryService.shared.health(for:)`. UI-only — no new tests; verified by build + existing suite.

- [ ] **Step 1: Implement**

In `MenubarAccountRow`, add `@ObservedObject private var historyService = BackupHistoryService.shared` and replace `statusColor` (:244-258) so health takes over whenever no backup is actively running:

```swift
var statusColor: Color {
    guard account.isEnabled else { return .gray }
    if let progress = progress {
        switch progress.status {
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        default: return .gray
        }
    }
    let health = historyService.health(for: account.email)
    if health.consecutiveFailures >= 2 { return .red }
    if health.consecutiveFailures == 1 { return .orange }
    return .green
}
```

(Adapt the `progress.status` cases to whatever the existing switch at :244-258 already handles — keep its in-progress behavior identical; only the idle branch changes from its current value to health-derived color.)

Below the `Last: … ago` text (:235-238), add a failure hint when unhealthy:

```swift
if historyService.health(for: account.email).consecutiveFailures >= 2 {
    Text("\(historyService.health(for: account.email).consecutiveFailures) failures — check Settings → Accounts")
        .font(.caption2)
        .foregroundStyle(.red)
}
```

- [ ] **Step 2: Verify** — `xcodebuild build … | tail -5` → BUILD SUCCEEDED; run full suite once (no regressions).
- [ ] **Step 3: Commit** — `feat: menubar shows per-account backup health badge`

---

### Task 4: CredentialProbeService (mockable IMAP login probe)

**Files:**
- Create: `MailKeep/Services/CredentialProbeService.swift` (register in pbxproj, app target)
- Create: `MailKeepTests/CredentialProbeServiceTests.swift` (register, test target)
- Possibly modify: `MailKeepTests/Mocks/MockIMAPService.swift` (only if `shouldFailLogin` doesn't throw `IMAPError.authenticationFailed` — check first; if different, add `var loginError: Error?` honored before the flag)

**Interfaces:**
- Produces (consumed by Task 5):
  - `enum ProbeOutcome: Equatable { case ok; case credentialFailure(String); case transient(String) }`
  - `@MainActor final class CredentialProbeService { static let shared; var makeIMAPService: (EmailAccount) -> any IMAPServiceProtocol; func probe(_ account: EmailAccount) async -> ProbeOutcome }`
- Classification: `IMAPError.authenticationFailed` and `IMAPError.oauthFailed` → `.credentialFailure(localizedDescription)`; every other error → `.transient(localizedDescription)` (network problems are NOT credential issues and must never trigger the re-enter sheet).

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import MailKeep

@MainActor
final class CredentialProbeServiceTests: XCTestCase {

    private func account() -> EmailAccount {
        EmailAccount(email: "probe@example.com", imapServer: "imap.example.com")
    }

    func testProbeSucceedsAndLogsOut() async {
        let mock = MockIMAPService()
        let service = CredentialProbeService()
        service.makeIMAPService = { _ in mock }
        let outcome = await service.probe(account())
        XCTAssertEqual(outcome, .ok)
        let logins = await mock.loginCallCount
        let logouts = await mock.logoutCallCount
        XCTAssertEqual(logins, 1)
        XCTAssertEqual(logouts, 1)
    }

    func testLoginFailureIsCredentialFailure() async {
        let mock = MockIMAPService()
        await mock.setShouldFailLogin(true)   // adapt to the mock's actual API (property vs setter)
        let service = CredentialProbeService()
        service.makeIMAPService = { _ in mock }
        let outcome = await service.probe(account())
        guard case .credentialFailure = outcome else {
            return XCTFail("Expected credentialFailure, got \(outcome)")
        }
    }

    func testConnectFailureIsTransient() async {
        let mock = MockIMAPService()
        await mock.setShouldFailConnect(true)  // adapt to the mock's actual API
        let service = CredentialProbeService()
        service.makeIMAPService = { _ in mock }
        let outcome = await service.probe(account())
        guard case .transient = outcome else {
            return XCTFail("Expected transient, got \(outcome)")
        }
    }
}
```

Adapt mock property access to its actual form (it may be an actor needing `await`, or a class with direct sets). Requirements that must hold regardless: login-failure → credentialFailure, connect-failure → transient, success calls logout exactly once. `CredentialProbeService()` needs a non-singleton `init` for tests — make `init()` internal, keep `shared` for production.

- [ ] **Step 2: Run — compile FAILURE expected.**

- [ ] **Step 3: Implement** `MailKeep/Services/CredentialProbeService.swift`:

```swift
import Foundation

/// Outcome of a lightweight credential probe (connect + login + logout, no mail).
enum ProbeOutcome: Equatable {
    case ok
    /// The server rejected our credentials — user action needed.
    case credentialFailure(String)
    /// Network or other non-credential problem — retry silently later.
    case transient(String)
}

/// Probes an account's stored credentials with a real IMAP login so dead
/// passwords/tokens surface within a day instead of at the next backup
/// failure. The IONOS password that silently failed for 7 weeks (June–July
/// 2026) is the motivating case.
@MainActor
final class CredentialProbeService {
    static let shared = CredentialProbeService()

    /// Injection seam for tests (MockIMAPService).
    var makeIMAPService: (EmailAccount) -> any IMAPServiceProtocol = { IMAPService(account: $0) }

    func probe(_ account: EmailAccount) async -> ProbeOutcome {
        let service = makeIMAPService(account)
        do {
            try await service.connect()
            try await service.login(password: nil)
            try? await service.logout()
            await service.disconnect()
            logInfo("Credential probe OK for \(account.email)")
            return .ok
        } catch let error as IMAPError {
            await service.disconnect()
            switch error {
            case .authenticationFailed, .oauthFailed:
                logWarning("Credential probe FAILED (credentials) for \(account.email): \(error.localizedDescription)")
                return .credentialFailure(error.localizedDescription)
            default:
                logInfo("Credential probe transient error for \(account.email): \(error.localizedDescription)")
                return .transient(error.localizedDescription)
            }
        } catch {
            await service.disconnect()
            return .transient(error.localizedDescription)
        }
    }
}
```

Check `IMAPServiceProtocol` for the exact `disconnect()` signature (non-throwing async) and adjust `await`/`try?` accordingly.

- [ ] **Step 4: Run focused class, then full suite — green.**
- [ ] **Step 5: Commit** — `feat: add CredentialProbeService with mockable IMAP login probe`

---

### Task 5: Daily probe scheduling + feed failures into the credentials sheet

**Files:**
- Modify: `MailKeep/Services/BackupManager.swift` (add `probeTimer` property near :27; start from `init` near :92)
- Create: `MailKeep/Services/BackupManager+CredentialProbe.swift` (register, app target)
- Modify: `MailKeep/Views/Components/MissingPasswordsView.swift` (subtitle copy)
- Modify: `MailKeepTests/CredentialProbeServiceTests.swift` (add scheduling/merge tests)

**Interfaces:**
- Consumes: `CredentialProbeService` (Task 4), `NotificationService.notifyRepeatedFailures` (Task 2 — reused for probe alerts with the same dedupe store), `accountsWithMissingPasswords` sheet flow.
- Produces on `BackupManager` (extension file):
  - `static func probeIsDue(lastProbe: Date?, now: Date) -> Bool` (pure: nil → true; ≥ 24 h → true)
  - `func runCredentialProbeIfDue()` (gates on `!isBackingUp`, `probeIsDue`, then records `Date()` under UserDefaults key `"LastCredentialProbeDate"` and calls `runCredentialProbe()`)
  - `func runCredentialProbe() async` — probes each enabled account sequentially via `CredentialProbeService.shared`; accounts with `.credentialFailure` are appended (deduplicated by id) to `accountsWithMissingPasswords` and trigger `notifyRepeatedFailures(account:consecutiveFailures:1 lastError:reason)`; `.transient` outcomes are logged only.
- Timer: `probeTimer` fires every 3600 s with 300 s tolerance, created in `init` — **guarded so it does not start in the XCTest host** (mirror the `MailKeepApp.isRunningTests` pattern with `NSClassFromString("XCTestCase") == nil`).

- [ ] **Step 1: Failing tests** (add to `CredentialProbeServiceTests.swift`; use `CredentialStore.testFileOverride` + `BackupManager.testAccountsFileOverride` + `KeychainService.testServiceOverride` with per-run unique values, mirroring `MissingCredentialsTests.setUp` exactly):

```swift
func testProbeIsDueSemantics() {
    let now = Date()
    XCTAssertTrue(BackupManager.probeIsDue(lastProbe: nil, now: now))
    XCTAssertFalse(BackupManager.probeIsDue(lastProbe: now.addingTimeInterval(-3_600), now: now))
    XCTAssertTrue(BackupManager.probeIsDue(lastProbe: now.addingTimeInterval(-90_000), now: now))
}

func testCredentialFailureLandsInMissingCredentialsList() async {
    // setUp-style isolation as in MissingCredentialsTests, then:
    let manager = BackupManager()
    let broken = EmailAccount(email: "dead@example.com", imapServer: "imap.example.com")
    manager.accounts = [broken]
    let mock = MockIMAPService()
    await mock.setShouldFailLogin(true)
    CredentialProbeService.shared.makeIMAPService = { _ in mock }
    defer { CredentialProbeService.shared.makeIMAPService = { IMAPService(account: $0) } }

    let notifyKey = "TestProbeNotify-\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: notifyKey) }
    await manager.runCredentialProbe(notificationDefaultsKey: notifyKey)

    XCTAssertEqual(manager.accountsWithMissingPasswords.map(\.email), ["dead@example.com"])
}

func testTransientFailureDoesNotFlagAccount() async {
    let manager = BackupManager()
    let flaky = EmailAccount(email: "flaky@example.com", imapServer: "imap.example.com")
    manager.accounts = [flaky]
    let mock = MockIMAPService()
    await mock.setShouldFailConnect(true)
    CredentialProbeService.shared.makeIMAPService = { _ in mock }
    defer { CredentialProbeService.shared.makeIMAPService = { IMAPService(account: $0) } }

    let notifyKey = "TestProbeNotify-\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: notifyKey) }
    await manager.runCredentialProbe(notificationDefaultsKey: notifyKey)

    XCTAssertTrue(manager.accountsWithMissingPasswords.isEmpty)
}
```

Note: `runCredentialProbe()` must use a parameterizable notification defaults key or accept that a real (rate-limited) notification fires in the test host once per day — prefer adding `notificationDefaultsKey: String = "HealthNotificationLastSent"` as a parameter with the test passing a unique key it removes in tearDown.

- [ ] **Step 2: Run — compile FAILURE expected.**

- [ ] **Step 3: Implement** `BackupManager+CredentialProbe.swift`:

```swift
import Foundation

extension BackupManager {

    static let lastProbeDateKey = "LastCredentialProbeDate"

    /// Pure gate: probe at most once per 24 h.
    nonisolated static func probeIsDue(lastProbe: Date?, now: Date = Date()) -> Bool {
        guard let lastProbe else { return true }
        return now.timeIntervalSince(lastProbe) >= 86_400
    }

    /// Start the hourly check timer. Call once from init; not under XCTest.
    func startCredentialProbeTimer() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        probeTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runCredentialProbeIfDue() }
        }
        timer.tolerance = 300
        probeTimer = timer
        Task { @MainActor in self.runCredentialProbeIfDue() }
    }

    func runCredentialProbeIfDue() {
        guard !isBackingUp else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastProbeDateKey) as? Date
        guard Self.probeIsDue(lastProbe: last) else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastProbeDateKey)
        Task { await runCredentialProbe() }
    }

    /// Probe every enabled account; credential failures join the
    /// missing-credentials sheet and fire a rate-limited notification.
    func runCredentialProbe(notificationDefaultsKey: String = "HealthNotificationLastSent") async {
        logInfo("Running daily credential probe for \(accounts.count) account(s)")
        for account in accounts where account.isEnabled {
            let outcome = await CredentialProbeService.shared.probe(account)
            if case .credentialFailure(let reason) = outcome {
                if !accountsWithMissingPasswords.contains(where: { $0.id == account.id }) {
                    accountsWithMissingPasswords.append(account)
                }
                NotificationService.shared.notifyRepeatedFailures(
                    account: account.email, consecutiveFailures: 1,
                    lastError: reason, defaultsKey: notificationDefaultsKey)
            }
        }
    }
}
```

Add `var probeTimer: Timer?` next to `scheduleTimer` in `BackupManager.swift` and call `startCredentialProbeTimer()` at the end of `init`. Update `MissingPasswordsView` subtitle (currently "…need their credentials re-entered.\nThis can happen after migrating from a previous version.") to:
`"The following accounts need attention: the stored password or Google authorization no longer works.\nRe-enter the password or re-authorize below."`

- [ ] **Step 4: Run focused class, then full suite — green.**
- [ ] **Step 5: Commit** — `feat: daily credential probe feeds failures into the credentials sheet`

---

### Task 6: Fix stats date parsing + per-account stats in Accounts settings

**Files:**
- Modify: `MailKeep/Services/BackupManager+Statistics.swift` (`parseDateFromFilename`, :142-154)
- Modify: `MailKeep/Views/Settings/AccountsSettingsView.swift` (row :14-64)
- Create: `MailKeepTests/StatisticsTests.swift` (register, test target)

**Interfaces:** none new — `parseDateFromFilename` becomes correct for real filenames `<UID>_<yyyyMMdd>_<HHmmss>_<sender>.eml`; it must be made `internal static` (currently `private`) for tests.

- [ ] **Step 1: Failing tests** (`StatisticsTests.swift`):

```swift
import XCTest
@testable import MailKeep

final class StatisticsTests: XCTestCase {
    func testParseDateFromRealFilename() {
        let date = BackupManager.parseDateFromFilename("8436_20260711_141521_Talk_der_Nation.eml")
        XCTAssertNotNil(date)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 11)
        XCTAssertEqual(comps.hour, 14)
    }

    func testParseDateFromCollisionSuffixedFilename() {
        XCTAssertNotNil(BackupManager.parseDateFromFilename("8436_20260711_141521_Sender_1.eml"))
    }

    func testParseDateReturnsNilForGarbage() {
        XCTAssertNil(BackupManager.parseDateFromFilename("not-an-email.eml"))
        XCTAssertNil(BackupManager.parseDateFromFilename(".uid_cache"))
    }
}
```

- [ ] **Step 2: Run — FAILURE expected** (symbol private / wrong parsing).

- [ ] **Step 3: Implement** — replace `parseDateFromFilename` with (keep it `nonisolated`, raise visibility to `internal static`):

```swift
/// Filenames are "<UID>_<yyyyMMdd>_<HHmmss>_<sender>[ _N].eml".
/// Find the first component that is an 8-digit date and pair it with the
/// following 6-digit time — robust to the numeric UID prefix (which the
/// previous implementation mistook for the date, leaving stats dateless).
internal nonisolated static func parseDateFromFilename(_ filename: String) -> Date? {
    let base = (filename as NSString).deletingPathExtension
    let parts = base.split(separator: "_").map(String.init)
    for index in parts.indices.dropLast() {
        let candidate = parts[index], time = parts[index + 1]
        if candidate.count == 8, candidate.allSatisfy(\.isNumber),
           time.count == 6, time.allSatisfy(\.isNumber) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.date(from: "\(candidate)_\(time)")
        }
    }
    return nil
}
```

Then in `AccountsSettingsView`'s per-account row, under the `imapServer` caption (:28-30), add a stats line loaded like `AccountRowView` does (:35-58):

```swift
@State private var stats: [UUID: AccountStats] = [:]   // on the parent view
```
and in the row VStack:
```swift
if let s = stats[account.id] {
    Text("\(s.totalEmails) emails · \(ByteCountFormatter.string(fromByteCount: s.totalSize, countStyle: .file))")
        .font(.caption2)
        .foregroundStyle(.secondary)
}
```
with a `.task(id: account.id) { stats[account.id] = await backupManager.getStats(for: account) }` on the row content. Follow the exact state/task placement pattern in `AccountRowView.swift:35-58`.

- [ ] **Step 4: Run focused class, full suite, and a build — green.**
- [ ] **Step 5: Commit** — `fix: stats date parsing skips the UID prefix; show per-account stats in settings`

---

### Task 7: StorageService email enumeration API

**Files:**
- Modify: `MailKeep/Services/StorageService.swift`
- Modify: `MailKeepTests/StorageServiceTests.swift` (append tests; follow its temp-dir setUp pattern at :9-25)

**Interfaces:**
- Produces (consumed by Task 8/9): `StorageService.listEmailFiles(accountEmail: String) throws -> [URL]` — every `.eml` under the account directory, recursive, **excluding** hidden files/dirs (`.uid_cache`, `.hash_index`), `*.tmp`, and attachment folders' contents (attachment folders contain no `.eml`, so `.eml`-extension filtering suffices); sorted by path for deterministic output; empty array (not an error) when the account directory doesn't exist.

- [ ] **Step 1: Failing tests** — append to `StorageServiceTests.swift`:

```swift
func testListEmailFilesReturnsAllEmlRecursively() async throws {
    let email = Email(uid: 1, messageId: "<m1>", date: Date(), sender: "Alice", subject: "Hi")
    _ = try await storageService.saveEmail(Data("mail one".utf8), email: email,
                                           accountEmail: "list@example.com", folderPath: "INBOX")
    let email2 = Email(uid: 2, messageId: "<m2>", date: Date(), sender: "Bob", subject: "Yo")
    _ = try await storageService.saveEmail(Data("mail two".utf8), email: email2,
                                           accountEmail: "list@example.com", folderPath: "Work/Projects")
    let files = try await storageService.listEmailFiles(accountEmail: "list@example.com")
    XCTAssertEqual(files.count, 2)
    XCTAssertTrue(files.allSatisfy { $0.pathExtension == "eml" })
    XCTAssertEqual(files, files.sorted { $0.path < $1.path })
}

func testListEmailFilesSkipsSidecarsAndTmp() async throws {
    let email = Email(uid: 3, messageId: "<m3>", date: Date(), sender: "C", subject: "S")
    let saved = try await storageService.saveEmail(Data("mail".utf8), email: email,
                                                   accountEmail: "list2@example.com", folderPath: "INBOX")
    let dir = saved.deletingLastPathComponent()
    try Data("junk".utf8).write(to: dir.appendingPathComponent("leftover.tmp"))
    // .uid_cache already exists from saveEmail
    let files = try await storageService.listEmailFiles(accountEmail: "list2@example.com")
    XCTAssertEqual(files.count, 1)
}

func testListEmailFilesForUnknownAccountIsEmpty() async throws {
    let files = try await storageService.listEmailFiles(accountEmail: "ghost@example.com")
    XCTAssertTrue(files.isEmpty)
}
```

Adapt the `Email` initializer to its actual signature (read `Models/Email.swift` init before writing; the fields above are indicative).

- [ ] **Step 2: Run — compile FAILURE expected.**

- [ ] **Step 3: Implement** in `StorageService.swift` (near `getEmailCount`, :527):

```swift
/// All stored .eml files for an account, recursive, deterministic order.
/// Hidden sidecars (.uid_cache/.hash_index) and in-flight *.tmp are excluded.
/// Missing account directory → empty array (a new account has no backups yet).
func listEmailFiles(accountEmail: String) throws -> [URL] {
    let accountDir = baseURL.appendingPathComponent(accountEmail.sanitizedForFilename())
    guard FileManager.default.fileExists(atPath: accountDir.path) else { return [] }
    guard let enumerator = FileManager.default.enumerator(
        at: accountDir, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]) else { return [] }
    var result: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "eml" {
        result.append(url)
    }
    return result.sorted { $0.path < $1.path }
}
```

- [ ] **Step 4: Run StorageServiceTests, then full suite — green.**
- [ ] **Step 5: Commit** — `feat: StorageService.listEmailFiles enumeration API`

---

### Task 8: MboxExportService (mboxrd writer)

**Files:**
- Create: `MailKeep/Services/MboxExportService.swift` (register, app target)
- Create: `MailKeepTests/MboxExportServiceTests.swift` (register, test target)

**Interfaces:**
- Produces (consumed by Task 9):
  - `struct MboxExportSummary: Equatable { var exported: Int; var skippedUnreadable: Int }`
  - `actor MboxExportService { func export(emlFiles: [URL], to destination: URL, progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) throws -> MboxExportSummary }`
- Format (mboxrd, the variant Thunderbird/Apple Mail import): per message — separator line `From MAILER-DAEMON <asctime of file mtime, en_US_POSIX, e.g. "Fri Jul 25 17:41:00 2026">\n`; message bytes with CRLF and lone CR normalized to LF; any body line matching `^>*From ` prefixed with one additional `>`; ensure the message ends with `\n` and append one empty line after each message. Unreadable files are skipped and counted, never fatal. Output written incrementally via `FileHandle` (no whole-mailbox buffering); destination truncated/created at start.

- [ ] **Step 1: Failing tests** (`MboxExportServiceTests.swift`):

```swift
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

    func testExportProducesSeparatorPerMessage() async throws {
        let a = try writeEml("1.eml", "Subject: A\r\n\r\nbody A\r\n")
        let b = try writeEml("2.eml", "Subject: B\r\n\r\nbody B\r\n")
        let dest = tempDir.appendingPathComponent("out.mbox")
        let summary = try await MboxExportService().export(emlFiles: [a, b], to: dest)
        XCTAssertEqual(summary, MboxExportSummary(exported: 2, skippedUnreadable: 0))
        let text = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\nFrom MAILER-DAEMON ").count
                       + (text.hasPrefix("From MAILER-DAEMON ") ? 0 : 1), 2, "expected 2 separators")
        XCTAssertFalse(text.contains("\r"), "CRLF must be normalized to LF")
    }

    func testFromLinesAreQuoted() async throws {
        let a = try writeEml("1.eml", "Subject: T\n\nFrom here on\n>From quoted already\nnot From\n")
        let dest = tempDir.appendingPathComponent("out.mbox")
        _ = try await MboxExportService().export(emlFiles: [a], to: dest)
        let text = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(text.contains("\n>From here on\n"))
        XCTAssertTrue(text.contains("\n>>From quoted already\n"))
        XCTAssertTrue(text.contains("\nnot From\n"))
    }

    func testUnreadableFileIsSkippedNotFatal() async throws {
        let a = try writeEml("1.eml", "Subject: A\n\nok\n")
        let missing = tempDir.appendingPathComponent("gone.eml")
        let dest = tempDir.appendingPathComponent("out.mbox")
        let summary = try await MboxExportService().export(emlFiles: [a, missing], to: dest)
        XCTAssertEqual(summary.exported, 1)
        XCTAssertEqual(summary.skippedUnreadable, 1)
    }

    func testProgressCallbackCounts() async throws {
        let a = try writeEml("1.eml", "x\n")
        let b = try writeEml("2.eml", "y\n")
        let dest = tempDir.appendingPathComponent("out.mbox")
        let counter = ProgressCounter()
        _ = try await MboxExportService().export(emlFiles: [a, b], to: dest) { done, total in
            Task { await counter.record(done: done, total: total) }
        }
        // allow the async recordings to land
        try await Task.sleep(nanoseconds: 200_000_000)
        let final = await counter.last
        XCTAssertEqual(final?.total, 2)
        XCTAssertEqual(final?.done, 2)
    }
}

private actor ProgressCounter {
    var last: (done: Int, total: Int)?
    func record(done: Int, total: Int) { last = (done, total) }
}
```

- [ ] **Step 2: Run — compile FAILURE expected.**

- [ ] **Step 3: Implement** `MailKeep/Services/MboxExportService.swift`:

```swift
import Foundation

struct MboxExportSummary: Equatable {
    var exported: Int
    var skippedUnreadable: Int
}

/// Writes stored .eml files into a single mboxrd file (importable by
/// Apple Mail, Thunderbird, mutt, …). A backup you can't restore elsewhere
/// is a hope, not a backup — this is the "get my mail out" path.
actor MboxExportService {

    enum MboxExportError: LocalizedError {
        case cannotCreateDestination(String)
        var errorDescription: String? {
            switch self {
            case .cannotCreateDestination(let path):
                return "Cannot create export file at \(path)"
            }
        }
    }

    func export(emlFiles: [URL], to destination: URL,
                progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) throws -> MboxExportSummary {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw MboxExportError.cannotCreateDestination(destination.path)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var summary = MboxExportSummary(exported: 0, skippedUnreadable: 0)
        let total = emlFiles.count
        let asctime = DateFormatter()
        asctime.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        asctime.locale = Locale(identifier: "en_US_POSIX")

        for (index, file) in emlFiles.enumerated() {
            guard let raw = try? Data(contentsOf: file) else {
                summary.skippedUnreadable += 1
                progress?(index + 1, total)
                continue
            }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date()
            let separator = "From MAILER-DAEMON \(asctime.string(from: mtime))\n"
            try handle.write(contentsOf: Data(separator.utf8))
            try handle.write(contentsOf: Self.mboxrdBody(from: raw))
            summary.exported += 1
            progress?(index + 1, total)
        }
        return summary
    }

    /// Normalize CRLF/CR to LF, quote ^>*From_ lines, guarantee trailing
    /// newline plus one blank separator line. Operates on bytes so binary
    /// attachment payloads survive untouched apart from line endings.
    static func mboxrdBody(from raw: Data) -> Data {
        var normalized = Data(capacity: raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            let byte = raw[i]
            if byte == 0x0D {                       // CR or CRLF → LF
                normalized.append(0x0A)
                let next = raw.index(after: i)
                i = (next < raw.endIndex && raw[next] == 0x0A) ? raw.index(after: next) : next
            } else {
                normalized.append(byte)
                i = raw.index(after: i)
            }
        }
        var out = Data(capacity: normalized.count + 64)
        for line in normalized.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var idx = line.startIndex
            while idx < line.endIndex, line[idx] == UInt8(ascii: ">") { idx = line.index(after: idx) }
            let restStartsWithFrom = line[idx...].starts(with: Data("From ".utf8))
            if restStartsWithFrom { out.append(UInt8(ascii: ">")) }
            out.append(contentsOf: line)
            out.append(0x0A)
        }
        // split with omittingEmptySubsequences:false yields a trailing empty
        // element when data ends in \n — that became our final newline. Add
        // the blank message separator line:
        if out.last != 0x0A { out.append(0x0A) }
        out.append(0x0A)
        return out
    }
}
```

Note for the implementer: the `split`-based rewrite appends a newline per element, which can add one extra trailing newline compared to the input — that is fine for mbox (extra blank line between messages is legal); the tests assert separators and quoting, not byte-exact trailers. If a test above conflicts with the exact trailing-newline behavior, adjust the IMPLEMENTATION comment and test together so quoting and separator counts (the format-critical parts) hold.

- [ ] **Step 4: Run focused class, then full suite — green.**
- [ ] **Step 5: Commit** — `feat: MboxExportService writes mboxrd exports`

---

### Task 9: Export UI + docs

**Files:**
- Modify: `MailKeep/Views/MainWindow/MainWindowView.swift` (`AccountDetailView`, next to "Open in Finder" :168-172)
- Modify: `README.md` (feature list) and `CLAUDE.md` only if it enumerates features (check; likely no change)

**Interfaces:** Consumes `StorageService.listEmailFiles` (Task 7) and `MboxExportService` (Task 8). UI verified by build.

- [ ] **Step 1: Implement**

In `AccountDetailView` add state:

```swift
@State private var isExporting = false
@State private var exportMessage: String?
```

Next to the "Open in Finder" button (:168-172):

```swift
Button {
    exportAccount()
} label: {
    if isExporting {
        ProgressView().controlSize(.small)
    } else {
        Label("Export as .mbox…", systemImage: "square.and.arrow.up")
    }
}
.disabled(isExporting)
```

and the handler (NSSavePanel pattern from EmailBrowserView.swift:684-694):

```swift
private func exportAccount() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(account.email).mbox"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    isExporting = true
    exportMessage = nil
    let storage = StorageService(baseURL: backupManager.backupLocation)
    Task {
        do {
            let files = try await storage.listEmailFiles(accountEmail: account.email)
            let summary = try await MboxExportService().export(emlFiles: files, to: destination)
            await MainActor.run {
                isExporting = false
                exportMessage = "Exported \(summary.exported) emails" +
                    (summary.skippedUnreadable > 0 ? " (\(summary.skippedUnreadable) unreadable skipped)" : "")
            }
        } catch {
            await MainActor.run {
                isExporting = false
                exportMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
```

Show `exportMessage` as a caption below the button row (`Text(exportMessage ?? "")` guarded with `if let`). Match `AccountDetailView`'s existing property names for the account/backupManager (read the surrounding struct first — the account property may be named differently, e.g. `let account: EmailAccount` vs a binding).

- [ ] **Step 2: README** — add to the feature list: backup-health menubar badge, daily credential probe, `.mbox` export. One line each, factual.

- [ ] **Step 3: Verify** — `xcodebuild build … | tail -5` → BUILD SUCCEEDED; full suite once.
- [ ] **Step 4: Commit** — `feat: export account backups as .mbox from the account detail view`

---

## Post-merge manual verification (with the user)

1. `./scripts/install.sh`, launch, open the menubar — every healthy account shows a green dot; break a password on a throwaway account and run a backup twice → dot turns red and one notification arrives (a second failure within 24 h stays silent).
2. Settings → Accounts shows per-account email counts/sizes; account detail shows non-nil oldest/newest dates (the date-parsing fix).
3. Export a small account to `.mbox`, import into Apple Mail (File → Import Mailboxes → "Files in mbox format") — messages readable.
4. Next morning: credential probe has run (`LastCredentialProbeDate` set); no false-positive sheet.

## Task dependencies

- Task 1 → Task 2 → Task 3 (strict)
- Task 4 → Task 5 (strict); independent of 1–3
- Task 6 independent
- Task 7 → Task 8 → Task 9 (strict)
