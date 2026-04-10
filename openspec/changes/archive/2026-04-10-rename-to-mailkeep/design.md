## Context

The product name is `MailKeep` but the entire technical stack still uses `IMAPBackup`:
- Xcode project/scheme: `IMAPBackup.xcodeproj`, scheme `IMAPBackup`
- Build target and Swift module: `IMAPBackup`
- Test target: `IMAPBackupTests`
- Source directories: `IMAPBackup/`, `IMAPBackupTests/`
- CI workflows reference `-scheme IMAPBackup` and `-target IMAPBackupTests`

The `.app` bundle is already named `MailKeep.app` (PRODUCT_NAME was updated earlier), so the build artifact is correct, but everything upstream is still `IMAPBackup`.

## Goals / Non-Goals

**Goals:**
- All human-visible and machine-visible identifiers consistently say `MailKeep`
- CI still passes after the rename
- Xcode project opens and builds without manual intervention

**Non-Goals:**
- Renaming the GitHub repository (separate operation, requires updating remote URLs)
- Changing the bundle identifier domain prefix (`com.kzahedi.*`)
- Renaming internal Swift type names that happen to contain `IMAP` (e.g., `IMAPService`, `IMAPError`) — these describe the protocol, not the product

## Decisions

### D1: Rename Xcode project file
Rename `IMAPBackup.xcodeproj` → `MailKeep.xcodeproj`. All references to the project in CI workflows must be updated. This is a one-time mechanical change.

### D2: Rename build target and test target via project.pbxproj
Edit `project.pbxproj` to rename `IMAPBackup` target → `MailKeep` and `IMAPBackupTests` → `MailKeepTests`. Update `PRODUCT_MODULE_NAME`, `PRODUCT_NAME`, `PRODUCT_BUNDLE_IDENTIFIER` entries accordingly.

### D3: Rename source directories
Move `IMAPBackup/` → `MailKeep/` and `IMAPBackupTests/` → `MailKeepTests/`. Update file references in `project.pbxproj`. Swift files themselves need no changes (Swift module name comes from the target, not the directory).

### D4: Update test imports
Replace `@testable import IMAPBackup` with `@testable import MailKeep` in all test files. This is a simple global search-and-replace.

### D5: Update CI workflows
Replace `-scheme IMAPBackup` with `-scheme MailKeep` and `-project IMAPBackup.xcodeproj` with `-project MailKeep.xcodeproj` in both `ci.yml` and `release.yml`.

### D6: Update Info.plist and README
Update `CFBundleName` if it still says `IMAPBackup`. Update README references.

## Risks / Trade-offs

- **Xcode project.pbxproj edits are fragile**: Incorrect edits break the project. Prefer using Xcode's built-in rename (Product > Rename) when possible, but for CI automation, sed-based edits with careful patterns are acceptable.
- **`IMAPBackup` appears inside type names** (e.g., `IMAPBackupTests` in test class references): these must be updated only in the test target context, not in protocol/service names like `IMAPService`.
- **Derived data cache**: After rename, derived data should be cleaned to avoid stale build artifacts.
