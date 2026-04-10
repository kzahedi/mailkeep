### Requirement: saveAccounts encodes with explicit error logging on failure
`BackupManager+Accounts.saveAccounts()` SHALL use a `do/catch` block when encoding accounts. If `JSONEncoder().encode(_:)` throws, the error SHALL be passed to `logError(...)`. The `UserDefaults` write SHALL NOT occur when encoding fails.

#### Scenario: Encoding success writes to UserDefaults
- **WHEN** `saveAccounts()` is called and `JSONEncoder` encodes successfully
- **THEN** the encoded data is written to `UserDefaults` under the accounts key
- **THEN** no error is logged

#### Scenario: Encoding failure logs the error
- **WHEN** `saveAccounts()` is called and `JSONEncoder` throws (e.g., injected mock encoder)
- **THEN** `logError` is called with a message that includes the thrown error's description
- **THEN** no data is written to `UserDefaults` for that call

#### Scenario: App continues operating after encoding failure
- **WHEN** `saveAccounts()` fails to encode
- **THEN** the in-memory `accounts` array is unchanged
- **THEN** no exception propagates to the caller (the method remains non-throwing)
