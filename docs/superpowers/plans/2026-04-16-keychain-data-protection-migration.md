# Keychain Data Protection Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure the account list is always loaded after a macOS restart by migrating Keychain storage from the legacy ACL-based keychain (which silently fails in Login Item context) to the data protection keychain (`kSecUseDataProtectionKeychain: true`).

**Architecture:** The legacy macOS keychain uses per-application ACLs; when a Login Item starts at boot, the ACL dialog can't appear and `SecItemCopyMatching` silently returns an error, leaving accounts empty. The data protection keychain uses iOS-style data-class encryption with no ACL checks — it's accessible to the owning user's process after first login, no dialog. We add `kSecUseDataProtectionKeychain: true` to all account-list and per-account-password Keychain operations, and add a one-time migration path so existing items (saved without this flag) are transparently promoted on first read.

**Tech Stack:** Swift 5, Security.framework, macOS 14+ (`kSecUseDataProtectionKeychain` available since 10.15)

---

## File Map

| File | Change |
|------|--------|
| `MailKeep/Services/KeychainService.swift` | Add DP flag to all account-list ops; add legacy fallback + migration; add DP flag to password ops; add error logging |
| `MailKeep/Services/BackupManager+Accounts.swift` | Add logging in `loadAccounts()` for decode success/failure |
| `MailKeepTests/BackupManagerAccountsTests.swift` | Add test for legacy→DP migration; confirm existing tests pass |

---

## Task 1: Add logging to `loadAccounts()`

**Files:**
- Modify: `MailKeep/Services/BackupManager+Accounts.swift:90-104`

This has zero visibility today — if the Keychain read fails or the JSON decode fails, the app silently starts with no accounts. Add INFO logging so future failures are visible in the log file.

- [ ] **Step 1: Replace `loadAccounts()` with a logging-aware version**

Replace the entire function (lines 90–104):

```swift
func loadAccounts() {
    let keychain = KeychainService.shared

    // Prefer Keychain; fall back to UserDefaults for one-time migration
    if let data = keychain.loadAccountList() {
        if let decoded = try? JSONDecoder().decode([EmailAccount].self, from: data) {
            accounts = decoded
            logInfo("Loaded \(decoded.count) account(s) from Keychain")
        } else {
            logError("loadAccounts: JSON decode failed — account list data in Keychain is corrupt")
        }
    } else if let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([EmailAccount].self, from: data) {
        // Migrate to Keychain and remove from UserDefaults
        accounts = decoded
        try? keychain.saveAccountList(data)
        UserDefaults.standard.removeObject(forKey: accountsKey)
        logInfo("Migrated \(decoded.count) account(s) from UserDefaults to Keychain")
    } else {
        logInfo("loadAccounts: no accounts found (new install or first run)")
    }
}
```

- [ ] **Step 2: Verify the file compiles**

```bash
cd /Volumes/Eregion/projects/mailkeep
xcodebuild -scheme MailKeep -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error:|warning:|BUILD"
```

Expected: `BUILD SUCCEEDED` with no errors.

- [ ] **Step 3: Commit**

```bash
git add MailKeep/Services/BackupManager+Accounts.swift
git commit -m "fix: add logging to loadAccounts for decode success and failures"
```

---

## Task 2: Migrate account-list Keychain ops to data protection keychain

**Files:**
- Modify: `MailKeep/Services/KeychainService.swift:137-199`

Replace `saveAccountList`, `loadAccountList`, and `deleteAccountList` with versions that use `kSecUseDataProtectionKeychain: true`. `loadAccountList` also adds a one-time migration: if no item exists in the DP keychain, it falls back to the legacy keychain, migrates the data, and removes the legacy copy.

- [ ] **Step 1: Replace the three account-list methods**

Replace lines 137–199 (from `/// Save the full account list...` through `}` of `deleteAccountList`) with:

