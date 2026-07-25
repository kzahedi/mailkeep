# Credential Robustness Refactoring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make MailKeep's credential handling (IMAP passwords + Google OAuth tokens) fully reliable on a machine with an unpaid Apple developer account, where ad-hoc code signing breaks Keychain ACLs on every rebuild.

**Architecture:** Move credentials from the macOS Keychain to a file-backed `CredentialStore` actor (`~/Library/Application Support/MailKeep/credentials.json`, POSIX 0600, atomic writes) — the same fix already proven for `accounts.json`. A one-time, retry-safe migration reads existing Keychain items into the file. The Keychain code is retained read-only for migration, with its silent-wipe read bug fixed first. Missing-credential detection is extended to OAuth accounts with an in-app re-authorize flow. `install.sh` gains optional re-signing with a stable self-signed identity.

**Tech Stack:** Swift (actors, async/await), XCTest, bash. No new dependencies.

## Global Constraints

- Never log or print credential values (passwords, tokens) — only counts and account emails.
- Keychain items are **left in place** after migration (rollback safety). Nothing deletes them.
- The credential migration may only be marked complete when every Keychain read either succeeded or returned `errSecItemNotFound`. A blocked read (`errSecInteractionNotAllowed`, etc.) must retry on next launch.
- All tests must be isolated: use `CredentialStore.testFileOverride` / unique per-test Keychain service names; reset overrides in `tearDown`. Never touch production services `com.kzahedi.MailKeep` / `com.kzahedi.MailKeep.oauth` or the real `credentials.json` from tests.
- Test command (unit tests only, UI tests excluded):
  `xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests 2>&1 | tail -30`
  To run one class, append `/<ClassName>` to `-only-testing:`.
- Match existing code style: `logInfo`/`logError`/`logWarning` global functions for app code, `print("[Migration] …")` inside `MigrationService`.
- Work on branch `refactor/credential-store`; one commit per task.
- **Adding a new Swift file to the Xcode project:** `project.pbxproj` uses explicit file references (no synchronized folders). Every new file needs 4 entries, mirroring an existing sibling (e.g. `KeychainService.swift` at pbxproj lines 44, 136, 297, 549 for app files; any `*Tests.swift` for test files): (1) a `PBXBuildFile` entry, (2) a `PBXFileReference` entry, (3) a child entry in the containing group, (4) an entry in the target's Sources build phase. Invent a new unique 24-hex-char ID pair following the existing `B10000xx…` pattern. App files → MailKeep target sections; test files → MailKeepTests target sections. Verify with a build afterwards — a missing entry fails with "cannot find … in scope".

## Background (why — read before Task 1)

The Xcode project has `DEVELOPMENT_TEAM = ""`, so every build is ad-hoc signed with a **different identity per rebuild**. Legacy-Keychain item ACLs are bound to the signing identity, so after each rebuild macOS either re-prompts (manual launch) or silently denies access (`errSecInteractionNotAllowed`) when the app starts as a Login Item with no UI. The account list already moved to `accounts.json` for this reason (commit 988c522); passwords and OAuth tokens are still in the Keychain and still fail this way. This plan moves them to a file too. Security trade-off (accepted): file is user-readable-only (0600) and FileVault encrypts at rest; the Keychain's extra ACL layer was already ineffective under ad-hoc signing.

---

### Task 1: Fix KeychainService silent-wipe bug (blocked read ≠ empty store)

`KeychainService.loadStore()` returns `[:]` on **any** error. `savePassword`/`deletePassword` then read-modify-write that result: a blocked read plus one save **overwrites the consolidated store, wiping all other passwords**. It also makes migration (Task 3) unable to tell "empty" from "denied". Fix: only `errSecItemNotFound` maps to empty; every other failure throws.

**Files:**
- Modify: `MailKeep/Services/KeychainService.swift`
- Create: `MailKeepTests/KeychainServiceTests.swift`

**Interfaces:**
- Produces: `KeychainService.decodeStoreResult(status:data:) throws -> [String: String]` (internal, nonisolated static — pure, for tests); `KeychainError.readFailed(OSStatus)`.
- Existing public API of `KeychainService` is unchanged in signature except that read errors now propagate as `KeychainError.readFailed` instead of masquerading as `.notFound`/empty.

- [ ] **Step 1: Write the failing tests**

Create `MailKeepTests/KeychainServiceTests.swift`:

```swift
import XCTest
@testable import MailKeep

final class KeychainServiceTests: XCTestCase {

    func testDecodeStoreResultReturnsDictOnSuccess() throws {
        let data = try JSONEncoder().encode(["ABC": "secret"])
        let store = try KeychainService.decodeStoreResult(status: errSecSuccess, data: data)
        XCTAssertEqual(store, ["ABC": "secret"])
    }

    func testDecodeStoreResultReturnsEmptyOnNotFound() throws {
        let store = try KeychainService.decodeStoreResult(status: errSecItemNotFound, data: nil)
        XCTAssertTrue(store.isEmpty)
    }

    func testDecodeStoreResultThrowsOnInteractionNotAllowed() {
        XCTAssertThrowsError(
            try KeychainService.decodeStoreResult(status: errSecInteractionNotAllowed, data: nil)
        ) { error in
            guard case KeychainError.readFailed(let status) = error else {
                return XCTFail("Expected readFailed, got \(error)")
            }
            XCTAssertEqual(status, errSecInteractionNotAllowed)
        }
    }

    func testDecodeStoreResultThrowsOnCorruptData() {
        XCTAssertThrowsError(
            try KeychainService.decodeStoreResult(status: errSecSuccess, data: Data("not json".utf8))
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests/KeychainServiceTests 2>&1 | tail -30`
Expected: compile FAILURE — `decodeStoreResult` and `KeychainError.readFailed` don't exist.

