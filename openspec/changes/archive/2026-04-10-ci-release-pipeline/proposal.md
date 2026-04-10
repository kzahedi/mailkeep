## Why

The CI pipeline silently masks test failures, and every release build fails to compile due to a missing step. The goal is to fix both so that GitHub Releases can serve a working `.dmg` to users — the first publicly distributable build.

## What Changes

- **CI (`ci.yml`)**: Remove xcpretty pipe that swallows test failure exit codes; pin Xcode version; add `-project` flag; add concurrency group, timeout, and least-privilege permissions; pin third-party actions to commit SHAs; fix heredoc indentation in OAuthSecrets generation.
- **Release (`release.yml`)**: Add OAuthSecrets generation step (currently absent — every release fails to compile); validate version input to prevent shell injection; remove `|| true` guards that hide PlistBuddy failures; add a git tag creation step for `workflow_dispatch`; pin Xcode version and action SHAs; add permissions, timeout, concurrency.
- **DMG distribution**: The release workflow already produces a `.dmg` via `hdiutil`. The blocker is the compile failure. Once fixed, release notes will document the Gatekeeper bypass (`xattr -cr`) since the app is ad-hoc signed.

## Capabilities

### New Capabilities

- `ci-pipeline`: Reliable CI that correctly reports test pass/fail on every push and PR.
- `release-pipeline`: Automated release workflow that compiles, packages, and publishes a `.dmg` to GitHub Releases on tag push or manual dispatch.

### Modified Capabilities

_(none — no existing specs)_

## Impact

- **Files changed**: `.github/workflows/ci.yml`, `.github/workflows/release.yml`
- **No application code changes**
- **Third-party actions**: `actions/checkout`, `maxim-lobanov/setup-xcode`, `actions/upload-artifact`, `softprops/action-gh-release` — all pinned to specific commit SHAs
- **GitHub Secrets required**: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` (already present for CI; release workflow will use same secrets)