```swift
/// Save the full account list as a JSON blob.
/// Stores in the data protection keychain (no ACL checks, accessible after first login).
/// Uses upsert (update if exists, add if not) to avoid data loss.
nonisolated func saveAccountList(_ data: Data) throws {
    let serviceName = Self.testServiceOverride ?? accountListService
    let lookupQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountListAccount,
        kSecUseDataProtectionKeychain as String: true
    ]

    let checkStatus = SecItemCopyMatching(lookupQuery as CFDictionary, nil)
    if checkStatus == errSecSuccess {
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(lookupQuery as CFDictionary, updateAttributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw KeychainError.saveFailed(updateStatus)
        }
    } else {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountListAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.saveFailed(addStatus)
        }
    }
}

/// Load the account list JSON blob.
/// Tries the data protection keychain first. Falls back to legacy keychain and
/// performs a one-time migration if an item is found there.
/// Returns nil only if no item exists in either keychain.
nonisolated func loadAccountList() -> Data? {
    let serviceName = Self.testServiceOverride ?? accountListService

    // Primary: data protection keychain (no ACL dialog, safe for Login Items)
    let dpQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountListAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseDataProtectionKeychain as String: true
    ]
    var result: AnyObject?
    var status = SecItemCopyMatching(dpQuery as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data {
        return data
    }
    if status != errSecItemNotFound {
        print("[KeychainService] loadAccountList: data-protection keychain error \(status)")
    }

    // Fallback: legacy keychain (items saved before this migration)
    let legacyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountListAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    result = nil
    status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data {
        print("[KeychainService] loadAccountList: migrating legacy item to data-protection keychain")
        // Migrate: write to DP keychain, then remove legacy copy
        if (try? saveAccountList(data)) != nil {
            let deleteLegacy: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: accountListAccount
                // No kSecUseDataProtectionKeychain — targets legacy keychain only
            ]
            SecItemDelete(deleteLegacy as CFDictionary)
        }
        return data
    }
    if status != errSecItemNotFound {
        print("[KeychainService] loadAccountList: legacy keychain error \(status)")
    }

    return nil
}

/// Delete the account list entry from both the data protection and legacy keychains.
nonisolated func deleteAccountList() throws {
    let serviceName = Self.testServiceOverride ?? accountListService

    // Delete from data protection keychain
    let dpQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountListAccount,
        kSecUseDataProtectionKeychain as String: true
    ]
    let dpStatus = SecItemDelete(dpQuery as CFDictionary)

    // Also delete from legacy keychain (migration cleanup)
    let legacyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountListAccount
    ]
    SecItemDelete(legacyQuery as CFDictionary)  // ignore result — best-effort cleanup

    guard dpStatus == errSecSuccess || dpStatus == errSecItemNotFound else {
        throw KeychainError.deleteFailed(dpStatus)
    }
}
```

- [ ] **Step 2: Build to verify no compile errors**

```bash
xcodebuild -scheme MailKeep -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add MailKeep/Services/KeychainService.swift
git commit -m "fix: use data-protection keychain for account list; add legacy migration"
```

---

## Task 3: Migrate per-account password ops to data protection keychain

**Files:**
- Modify: `MailKeep/Services/KeychainService.swift:19-53` (savePassword)
- Modify: `MailKeep/Services/KeychainService.swift:60-82` (getPassword)
- Modify: `MailKeep/Services/KeychainService.swift:88-102` (deletePassword)

Same treatment as the account list — add `kSecUseDataProtectionKeychain: true` and a migration fallback in `getPassword`.

- [ ] **Step 1: Replace `savePassword`**

Replace lines 19–53 with:

