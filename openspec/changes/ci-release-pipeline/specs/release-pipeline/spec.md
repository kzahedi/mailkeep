## ADDED Requirements

### Requirement: Release workflow compiles the app
The release workflow SHALL generate `OAuthSecrets.swift` before invoking `xcodebuild`, so the project compiles without missing-type errors.

#### Scenario: OAuthSecrets generated before build
- **WHEN** the release workflow runs
- **THEN** `IMAPBackup/Resources/OAuthSecrets.swift` exists before `xcodebuild` is invoked

### Requirement: Version input is validated before use
The release workflow SHALL validate that any manually supplied version string matches `^[0-9]+\.[0-9]+\.[0-9]+$` before using it in shell commands, and fail the job if it does not match.

#### Scenario: Valid version accepted
- **WHEN** `workflow_dispatch` is triggered with version `1.2.3`
- **THEN** the workflow proceeds normally

#### Scenario: Invalid version rejected
- **WHEN** `workflow_dispatch` is triggered with a version containing shell metacharacters or non-numeric segments
- **THEN** the workflow fails immediately with an error message before any build step runs

### Requirement: Version input is not interpolated directly into shell
The release workflow SHALL assign `${{ github.event.inputs.version }}` to an environment variable and reference only the env var in shell commands, never the expression directly.

#### Scenario: Expression injection not possible
- **WHEN** a version string containing `$(...)` or backticks is supplied
- **THEN** the string is treated as a literal value, not executed as a shell command

### Requirement: Release workflow produces a .dmg and uploads it to GitHub Releases
On a tag push or successful `workflow_dispatch`, the release workflow SHALL create a `.dmg` containing the app and attach it as a release asset on GitHub Releases.

#### Scenario: Tag push triggers release
- **WHEN** a tag matching `v[0-9]+.[0-9]+.0` is pushed
- **THEN** a GitHub Release is created with the `.dmg` attached

#### Scenario: Manual dispatch triggers release
- **WHEN** `workflow_dispatch` is triggered with a valid version
- **THEN** a git tag is created, pushed, and a GitHub Release is created with the `.dmg` attached

### Requirement: PlistBuddy version update failure aborts the release
The release workflow SHALL NOT use `|| true` on `PlistBuddy` commands. A failure to update the version in `Info.plist` SHALL abort the job.

#### Scenario: PlistBuddy fails
- **WHEN** the PlistBuddy command exits non-zero
- **THEN** the release job fails before the build step runs

### Requirement: Release uses a pinned, reproducible Xcode version
Same requirement as CI: fixed Xcode version string, not `latest-stable`.

#### Scenario: Xcode version is explicit
- **WHEN** the release workflow runs
- **THEN** the same Xcode version is selected regardless of runner image update timing

### Requirement: Release workflow uses explicit project reference
All `xcodebuild` invocations SHALL include `-project IMAPBackup.xcodeproj`.

#### Scenario: Explicit project flag
- **WHEN** `xcodebuild` is invoked in the release workflow
- **THEN** it targets `IMAPBackup.xcodeproj` directly

### Requirement: Release workflow limits GITHUB_TOKEN to contents write
The release workflow SHALL declare `permissions: contents: write` (minimum needed to create releases and upload assets) and nothing broader.

#### Scenario: Token scope is minimal
- **WHEN** the release job runs
- **THEN** the GITHUB_TOKEN cannot modify repository settings or trigger other workflows

### Requirement: Release workflow has a build timeout
The release job SHALL specify `timeout-minutes: 30`.

#### Scenario: Hung release build
- **WHEN** `xcodebuild` hangs for more than 30 minutes
- **THEN** the job is automatically cancelled

### Requirement: Third-party actions are pinned to commit SHAs
All third-party `uses:` references in the release workflow SHALL be pinned to full commit SHAs.

#### Scenario: Action reference is immutable
- **WHEN** the release workflow references a third-party action
- **THEN** the reference is a SHA, not a mutable tag

### Requirement: Release notes document Gatekeeper bypass
Because the distributed app is ad-hoc signed and not notarized, the GitHub Release description SHALL include instructions for users to bypass Gatekeeper on first launch.

#### Scenario: User downloads and opens the app
- **WHEN** a user downloads the `.dmg` and tries to open the app on a stock macOS system
- **THEN** the release notes contain a command or steps to clear the quarantine attribute
