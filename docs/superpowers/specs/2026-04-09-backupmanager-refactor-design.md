# BackupManager Refactor Design

**Date:** 2026-04-09
**Status:** Approved

## Problem

`BackupManager.swift` is 1294 lines covering 8 distinct responsibilities. It is hard to navigate and reason about. `SettingsView` has already been split into focused files; BackupManager should follow the same pattern.

## Approach

Option B: move scheduling types to their own file, split BackupManager into extension files. No callers change. All `@Published` state stays on `BackupManager`. All method signatures stay the same.

## New File: `BackupScheduleTypes.swift`

Move the 4 scheduling types currently at the top of `BackupManager.swift` into `IMAPBackup/Services/BackupScheduleTypes.swift`:

- `Weekday` — enum (Sun–Sat) with `shortName` and `fullName`
- `ScheduleIntervalUnit` — enum (hours/days/weeks) with `toSeconds(_:)`
- `ScheduleConfiguration` — struct with weekday, customInterval, customUnit
- `BackupSchedule` — enum (manual/hourly/daily/weekly/custom) with `interval`, `needsTimeSelection`, `needsWeekdaySelection`, `needsCustomConfiguration`

These are pure value types with no dependency on BackupManager. Views use them directly.

## BackupManager Extension Files

All extensions live in `IMAPBackup/Services/` alongside `BackupManager.swift`.

### `BackupManager.swift` (~200 lines)

Retains:
- Class declaration, `@MainActor`, `ObservableObject`
- All `@Published` properties
- All private state (`activeTasks`, `activeHistoryIds`, `activeIMAPServices`, `cancellables`, `scheduleTimer`, `pendingProgressUpdates`, `progressFlushTask`, `progressUpdateInterval`, `lastSubjectUpdateTime`, `lastSubjectUpdateCount`, `statsCache`, `statsCacheTTL`, UserDefaults keys)
- `init()`
- `BackupManagerError` nested enum
- `subscribeToRateLimitChanges()` and `handleRateLimitSettingsChange(_:)` (shared across scheduling and operations)
- `updateIsBackingUp()`

### `BackupManager+Accounts.swift`

Contains the `// MARK: - Account Management` and `// MARK: - Password Management` sections:
- `loadAccounts()`, `saveAccounts()`
- `addAccount(_:)`, `updateAccount(_:)`, `removeAccount(_:)`
- `moveAccount(from:to:)`
- `checkForMissingPasswords()`

### `BackupManager+Scheduling.swift`

Contains the `// MARK: - Scheduling` section:
- `loadSchedule()`, `setSchedule(_:)`, `setScheduledTime(_:)`, `setScheduleConfiguration(_:)`
- `scheduledTimeFormatted`
- `updateScheduler()`, `calculateNextBackupDate()`, `scheduleNextBackup(after:)`

### `BackupManager+Operations.swift`

Contains the `// MARK: - Backup Operations` section:
- `startBackup(for:)`, `startBackupAll()`
- `cancelBackup(for:)`, `cancelAllBackups()`
- `checkAllBackupsComplete()`

### `BackupManager+Execution.swift`

Contains the `// MARK: - Backup Execution` and `// MARK: - Attachment Extraction` sections:
- `performBackup(for:)` and all private helpers it calls
- `extractAttachments(from:emailURL:accountEmail:folderPath:storageService:)`

### `BackupManager+Progress.swift`

Contains the progress throttling methods (currently in the Errors MARK section):
- `updateProgress(for:update:)`
- `flushProgressUpdates()`
- `updateProgressImmediate(for:update:)`
- `shouldUpdateSubject(for:currentCount:)`

### `BackupManager+Location.swift`

Contains the `// MARK: - Backup Location` section:
- `isUsingICloud`, `iCloudAvailable`, `iCloudDriveURL`
- `setBackupLocation(_:)`, `useICloudDrive()`, `useLocalStorage()`
- `setStreamingThreshold(_:)`, `selectBackupLocation()`

### `BackupManager+Statistics.swift`

Contains the `// MARK: - Statistics` section:
- `AccountStats` and `GlobalStats` nested structs
- `getStats(for:)`, `getGlobalStats()`
- `calculateStatsAtDirectory(_:)` static helper
- `invalidateStatsCache(for:)`, `invalidateAllStatsCache()`

## File Size Targets

| File | Est. lines |
|------|------------|
| `BackupScheduleTypes.swift` | ~100 |
| `BackupManager.swift` | ~200 |
| `BackupManager+Accounts.swift` | ~120 |
| `BackupManager+Scheduling.swift` | ~170 |
| `BackupManager+Operations.swift` | ~90 |
| `BackupManager+Execution.swift` | ~400 |
| `BackupManager+Progress.swift` | ~65 |
| `BackupManager+Location.swift` | ~60 |
| `BackupManager+Statistics.swift` | ~155 |

## Xcode Project

All new files must be added to the `IMAPBackup` target in `IMAPBackup.xcodeproj/project.pbxproj`. The original `BackupManager.swift` stays in place — its content is reduced, not moved or renamed.

## What Does Not Change

- No `@Published` property names or types
- No method signatures
- No callers in views, tests, or other services
- No UserDefaults keys or Keychain access patterns
- `BackupScheduleTypes.swift` types are in the same module — no imports needed

## Testing

- Build must succeed with no errors after each file is created
- All existing tests must pass unchanged
- Manual smoke test: launch app, trigger a backup, verify scheduling still works
