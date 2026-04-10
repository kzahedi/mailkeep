## Why

The codebase has accumulated dead code, duplicate declarations, and two silent-failure patterns that hide real errors from developers and users. Removing dead code reduces build surface and test noise; fixing the silent failures prevents data loss and security exposure that are invisible today.

## What Changes

- Remove `extractEmailData(from:)` private method in `IMAPService` — never called
- Remove `parseEmailHeaders(_:)` stub in `IMAPService` — always returns `[]`; remove matching `fetchEmailHeaders` from `IMAPServiceProtocol`
- Delete `IMAPBackup/Services/Constants.swift` — exact duplicate of `IMAPBackup/Constants.swift`
- Remove `BackupLocationManager` class from `StorageService.swift` — defined but never instantiated
- Remove duplicate `trace()` log lines throughout `IMAPService` — every call logs the same message twice
- Remove `DatabaseService.swift` and its tests — SQLite backend was never wired into the production pipeline; active UID caching uses plain-text `.uid_cache` files via `StorageService`
- **Fix M1**: Replace `try? JSONEncoder().encode(accounts)` in `BackupManager+Accounts.saveAccounts()` with `do/catch` that calls `logError(...)` on failure
- **Fix M6**: Move `BackupHistoryService` persistence out of unencrypted `UserDefaults` into a secure file store (encrypted on-disk JSON or SQLite table); history entries contain email addresses, timestamps, and error strings

## Capabilities

### New Capabilities

- `dead-code-removal`: Deletion of dead/duplicate code across `IMAPService`, `StorageService`, `DatabaseService`, and `Constants` (M2, M3, M4, M5, M7, M8/C1)
- `error-observability`: Silent encoding failures in account and history persistence are surfaced via `logError` (M1)
- `history-storage-security`: Backup history records are moved from cleartext `UserDefaults` to an encrypted or access-controlled file store (M6)

### Modified Capabilities

<!-- None: no existing spec-level behavior changes -->

## Impact

- **Files deleted**: `IMAPBackup/Services/DatabaseService.swift`, `IMAPBackup/Services/Constants.swift`, all `DatabaseService` test files
- **Files modified**: `IMAPBackup/Services/IMAPService.swift`, `IMAPBackup/Services/IMAPServiceProtocol.swift`, `IMAPBackup/Services/StorageService.swift`, `IMAPBackup/Services/BackupManager+Accounts.swift`, `IMAPBackup/Services/BackupHistoryService.swift`
- **Dependencies**: Removing `DatabaseService` drops the `SQLite3` import from that file; confirm `SQLite3` is not needed elsewhere if M6 opts for encrypted JSON
- **Tests**: `DatabaseService` tests are removed; new tests cover `saveAccounts` error path and history persistence round-trip
