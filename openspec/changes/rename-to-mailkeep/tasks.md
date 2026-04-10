## 1. Rename Xcode Project and Scheme Files

- [x] 1.1 Rename `IMAPBackup.xcodeproj/` directory to `MailKeep.xcodeproj/` (`git mv IMAPBackup.xcodeproj MailKeep.xcodeproj`)
- [x] 1.2 Rename `MailKeep.xcodeproj/xcshareddata/xcschemes/IMAPBackup.xcscheme` to `MailKeep.xcscheme`
- [x] 1.3 Inside `MailKeep.xcscheme`, replace all occurrences of `IMAPBackup` with `MailKeep` (scheme references target name in `BuildableReference` and `BlueprintName` attributes)

## 2. Update project.pbxproj — Target Names and Module

- [x] 2.1 In `MailKeep.xcodeproj/project.pbxproj`, replace `PRODUCT_MODULE_NAME = IMAPBackup;` with `PRODUCT_MODULE_NAME = MailKeep;` (two occurrences, Debug and Release)
- [x] 2.2 Replace all target-name occurrences of `"IMAPBackup"` (in `name =` and `remoteInfo =` fields for the main target) with `"MailKeep"`
- [x] 2.3 Replace all target-name occurrences of `"IMAPBackupTests"` with `"MailKeepTests"` in project.pbxproj
- [x] 2.4 Replace all target-name occurrences of `"IMAPBackupUITests"` with `"MailKeepUITests"` in project.pbxproj
- [x] 2.5 Replace built-product references: `IMAPBackup.app` → `MailKeep.app`, `IMAPBackupTests.xctest` → `MailKeepTests.xctest`, `IMAPBackupUITests.xctest` → `MailKeepUITests.xctest`

## 3. Rename Source Directories and Files

- [x] 3.1 Rename the `IMAPBackup/` source directory to `MailKeep/` (`git mv IMAPBackup MailKeep`)
- [x] 3.2 Rename the `IMAPBackupTests/` directory to `MailKeepTests/` (`git mv IMAPBackupTests MailKeepTests`)
- [x] 3.3 Rename the `IMAPBackupUITests/` directory to `MailKeepUITests/` (`git mv IMAPBackupUITests MailKeepUITests`)
- [x] 3.4 Rename `MailKeep/App/IMAPBackupApp.swift` → `MailKeep/App/MailKeepApp.swift` (`git mv`)
- [x] 3.5 Rename `MailKeep/Resources/IMAPBackup.entitlements` → `MailKeep/Resources/MailKeep.entitlements` (`git mv`)
- [x] 3.6 In `project.pbxproj`, update all `path =` references: `path = IMAPBackup;` → `path = MailKeep;`, `path = IMAPBackupTests;` → `path = MailKeepTests;`, `path = IMAPBackupUITests;` → `path = MailKeepUITests;`
- [x] 3.7 In `project.pbxproj`, update file references for renamed individual files: `IMAPBackupApp.swift` → `MailKeepApp.swift`, `IMAPBackup.entitlements` → `MailKeep.entitlements`, UITest file name references
- [x] 3.8 In `project.pbxproj`, update the `CODE_SIGN_ENTITLEMENTS` build setting to point to `MailKeep/Resources/MailKeep.entitlements`

## 4. Update Source Code Content

- [x] 4.1 In `MailKeep/App/MailKeepApp.swift`, rename `struct IMAPBackupApp: App` → `struct MailKeepApp: App` and update the `@main` entry point accordingly
- [x] 4.2 In `MailKeepUITests/IMAPBackupUITests.swift`, rename `final class IMAPBackupUITests` → `final class MailKeepUITests` and rename the file to `MailKeepUITests.swift` (`git mv`)
- [x] 4.3 In `MailKeepUITests/IMAPBackupUITestsLaunchTests.swift`, rename `final class IMAPBackupUITestsLaunchTests` → `final class MailKeepUITestsLaunchTests` and rename file to `MailKeepUITestsLaunchTests.swift` (`git mv`)

## 5. Update Test Imports

- [x] 5.1 In all 16 test files under `MailKeepTests/`, replace `@testable import IMAPBackup` with `@testable import MailKeep` (global search-and-replace across `MailKeepTests/`)

## 6. Update CI Workflows

- [x] 6.1 In `.github/workflows/ci.yml`, replace `-project IMAPBackup.xcodeproj` with `-project MailKeep.xcodeproj`
- [x] 6.2 In `.github/workflows/ci.yml`, replace `-scheme IMAPBackup` with `-scheme MailKeep`
- [x] 6.3 In `.github/workflows/release.yml`, replace `-project IMAPBackup.xcodeproj` with `-project MailKeep.xcodeproj`
- [x] 6.4 In `.github/workflows/release.yml`, replace `-scheme IMAPBackup` with `-scheme MailKeep`

## 7. Update Remaining References

- [x] 7.1 Check `Info.plist` for any `CFBundleName` or display name still set to `IMAPBackup`; update to `MailKeep` if found
- [x] 7.2 Search entire repo for remaining `IMAPBackup` string occurrences (excluding openspec artifacts and git history); fix any found in Swift source, plists, or markdown

## 8. Verification

- [x] 8.1 Run `xcodebuild -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' build` and confirm BUILD SUCCEEDED
- [x] 8.2 Run `xcodebuild -project MailKeep.xcodeproj -scheme MailKeep -destination 'platform=macOS' test` and confirm all tests pass
- [x] 8.3 Open `MailKeep.xcodeproj` in Xcode and confirm no missing file references or scheme errors
