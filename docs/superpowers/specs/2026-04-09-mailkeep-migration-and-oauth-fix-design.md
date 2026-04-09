# MailKeep: File System Migration & OAuth Re-authorize Fix

**Date:** 2026-04-09  
**Status:** Approved

## Problem

Two independent issues:

1. **IMAPBackup naming**: All user-visible and internal directories still use the old "IMAPBackup" name despite the app being branded MailKeep. Logs live at `~/Library/Application Support/IMAPBackup/Logs/`, emails at `~/Documents/IMAPBackup/`. This is confusing.

2. **OAuth re-authorization bug**: Gmail accounts authenticated via OAuth2 have no way to re-authorize from the UI when their refresh tokens expire or are revoked by Google. The app silently fails every scheduled backup. The only workaround is deleting and re-adding the account.

## Scope

Three parts delivered together in one branch:

1. File system migration (new `MigrationService` phase)
2. Code path cleanup (7 hardcoded `"IMAPBackup"` strings)
3. OAuth re-authorize button (`EditAccountView`)

---

## Part 1: File System Migration

### Existing Migration Context

`MigrationService.swift` already exists and handles a one-time migration of UserDefaults and Keychain items from bundle ID `com.kzahedi.IMAPBackup` to `com.kzahedi.MailKeep`. It is already marked complete for existing installs. The new file system migration is a separate phase with its own completion key.

### New Method: `migrateFileSystemIfNeeded()`

Completion key: `"MigrationFileSystemToMailKeepCompleted"`

Called from `IMAPBackupApp.init()` immediately after `MigrationService.migrateIfNeeded()`, synchronously, before `BackupManager()` is initialized. This ordering ensures:
- Logs directory is in the right place before `LoggingService` is first accessed
- `BackupLocation` in UserDefaults is updated before `BackupManager.init()` reads it

#### App Support (Logs)

Source: `~/Library/Application Support/IMAPBackup/`  
Destination: `~/Library/Application Support/MailKeep/`

- If source exists and destination does not: `FileManager.moveItem` (atomic rename, same volume)
- If both exist: move each item from source into destination, skip conflicts (don't overwrite)
- If source does not exist: no-op

#### Backup Storage

Read `BackupLocation` from `UserDefaults.standard.string(forKey: "BackupLocation")`.

- **If no saved location**: nothing to do — new code default (`MailKeep`) handles fresh installs
- **If saved path ends with `"IMAPBackup"`** (the default or iCloud default):
  - Compute new path: replace last component with `"MailKeep"`
  - If source exists and destination does not: `FileManager.moveItem`, then update `BackupLocation` in UserDefaults
  - If both exist: update UserDefaults to point to destination (assume already partially migrated)
  - If source does not exist: update UserDefaults to destination path (data was already moved or never created)
- **If saved path ends with anything else** (custom user location): leave it completely alone

#### Error Handling

All file operations are wrapped in do/catch with `print()` (not `LoggingService`, to avoid chicken-and-egg). A failure logs the error and skips that step — it does NOT block app launch or set the completion key. The completion key is only set when the migration fully succeeds, so a failed migration will be retried on next launch.

---

## Part 2: Code Path Cleanup

All hardcoded `"IMAPBackup"` strings in production Swift files are updated to `"MailKeep"`. No new constants file is needed — the strings are already specific enough to be self-documenting.

| File | Line | Change |
|------|------|--------|
| `LoggingService.swift` | 34 | OS log subsystem: `com.kzahedi.IMAPBackup` → `com.kzahedi.MailKeep` |
| `LoggingService.swift` | 44 | Log dir component: `IMAPBackup/Logs` → `MailKeep/Logs` |
| `BackupManager.swift` | 161 | Default backup location component |
| `BackupManager.swift` | 886 | Debug file prefix: `IMAPBackup_debug_` → `MailKeep_debug_` |
| `BackupManager.swift` | 1100 | iCloud URL component |
| `BackupManager.swift` | 1104 | iCloud hardcoded fallback path component |
| `BackupManager.swift` | 1121 | `useLocalStorage()` path component |
| `StorageService.swift` | 590 | Default backup location component |
| `AppDelegate.swift` | 18 | UID cache validation path component |

The `@testable import IMAPBackup` in test files refers to the Swift module name (set in the Xcode target, not in source). That is left unchanged — renaming the module target is out of scope and risks breaking the build.

---

## Part 3: OAuth Re-authorize Button

### Problem

`EditAccountView` for OAuth accounts shows a static green "Signed in with Google" label with no action. When tokens expire (Google revokes them after inactivity, password changes, etc.), there is no recovery path short of deleting and re-adding the account.

### Solution

Add a "Re-authorize with Google" button in the OAuth section of `EditAccountView` that:
1. Calls `GoogleOAuthService.shared.authorize()` (opens the browser-based OAuth flow)
2. On success: calls `account.saveOAuthTokens(tokens)` to persist new tokens in Keychain
3. Shows inline success confirmation or error message

### State added to `EditAccountView`

```swift
@State private var isReauthorizing = false
@State private var reauthorizeResult: ReauthResult?

enum ReauthResult {
    case success
    case failure(String)
}
```

### UI placement

Replaces the existing "To change the Google account, delete this account and add a new one." note in the OAuth section. The button is placed below the server info and above the dismiss action row. A `ProgressView` is shown inline while the OAuth flow is in progress.

### No changes needed to

- `GoogleOAuthService.swift` — `authorize()` already handles the full PKCE flow
- `EmailAccount.swift` — `saveOAuthTokens()` already exists
- `BackupManager` — picks up new tokens automatically on next backup attempt

---

## Testing

- **Migration**: Manually verify on a build with existing `~/Library/Application Support/IMAPBackup/Logs/` and `~/Documents/IMAPBackup/` present. Confirm both are renamed and app launches with logs writing to new paths.
- **Migration idempotency**: Run the app twice; verify migration does not run a second time (completion key is set).
- **OAuth button**: Manually trigger re-auth for a Gmail account. Verify tokens update in Keychain and next backup succeeds.
- **Custom backup location**: Set a custom backup path (not ending in `IMAPBackup`), run migration, verify it is untouched.

## Out of Scope

- Renaming the Xcode target / Swift module from `IMAPBackup` to `MailKeep`
- Migrating iCloud backup data (iCloud renames require coordination with CloudKit; the path update in code is sufficient for new writes)
- Any changes to `rbh@ghazi-zahedi.de` password — that is a credentials issue, not a code issue