- [ ] **Step 3: Implement**

In `MailKeep/Services/KeychainService.swift`:

3a. Add to `enum KeychainError` a new case and description:

```swift
case readFailed(OSStatus)
```
```swift
case .readFailed(let status):
    return "Failed to read from Keychain (status: \(status)) — macOS may be blocking access after a rebuild changed the app's code signature"
```

3b. Add inside `actor KeychainService`:

```swift
/// Map a SecItemCopyMatching result for the consolidated store into a store dictionary.
/// Only errSecItemNotFound means "genuinely empty". Any other failure throws so a
/// blocked read (e.g. errSecInteractionNotAllowed at Login Item startup) can never be
/// mistaken for an empty store and wipe existing passwords on the next save.
nonisolated static func decodeStoreResult(status: OSStatus, data: Data?) throws -> [String: String] {
    switch status {
    case errSecItemNotFound:
        return [:]
    case errSecSuccess:
        guard let data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw KeychainError.readFailed(errSecDecode)
        }
        return dict
    default:
        throw KeychainError.readFailed(status)
    }
}
```

3c. Rewrite `loadStore(service:)` to throw, using the helper:

```swift
private func loadStore(service: String) throws -> [String: String] {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: credentialStoreAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return try Self.decodeStoreResult(status: status, data: result as? Data)
}
```

3d. Update the four callers inside `KeychainService`:
- `savePassword`: `var store = try loadStore(service: serviceName)` (this is the wipe fix)
- `getPassword`: `let store = try loadStore(service: serviceName)`
- `deletePassword`: `var store = try loadStore(service: serviceName)`
- `hasPassword`: `let store = (try? loadStore(service: serviceName)) ?? [:]` — keep non-throwing signature; a blocked read here only affects the "missing passwords" banner, never data. Also in `getPassword`'s migration path, change `try? saveStore(...)` to keep behavior identical (leave as `try?`).

- [ ] **Step 4: Run tests to verify they pass**

Run the same command as Step 2. Expected: 4 tests PASS.
Then run the full unit suite to catch regressions:
`xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MailKeep/Services/KeychainService.swift MailKeepTests/KeychainServiceTests.swift
git commit -m "fix: keychain read errors no longer masquerade as empty store (silent password wipe)"
```

---

### Task 2: File-backed CredentialStore actor

New primary credential backend: one JSON file, no ACLs, no dialogs, works identically for manual launches, Login Item startup, and every rebuild.

**Files:**
- Create: `MailKeep/Services/CredentialStore.swift`
- Create: `MailKeepTests/CredentialStoreTests.swift`

**Interfaces:**
- Produces (used by Tasks 3–5):
  - `CredentialStore.shared` (actor)
  - `static var testFileOverride: URL?` (nonisolated(unsafe), tests only)
  - `func savePassword(_ password: String, for accountId: UUID) throws`
  - `func getPassword(for accountId: UUID) throws -> String` (throws `CredentialStoreError.notFound`)
  - `func deletePassword(for accountId: UUID) throws`
  - `func hasPassword(for accountId: UUID) -> Bool`
  - `func saveOAuthTokenString(_ token: String, for accountId: UUID) throws`
  - `func getOAuthTokenString(for accountId: UUID) throws -> String`
  - `func deleteOAuthTokenString(for accountId: UUID) throws`
  - `func hasOAuthToken(for accountId: UUID) -> Bool`
  - `nonisolated static func importIfAbsent(passwords: [String: String], oauthTokens: [String: String]) throws` (migration only; existing file entries win)

- [ ] **Step 1: Write the failing tests**

Create `MailKeepTests/CredentialStoreTests.swift`:

```swift
import XCTest
@testable import MailKeep

final class CredentialStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        CredentialStore.testFileOverride = tempDir.appendingPathComponent("credentials.json")
    }

    override func tearDown() {
        CredentialStore.testFileOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testPasswordRoundTrip() async throws {
        let id = UUID()
        try await CredentialStore.shared.savePassword("s3cret", for: id)
        let loaded = try await CredentialStore.shared.getPassword(for: id)
        XCTAssertEqual(loaded, "s3cret")
    }

    func testGetPasswordThrowsNotFoundWhenMissing() async {
        do {
            _ = try await CredentialStore.shared.getPassword(for: UUID())
            XCTFail("Expected notFound")
        } catch {
            guard case CredentialStoreError.notFound = error else {
                return XCTFail("Expected notFound, got \(error)")
            }
        }
    }

    func testDeletePasswordRemovesOnlyThatEntry() async throws {
        let a = UUID(), b = UUID()
        try await CredentialStore.shared.savePassword("pw-a", for: a)
        try await CredentialStore.shared.savePassword("pw-b", for: b)
        try await CredentialStore.shared.deletePassword(for: a)
        let hasA = await CredentialStore.shared.hasPassword(for: a)
        let hasB = await CredentialStore.shared.hasPassword(for: b)
        XCTAssertFalse(hasA)
        XCTAssertTrue(hasB)
    }

    func testOAuthTokenRoundTrip() async throws {
        let id = UUID()
        try await CredentialStore.shared.saveOAuthTokenString("{\"token\":1}", for: id)
        let loaded = try await CredentialStore.shared.getOAuthTokenString(for: id)
        XCTAssertEqual(loaded, "{\"token\":1}")
        let has = await CredentialStore.shared.hasOAuthToken(for: id)
        XCTAssertTrue(has)
    }

    func testFileHasOwnerOnlyPermissions() async throws {
        try await CredentialStore.shared.savePassword("x", for: UUID())
        let attrs = try FileManager.default.attributesOfItem(
            atPath: CredentialStore.testFileOverride!.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testCorruptFileIsPreservedAndStoreStartsFresh() async throws {
        let url = CredentialStore.testFileOverride!
        try Data("not json".utf8).write(to: url)
        let id = UUID()
        try await CredentialStore.shared.savePassword("new", for: id)
        let loaded = try await CredentialStore.shared.getPassword(for: id)
        XCTAssertEqual(loaded, "new")
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testImportIfAbsentDoesNotOverwriteExisting() async throws {
        let id = UUID()
        try await CredentialStore.shared.savePassword("file-wins", for: id)
        try CredentialStore.importIfAbsent(
            passwords: [id.uuidString: "keychain-value", "OTHER-KEY": "imported"],
            oauthTokens: [:])
        let existing = try await CredentialStore.shared.getPassword(for: id)
        XCTAssertEqual(existing, "file-wins")
        let data = try Data(contentsOf: CredentialStore.testFileOverride!)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let passwords = json["passwords"] as! [String: String]
        XCTAssertEqual(passwords["OTHER-KEY"], "imported")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests/CredentialStoreTests 2>&1 | tail -30`
