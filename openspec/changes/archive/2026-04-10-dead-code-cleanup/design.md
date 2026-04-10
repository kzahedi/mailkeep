## Context

The mailkeep codebase has grown incrementally; several artifacts from abandoned approaches remain:

- `DatabaseService` was an early SQLite-backed UID tracking layer. The production pipeline was later re-implemented using plain-text `.uid_cache` files managed by `StorageService`. `DatabaseService` was never wired up in production and appears only in its own test file.
- `IMAPService` contains two private helpers (`extractEmailData`, `parseEmailHeaders`) that were written but never called, plus a corresponding unimplemented protocol method (`fetchEmailHeaders`). Every trace call in `IMAPService` emits the same log line twice due to an oversight.
- Two identical `enum Constants` blocks exist in different directories, a redeclaration that compiles only by accident of module scoping.
- `BackupLocationManager` in `StorageService.swift` duplicates location-management that `BackupManager+Location.swift` already handles; it was never referenced after extraction.
- `BackupHistoryService` silently persists sensitive history (email addresses, error strings, timestamps) into the macOS `UserDefaults` plist, which is readable without decryption.
- `saveAccounts()` in `BackupManager+Accounts` discards `JSONEncoder` failures silently, risking invisible account data loss on restart.

## Goals / Non-Goals

**Goals:**
- Eliminate all confirmed dead code (zero production references)
- Surface encoding errors through the existing `logError` pathway
- Move history entries out of unencrypted `UserDefaults` into an access-controlled store
- Leave the production backup pipeline, IDLE system, and UI completely unchanged

**Non-Goals:**
- Implementing a new `parseEmailHeaders` or `fetchEmailHeaders` — these are removed, not replaced
- Migrating `DatabaseService` data to another store — no production data was ever written to it
- Encrypting accounts stored in `UserDefaults` (separate concern, not in scope)
- Changing `BackupHistoryEntry` data model fields

## Decisions

### D1 — Delete `DatabaseService` entirely, do not archive

**Decision:** Delete `DatabaseService.swift` and all associated test files.

**Rationale:** The file is zero-impact on production. Keeping it as "documentation" of the SQLite approach adds build time (SQLite3 link) and test maintenance burden for a pathway that was explicitly abandoned. There is no migration path because no production data was written.

**Alternatives considered:**
- Keep with a deprecation comment — rejected; commented-out dead code is still dead code and adds noise.
- Extract to a separate module for potential future use — rejected; premature, and the UID-cache approach is simpler.

### D2 — Remove `parseEmailHeaders` / `fetchEmailHeaders` as a pair

**Decision:** Remove both the private stub in `IMAPService` and the `fetchEmailHeaders` declaration from `IMAPServiceProtocol`.

**Rationale:** The stub always returns `[]`. The implementation (`fetchEmailHeaders`) calls the stub and returns its empty result. Any callers of the protocol method would silently receive no headers. The correct fix is removal; when header parsing is needed it should be a proper implementation from scratch.

**Alternatives considered:**
- Implement the stub properly — out of scope for this cleanup change; would require a separate proposal.
- Leave the protocol method but remove the implementation — breaks the protocol contract; rejected.

### D3 — Encrypted JSON file for history persistence

**Decision:** Replace `UserDefaults` in `BackupHistoryService` with an encrypted JSON file stored in the app's Application Support directory, protected by `FileProtectionType.complete`.

**Rationale:** `FileProtectionType.complete` encrypts the file when the device is locked using macOS Data Protection (analogous to iOS), requiring no third-party dependency and no keychain involvement for the encryption key. This is the lowest-complexity option that removes the plaintext exposure.

**Alternatives considered:**
- SQLite table — heavier; would require re-introducing a SQLite dependency after removing `DatabaseService`.
- Keychain — designed for small secrets, not 100 history records; not suitable.
- NSFileProtection without encryption (default) — no improvement over UserDefaults; rejected.
- Third-party encrypted store — adds dependency for a straightforward need; rejected.

### D4 — `saveAccounts` error handling via existing `logError`

**Decision:** Wrap the encoder call in `do/catch` and forward the error to `logError("saveAccounts encoding failed: \(error)")`.

**Rationale:** `BackupManager` already has a `logError` method used throughout the file. No new infrastructure is needed. The failure is non-fatal (accounts remain in memory for the current session) but must be visible in logs so operators can diagnose.

**Alternatives considered:**
- Throw the error to the caller — `saveAccounts` is `void` and called fire-and-forget in several places; changing the signature would cascade.
- Alert the user — encoding failure is an internal invariant violation, not a user-actionable error; log is appropriate.

### D5 — Canonical `Constants.swift` is `IMAPBackup/Constants.swift`

**Decision:** Delete `IMAPBackup/Services/Constants.swift`. The top-level file is kept because it is more complete (includes `baseRetryDelaySeconds` and `defaultIMAPPort`) and its location matches the project's module root convention.

**Rationale:** Both files define `enum Constants` with identical values. The Services-level copy is missing two constants present in the top-level file. Keeping the more complete file avoids any reference breakage.

## Risks / Trade-offs

- [History migration] Existing `UserDefaults` history is abandoned when switching to the encrypted file — entries from before the update disappear. Mitigation: perform a one-time migration in `BackupHistoryService.init()` that reads `UserDefaults`, writes to the new file, then clears the key. The migration runs once on first launch after update.
- [Constants deletion] Any Swift file in the `Services/` group that qualified `Constants` with a module path could break if the compiler resolved it from the Services-local copy. Mitigation: run a full clean build immediately after deletion and fix any resolution errors before merging.
- [Duplicate trace lines] Removing one of the two trace calls per site changes log volume. No functional impact; log consumers should not rely on duplicate lines.

## Migration Plan

1. Delete `DatabaseService.swift` and test files. Run tests — all should pass.
2. Delete `IMAPBackup/Services/Constants.swift`. Build and fix any constant resolution errors.
3. Remove dead methods from `IMAPService.swift` and `IMAPServiceProtocol.swift`. Build.
4. Remove `BackupLocationManager` from `StorageService.swift`. Build.
5. Remove duplicate `trace()` calls in `IMAPService.swift`. Build.
6. Fix `saveAccounts()` in `BackupManager+Accounts.swift`. Add test for error path.
7. Migrate `BackupHistoryService` to encrypted file store. Include `UserDefaults` migration on first launch. Add round-trip test.
8. Full regression run of all tests.

Rollback: each step is an isolated commit; revert the relevant commit if regression is found.

## Open Questions

- OQ1: Should the one-time `UserDefaults` → encrypted-file history migration be gated behind a migration version flag, or is a simple "if encrypted file doesn't exist, migrate" check sufficient?
- OQ2: Is `FileProtectionType.complete` available on all macOS versions targeted by mailkeep, or is a fallback needed?
