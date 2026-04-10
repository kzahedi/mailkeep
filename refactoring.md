# Refactoring & Fix Backlog

Generated from code review + GitHub workflow review — 2026-04-10.

---

## 🔴 Critical

### C1 — UInt32→Int32 truncation corrupts UIDs in SQLite
**File:** `IMAPBackup/Services/DatabaseService.swift:111,173,247`
`sqlite3_bind_int` stores IMAP UIDs as `Int32`. Any UID ≥ 2,147,483,648 silently truncates, causing those emails to re-download on every backup.
**Fix:** Replace `sqlite3_bind_int` / `sqlite3_column_int` with `sqlite3_bind_int64` / `sqlite3_column_int64` throughout.

---

### C2 — `readResponse()` returns `""` on non-UTF-8 data — infinite hang risk
**File:** `IMAPBackup/Services/IMAPService.swift:812–817`
Non-UTF-8 bytes (binary attachments, non-UTF-8 server error text) cause `readResponse()` to return an empty string. Any `while true` read loop calling it — including the IDLE reader — spins forever.
**Fix:** Decode with `.isoLatin1` fallback (never fails), or throw `IMAPError.receiveFailed("Non-UTF-8 response")`.

---

### C3 — Streaming fetch corrupts binary email bodies
**File:** `IMAPBackup/Services/IMAPService.swift` — `performStreamingFetch`
The streaming path round-trips raw bytes through `String(data:encoding:.utf8)` then back to `Data`. Invalid UTF-8 bytes (binary attachments) are silently dropped. The in-memory path (`fetchEmailWithLiteralParsing`) correctly uses raw `Data` reads.
**Fix:** Give the streaming path its own raw `Data` receive loop, bypassing `readResponse()`.

---

### C4 — CI: `| xcpretty || true` silently masks test failures
**File:** `.github/workflows/ci.yml:53`
`xcpretty` is not installed on macOS runners. The pipe makes the pipeline exit code the exit code of `xcpretty` (not `xcodebuild`). Failing tests show green in CI.
**Fix:** Add `set -o pipefail` and install xcpretty, or remove it entirely and use raw `xcodebuild` output.

---

### C5 — Release workflow: `OAuthSecrets.swift` never generated
**File:** `.github/workflows/release.yml`
`ci.yml` has a step to generate `OAuthSecrets.swift` from GitHub Secrets. `release.yml` does not. Every release build fails immediately with a Swift compile error.
**Fix:** Copy the generation step from `ci.yml` into `release.yml` before the build step.

---

### C6 — Release workflow: expression injection via `workflow_dispatch` version input
**File:** `.github/workflows/release.yml:32–33,43–44`
The version input is interpolated directly into shell commands without validation. A collaborator with Actions write access can execute arbitrary code in the runner.
**Fix:** Validate the version format before use:
```bash
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Invalid version: $VERSION"; exit 1
fi
```

---

## 🟠 Important

### I1 — `isConnected` set after continuation resumes
**File:** `IMAPBackup/Services/IMAPService.swift:228–235`
`continuation.resume()` fires before `Task { await self?.setConnected(true) }` runs. If the caller immediately checks `isConnectionHealthy()`, it returns false and may trigger a spurious reconnect.
**Fix:** Set `isConnected = true` before resuming the continuation, or restructure to avoid the actor hop.

---

### I2 — `ContinuationState.hasResumed` is an unprotected TOCTOU race
**File:** `IMAPBackup/Services/IMAPService.swift:217–248`
`ContinuationState` is a plain `class`; `hasResumed` is accessed from whatever thread NWConnection calls back on. Two simultaneous state callbacks can both pass the `guard !state.hasResumed` check.
**Fix:** Protect `hasResumed` with `NSLock` or `os_unfair_lock`.

---