Expected: compile FAILURE — `CredentialStore` doesn't exist.

- [ ] **Step 3: Implement**

Create `MailKeep/Services/CredentialStore.swift` and register it in `project.pbxproj` per the Global Constraints procedure (MailKeep target; the test file from Step 1 goes in the MailKeepTests target).

```swift
import Foundation

/// File-backed credential store — the primary backend for IMAP passwords and
/// OAuth tokens.
///
/// Why not the Keychain: this app is built with an unpaid Apple account, so every
/// rebuild is ad-hoc signed with a new identity. Legacy-Keychain ACLs are bound to
/// the signing identity, causing permission prompts on manual launches and silent
/// errSecInteractionNotAllowed failures at Login Item startup. Same rationale as
/// accounts.json (commit 988c522), now applied to credentials.
///
/// Storage: ~/Library/Application Support/MailKeep/credentials.json,
/// POSIX 0600, atomic writes. FileVault provides at-rest encryption.
actor CredentialStore {
    static let shared = CredentialStore()

    /// Override the credentials file URL in tests. Reset to nil in tearDown.
    nonisolated(unsafe) static var testFileOverride: URL? = nil

    private struct FileContents: Codable {
        var passwords: [String: String] = [:]
        var oauthTokens: [String: String] = [:]
    }

    nonisolated static var fileURL: URL {
        if let override = testFileOverride { return override }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MailKeep/credentials.json")
    }

    // MARK: - File I/O

    private nonisolated static func load() throws -> FileContents {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return FileContents() }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(FileContents.self, from: data)
        } catch {
            // Corrupt file: preserve for manual recovery, start fresh. The user can
            // re-enter credentials via the missing-credentials prompt.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            logError("credentials.json is corrupt — moved to \(backup.lastPathComponent), starting fresh")
            return FileContents()
        }
    }

    private nonisolated static func save(_ contents: FileContents) throws {
        let url = fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(contents)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Passwords

    func savePassword(_ password: String, for accountId: UUID) throws {
        var contents = try Self.load()
        contents.passwords[accountId.uuidString] = password
        try Self.save(contents)
    }

    func getPassword(for accountId: UUID) throws -> String {
        guard let password = try Self.load().passwords[accountId.uuidString] else {
            throw CredentialStoreError.notFound
        }
        return password
    }

    func deletePassword(for accountId: UUID) throws {
        var contents = try Self.load()
        contents.passwords.removeValue(forKey: accountId.uuidString)
        try Self.save(contents)
    }

    func hasPassword(for accountId: UUID) -> Bool {
        ((try? Self.load())?.passwords[accountId.uuidString]) != nil
    }

    // MARK: - OAuth tokens (JSON-encoded GoogleOAuthTokens strings)

    func saveOAuthTokenString(_ token: String, for accountId: UUID) throws {
        var contents = try Self.load()
        contents.oauthTokens[accountId.uuidString] = token
        try Self.save(contents)
    }

    func getOAuthTokenString(for accountId: UUID) throws -> String {
        guard let token = try Self.load().oauthTokens[accountId.uuidString] else {
            throw CredentialStoreError.notFound
        }
        return token
    }

    func deleteOAuthTokenString(for accountId: UUID) throws {
        var contents = try Self.load()
        contents.oauthTokens.removeValue(forKey: accountId.uuidString)
        try Self.save(contents)
    }

    func hasOAuthToken(for accountId: UUID) -> Bool {
        ((try? Self.load())?.oauthTokens[accountId.uuidString]) != nil
    }

    // MARK: - Migration import

    /// Merge credentials read from the legacy Keychain into the file store.
    /// Existing file entries always win (post-migration edits live in the file).
    /// Called synchronously at app startup (MigrationService) before any other
    /// CredentialStore access, so the nonisolated file write is safe.
    nonisolated static func importIfAbsent(
        passwords: [String: String], oauthTokens: [String: String]) throws {
        var contents = try load()
        for (key, value) in passwords where contents.passwords[key] == nil {
            contents.passwords[key] = value
        }
        for (key, value) in oauthTokens where contents.oauthTokens[key] == nil {
            contents.oauthTokens[key] = value
        }
        try save(contents)
    }
}

enum CredentialStoreError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Credential not found — re-enter it in Settings → Accounts"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests/CredentialStoreTests 2>&1 | tail -30`
Expected: 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add MailKeep/Services/CredentialStore.swift MailKeepTests/CredentialStoreTests.swift MailKeep.xcodeproj/project.pbxproj
git commit -m "feat: add file-backed CredentialStore (passwords + OAuth tokens)"
```

---

### Task 3: One-time Keychain → file migration in MigrationService

Reads everything under both Keychain services and imports into `CredentialStore`. Retry-safe: completion flag is only set when reads were not blocked.

**Files:**
- Modify: `MailKeep/Services/MigrationService.swift`
- Create: `MailKeepTests/CredentialMigrationTests.swift`

**Interfaces:**
- Consumes: `CredentialStore.importIfAbsent(passwords:oauthTokens:)` (Task 2).
- Produces:
  - `MigrationService.migrateCredentialsIfNeeded(passwordService: String = "com.kzahedi.MailKeep", oauthService: String = "com.kzahedi.MailKeep.oauth", defaultsKey: String = "CredentialsFileMigrationCompleted")` — called from `MailKeepApp` in Task 4.
  - `MigrationService.readAllKeychainCredentials(service:) -> ([String: String], Bool)` (internal, for tests).

- [ ] **Step 1: Write the failing tests**

Create `MailKeepTests/CredentialMigrationTests.swift`. Tests use a unique Keychain service per run (never the production services) and clean up after themselves:

```swift
import XCTest
import Security
@testable import MailKeep

