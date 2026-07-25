# Stable Code Signing Without a Paid Apple Account

## Why

`DEVELOPMENT_TEAM` is empty in this project, so Xcode ad-hoc signs every build —
each rebuild gets a **different** signing identity. macOS ties legacy-Keychain
item ACLs and TCC permission grants to that identity, so every rebuild resets
them ("MailKeep wants to access…" prompts; silent failures as a Login Item).
MailKeep now stores credentials in a file to be immune to this, but a stable
identity is still worthwhile for TCC grants (notifications, automation).

## One-time setup (~2 minutes)

1. Open **Keychain Access** (login keychain selected).
2. Menu: **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name: `MailKeep Dev` (must match exactly — install.sh looks for this name)
   Identity Type: **Self-Signed Root**
   Certificate Type: **Code Signing**
4. Create, accepting the defaults.
5. Verify: `security find-identity -v -p codesigning | grep "MailKeep Dev"`

`./scripts/install.sh` now signs every Release build with this identity.
The first `codesign` run may prompt to allow key access — click **Always Allow**.

## Notes

- This identity is only trusted on this Mac. Fine for personal use; not for
  distribution.
- If the certificate is deleted, install.sh falls back to ad-hoc signing with a
  warning.
