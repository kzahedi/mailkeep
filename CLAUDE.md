# MailKeep — Claude Code Instructions

## "Accounts disappear on restart" symptom — debug recipe

If the user reports that MailKeep shows no accounts after a restart, that the app
"comes up empty", or anything similar — **run `./scripts/check-installs.sh` FIRST,
before reading code or git history.** This is almost certainly install drift, not
a code bug.

### Why this recipe exists

The accounts list is stored at `~/Library/Application Support/MailKeep/accounts.json`
(commit 988c522, April 2026). Before that, it lived in the legacy Keychain with an
ACL tied to the code-signing identity, which silently failed at Login Item startup
with `errSecInteractionNotAllowed`.

The code fix is correct. But Xcode registers every Debug and Release build with
Launch Services under the same bundle ID `com.kzahedi.MailKeep`. When two or more
`MailKeep.app` bundles exist on disk, Launch Services may resolve the bundle ID to
a stale one for **manual launches** (Spotlight/Dock/Finder) — typically preferring
`~/Applications/` over `~/Library/Developer/Xcode/DerivedData/...`. The Login Item
keeps working because it has an absolute path; the manual relaunch falls onto a
pre-fix binary and shows no accounts.

### The recipe

```bash
./scripts/check-installs.sh   # diagnose; exits 0 if clean, 1 on any drift
./scripts/install.sh          # rebuild Release, consolidate to ~/Applications, refresh LS, repoint Login Item
```

`install.sh` is idempotent — safe to re-run.

### Canonical state

After `install.sh` the system holds **exactly one** `MailKeep.app`:

- Disk: `~/Applications/MailKeep.app`
- Launch Services: one registration, that path
- Login Item: that path
- `mdfind "kMDItemCFBundleIdentifier == com.kzahedi.MailKeep"` returns one line
- Credentials: `~/Library/Application Support/MailKeep/credentials.json` (0600)

Any deviation = drift. The DerivedData builds Xcode produces during development
will re-register themselves — that's expected. Re-run `install.sh` when you want
manual launches to resolve to a fresh binary again.

### What NOT to do when this symptom appears

- Do not start rewriting the account-loading code — it works.
- Do not blame Keychain ACLs — that was the original bug and is already fixed.
- Do not write a new "fix" before running `check-installs.sh`.
- Do not delete `~/Library/Application Support/MailKeep/accounts.json` or
  `credentials.json`. accounts.json is the account list; credentials.json holds
  IMAP passwords and OAuth tokens (since the file-store migration, 2026-07).
  Legacy copies may still exist in the Keychain (services `com.kzahedi.MailKeep`
  and `com.kzahedi.MailKeep.oauth`) — they are intentionally left as a fallback
  and are no longer read outside one-time migration.

## Backup health & credential probe (since 2026-07-25, merge e55438d)

When debugging "account shows red/orange dot" or "credentials sheet keeps appearing":

- The menubar dot derives from `BackupHistoryService.health(for:)` — red = ≥2
  consecutive failed backups, orange = 1, green = no recent failure (note: also
  green when there is NO history at all — known limitation).
- A daily credential probe (real IMAP login, no mail transfer) runs at most once
  per 24 h. Gate: UserDefaults `LastCredentialProbeDate`. Accounts it flags are
  persisted in UserDefaults `ProbeFlaggedAccountIDs` and stay in the
  missing-credentials sheet across restarts until a probe or backup succeeds.
- Failure notifications are deduped to one per account per 24 h via UserDefaults
  `HealthNotificationLastSent` (shared by backup-failure escalation and probe
  alerts). Deleting that key re-arms notifications immediately.
- Network errors never flag credentials: only `IMAPError.authenticationFailed` /
  `.oauthFailed` do; OAuth token-refresh URLErrors are rethrown as
  `connectionFailed` (transient) in `loginWithOAuth2`.
- Do not delete `backup_history.json` to "reset" a red dot — fix the underlying
  account; the dot clears on the next successful backup.