final class CredentialMigrationTests: XCTestCase {
    var tempDir: URL!
    var testService: String!
    var testOAuthService: String!
    var testDefaultsKey: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialMigrationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        CredentialStore.testFileOverride = tempDir.appendingPathComponent("credentials.json")
        let suffix = UUID().uuidString
        testService = "com.kzahedi.MailKeep.test-migration-\(suffix)"
        testOAuthService = "com.kzahedi.MailKeep.test-migration-oauth-\(suffix)"
        testDefaultsKey = "TestCredentialsMigration-\(suffix)"
    }

    override func tearDown() {
        CredentialStore.testFileOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        for service in [testService!, testOAuthService!] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            SecItemDelete(query as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: testDefaultsKey)
        super.tearDown()
    }

    private func addKeychainItem(service: String, account: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess, "Failed to seed keychain item")
    }

    func testReadAllExpandsConsolidatedStoreAndLegacyItems() throws {
        let uuidA = UUID().uuidString
        let uuidB = UUID().uuidString
        let consolidated = try JSONEncoder().encode([uuidA: "pw-a"])
        addKeychainItem(service: testService, account: "__credential_store__",
                        value: String(data: consolidated, encoding: .utf8)!)
        addKeychainItem(service: testService, account: uuidB, value: "pw-b")

        let (credentials, complete) = MigrationService.readAllKeychainCredentials(service: testService)
        XCTAssertTrue(complete)
        XCTAssertEqual(credentials[uuidA], "pw-a")
        XCTAssertEqual(credentials[uuidB], "pw-b")
    }

    func testReadAllReturnsCompleteOnEmptyService() {
        let (credentials, complete) = MigrationService.readAllKeychainCredentials(service: testService)
        XCTAssertTrue(complete)
        XCTAssertTrue(credentials.isEmpty)
    }

    func testConsolidatedStoreWinsOverLegacyItemForSameUUID() throws {
        let uuid = UUID().uuidString
        let consolidated = try JSONEncoder().encode([uuid: "newer"])
        addKeychainItem(service: testService, account: "__credential_store__",
                        value: String(data: consolidated, encoding: .utf8)!)
        addKeychainItem(service: testService, account: uuid, value: "older")

        let (credentials, _) = MigrationService.readAllKeychainCredentials(service: testService)
        XCTAssertEqual(credentials[uuid], "newer")
    }

    func testMigrateWritesFileAndSetsFlag() async throws {
        let uuid = UUID()
        addKeychainItem(service: testService, account: uuid.uuidString, value: "migrated-pw")
        addKeychainItem(service: testOAuthService, account: uuid.uuidString, value: "{\"t\":1}")

        MigrationService.migrateCredentialsIfNeeded(
            passwordService: testService, oauthService: testOAuthService,
            defaultsKey: testDefaultsKey)

        XCTAssertTrue(UserDefaults.standard.bool(forKey: testDefaultsKey))
        let pw = try await CredentialStore.shared.getPassword(for: uuid)
        XCTAssertEqual(pw, "migrated-pw")
        let token = try await CredentialStore.shared.getOAuthTokenString(for: uuid)
        XCTAssertEqual(token, "{\"t\":1}")
    }

    func testMigrateIsSkippedWhenFlagAlreadySet() async {
        UserDefaults.standard.set(true, forKey: testDefaultsKey)
        let uuid = UUID()
        addKeychainItem(service: testService, account: uuid.uuidString, value: "should-not-migrate")

        MigrationService.migrateCredentialsIfNeeded(
            passwordService: testService, oauthService: testOAuthService,
            defaultsKey: testDefaultsKey)

        let has = await CredentialStore.shared.hasPassword(for: uuid)
        XCTAssertFalse(has)
    }

    func testMigrationLeavesKeychainItemsInPlace() {
        let uuid = UUID().uuidString
        addKeychainItem(service: testService, account: uuid, value: "keep-me")

        MigrationService.migrateCredentialsIfNeeded(
            passwordService: testService, oauthService: testOAuthService,
            defaultsKey: testDefaultsKey)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService!,
            kSecAttrAccount as String: uuid
        ]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecSuccess)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests/CredentialMigrationTests 2>&1 | tail -30`
Expected: compile FAILURE — the two new MigrationService functions don't exist.

- [ ] **Step 3: Implement**

Add to `MailKeep/Services/MigrationService.swift` (inside the `enum MigrationService`):

```swift
// MARK: - Credential Migration (Keychain → file-backed CredentialStore)

private static let credentialsFileMigrationKey = "CredentialsFileMigrationCompleted"

