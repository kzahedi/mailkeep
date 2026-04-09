# IMAP IDLE Real-Time Inbox Monitoring — Design Spec

**Date:** 2026-04-09
**Issue:** #37
**Status:** Approved

---

## Goal

Add IMAP IDLE support so MailKeep is notified immediately when new mail arrives in INBOX, triggering an incremental backup without waiting for the next scheduled run. Scheduled backups continue to run as a correctness sweep (catching moves, deletions, and any missed notifications).

---

## Background: IMAP IDLE Protocol

RFC 2177 defines IMAP IDLE. The client sends the `IDLE` command; the server holds the connection open and sends untagged responses as mailbox state changes:

- `* N EXISTS` — mailbox now contains N messages (new mail arrived)
- `* N EXPUNGE` — message N was removed
- `* N FETCH (FLAGS (...))` — flags changed on message N

The client sends `DONE\r\n` to exit IDLE mode before issuing any other command.

**Key constraints:**
- IDLE only works on the currently selected folder (INBOX in our case).
- IDLE does not tell you *what* moved *where* — only that EXISTS count changed.
- RFC 2177 recommends clients re-issue IDLE at least every 29 minutes (servers may close idle connections at 30 minutes). We use 25 minutes.
- After receiving `EXISTS`, we exit IDLE, fetch new UIDs, download them, then re-enter IDLE.
- IDLE is INBOX-only in this design. Moved/deleted mail in other folders is handled by scheduled backups.

---

## Section 1: Settings Model

### Global toggle

```swift
// UserDefaults key in BackupManager
let idleEnabledKey = "idleEnabled"  // Bool, default false (opt-in)
```

Stored in `UserDefaults.standard`. Default is **off** — IDLE keeps a persistent TCP connection per account, so it's opt-in.

### Per-account toggle

Add `idleEnabled: Bool?` to `EmailAccount`:

```swift
struct EmailAccount: Codable, Identifiable {
    // ... existing fields ...
    var idleEnabled: Bool?  // nil = inherit global (treated as true when global is on)
}
```

`nil` means "follow global setting". `false` means explicitly disabled for this account regardless of global. `true` means enabled (but only effective when global is also on).

Effective logic: `globalEnabled && (account.idleEnabled ?? true)`

---

## Section 2: IDLEManager Actor

Central coordinator. One instance (`IDLEManager.shared`). Maintains one persistent `IMAPService` connection per monitored account.

```swift
actor IDLEManager {
    static let shared = IDLEManager()

    private var monitors: [UUID: Task<Void, Never>] = [:]
    private var onNewMailCallbacks: [UUID: (UUID) -> Void] = [:]

    func startMonitoring(accounts: [EmailAccount], onNewMail: @escaping (UUID) -> Void) {
        for account in accounts {
            guard monitors[account.id] == nil else { continue }
            onNewMailCallbacks[account.id] = onNewMail
            let task = Task { await self.runMonitor(for: account) }
            monitors[account.id] = task
        }
    }

    func stopMonitoring(accountId: UUID) {
        monitors[accountId]?.cancel()
        monitors.removeValue(forKey: accountId)
        onNewMailCallbacks.removeValue(forKey: accountId)
    }

    func stopAll() {
        for task in monitors.values { task.cancel() }
        monitors.removeAll()
        onNewMailCallbacks.removeAll()
    }
}
```

### Monitor loop (`runMonitor`)

```swift
private func runMonitor(for account: EmailAccount) async {
    while !Task.isCancelled {
        let service = IMAPService(account: account)
        do {
            try await service.connect()
            try await service.login()
            _ = try await service.selectFolder("INBOX")
            var lastUID = try await service.fetchLastUID()

            while !Task.isCancelled {
                let notification = try await service.waitForIDLENotification(timeout: 25 * 60)
                switch notification {
                case .exists:
                    let newUIDs = try await service.fetchNewUIDs(after: lastUID)
                    if !newUIDs.isEmpty {
                        lastUID = newUIDs.max() ?? lastUID
                        let cb = onNewMailCallbacks[account.id]
                        cb?(account.id)
                    }
                    // Re-enter IDLE (waitForIDLENotification sends IDLE at start)
                case .timeout:
                    // 25-minute keepalive: DONE was sent, re-enter IDLE
                    break
                }
            }
            try? await service.logout()
        } catch {
            // Connection lost — wait 30s then reconnect
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }
}
```