### I3 — Actor isolation violated in `StorageService` and `SearchService`
**Files:** `IMAPBackup/Services/StorageService.swift:101–141`, `SearchService.swift:160,185`
`DispatchQueue.global().async { self.fileManager... }` accesses actor-isolated properties from arbitrary GCD threads. Will be a compile error under Swift 6 strict concurrency.
**Fix:** Replace with `Task.detached(priority: .utility)` or mark the relevant methods `nonisolated` (they only touch immutable state).

---

### I4 — Force-unwrap crash: regex range captures
**File:** `IMAPBackup/Services/IMAPService.swift:849–851`
`Range(match.range(at: N), in: line)!` — `Range(_:in:)` can return `nil`.
**Fix:** Use `guard let` with a `nil` return.

---

### I5 — Force-unwrap crash: `windows.first!` with no windows
**File:** `IMAPBackup/Services/GoogleOAuthService.swift:361`
Crashes if there are no windows (headless or early launch).
**Fix:** `return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()`

---

### I6 — Force-unwrap crash: `components.day! += 1`
**File:** `IMAPBackup/Services/BackupManager+Scheduling.swift:94`
`components.day` is `Optional<Int>` — crashes if `Calendar.dateComponents` doesn't populate `.day`.
**Fix:** `if let day = components.day { components.day = day + 1 }`

---

### I7 — Force-unwrap crash: `components.url!`
**File:** `IMAPBackup/Services/GoogleOAuthService.swift:208`
`URLComponents.url` returns `nil` if any component contains an invalid character.
**Fix:** `guard let url = components.url else { throw GoogleOAuthError.notConfigured }; return url`

---

### I8 — `AppDelegate` hardcodes backup location as `Documents/MailKeep`
**File:** `IMAPBackup/App/AppDelegate.swift:17–22`
`validateUIDCaches` always scans `~/Documents/MailKeep`, ignoring the user-configured backup location. Scans the wrong directory if the user changed it.
**Fix:** Read the location from `UserDefaults.standard.string(forKey: "BackupLocation")` with the same fallback as `BackupManager.init`.

---

### I9 — `sendDone` silently returns on `NO` response
**File:** `IMAPBackup/Services/IMAPService+IDLE.swift:129`
A `NO` response to `DONE` means the IMAP command was rejected — connection state is undefined. The function currently returns without throwing.
**Fix:** `throw IMAPError.commandFailed("DONE rejected with NO: \(chunk)")` on the `NO` branch.

---

### I10 — IDLE timeout path doesn't send `DONE` before disconnecting
**File:** `IMAPBackup/Services/IMAPService+IDLE.swift`
RFC 2177 §3 requires the client to send `DONE` before closing a connection in IDLE mode. The timeout path calls `disconnect()` directly without sending `DONE`, which may cause server-side log noise or throttling.
**Fix:** Send `DONE\r\n` in the timeout task before cancelling the reader, then disconnect.

---

### I11 — `IDLEManager` creates `IMAPService` without rate limiting
**File:** `IMAPBackup/Services/IDLEManager.swift:57`
Each reconnect creates a fresh `IMAPService` that never calls `configureRateLimit`. Under aggressive reconnect conditions, `connect()` and `login()` hammer the server without throttling.
**Fix:** Call `configureRateLimit(...)` on the service after creation in `runMonitor`, or accept a factory closure from `startMonitoring`.

---

### I12 — `parseListLine` regex doesn't handle `NIL` delimiter
**File:** `IMAPBackup/Services/IMAPService.swift:843–865`
Flat-namespace IMAP servers return `* LIST (\Noselect) NIL ""`. The current regex expects a quoted single character for the delimiter and silently skips `NIL`, hiding folders.
**Fix:** Make the delimiter group handle `NIL`: `"(.)|NIL"`.

---

### I13 — Account list stored in unencrypted UserDefaults
**File:** `IMAPBackup/Services/BackupManager+Accounts.swift:116–122`
The full `[EmailAccount]` array (email addresses, server hostnames, ports, auth type) is written to the unencrypted plist at `~/Library/Preferences/`. Readable by any same-user process.
**Fix:** Store the account list in the Keychain as a JSON blob, or document this as a conscious trade-off.

