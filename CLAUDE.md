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

Any deviation = drift. The DerivedData builds Xcode produces during development
will re-register themselves — that's expected. Re-run `install.sh` when you want
manual launches to resolve to a fresh binary again.

### What NOT to do when this symptom appears

- Do not start rewriting the account-loading code — it works.
- Do not blame Keychain ACLs — that was the original bug and is already fixed.
- Do not write a new "fix" before running `check-installs.sh`.
- Do not delete `~/Library/Application Support/MailKeep/accounts.json`. It contains
  the real account list. Backups: `~/Library/Application Support/MailKeep/Logs/`
  has historical logs but no account list backup; passwords live in Keychain.