/// One-time migration of IMAP passwords and OAuth tokens from the Keychain to the
/// file-backed CredentialStore. Runs synchronously at startup, before any other
/// CredentialStore access.
///
/// Retry-safe: the completion flag is set ONLY when every Keychain read either
/// succeeded or was confirmed empty. A blocked read (errSecInteractionNotAllowed
/// at Login Item startup after a rebuild changed the code signature) leaves the
/// flag unset so the migration retries on the next launch — typically a manual
/// launch where the user can approve the Keychain prompt.
///
/// Keychain items are intentionally left in place (rollback safety).
static func migrateCredentialsIfNeeded(
    passwordService: String = "com.kzahedi.MailKeep",
    oauthService: String = "com.kzahedi.MailKeep.oauth",
    defaultsKey: String = credentialsFileMigrationKey
) {
    guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }

    let (passwords, passwordsComplete) = readAllKeychainCredentials(service: passwordService)
    let (tokens, tokensComplete) = readAllKeychainCredentials(service: oauthService)

    if !passwords.isEmpty || !tokens.isEmpty {
        do {
            try CredentialStore.importIfAbsent(passwords: passwords, oauthTokens: tokens)
            print("[Migration] Migrated \(passwords.count) password(s) and \(tokens.count) OAuth token(s) from Keychain to file store")
        } catch {
            print("[Migration] Failed to write credentials file: \(error) — will retry next launch")
            return
        }
    }

    if passwordsComplete && tokensComplete {
        UserDefaults.standard.set(true, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
        print("[Migration] Credential migration to file store completed")
    } else {
        print("[Migration] Keychain read was blocked — credential migration will retry next launch")
    }
}

/// Read every generic-password item under `service` and flatten to
/// UUID-string → value. The consolidated "__credential_store__" JSON blob is
/// expanded and wins over legacy per-UUID items (it is the newer format).
/// Returns (credentials, complete) where complete=false means the read was
/// blocked/denied and the caller must NOT mark migration finished.
internal static func readAllKeychainCredentials(service: String) -> ([String: String], Bool) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnAttributes as String: true,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecItemNotFound { return ([:], true) }
    guard status == errSecSuccess, let items = result as? [[String: Any]] else {
        print("[Migration] Keychain read for \(service) failed with status \(status)")
        return ([:], false)
    }

    var perItem: [String: String] = [:]
    var consolidated: [String: String] = [:]
    for item in items {
        guard let account = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data else { continue }
        if account == "__credential_store__" {
            if let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                consolidated = dict
            }
        } else if UUID(uuidString: account) != nil,
                  let value = String(data: data, encoding: .utf8) {
            perItem[account] = value
        }
    }
    return (perItem.merging(consolidated) { _, consolidatedValue in consolidatedValue }, true)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests/CredentialMigrationTests 2>&1 | tail -30`
Expected: 6 tests PASS. Note: the seeded test items have no ACL restriction for the test runner (same process created them), so reads succeed without prompts.

- [ ] **Step 5: Commit**

```bash
git add MailKeep/Services/MigrationService.swift MailKeepTests/CredentialMigrationTests.swift
git commit -m "feat: one-time retry-safe migration of credentials from Keychain to file store"
```

---

### Task 4: Switch all call sites to CredentialStore and wire migration into startup

After this task the Keychain is no longer touched at runtime except by `MigrationService` (read-only).

**Files:**
- Modify: `MailKeep/App/MailKeepApp.swift` (line ~12)
- Modify: `MailKeep/Models/EmailAccount.swift` (lines 133–188)
- Modify: `MailKeep/Services/BackupManager+Accounts.swift` (lines 30, 58, 75, 91)
- Modify: `MailKeep/Views/Components/MissingPasswordsView.swift` (line 130)
- Modify: `MailKeep/Views/Settings/AccountsSettingsView.swift` (lines 302, 330)
- Modify: `MailKeepTests/BackupManagerAccountsTests.swift` (setUp/tearDown)

**Interfaces:**
- Consumes: full `CredentialStore` API (Task 2), `MigrationService.migrateCredentialsIfNeeded()` (Task 3).
- Produces: `EmailAccount` credential methods keep their exact existing signatures (`getPassword() async -> String?`, `savePassword(_:) async throws`, `deletePassword() async throws`, `hasPassword() async -> Bool`, `saveOAuthTokens(_:) async throws`, `getOAuthTokens() async -> GoogleOAuthTokens?`, `deleteOAuthTokens() async throws`) — only their backing store changes. Task 5 relies on `CredentialStore.shared.hasOAuthToken(for:)`.

- [ ] **Step 1: Write the failing test**

Add to `MailKeepTests/BackupManagerAccountsTests.swift` (and add `CredentialStore.testFileOverride = tempDir.appendingPathComponent("credentials.json")` in `setUp`, `CredentialStore.testFileOverride = nil` in `tearDown`, mirroring the existing `testAccountsFileOverride` pattern at lines 23–42):

```swift
func testAddAccountStoresPasswordInCredentialStore() async throws {
    let account = EmailAccount(email: "file@example.com", imapServer: "imap.example.com")
    let added = try await backupManager.addAccount(account, password: "file-pw")
    XCTAssertTrue(added)
    let stored = try await CredentialStore.shared.getPassword(for: account.id)
    XCTAssertEqual(stored, "file-pw")
}

