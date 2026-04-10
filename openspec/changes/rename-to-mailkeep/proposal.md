## Why

The codebase, Xcode project, module name, bundle identifier, and source files all use the legacy `IMAPBackup` name, while the actual product is called `MailKeep`. This inconsistency creates confusion for contributors, and affects every layer: Xcode scheme, build target, Swift module, test target, file names, class/struct names, and the GitHub repository name.

## What Changes

- Rename Xcode project target `IMAPBackup` → `MailKeep`
- Rename Swift module from `IMAPBackup` to `MailKeep` (affects `@testable import IMAPBackup` in tests)
- Rename test target `IMAPBackupTests` → `MailKeepTests`
- Rename source directory `IMAPBackup/` → `MailKeep/` (all `.swift` files move)
- Rename `IMAPBackupTests/` → `MailKeepTests/`
- Update bundle identifier from `com.*.imapbackup` → `com.*.mailkeep` (or equivalent)
- Update `Info.plist` `CFBundleName` and display name
- Update all `import IMAPBackup` / `@testable import IMAPBackup` references in test files
- Update `.github/workflows/ci.yml` and `release.yml` build and test commands
- Update `README.md` and any other documentation references
- Rename `IMAPBackup.xcodeproj` → `MailKeep.xcodeproj` (**BREAKING** for existing bookmarks/scripts)

## Capabilities

### New Capabilities
- `project-rename`: Rename all `IMAPBackup` identifiers, file names, and Xcode project settings to `MailKeep`

### Modified Capabilities

## Impact

- Xcode project file (`.xcodeproj/project.pbxproj`)
- All Swift source files containing `IMAPBackup` in class/struct/enum names or comments
- All test files (`@testable import IMAPBackup`)
- CI workflow files referencing scheme/target names
- `Info.plist`
- `README.md` and docs