```swift
/// Save password to Keychain (data protection keychain — no ACL dialogs).
func savePassword(_ password: String, for accountId: UUID, service: String? = nil) throws {
    let serviceName = service ?? defaultService
    let account = accountId.uuidString
    guard let passwordData = password.data(using: .utf8) else {
        throw KeychainError.encodingFailed
    }

    let lookupQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: account,
        kSecUseDataProtectionKeychain as String: true
    ]

    let checkStatus = SecItemCopyMatching(lookupQuery as CFDictionary, nil)
    if checkStatus == errSecSuccess {
        let updateAttributes: [String: Any] = [kSecValueData as String: passwordData]
        let updateStatus = SecItemUpdate(lookupQuery as CFDictionary, updateAttributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw KeychainError.saveFailed(updateStatus)
        }
    } else {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
}
```

- [ ] **Step 2: Replace `getPassword`**

Replace lines 60–82 with:

```swift
/// Retrieve password from Keychain.
/// Tries data protection keychain first; falls back to legacy keychain and migrates on hit.
func getPassword(for accountId: UUID, service: String? = nil) throws -> String {
    let serviceName = service ?? defaultService
    let account = accountId.uuidString

    // Primary: data protection keychain
    let dpQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseDataProtectionKeychain as String: true
    ]
    var result: AnyObject?
    var status = SecItemCopyMatching(dpQuery as CFDictionary, &result)
    if status == errSecSuccess,
       let passwordData = result as? Data,
       let password = String(data: passwordData, encoding: .utf8) {
        return password
    }

    // Fallback: legacy keychain (items saved before migration)
    let legacyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    result = nil
    status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
    if status == errSecSuccess,
       let passwordData = result as? Data,
       let password = String(data: passwordData, encoding: .utf8) {
        // Migrate to data protection keychain
        try? savePassword(password, for: accountId, service: service)
        // Remove legacy copy
        let deleteLegacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteLegacy as CFDictionary)
        return password
    }

    throw KeychainError.notFound
}
```

- [ ] **Step 3: Replace `deletePassword`**

Replace lines 88–102 with:

```swift
/// Delete password from Keychain (both data protection and legacy).
func deletePassword(for accountId: UUID, service: String? = nil) throws {
    let serviceName = service ?? defaultService
    let account = accountId.uuidString

    // Delete from data protection keychain
    let dpQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: account,
        kSecUseDataProtectionKeychain as String: true
    ]
    let dpStatus = SecItemDelete(dpQuery as CFDictionary)

    // Delete from legacy keychain too (cleanup)
    let legacyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: account
    ]
    SecItemDelete(legacyQuery as CFDictionary)

    guard dpStatus == errSecSuccess || dpStatus == errSecItemNotFound else {
        throw KeychainError.deleteFailed(dpStatus)
    }
}
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild -scheme MailKeep -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add MailKeep/Services/KeychainService.swift
git commit -m "fix: use data-protection keychain for per-account passwords; add legacy migration"
```

---

## Task 4: Update and extend tests

**Files:**
- Modify: `MailKeepTests/BackupManagerAccountsTests.swift`

The existing round-trip tests still work (they just write/read from DP keychain now). Add one new test that verifies the legacy→DP migration path works end-to-end.

- [ ] **Step 1: Add the legacy migration test**

Add after `testMigrationFromUserDefaultsToKeychain` (before `// MARK: - Helpers`):

```swift
func testLoadAccountsMigratesLegacyKeychainItemToDataProtection() {
    // Seed the LEGACY keychain directly (no kSecUseDataProtectionKeychain),
    // simulating an item written by an older version of the app.
    let account = makeAccount(email: "migrate@example.com")
    let data = try! JSONEncoder().encode([account])
    let serviceName = "com.kzahedi.MailKeep.accounts.uitesting"
    let legacyAdd: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: "account-list",
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
    ]
    let addStatus = SecItemAdd(legacyAdd as CFDictionary, nil)
    XCTAssertEqual(addStatus, errSecSuccess, "Pre-condition: legacy item must be inserted")

    // loadAccountList() should find the legacy item and migrate it
    let loaded = KeychainService.shared.loadAccountList()
    XCTAssertNotNil(loaded, "loadAccountList must return data after migrating legacy item")

    // The item must now exist in the data protection keychain
    let dpRead: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: "account-list",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseDataProtectionKeychain as String: true
    ]
    var dpResult: AnyObject?
    let dpStatus = SecItemCopyMatching(dpRead as CFDictionary, &dpResult)
    XCTAssertEqual(dpStatus, errSecSuccess, "Item must be in data-protection keychain after migration")

    // The legacy item must be gone (query legacy keychain only — no DP flag)
    // Note: without kSecUseDataProtectionKeychain the query only searches the legacy keychain.
    let legacyRead: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: "account-list",
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var legacyResult: AnyObject?
    let legacyStatus = SecItemCopyMatching(legacyRead as CFDictionary, &legacyResult)
    XCTAssertEqual(legacyStatus, errSecItemNotFound, "Legacy item must be removed after migration")
}
```