func testRemoveAccountDeletesCredentials() async throws {
    let account = EmailAccount(email: "gone@example.com", imapServer: "imap.example.com")
    _ = try await backupManager.addAccount(account, password: "pw")
    backupManager.removeAccount(account)
    // removeAccount deletes asynchronously; poll briefly
    for _ in 0..<50 {
        let has = await CredentialStore.shared.hasPassword(for: account.id)
        if !has { return }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTFail("Password still present after removeAccount")
}
```

(If the test class has no `backupManager` property, follow the existing pattern in that file for constructing/accessing `BackupManager` — reuse whatever the neighbouring tests use.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests/BackupManagerAccountsTests 2>&1 | tail -30`
Expected: the two new tests FAIL (password went to Keychain, not CredentialStore).

- [ ] **Step 3: Switch the call sites**

3a. `MailKeep/App/MailKeepApp.swift` — after `MigrationService.migrateFileSystemIfNeeded()` (line 12) add:

```swift
MigrationService.migrateCredentialsIfNeeded()
```

3b. `MailKeep/Models/EmailAccount.swift` — replace every `KeychainService.shared` call:

```swift
/// Get password from the credential store
func getPassword() async -> String? {
    if let tempPassword = _password, !tempPassword.isEmpty {
        return tempPassword
    }
    return try? await CredentialStore.shared.getPassword(for: id)
}

/// Save password to the credential store
func savePassword(_ password: String) async throws {
    try await CredentialStore.shared.savePassword(password, for: id)
}

/// Delete password from the credential store
func deletePassword() async throws {
    try await CredentialStore.shared.deletePassword(for: id)
}

/// Check if password exists
func hasPassword() async -> Bool {
    if _password != nil { return true }
    return await CredentialStore.shared.hasPassword(for: id)
}
```

OAuth methods (delete the now-unused `oauthTokenKey` computed property):

```swift
func saveOAuthTokens(_ tokens: GoogleOAuthTokens) async throws {
    let data = try JSONEncoder().encode(tokens)
    guard let tokenString = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "EmailAccount", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Failed to encode OAuth tokens"])
    }
    try await CredentialStore.shared.saveOAuthTokenString(tokenString, for: id)
}

func getOAuthTokens() async -> GoogleOAuthTokens? {
    guard let tokenString = try? await CredentialStore.shared.getOAuthTokenString(for: id),
          let data = tokenString.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(GoogleOAuthTokens.self, from: data)
}

func deleteOAuthTokens() async throws {
    try await CredentialStore.shared.deleteOAuthTokenString(for: id)
}
```

3c. `MailKeep/Services/BackupManager+Accounts.swift`:
- Line 30: `let hasPassword = await CredentialStore.shared.hasPassword(for: account.id)`
- Line 58: `try await CredentialStore.shared.savePassword(passwordToSave, for: account.id)` (update log line to "Password saved to credential store for …")
- Line 75 (`removeAccount`) — also delete OAuth tokens (previously leaked):

```swift
Task {
    do {
        try await CredentialStore.shared.deletePassword(for: account.id)
        try await CredentialStore.shared.deleteOAuthTokenString(for: account.id)
    } catch {
        logWarning("Failed to delete credentials for \(account.email): \(error.localizedDescription)")
    }
}
```
- Line 91: `try await CredentialStore.shared.savePassword(password, for: account.id)`

3d. `MailKeep/Views/Components/MissingPasswordsView.swift` line 130:
`try await CredentialStore.shared.savePassword(password, for: account.id)`

3e. `MailKeep/Views/Settings/AccountsSettingsView.swift`:
- Line 302: `} else if let storedPassword = try? await CredentialStore.shared.getPassword(for: account.id) {` (rename the local variable from `keychainPassword` to `storedPassword` and update its use on the following lines)
- Line 330: `try await CredentialStore.shared.savePassword(password, for: account.id)`

3f. Verify no runtime Keychain use remains:

```bash
grep -rn "KeychainService.shared" MailKeep/ | grep -v "Services/KeychainService.swift" | grep -v "Services/MigrationService.swift"
```
Expected output: empty. (`MigrationService` uses raw `SecItem*` calls, not `KeychainService.shared`; `loadAccountList` keychain fallback in `BackupManager+Accounts.swift:120-121` stays — it is account-list migration, not credentials.)

- [ ] **Step 4: Run the full unit suite**

Run: `xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests 2>&1 | tail -30`
Expected: PASS, including the two new tests.

- [ ] **Step 5: Commit**

```bash
git add -A MailKeep/ MailKeepTests/
git commit -m "refactor: route all credential access through file-backed CredentialStore"
```

---

### Task 5: Detect missing OAuth tokens and offer in-app re-authorization

Today only password accounts appear in the missing-credentials prompt; OAuth accounts fail silently at sync time. Extend detection and let the user re-authorize from the same sheet.

**Files:**
- Modify: `MailKeep/Services/BackupManager+Accounts.swift` (`checkForMissingPasswords`, lines 23–40)
- Modify: `MailKeep/Views/Components/MissingPasswordsView.swift`
- Create: `MailKeepTests/MissingCredentialsTests.swift`

**Interfaces:**
- Consumes: `CredentialStore.shared.hasPassword(for:)`, `CredentialStore.shared.hasOAuthToken(for:)` (Task 2); `GoogleOAuthService.shared.authorize()` and `account.saveOAuthTokens(_:)` (existing, see `AccountsSettingsView.reauthorize()` lines 366–385 for the reference pattern).
- Produces: `BackupManager.accountsWithMissingPasswords` now also contains OAuth accounts with no stored token (property name intentionally unchanged to avoid churn in `MainWindowView.swift:52-62`).

- [ ] **Step 1: Write the failing test**

Create `MailKeepTests/MissingCredentialsTests.swift`:

```swift
import XCTest
@testable import MailKeep

@MainActor
final class MissingCredentialsTests: XCTestCase {
    var tempDir: URL!
    var backupManager: BackupManager!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingCredentialsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        CredentialStore.testFileOverride = tempDir.appendingPathComponent("credentials.json")
        BackupManager.testAccountsFileOverride = tempDir.appendingPathComponent("accounts.json")
        backupManager = BackupManager()
    }

    override func tearDown() async throws {
        CredentialStore.testFileOverride = nil
        BackupManager.testAccountsFileOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testOAuthAccountWithoutTokenIsFlaggedAsMissing() async throws {
        let withToken = EmailAccount.gmailOAuth(email: "ok@gmail.com")
        let withoutToken = EmailAccount.gmailOAuth(email: "broken@gmail.com")
        try await CredentialStore.shared.saveOAuthTokenString("{\"t\":1}", for: withToken.id)
        backupManager.accounts = [withToken, withoutToken]

        backupManager.checkForMissingPasswords()

        // checkForMissingPasswords updates asynchronously; poll briefly
        for _ in 0..<50 {
            if backupManager.accountsWithMissingPasswords.map(\.email) == ["broken@gmail.com"] {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Expected exactly broken@gmail.com to be flagged, got \(backupManager.accountsWithMissingPasswords.map(\.email))")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests/MissingCredentialsTests 2>&1 | tail -30`
Expected: FAIL — OAuth accounts are currently skipped by the `guard account.authType == .password` in `checkForMissingPasswords`.

- [ ] **Step 3: Implement**

3a. Replace the body of `checkForMissingPasswords()` in `BackupManager+Accounts.swift`:

```swift
/// Check all accounts for missing credentials (passwords AND OAuth tokens)
func checkForMissingPasswords() {
    Task {
        var missing: [EmailAccount] = []
        for account in accounts {
            switch account.authType {
            case .password:
                let has = await CredentialStore.shared.hasPassword(for: account.id)
                if !has { missing.append(account) }
            case .oauth2:
                let has = await CredentialStore.shared.hasOAuthToken(for: account.id)
                if !has { missing.append(account) }
            }
        }
        await MainActor.run {
            self.accountsWithMissingPasswords = missing
        }
    }
}
```

3b. In `MissingPasswordsView.swift`:
- Update header copy (lines 24–31): title `"Credentials Required"`, subtitle `"The following accounts need their credentials re-entered.\nThis can happen after migrating from a previous version."`
- In `accountRow(for:)`, replace the `SecureField` (line 96–98) with an auth-type switch:

```swift
if account.authType == .oauth2 {
    Button {
        reauthorize(account)
    } label: {
        Label("Re-authorize with Google", systemImage: "person.crop.circle.badge.checkmark")
    }
    .disabled(savingAccount != nil)
} else {
    SecureField("Password", text: binding(for: account.id))
        .textFieldStyle(.roundedBorder)
        .disabled(savingAccount != nil)
}
```

- In `saveAllPasswords()`, skip OAuth accounts: change the loop's first guard to

```swift
guard account.authType == .password,
      let password = passwords[account.id], !password.isEmpty else {
    continue
}
```

- Add the re-authorize method (mirrors `AccountsSettingsView.reauthorize()`):

```swift
private func reauthorize(_ account: EmailAccount) {
    errorMessage = nil
    savingAccount = account.id

    Task {
        do {
            let tokens = try await GoogleOAuthService.shared.authorize()
            try await account.saveOAuthTokens(tokens)
        } catch {
            await MainActor.run {
                errorMessage = "Re-authorization failed for \(account.email): \(error.localizedDescription)"
                savingAccount = nil
            }
            return
        }
        await MainActor.run {
            savingAccount = nil
            backupManager.checkForMissingPasswords()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the full unit suite:
`xcodebuild test -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' -only-testing:MailKeepTests 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MailKeep/Services/BackupManager+Accounts.swift MailKeep/Views/Components/MissingPasswordsView.swift MailKeepTests/MissingCredentialsTests.swift
git commit -m "feat: detect missing OAuth tokens and offer in-app re-authorization"
```

---

### Task 6: Stable signing identity support in install scripts

With credentials in a file this is defense-in-depth (it also stabilizes TCC grants and any future Keychain use), and it's free: a self-signed code-signing certificate gives every rebuild the same identity.

**Files:**
- Modify: `scripts/install.sh` (insert new step after step 2 "Build"; renumber `[x/7]` → `[x/8]` throughout)
- Modify: `scripts/check-installs.sh` (add informational signing check)
- Create: `docs/signing.md`

**Interfaces:**
- Consumes: nothing from other tasks (independent).
- Produces: `install.sh` signs with identity named exactly `MailKeep Dev` when present; `docs/signing.md` documents one-time cert creation.

- [ ] **Step 1: Add the signing step to `install.sh`**

Insert after the build step (current step 2, after `green "  ✓ built $NEW_APP"`) and renumber all subsequent step labels from `[3/7]`…`[7/7]` to `[4/8]`…`[8/8]`:

```bash
# --- 3. Re-sign with stable identity if one exists ---
# Ad-hoc signatures (unpaid Apple account) change on every rebuild, resetting
# Keychain ACLs and TCC permission grants. A self-signed "MailKeep Dev" cert
# (see docs/signing.md) gives every build the same identity.
blue "[3/8] Code signing…"
if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -q '"MailKeep Dev"'; then
  ent_file=$(/usr/bin/mktemp /tmp/mailkeep-ent.XXXXXX)
  if ! /usr/bin/codesign -d --entitlements - --xml "$NEW_APP" > "$ent_file" 2>/dev/null || [ ! -s "$ent_file" ]; then
    /bin/rm -f "$ent_file"
    ent_file=""
  fi
  if [ -n "$ent_file" ]; then
    /usr/bin/codesign --force --sign "MailKeep Dev" --entitlements "$ent_file" "$NEW_APP" \
      || { red "codesign failed"; exit 1; }
    /bin/rm -f "$ent_file"
  else
    /usr/bin/codesign --force --sign "MailKeep Dev" "$NEW_APP" \
      || { red "codesign failed"; exit 1; }
  fi
  green "  ✓ signed with stable identity 'MailKeep Dev'"
else
  yellow "  ⚠ no 'MailKeep Dev' identity — keeping ad-hoc signature (identity changes every rebuild; see docs/signing.md for the one-time fix)"
fi
echo
```

- [ ] **Step 2: Add informational signing check to `check-installs.sh`**

Read `scripts/check-installs.sh` first, then append (before its final exit logic, warn-only — must NOT change the script's exit code):

```bash
# Informational: show signing identity of the canonical install
if [ -d "$HOME/Applications/MailKeep.app" ]; then
  authority=$(/usr/bin/codesign -dv "$HOME/Applications/MailKeep.app" 2>&1 | /usr/bin/grep '^Authority=' | /usr/bin/head -1)
  if [ -n "$authority" ]; then
    echo "Signing: $authority"
  else
    echo "Signing: ad-hoc (identity changes every rebuild — see docs/signing.md)"
  fi
fi
```

- [ ] **Step 3: Write `docs/signing.md`**

```markdown
# Stable Code Signing Without a Paid Apple Account

## Why

`DEVELOPMENT_TEAM` is empty in this project, so Xcode ad-hoc signs every build —
each rebuild gets a **different** signing identity. macOS ties legacy-Keychain
item ACLs and TCC permission grants to that identity, so every rebuild resets
them ("MailKeep wants to access…" prompts; silent failures as a Login Item).
MailKeep now stores credentials in a file to be immune to this, but a stable
identity is still worthwhile for TCC grants (notifications, automation).

## One-time setup (~2 minutes)

1. Open **Keychain Access** (login keychain selected).
2. Menu: **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name: `MailKeep Dev` (must match exactly — install.sh looks for this name)
   Identity Type: **Self-Signed Root**
   Certificate Type: **Code Signing**
4. Create, accepting the defaults.
5. Verify: `security find-identity -v -p codesigning | grep "MailKeep Dev"`

`./scripts/install.sh` now signs every Release build with this identity.
The first `codesign` run may prompt to allow key access — click **Always Allow**.

## Notes

- This identity is only trusted on this Mac. Fine for personal use; not for
  distribution.
- If the certificate is deleted, install.sh falls back to ad-hoc signing with a
  warning.
```

- [ ] **Step 4: Verify**

```bash
bash -n scripts/install.sh && bash -n scripts/check-installs.sh && echo SYNTAX-OK
./scripts/check-installs.sh; echo "exit=$?"
```
Expected: `SYNTAX-OK`; check-installs runs and prints the new `Signing:` line, exit code unchanged from its drift verdict. Do **not** run `install.sh` (it would quit/replace the running app — user runs it after merge).

- [ ] **Step 5: Commit**

```bash
git add scripts/install.sh scripts/check-installs.sh docs/signing.md
git commit -m "feat: install.sh signs with stable 'MailKeep Dev' identity when available"
```

---

### Task 7: Documentation and in-app copy

**Files:**
- Modify: `MailKeep/Views/Settings/AdvancedSettingsView.swift:59`
- Modify: `CLAUDE.md` (repo root)
- Modify: `README.md` (only if it mentions Keychain — check with `grep -in keychain README.md`)

**Interfaces:** none (text only).

- [ ] **Step 1: Update in-app copy**

`AdvancedSettingsView.swift:59` — replace
`Text("OAuth tokens are stored securely in the macOS Keychain.")` with:

```swift
Text("Credentials are stored in ~/Library/Application Support/MailKeep/credentials.json (readable only by your user, encrypted at rest by FileVault).")
```

- [ ] **Step 2: Update CLAUDE.md**

In the "What NOT to do when this symptom appears" section, extend the last bullet:

```markdown
- Do not delete `~/Library/Application Support/MailKeep/accounts.json` or
  `credentials.json`. accounts.json is the account list; credentials.json holds
  IMAP passwords and OAuth tokens (since the file-store migration, 2026-07).
  Legacy copies may still exist in the Keychain (services `com.kzahedi.MailKeep`
  and `com.kzahedi.MailKeep.oauth`) — they are intentionally left as a fallback
  and are no longer read outside one-time migration.
```

Also add one line under "Canonical state":

```markdown
- Credentials: `~/Library/Application Support/MailKeep/credentials.json` (0600)
```

- [ ] **Step 3: Update README.md if needed**

Run `grep -in keychain README.md`. For each hit describing password/token storage, update to describe the file store (same wording as the AdvancedSettingsView text) and link `docs/signing.md`.

- [ ] **Step 4: Build check**

Run: `xcodebuild build -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add MailKeep/Views/Settings/AdvancedSettingsView.swift CLAUDE.md README.md
git commit -m "docs: document file-backed credential store and stable signing"
```

---

## Post-merge manual verification (performed with the user)

1. `./scripts/install.sh` (rebuild, consolidate, re-sign if cert exists)
2. Launch MailKeep manually → accounts present, no Keychain prompt.
3. Confirm migration log line in `~/Library/Application Support/MailKeep/Logs/` and that `credentials.json` exists with `-rw-------`.
4. Run a backup on one password account and one OAuth account.
5. Quit, relaunch via Login Item path (`open ~/Applications/MailKeep.app`), rerun a sync — no prompts, no oauthFailed.

## Task dependencies

- Task 1 → independent (do first; Task 3 relies on its semantics only conceptually)
- Task 2 → Task 3 → Task 4 → Task 5 (strict order)
- Task 6, Task 7 → independent, any time after Task 4 (Task 7 references the file store)
