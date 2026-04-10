## 1. Delete DatabaseService

- [x] 1.1 Delete `IMAPBackup/Services/DatabaseService.swift`
- [x] 1.2 Delete all test files that import or reference `DatabaseService` (search for `DatabaseService` in the test target)
- [x] 1.3 Remove `SQLite3` from the build target's linked libraries if it is only referenced by `DatabaseService.swift`
- [x] 1.4 Run a clean build and confirm zero errors and zero warnings from removed types

## 2. Remove Dead Methods from IMAPService

- [x] 2.1 Delete the `extractEmailData(from:)` private method in `IMAPBackup/Services/IMAPService.swift` (lines 924–970)
- [x] 2.2 Delete the `parseEmailHeaders(_:)` private stub in `IMAPBackup/Services/IMAPService.swift` (lines 899–904)
- [x] 2.3 Delete the `fetchEmailHeaders(uids:)` implementation in `IMAPService.swift` (lines 394–399)
- [x] 2.4 Remove the `fetchEmailHeaders(uids:)` declaration from `IMAPBackup/Services/IMAPServiceProtocol.swift`
- [x] 2.5 Build and confirm `IMAPService` still conforms fully to `IMAPServiceProtocol`

## 3. Delete Duplicate Constants File

- [x] 3.1 Delete `IMAPBackup/Services/Constants.swift`
- [x] 3.2 Build and fix any `Constants` reference that was resolving from the Services-level file (check for `baseRetryDelaySeconds` — present only in the top-level file)
- [x] 3.3 Confirm a single `enum Constants` exists in the module with no redeclaration error

## 4. Remove BackupLocationManager

- [x] 4.1 Delete the `BackupLocationManager` class and its `// MARK: - Backup Location Manager` section from `IMAPBackup/Services/StorageService.swift` (lines 576–602)
- [x] 4.2 Search for any `BackupLocationManager` reference in production files and remove it
- [x] 4.3 Build and confirm zero errors

## 5. Remove Duplicate trace() Calls in IMAPService

- [x] 5.1 Search `IMAPService.swift` for consecutive `trace(...)` pairs where messages differ only by a `[DEBUG]` prefix
- [x] 5.2 Remove the non-`[DEBUG]` variant at each duplicate site (keep the `[DEBUG]`-prefixed call)
- [x] 5.3 Build and confirm no compilation errors

## 6. Fix saveAccounts Silent Failure (M1)

- [x] 6.1 Replace `if let encoded = try? JSONEncoder().encode(accounts)` in `BackupManager+Accounts.saveAccounts()` with a `do { let encoded = try JSONEncoder().encode(accounts); UserDefaults.standard.set(encoded, forKey: accountsKey) } catch { logError("saveAccounts encoding failed: \(error)") }`
- [ ] 6.2 Write a unit test that injects a type that fails `Encodable` and asserts `logError` is called and `UserDefaults` is not written

## 7. Migrate BackupHistoryService to Encrypted File Store

- [x] 7.1 Add a private helper in `BackupHistoryService` that returns the `URL` for `backup_history.json` in the app's Application Support directory
- [x] 7.2 Replace `saveHistory()` body: encode entries to JSON and write to the file URL with `FileProtectionType.complete` attribute set
- [x] 7.3 Replace `loadHistory()` body: read from the file URL and decode; call `logError` on any `catch`
- [x] 7.4 Implement one-time migration in `init()`: if the encrypted file does not yet exist, check `UserDefaults` for the `BackupHistory` key; if present, decode entries, write to the encrypted file, and remove the `UserDefaults` key
- [x] 7.5 Ensure `loadHistory()` does not crash and logs an error when the file is missing or corrupt
- [ ] 7.6 Write a unit test confirming a round-trip: save entries → reload from file → entries match
- [ ] 7.7 Write a unit test confirming the one-time migration: seed `UserDefaults`, call `init()`, assert entries loaded correctly and `UserDefaults` key is cleared
- [ ] 7.8 Write a unit test confirming that a missing/corrupt file logs an error and returns empty entries

## 8. Final Verification

- [x] 8.1 Run the full test suite and confirm all tests pass
- [x] 8.2 Do a project-wide search for `DatabaseService`, `parseEmailHeaders`, `extractEmailData`, `fetchEmailHeaders`, `BackupLocationManager` and confirm zero hits in production files
- [x] 8.3 Confirm `UserDefaults` is not used for history storage by searching for `historyKey` or `"BackupHistory"` in `BackupHistoryService.swift`
- [x] 8.4 Confirm `saveAccounts` contains a `do/catch` block and no `try?` on the encoder
