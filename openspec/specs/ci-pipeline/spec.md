### Requirement: CI correctly reports test failures
The CI workflow SHALL exit with a non-zero status code when any unit test fails, causing the GitHub check to show as failed.

#### Scenario: Test failure is visible
- **WHEN** `xcodebuild test` exits with a non-zero code
- **THEN** the workflow job fails and the commit/PR check shows red

#### Scenario: Test success is visible
- **WHEN** all tests pass
- **THEN** the workflow job succeeds and the commit/PR check shows green

### Requirement: CI uses a pinned, reproducible Xcode version
The CI workflow SHALL specify a fixed Xcode version string (not `latest-stable`) so that builds are reproducible across runner image updates.

#### Scenario: Xcode version is explicit
- **WHEN** the workflow runs
- **THEN** the same Xcode version is selected regardless of when the runner image was last updated

### Requirement: CI generates OAuthSecrets.swift before building
The CI workflow SHALL generate `IMAPBackup/Resources/OAuthSecrets.swift` from GitHub Secrets before invoking `xcodebuild`, so the project compiles successfully.

#### Scenario: Secrets present
- **WHEN** `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` secrets are set in the repository
- **THEN** `OAuthSecrets.swift` is generated with the correct values and the build succeeds

### Requirement: CI uses explicit project reference in xcodebuild
All `xcodebuild` invocations in CI SHALL include `-project IMAPBackup.xcodeproj` to prevent silent auto-discovery failures.

#### Scenario: Explicit project flag
- **WHEN** `xcodebuild` is invoked
- **THEN** it targets `IMAPBackup.xcodeproj` directly, not via auto-discovery

### Requirement: CI limits GITHUB_TOKEN to read-only
The CI workflow SHALL declare `permissions: contents: read` so the GITHUB_TOKEN cannot write to the repository.

#### Scenario: Token scope is minimal
- **WHEN** the CI job runs
- **THEN** the GITHUB_TOKEN cannot push commits, create releases, or modify repository settings

### Requirement: CI cancels redundant runs
The CI workflow SHALL use a `concurrency` group keyed on the workflow name and ref, cancelling in-progress runs when a new one starts on the same branch.

#### Scenario: Rapid pushes
- **WHEN** two commits are pushed in quick succession to the same branch
- **THEN** the first CI run is cancelled and only the second completes

### Requirement: CI has a build timeout
The CI job SHALL specify `timeout-minutes: 30` to prevent runaway xcodebuild processes from consuming unlimited runner time.

#### Scenario: Hung build
- **WHEN** `xcodebuild` hangs for more than 30 minutes
- **THEN** the job is automatically cancelled by GitHub Actions

### Requirement: Third-party actions are pinned to commit SHAs
All third-party `uses:` references in CI SHALL be pinned to a full 40-character commit SHA, with the corresponding tag as an inline comment.

#### Scenario: Action reference is immutable
- **WHEN** the workflow file references a third-party action
- **THEN** the reference is a SHA, not a mutable tag like `@v1`