Reconnect-on-error loop: any throw (network drop, auth failure, server disconnect) causes a 30-second pause then full reconnect. Task cancellation exits cleanly.

---

## Section 3: IMAPService+IDLE Extension

Four new methods added to `IMAPService` in a new file `IMAPService+IDLE.swift`.

### `sendIDLE()`

Sends `TAG IDLE\r\n` and reads until the server sends `+ idling` (or equivalent continuation response). Throws if the server returns an error (e.g., server doesn't support IDLE — check `CAPABILITY` response on connect and skip IDLE if `IDLE` is absent).

```swift
func sendIDLE() async throws {
    let tag = nextTag()
    try await send("\(tag) IDLE\r\n")
    // Read lines until continuation response "+ ..."
    let response = try await readUntilContinuation()
    guard response.hasPrefix("+") else {
        throw IMAPError.idleNotSupported
    }
}
```

### `sendDone()`

Sends `DONE\r\n` (no tag — DONE is not a tagged command) and reads until the tagged OK response for the original IDLE tag.

```swift
func sendDone() async throws {
    try await send("DONE\r\n")
    try await readUntilTaggedOK(tag: currentIDLETag)
}
```

### `waitForIDLENotification(timeout:)`

Sends IDLE, then reads server responses line-by-line until:
- An `EXISTS` response arrives → sends DONE, returns `.exists(count)`
- Timeout elapses → sends DONE, returns `.timeout`
- Task is cancelled → sends DONE, throws `CancellationError`

```swift
func waitForIDLENotification(timeout: TimeInterval) async throws -> IDLENotification {
    try await sendIDLE()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard !Task.isCancelled else {
            try await sendDone()
            throw CancellationError()
        }
        let line = try await readLineWithTimeout(timeout: deadline.timeIntervalSinceNow)
        if line.contains("EXISTS") {
            let count = parseExistsCount(from: line)
            try await sendDone()
            return .exists(count)
        }
        // Ignore EXPUNGE, FLAGS, etc. — scheduled backup handles those
    }
    try await sendDone()
    return .timeout
}

enum IDLENotification {
    case exists(Int)
    case timeout
}
```

### `fetchNewUIDs(after lastUID: UInt32)`

Issues `UID SEARCH UID lastUID+1:*` to find UIDs greater than `lastUID`. Returns an empty array if none exist.

```swift
func fetchNewUIDs(after lastUID: UInt32) async throws -> [UInt32] {
    let tag = nextTag()
    let nextUID = lastUID + 1
    try await send("\(tag) UID SEARCH UID \(nextUID):*\r\n")
    return try await readSearchResponse(tag: tag)
}
```

### `fetchLastUID()`

Issues `UID SEARCH ALL` on the selected folder and returns the maximum UID, or 0 if empty.

```swift
func fetchLastUID() async throws -> UInt32 {
    let tag = nextTag()
    try await send("\(tag) UID SEARCH ALL\r\n")
    let uids = try await readSearchResponse(tag: tag)
    return uids.max() ?? 0
}
```

---

## Section 4: BackupManager Integration

### New file: `BackupManager+IDLE.swift`

```swift
extension BackupManager {

    // MARK: - IDLE Lifecycle

    func startIDLEMonitoring() {
        guard UserDefaults.standard.bool(forKey: idleEnabledKey) else { return }
        let idleAccounts = accounts.filter { account in
            account.idleEnabled ?? true
        }
        IDLEManager.shared.startMonitoring(accounts: idleAccounts) { [weak self] accountId in
            guard let self else { return }
            Task { @MainActor in
                await self.triggerIncrementalBackup(for: accountId)
            }
        }
    }

    func stopIDLEMonitoring() {
        Task { await IDLEManager.shared.stopAll() }
    }

    func restartIDLEMonitoring(for account: EmailAccount) {
        Task { await IDLEManager.shared.stopMonitoring(accountId: account.id) }
        startIDLEMonitoring()
    }

    // MARK: - Incremental Backup

    private func triggerIncrementalBackup(for accountId: UUID) async {
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }
        guard activeTasks[accountId] == nil else { return }  // full backup already running
        logInfo("IDLE notification received for \(account.email) — starting incremental backup")
        await performBackup(for: account)
    }
}
```

### Call sites in `BackupManager`

| Where | What |
|-------|------|
| `init()` | Call `startIDLEMonitoring()` after loading accounts |
| `saveAccount(_:)` | Call `restartIDLEMonitoring(for: account)` |
| `deleteAccount(_:)` | Call `IDLEManager.shared.stopMonitoring(accountId:)` |
| `setIDLEEnabled(_:)` | Call `startIDLEMonitoring()` or `stopIDLEMonitoring()` |

---

## Section 5: UI Changes

### SettingsView — Schedule tab

Add a toggle row above or below the schedule configuration:

```
───────────────────────────────────
 Real-Time Inbox Monitoring
 [toggle]  Monitor INBOX for new mail
           Keeps a connection open. Uses more battery.
───────────────────────────────────
```

Binding: `UserDefaults.standard` key `idleEnabled`. On toggle-on, call `BackupManager.shared.startIDLEMonitoring()`. On toggle-off, call `BackupManager.shared.stopIDLEMonitoring()`.

### EditAccountView — IMAP Settings section

Add a toggle row after the existing server/port fields:

```
 [toggle]  Real-Time Monitoring
           Disabled — enable in Settings → Schedule first
           (label shown when global toggle is off)
```

Binding: `account.idleEnabled` (stored as `Bool?`; toggle represents `true`/`false`, with `nil` treated as `true`). Toggle is disabled (grayed) when global `idleEnabled` is `false`, with explanatory label.

---

## Non-Goals

- IDLE on folders other than INBOX — scheduled backups handle other folders
- Detecting which folder a moved message went to — IDLE cannot tell us
- Showing a live "new mail" badge — notification is sent via existing `NotificationService`
- IDLE on accounts using OAuth token refresh (works the same; IMAPService handles auth)

---

## Testing

- Unit test `fetchNewUIDs(after:)` with mock IMAP responses
- Unit test `IDLEManager` monitor loop with cancellation and reconnect paths
- Unit test `BackupManager+IDLE` lifecycle (start/stop/restart call sites)
- Integration test: manual test against a real IMAP server — send a test email, verify backup triggers within ~5 seconds

---

## File Map

| File | Action |
|------|--------|
| `IMAPBackup/Services/IMAPService+IDLE.swift` | Create |
| `IMAPBackup/Services/IDLEManager.swift` | Create |
| `IMAPBackup/Services/BackupManager+IDLE.swift` | Create |
| `IMAPBackup/Models/EmailAccount.swift` | Modify — add `idleEnabled: Bool?` |
| `IMAPBackup/Services/BackupManager.swift` | Modify — add `idleEnabledKey`, call sites in `init`, `saveAccount`, `deleteAccount` |
| `IMAPBackup/Views/Settings/ScheduleSettingsView.swift` | Modify — add global IDLE toggle |
| `IMAPBackup/Views/Accounts/EditAccountView.swift` | Modify — add per-account IDLE toggle |
| `IMAPBackupTests/Services/IDLEManagerTests.swift` | Create |
| `IMAPBackupTests/Services/IMAPServiceIDLETests.swift` | Create |
| `IMAPBackupTests/Services/BackupManagerIDLETests.swift` | Create |
| `IMAPBackup.xcodeproj/project.pbxproj` | Modify — add all new source files |