---

### I14 — `RetentionService.applyRetention` blocks the main thread
**File:** `IMAPBackup/Services/BackupManager+Operations.swift:84–89`
`RetentionService` is `@MainActor`. `applyRetention` performs synchronous file enumeration on the main actor, freezing the UI on large backups.
**Fix:** Dispatch file enumeration to `Task.detached(priority: .utility)` inside `applyRetention`.

---

### I15 — `BackupLocationManager` uses `URL(string:)` for file paths
**File:** `IMAPBackup/Services/StorageService.swift:584–599`
Stores file URLs via `url.absoluteString` and reads them back via `URL(string:)`. Paths with spaces or special characters may not round-trip correctly.
**Fix:** Store `url.path`, retrieve with `URL(fileURLWithPath:)`.

---

### I16 — CI: No `permissions:` block — over-privileged GITHUB_TOKEN
**File:** `.github/workflows/ci.yml`, `release.yml`
Without an explicit `permissions:` block, the GITHUB_TOKEN defaults to read+write on all scopes (on older repos). The CI token can push code, create releases, and more.
**Fix:** Add least-privilege permissions to each job:
```yaml
permissions:
  contents: read   # ci.yml
  contents: write  # release.yml (for creating releases)
```

---

### I17 — CI: Third-party actions pinned to mutable tags
**Files:** `.github/workflows/ci.yml:19`, `release.yml:25,89,100`
`maxim-lobanov/setup-xcode@v1` and `softprops/action-gh-release@v1` are mutable tags — a maintainer can silently push a malicious commit.
**Fix:** Pin to full commit SHAs and add the tag name as a comment.

---

### I18 — CI: `|| true` on PlistBuddy — silent version mismatch in releases
**File:** `.github/workflows/release.yml:43–44`
If the Info.plist update fails, the release continues with the wrong version string.
**Fix:** Remove `|| true`. A failed plist update should abort the release.

---

### I19 — CI: No `-project` flag in `xcodebuild` calls
**Files:** `.github/workflows/ci.yml:38,48`, `release.yml:48`
Relies on auto-discovery of the `.xcodeproj`. Breaks silently if a workspace or second project is added.
**Fix:** Add `-project IMAPBackup.xcodeproj` to every `xcodebuild` invocation.

---

### I20 — CI: `workflow_dispatch` release may fail — tag doesn't exist
**File:** `.github/workflows/release.yml:98–109`
`softprops/action-gh-release` may require the tag to already exist. A manual dispatch with a new version number can fail or produce incorrect release notes.
**Fix:** Add a step to create and push the git tag before the release step.

---

### I21 — CI: Release app is unsigned and unnotarized
**File:** `.github/workflows/release.yml:51–55`
`CODE_SIGN_IDENTITY="-"` / `CODE_SIGNING_REQUIRED=NO` is correct for CI testing but not for distribution. Gatekeeper blocks unsigned apps for all users.
**Fix:** If an Apple Developer account is available, add `xcodebuild archive` + `xcrun notarytool submit`. Otherwise document this limitation in release notes.

---

## 🟡 Minor

### M1 — `saveAccounts()` silently swallows encoding failure
**File:** `IMAPBackup/Services/BackupManager+Accounts.swift:116–122`
`try? JSONEncoder().encode(accounts)` — if encoding fails, accounts aren't persisted and nothing is logged.
**Fix:** Use `do/catch` and call `logError(...)`.

---

### M2 — Dead code: `extractEmailData(from:)` is never called
**File:** `IMAPBackup/Services/IMAPService.swift:924–970`
**Fix:** Remove the method.

---

### M3 — Dead code: `parseEmailHeaders(_:)` always returns `[]`
**File:** `IMAPBackup/Services/IMAPService.swift:899–904`
The method has a `// TODO` body and has never been implemented. `fetchEmailHeaders` in the protocol is dead surface area.
**Fix:** Remove both the stub and the protocol method, or implement properly.

