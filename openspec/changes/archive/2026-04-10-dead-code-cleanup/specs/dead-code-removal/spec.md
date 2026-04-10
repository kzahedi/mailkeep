## ADDED Requirements

### Requirement: DatabaseService is removed from the codebase
`DatabaseService.swift` and all associated test files SHALL be deleted. No production code SHALL reference `DatabaseService`, `DatabaseError`, or the `SQLite3` import introduced solely by that file.

#### Scenario: Clean build after DatabaseService deletion
- **WHEN** `DatabaseService.swift` and its test files are deleted and the project is built
- **THEN** the build succeeds with zero errors and zero warnings related to the removed types

#### Scenario: No production instantiation of DatabaseService
- **WHEN** the source tree is searched for `DatabaseService` outside of the deleted test files
- **THEN** no references are found

### Requirement: extractEmailData is removed from IMAPService
The private method `extractEmailData(from:)` in `IMAPService.swift` SHALL be deleted. No call site SHALL exist anywhere in the codebase.

#### Scenario: extractEmailData absent after removal
- **WHEN** `IMAPService.swift` is built after the method is deleted
- **THEN** the build succeeds and no symbol named `extractEmailData` exists in the compiled binary

### Requirement: parseEmailHeaders stub and fetchEmailHeaders protocol method are removed
The private stub `parseEmailHeaders(_:)` in `IMAPService.swift` (which unconditionally returns `[]`) and the corresponding `fetchEmailHeaders(uids:)` declaration in `IMAPServiceProtocol` SHALL both be deleted.

#### Scenario: Protocol conformance is unbroken after removal
- **WHEN** both `parseEmailHeaders` and the `fetchEmailHeaders` protocol declaration are removed
- **THEN** `IMAPService` still fully conforms to `IMAPServiceProtocol` and the build succeeds

#### Scenario: No callers of fetchEmailHeaders remain
- **WHEN** the codebase is searched for `fetchEmailHeaders`
- **THEN** no references are found

### Requirement: Duplicate Constants.swift in Services/ is deleted
`IMAPBackup/Services/Constants.swift` SHALL be deleted. The canonical `IMAPBackup/Constants.swift` SHALL remain and SHALL be the sole definition of `enum Constants`.

#### Scenario: Single Constants definition after deletion
- **WHEN** `IMAPBackup/Services/Constants.swift` is deleted and the project builds
- **THEN** there is exactly one `enum Constants` in the module and no redeclaration error occurs

#### Scenario: Constants values are unchanged
- **WHEN** code that previously compiled against either Constants file is built against the surviving file
- **THEN** all constant references resolve correctly and values are identical

### Requirement: BackupLocationManager class is removed from StorageService
The `BackupLocationManager` class defined in `IMAPBackup/Services/StorageService.swift` SHALL be deleted. No production code SHALL reference `BackupLocationManager`.

#### Scenario: BackupLocationManager absent after removal
- **WHEN** `BackupLocationManager` is deleted from `StorageService.swift`
- **THEN** the build succeeds and no symbol named `BackupLocationManager` appears in the production target

#### Scenario: No remaining references to BackupLocationManager
- **WHEN** the source tree is searched for `BackupLocationManager`
- **THEN** no references are found in production files

### Requirement: Duplicate trace() log lines are removed from IMAPService
Each logical operation in `IMAPService.swift` SHALL emit at most one `trace()` call per entry point. Where two consecutive `trace()` calls log the same message (one with `[DEBUG]` prefix, one without), the non-`[DEBUG]` variant SHALL be removed.

#### Scenario: No consecutive duplicate trace calls
- **WHEN** `IMAPService.swift` is reviewed after cleanup
- **THEN** no two consecutive `trace()` calls within the same scope contain identical message content differing only by a `[DEBUG]` prefix

#### Scenario: Log output volume is halved for affected sites
- **WHEN** `connect()` is called during a test
- **THEN** exactly one trace log line is emitted for each logical step, not two
