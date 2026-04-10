## Why

Code review identified six confirmed bugs ranging from silent data loss to actor isolation violations. The most severe can delete email files that will never be re-downloaded, leave partially-written temp files on disk indefinitely, or publish accounts to the UI before their Keychain credentials exist.

## What Changes

- Fix `StorageService.checkAndHandleDuplicate()`: move before delete to prevent losing both the old and new copy on a filesystem error
- Fix `BackupManager+Execution`: clean up temp files when a streaming download fails all retries
- Fix `BackupManager+Accounts.addAccount()`: save password to Keychain before appending the account to the published `accounts` array
- Fix `IMAPService` actor isolation: wrap `continuation.resume()` calls in the NWConnection `stateUpdateHandler` inside a `Task` to avoid calling them from a non-actor thread
- Fix `RateLimitService.saveSettings()`: replace silent `try?` with `do/catch` + `logError`
- Fix IDLE reconnect loop: add exponential backoff with a maximum retry count so a permanently broken account does not loop forever

## Capabilities

### New Capabilities

- `streaming-download-cleanup`: Temp files from failed streaming downloads are deleted before the next retry attempt and on final failure

### Modified Capabilities

- `history-storage-security`: *(no requirement change — implementation only)*
- `connection-state-safety`: Actor-isolation rule tightened — `continuation.resume()` must only be called from within a `Task` when originating from a non-actor callback
- `idle-connection-management`: Reconnect loop must apply exponential backoff and terminate after a configurable maximum number of consecutive failures

## Impact

- `MailKeep/Services/StorageService.swift` — `checkAndHandleDuplicate()`
- `MailKeep/Services/BackupManager+Execution.swift` — streaming download retry loop
- `MailKeep/Services/BackupManager+Accounts.swift` — `addAccount()`
- `MailKeep/Services/IMAPService.swift` — `connect()` NWConnection state handler
- `MailKeep/Services/RateLimitService.swift` — `saveSettings()`
- `MailKeep/Services/IDLEManager.swift` — `runMonitor()` catch block
