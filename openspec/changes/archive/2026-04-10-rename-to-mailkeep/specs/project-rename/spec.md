## ADDED Requirements

### Requirement: Xcode project renamed to MailKeep

The Xcode project file SHALL be named `MailKeep.xcodeproj`. The build target SHALL be named `MailKeep`. The test target SHALL be named `MailKeepTests`. The Swift module name (`PRODUCT_MODULE_NAME`) SHALL be `MailKeep`.

#### Scenario: Project opens after rename
- **WHEN** the developer opens `MailKeep.xcodeproj` in Xcode
- **THEN** the project loads without errors and the build target is `MailKeep`

#### Scenario: Build target produces correct app bundle
- **WHEN** `xcodebuild -project MailKeep.xcodeproj -scheme MailKeep` is run
- **THEN** the build succeeds and produces `MailKeep.app`

### Requirement: Source directories use MailKeep name

The primary source directory SHALL be `MailKeep/` and the test directory SHALL be `MailKeepTests/`. All file references in `project.pbxproj` SHALL point to the new paths.

#### Scenario: Source files accessible after rename
- **WHEN** the project is built after directory rename
- **THEN** all source files are found with no "file not found" errors

### Requirement: Test files import MailKeep module

All test files SHALL use `@testable import MailKeep` instead of `@testable import IMAPBackup`.

#### Scenario: Tests compile after module rename
- **WHEN** `xcodebuild test` is run
- **THEN** all tests compile and pass with zero import errors

### Requirement: CI workflows reference MailKeep scheme

`.github/workflows/ci.yml` and `.github/workflows/release.yml` SHALL reference `-project MailKeep.xcodeproj` and `-scheme MailKeep`.

#### Scenario: CI passes after rename
- **WHEN** a push triggers the CI workflow
- **THEN** the build and test steps succeed using the new project and scheme names

### Requirement: Info.plist bundle name is MailKeep

`CFBundleName` in `Info.plist` SHALL be `MailKeep`.

#### Scenario: App displays correct name in Finder
- **WHEN** the app is built and inspected
- **THEN** the bundle name shown in Finder and About panels is `MailKeep`
