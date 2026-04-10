## Context

Two GitHub Actions workflows exist today:
- `ci.yml` — runs on push/PR to `main`. Builds and tests the app.
- `release.yml` — runs on tag push (`v*.*.0`) or manual dispatch. Builds, packages a `.dmg`, uploads to GitHub Releases.

**Current problems:**
1. `ci.yml` pipes `xcodebuild test` output through `xcpretty || true`. xcpretty is not installed on `macos-14` runners, so the pipe's exit code is always from xcpretty (non-zero → true), not from xcodebuild. Failing tests produce a green CI badge.
2. `release.yml` never generates `OAuthSecrets.swift` before building. The Swift compiler fails immediately with "cannot find type 'OAuthSecrets' in scope". No release has ever succeeded via GitHub Actions.
3. `release.yml` interpolates `${{ github.event.inputs.version }}` directly into a `run:` shell step. This is a GitHub Actions expression injection vector — any value with shell metacharacters executes arbitrary code in the runner.
4. Third-party actions are pinned to mutable floating tags (`@v1`, `@v4`). A compromised upstream maintainer can push a malicious commit under the same tag.
5. No `permissions:` block → GITHUB_TOKEN has read+write on all scopes by default. Least-privilege requires explicit declaration.
6. PlistBuddy failures are suppressed with `|| true`, so a release can ship with a wrong version string.
7. Xcode version is `latest-stable` (non-deterministic after runner image updates).
8. No `-project` flag in any `xcodebuild` call (relies on auto-discovery).
9. No `concurrency:` group → redundant runs queue on rapid pushes.
10. No `timeout-minutes` → hung `xcodebuild` runs for 6 hours.
11. Heredoc in OAuthSecrets generation is indented with spaces → leading whitespace in the generated Swift file.

## Goals / Non-Goals

**Goals:**
- CI correctly reports test pass/fail.
- `release.yml` compiles the app successfully and uploads a `.dmg` to GitHub Releases.
- Both workflows are hardened against supply-chain and injection attacks.
- Builds are reproducible (pinned Xcode, pinned action SHAs).
- Reasonable resource limits (timeout, concurrency cancellation).

**Non-Goals:**
- Code signing or notarization (no Apple Developer account; users will use `xattr -cr` to bypass Gatekeeper).
- UI test execution (excluded from CI; documented separately).
- Automatic patch release tagging (only major/minor tags trigger release).

## Decisions

### D1 — Remove xcpretty entirely (not install it)
xcpretty prettifies xcodebuild output but is not installed on GitHub-hosted macOS runners. The two options are: (a) install it with `gem install xcpretty`, or (b) remove it and use raw xcodebuild output. Raw output is verbose but complete, and xcodebuild's exit code is directly visible. Chosen: **remove xcpretty**. Rationale: fewer dependencies, simpler pipeline, no `|| true` escape hatch.

`set -o pipefail` is added at the top of any step that still uses pipes.

### D2 — Copy OAuthSecrets generation step verbatim into release.yml
The step already exists in `ci.yml` and works. The simplest fix is to duplicate it into `release.yml` immediately before the build step. Rationale: DRY would suggest a reusable workflow, but that adds complexity for a 5-line step. Duplication is the right call here.

### D3 — Fix expression injection with an intermediate env var
GitHub's recommended pattern is to assign the expression to an environment variable and then reference `$ENV_VAR` in the shell script. This prevents the expression value from being interpreted as shell syntax:
```yaml
env:
  VERSION_INPUT: ${{ github.event.inputs.version }}
run: |
  VERSION="$VERSION_INPUT"
```
Additionally, validate the format with a regex before use.

### D4 — Pin actions to full commit SHAs
All third-party action references (`actions/checkout`, `maxim-lobanov/setup-xcode`, `actions/upload-artifact`, `softprops/action-gh-release`) are pinned to their current commit SHAs, with the tag name as a comment. These SHAs are fetched at the time of this change and should be updated deliberately.

### D5 — Minimal permissions per workflow
- `ci.yml`: `contents: read` only.
- `release.yml`: `contents: write` (to create releases and upload assets).

### D6 — Pin Xcode to 16.2
Current `latest-stable` resolves to 16.2 on current runners. Pinning explicitly makes this contract visible and prevents unexpected upgrades.

### D7 — Add `-project IMAPBackup.xcodeproj` to all xcodebuild calls
Explicit is better than implicit. Prevents silent discovery failures if a workspace is ever added.

### D8 — Release tag creation for workflow_dispatch
When triggered by `workflow_dispatch`, the release workflow must create and push the git tag before `softprops/action-gh-release` runs — otherwise the action has no tag to attach assets to. Added as an explicit step using `git tag` + `git push`.

### D9 — Heredoc fix: use unindented heredoc or printf
The OAuthSecrets generation heredoc is indented to match YAML indentation, which embeds leading spaces into the generated Swift file. Fix by using an unindented `EOF` delimiter or by rewriting with `printf`.

## Risks / Trade-offs

- **Verbose CI output** → Removing xcpretty means raw xcodebuild output (~2000 lines per run). Acceptable given that the alternative silently hides failures.
- **SHA pinning maintenance** → Pinned SHAs must be manually updated when upstream actions release security fixes. Low operational burden for a small project; the security benefit outweighs it.
- **Unsigned .dmg blocked by Gatekeeper** → Users must run `xattr -dr com.apple.quarantine /Applications/IMAPBackup.app` or right-click → Open the first time. This must be documented in release notes. Apple notarization requires a paid Apple Developer account ($99/year).
- **Duplicated OAuthSecrets step** → Minor maintenance burden if the secret names ever change. Acceptable.

## Migration Plan

1. Apply changes to both workflow files in a single PR.
2. Merge to `main` — CI run validates the new `ci.yml` immediately.
3. Trigger a `workflow_dispatch` release with version `0.3.0` to validate the full release pipeline end-to-end before the next real release.
4. No rollback complexity — workflow files are the only thing changing.

## Open Questions

- _(none — all decisions resolved above)_
