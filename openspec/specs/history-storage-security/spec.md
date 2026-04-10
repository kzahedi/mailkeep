### Requirement: Backup history is persisted to an encrypted file, not UserDefaults
`BackupHistoryService` SHALL persist `BackupHistoryEntry` records to a JSON file stored in the app's Application Support directory. The file SHALL be protected with `FileProtectionType.complete` (Data Protection). `UserDefaults` SHALL NOT be used for history storage after this change.

#### Scenario: History file is created at the correct path
- **WHEN** `BackupHistoryService` saves history for the first time
- **THEN** a file named `backup_history.json` exists inside the app's Application Support directory
- **THEN** the file has `FileProtectionType.complete` set on it

#### Scenario: History survives app restart
- **WHEN** history entries are saved and the app is relaunched
- **THEN** `BackupHistoryService.entries` contains the same entries as before the restart
- **THEN** entries are loaded from the encrypted file, not from `UserDefaults`

#### Scenario: History key is absent from UserDefaults after migration
- **WHEN** the migration runs on first launch
- **THEN** `UserDefaults.standard.data(forKey: "BackupHistory")` returns `nil`

### Requirement: One-time migration moves existing UserDefaults history to the encrypted file
On first launch after the update, `BackupHistoryService` SHALL detect existing history in `UserDefaults`, write it to the encrypted file, and then remove the `UserDefaults` key. If no `UserDefaults` history exists, the migration step SHALL be skipped.

#### Scenario: Existing UserDefaults history is migrated
- **WHEN** `UserDefaults` contains a non-empty `BackupHistory` value on first launch
- **THEN** those entries appear in `BackupHistoryService.entries` after `init()` completes
- **THEN** the `BackupHistory` key is removed from `UserDefaults`
- **THEN** the encrypted file contains all migrated entries

#### Scenario: Migration is idempotent when no UserDefaults history exists
- **WHEN** `UserDefaults` does not contain a `BackupHistory` key
- **THEN** `init()` completes without error
- **THEN** `entries` is empty (or reflects whatever is already in the encrypted file)

#### Scenario: Migration does not run twice
- **WHEN** the app is launched a second time after a successful migration
- **THEN** no migration attempt is made (the `UserDefaults` key is already absent)
- **THEN** entries are loaded solely from the encrypted file

### Requirement: History read/write errors are logged, not silently swallowed
If reading from or writing to the encrypted history file fails, `BackupHistoryService` SHALL call `logError(...)` with a description of the failure. The service SHALL continue operating with the in-memory state rather than crashing.

#### Scenario: File write failure is logged
- **WHEN** the file system rejects a write (e.g., insufficient permissions in a test environment)
- **THEN** `logError` is called with a message identifying the failure
- **THEN** in-memory `entries` are unchanged

#### Scenario: File read failure is logged and returns empty entries
- **WHEN** the history file is unreadable on launch (corrupted or missing)
- **THEN** `logError` is called with a message identifying the failure
- **THEN** `entries` starts empty and the app continues normally