---

### M4 — Duplicate `Constants.swift` files
**Files:** `IMAPBackup/Constants.swift`, `IMAPBackup/Services/Constants.swift`
Both define `enum Constants` with the same values. One is dead or causes a redeclaration error.
**Fix:** Delete the duplicate.

---

### M5 — `BackupLocationManager` class is unused
**File:** `IMAPBackup/Services/StorageService.swift:578–601`
Defined but never referenced anywhere in the codebase.
**Fix:** Remove the class.

---

### M6 — `BackupHistoryService` stores history in unencrypted UserDefaults
**File:** `IMAPBackup/Services/BackupHistoryService.swift:72–85`
Up to 100 history entries (including email addresses, timestamps, error messages) stored in the plist.
**Fix:** Move to a SQLite table or encrypted file.

---

### M7 — Duplicate `trace()` log lines
**File:** `IMAPBackup/Services/IMAPService.swift` (multiple locations, e.g. lines 206–207)
Many calls log the same message twice — once with `[DEBUG]` prefix and once without.
**Fix:** Remove the redundant (non-`[DEBUG]`) variants.

---

### M8 — `DatabaseService` appears vestigial
**File:** `IMAPBackup/Services/DatabaseService.swift`
The active backup pipeline uses filesystem-based UID caching via `StorageService`. `DatabaseService` is only referenced in tests.
**Fix:** Confirm it's unused in production flow and remove, or document its role.

---

### M9 — CI: `xcode-version: latest-stable` is non-deterministic
**Files:** `.github/workflows/ci.yml:20`, `release.yml:27`
Resolves to a different Xcode version after each runner image update, making builds non-reproducible.
**Fix:** Pin to a specific version: `xcode-version: '16.2'`.

---

### M10 — CI: No `concurrency:` group — redundant runs waste minutes
**Files:** `.github/workflows/ci.yml`, `release.yml`
Rapid pushes queue multiple CI runs for the same branch.
**Fix:**
```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

---

### M11 — CI: No `timeout-minutes` — runaway builds consume unlimited time
**Files:** `.github/workflows/ci.yml`, `release.yml`
A hung `xcodebuild` runs until GitHub's 6-hour default timeout.
**Fix:** Add `timeout-minutes: 30` to each job.

---

### M12 — CI: Heredoc indentation adds leading whitespace to generated Swift file
**File:** `.github/workflows/ci.yml:28–34`
The heredoc is indented to match YAML structure; those spaces become literal content in `OAuthSecrets.swift`. Harmless but not idiomatic.
**Fix:** Use `<<-EOF` (strips leading tabs) or write the file with `printf`.

---

### M13 — CI: UI tests exist but never run
**File:** `.github/workflows/ci.yml`
`IMAPBackupUITests` target has test files but is excluded from the CI `TestAction`.
**Fix:** Enable if a virtual display is acceptable; otherwise document why they're excluded.

---

## Priority Order

| Priority | Item | Reason |
|----------|------|--------|
| 1 | C1 — SQLite UID truncation | Silent data corruption on every backup for high-UID mailboxes |
| 2 | C2 — `readResponse()` non-UTF-8 hang | Infinite hang risk in production |
| 3 | C3 — Streaming fetch binary corruption | Data loss for emails with binary attachments |
| 4 | C4 — CI masks test failures | Broken tests ship silently |
| 5 | C5 — Release workflow missing OAuthSecrets | Every release build fails |
| 6 | C6 — Expression injection in release.yml | RCE risk for anyone with Actions write access |
| 7 | I1/I2 — `isConnected` race + ContinuationState TOCTOU | Concurrency correctness |
| 8 | I9 — `sendDone` swallows NO | Undefined connection state after IDLE |
| 9 | I10 — IDLE timeout doesn't send DONE | RFC 2177 violation, server throttling |
| 10 | I4–I7 — Force unwraps | Crash risks in production |
