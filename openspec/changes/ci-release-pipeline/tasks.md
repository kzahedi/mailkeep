## 1. Preparation — look up pinned action SHAs

- [x] 1.1 Fetch the current commit SHA for `actions/checkout@v4` (via `gh api repos/actions/checkout/git/ref/tags/v4`)
- [x] 1.2 Fetch the current commit SHA for `maxim-lobanov/setup-xcode@v1` (via `gh api repos/maxim-lobanov/setup-xcode/git/ref/tags/v1`)
- [x] 1.3 Fetch the current commit SHA for `actions/upload-artifact@v4` (via `gh api repos/actions/upload-artifact/git/ref/tags/v4`)
- [x] 1.4 Fetch the current commit SHA for `softprops/action-gh-release@v1` (via `gh api repos/softprops/action-gh-release/git/ref/tags/v1`)

## 2. Fix ci.yml

- [x] 2.1 Remove `| xcpretty --color || true` from the Run tests step; use raw xcodebuild output
- [x] 2.2 Add `set -o pipefail` to the Run tests step shell preamble (defense in depth)
- [x] 2.3 Change `xcode-version: latest-stable` to `xcode-version: '16.2'`
- [x] 2.4 Add `-project IMAPBackup.xcodeproj` to the Build step xcodebuild call
- [x] 2.5 Add `-project IMAPBackup.xcodeproj` to the Run tests step xcodebuild call
- [x] 2.6 Add top-level `permissions: contents: read` block
- [x] 2.7 Add `concurrency:` group keyed on `${{ github.workflow }}-${{ github.ref }}` with `cancel-in-progress: true`
- [x] 2.8 Add `timeout-minutes: 30` to the `test` job
- [x] 2.9 Replace `actions/checkout@v4` with pinned SHA (from task 1.1), tag as comment
- [x] 2.10 Replace `maxim-lobanov/setup-xcode@v1` with pinned SHA (from task 1.2), tag as comment
- [x] 2.11 Fix OAuthSecrets heredoc indentation: replaced heredoc with `printf` (unambiguous, no indentation issue)

## 3. Fix release.yml

- [x] 3.1 Add OAuthSecrets generation step (copy from ci.yml, place before the Build application step)
- [x] 3.2 Assign `${{ github.event.inputs.version }}` to env var `VERSION_INPUT`; reference only `$VERSION_INPUT` in shell
- [x] 3.3 Add version format validation: `if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then echo "Invalid version: $VERSION"; exit 1; fi`
- [x] 3.4 Remove `|| true` from both PlistBuddy lines
- [x] 3.5 Change `xcode-version: latest-stable` to `xcode-version: '16.2'`
- [x] 3.6 Add `-project IMAPBackup.xcodeproj` to the Build application xcodebuild call
- [x] 3.7 Add top-level `permissions: contents: write` block
- [x] 3.8 Add `timeout-minutes: 30` to the `build` job
- [x] 3.9 Replace `actions/checkout@v4` with pinned SHA (from task 1.1), tag as comment
- [x] 3.10 Replace `maxim-lobanov/setup-xcode@v1` with pinned SHA (from task 1.2), tag as comment
- [x] 3.11 Replace `actions/upload-artifact@v4` with pinned SHA (from task 1.3), tag as comment
- [x] 3.12 Replace both `softprops/action-gh-release@v1` references with pinned SHA (from task 1.4), tag as comment
- [x] 3.13 Add a git tag creation step for `workflow_dispatch` path: `git tag v$VERSION && git push origin v$VERSION` (runs before the Create Release step)
- [x] 3.14 Add Gatekeeper bypass instructions to the `softprops/action-gh-release` body field

## 4. Validate

- [x] 4.1 Run `yamllint` or GitHub's workflow syntax checker on both files (or open in the GitHub Actions editor) to confirm valid YAML
- [ ] 4.2 Push changes to a branch and verify the CI run completes with a green/red badge correctly reflecting test results
- [ ] 4.3 Trigger `workflow_dispatch` with version `0.3.0` to validate the release pipeline end-to-end; confirm `.dmg` appears as a release asset on GitHub