- [ ] **Step 2: Add missing import for Security framework**

Check the top of `BackupManagerAccountsTests.swift`. If `import Security` is missing, add it after `import XCTest`:

```swift
import XCTest
import Security
@testable import MailKeep
```

- [ ] **Step 3: Run the full test suite**

```bash
xcodebuild test -scheme MailKeep -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E "Test (Case|Suite)|error:|FAILED|passed|failed"
```

Expected: all `BackupManagerAccountsTests` pass, including the new migration test.

- [ ] **Step 4: Commit**

```bash
git add MailKeepTests/BackupManagerAccountsTests.swift
git commit -m "test: add legacy→data-protection keychain migration test"
```

---

## Task 5: Build release and redeploy locally

- [ ] **Step 1: Build Release configuration**

```bash
xcodebuild -scheme MailKeep -configuration Release -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error:|BUILD|SYMROOT"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 2: Locate built app**

```bash
xcodebuild -scheme MailKeep -configuration Release -destination 'platform=macOS,arch=arm64' -showBuildSettings 2>&1 | grep "BUILT_PRODUCTS_DIR"
```

- [ ] **Step 3: Kill running instance and replace**

```bash
# Find where the current app is running from
ps aux | grep -i MailKeep | grep -v grep
```

If running from DerivedData or project build, quit the app from the menu bar first, then open the new build.

- [ ] **Step 4: Verify the migration works**

After launching the new build:
1. Open the MailKeep window — accounts should appear (loaded from legacy or DP keychain)
2. Check the log file: `tail -20 ~/Library/Application\ Support/MailKeep/Logs/imap-backup.log`
3. Expect to see: `Loaded N account(s) from Keychain` or `migrating legacy item to data-protection keychain`

- [ ] **Step 5: Final commit with version note**

```bash
git add -p  # review any remaining changes
git commit -m "fix: migrate Keychain to data-protection; accounts now load reliably after restart

The legacy macOS keychain uses ACL-based access control. When MailKeep
runs as a Login Item at boot, macOS cannot show the ACL authorization
dialog, causing SecItemCopyMatching to silently fail and accounts to
appear empty. The data protection keychain uses iOS-style encryption
classes with no ACL checks — items are accessible to the owning user
after first login, with no dialog required.

All account-list and per-password Keychain operations now use
kSecUseDataProtectionKeychain: true. A one-time migration reads
existing items from the legacy keychain and re-writes them to the DP
keychain on first load."
```

---

## Self-Review

**Spec coverage:**
- ✓ Account list ops migrated to DP keychain (Tasks 2)
- ✓ Password ops migrated to DP keychain (Task 3)
- ✓ One-time migration from legacy keychain (Tasks 2 & 3)
- ✓ Error logging added (Task 1)
- ✓ Tests for migration path (Task 4)
- ✓ Build and deploy (Task 5)

**Placeholder scan:** No TBD/TODO/placeholder text found.

**Type consistency:** All Keychain queries use the same key constants throughout. `serviceName`/`accountListAccount`/`accountListService` naming consistent with existing code. `kSecUseDataProtectionKeychain` applied uniformly.
