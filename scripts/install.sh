#!/bin/bash
# Build a fresh Release of MailKeep and consolidate to a single canonical install at
# ~/Applications/MailKeep.app. Removes every other MailKeep.app bundle on the system,
# refreshes Launch Services, and re-points the Login Item.
#
# This prevents the "accounts disappear on manual restart" bug, which is caused by
# Launch Services picking a stale ~/Applications binary instead of the fresh
# DerivedData build (see ~/.claude/projects/.../memory/project_accounts_fix.md).
#
# Idempotent. Safe to re-run.

set -euo pipefail

BUNDLE_ID="com.kzahedi.MailKeep"
CANONICAL="$HOME/Applications/MailKeep.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"
REPO_ROOT="$(/usr/bin/cd "$(/usr/bin/dirname "$0")/.." && /bin/pwd)"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[34m%s\033[0m\n' "$*"; }

# --- 1. Refuse to run while MailKeep is alive (would lock the binary on copy) ---
blue "[1/8] Checking MailKeep is not running…"
if /bin/ps -axo comm | /usr/bin/grep -q '/MailKeep$'; then
  red "MailKeep is currently running. Quit it (Cmd-Q) and re-run this script."
  exit 1
fi
green "  ✓ not running"
echo

# --- 2. Build Release from current HEAD ---
blue "[2/8] Building Release from current HEAD…"
BUILD_DIR=$(/usr/bin/mktemp -d /tmp/mailkeep-release.XXXXXX)
trap '/bin/rm -rf "$BUILD_DIR"' EXIT
cd "$REPO_ROOT"
/usr/bin/xcodebuild \
  -project MailKeep.xcodeproj \
  -scheme MailKeep \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination "platform=macOS" \
  build > "$BUILD_DIR/build.log" 2>&1 \
  || { red "Build failed. Last 30 lines of build log:"; /usr/bin/tail -30 "$BUILD_DIR/build.log"; exit 1; }
NEW_APP="$BUILD_DIR/Build/Products/Release/MailKeep.app"
[ -d "$NEW_APP" ] || { red "Build succeeded but $NEW_APP is missing"; exit 1; }
green "  ✓ built $NEW_APP"
echo

# --- 3. Re-sign with stable identity if one exists ---
# Ad-hoc signatures (unpaid Apple account) change on every rebuild, resetting
# Keychain ACLs and TCC permission grants. A self-signed "MailKeep Dev" cert
# (see docs/signing.md) gives every build the same identity.
blue "[3/8] Code signing…"
if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -q '"MailKeep Dev"'; then
  ent_file=$(/usr/bin/mktemp /tmp/mailkeep-ent.XXXXXX)
  if ! /usr/bin/codesign -d --entitlements - --xml "$NEW_APP" > "$ent_file" 2>/dev/null || [ ! -s "$ent_file" ]; then
    /bin/rm -f "$ent_file"
    ent_file=""
  fi
  if [ -n "$ent_file" ]; then
    /usr/bin/codesign --force --sign "MailKeep Dev" --entitlements "$ent_file" "$NEW_APP" \
      || { red "codesign failed"; exit 1; }
    /bin/rm -f "$ent_file"
  else
    /usr/bin/codesign --force --sign "MailKeep Dev" "$NEW_APP" \
      || { red "codesign failed"; exit 1; }
  fi
  green "  ✓ signed with stable identity 'MailKeep Dev'"
else
  yellow "  ⚠ no 'MailKeep Dev' identity — keeping ad-hoc signature (identity changes every rebuild; see docs/signing.md for the one-time fix)"
fi
echo

# --- 4. Sanity-check the new binary contains the file-storage fix ---
# Write strings to a temp file so grep reads a file rather than a pipe —
# avoids SIGPIPE/pipefail false negatives from grep -q exiting early.
blue "[4/8] Verifying new binary contains the fix…"
strings_file=$(mktemp /tmp/mailkeep-strings.XXXXXX)
/usr/bin/strings "$NEW_APP/Contents/MacOS/MailKeep" > "$strings_file"
if ! /usr/bin/grep -q 'MailKeep/accounts.json' "$strings_file"; then
  rm -f "$strings_file"
  red "New binary is missing the file-storage fix marker — refusing to deploy"
  exit 1
fi
if /usr/bin/grep -q '_TtC10IMAPBackup' "$strings_file"; then
  rm -f "$strings_file"
  red "New binary still uses pre-rename IMAPBackup module symbols — refusing to deploy"
  exit 1
fi
rm -f "$strings_file"
green "  ✓ has file-storage fix, uses MailKeep module"
echo

# --- 5. Install to canonical location ---
blue "[5/8] Installing to ${CANONICAL}…"
/bin/mkdir -p "$HOME/Applications"
if [ -e "$CANONICAL" ]; then
  backup="/tmp/MailKeep-old-$(/bin/date +%Y%m%d-%H%M%S).app"
  /bin/mv "$CANONICAL" "$backup"
  yellow "  ⚠ moved previous install to $backup (delete when satisfied)"
fi
/bin/cp -R "$NEW_APP" "$CANONICAL"
green "  ✓ installed"
echo

# --- 6. Remove every OTHER MailKeep.app bundle on the system ---
blue "[6/8] Removing stale MailKeep.app bundles…"
removed=0
while IFS= read -r path; do
  [ -z "$path" ] && continue
  [ "$path" = "$CANONICAL" ] && continue
  "$LSREG" -u "$path" >/dev/null 2>&1 || true
  /bin/rm -rf "$path"
  echo "      - $path"
  removed=$((removed + 1))
done < <(/usr/bin/mdfind "kMDItemCFBundleIdentifier == $BUNDLE_ID" 2>/dev/null)
if [ $removed -eq 0 ]; then
  green "  ✓ no stale bundles"
else
  green "  ✓ removed $removed stale bundle(s)"
fi
echo

# --- 7. Refresh Launch Services registration ---
# Unregister EVERY path LS knows for the bundle ID except the canonical one —
# including this script's own temp build (xcodebuild registers it during step 2)
# and phantom entries whose bundles are already gone from disk. mdfind (step 6)
# can't be trusted for this: Spotlight indexing lags behind fresh builds.
blue "[7/8] Refreshing Launch Services registration…"
"$LSREG" -u "$NEW_APP" >/dev/null 2>&1 || true
while IFS= read -r reg_path; do
  [ -z "$reg_path" ] && continue
  [ "$reg_path" = "$CANONICAL" ] && continue
  "$LSREG" -u "$reg_path" >/dev/null 2>&1 || true
  echo "      - unregistered $reg_path"
done < <("$LSREG" -dump 2>/dev/null | /usr/bin/awk -v id="$BUNDLE_ID" '
  /^----/             { path=""; ident=""; next }
  /^path:/            { sub(/^path:[[:space:]]+/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path=$0 }
  /^identifier:/      { sub(/^identifier:[[:space:]]+/, ""); ident=$0 }
  ident==id && path!=""  { print path; path=""; ident="" }
' | /usr/bin/sort -u)
"$LSREG" -f "$CANONICAL" >/dev/null 2>&1
green "  ✓ registered $CANONICAL (all other registrations purged)"
echo

# --- 8. Re-point the Login Item ---
blue "[8/8] Repointing Login Item…"
/usr/bin/osascript -e \
  'tell application "System Events" to delete (every login item whose name is "MailKeep")' \
  >/dev/null 2>&1 || true
/usr/bin/osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "System Events"
  make new login item at end of login items with properties {path:"$CANONICAL", hidden:false}
end tell
APPLESCRIPT
login_path=$(/usr/bin/osascript -e \
  'tell application "System Events" to get the path of every login item whose name is "MailKeep"' \
  2>/dev/null)
if [ "$login_path" = "$CANONICAL" ]; then
  green "  ✓ Login Item -> $login_path"
else
  yellow "  ⚠ Login Item is '$login_path' (expected $CANONICAL) — re-toggle Launch at Login in the app if it stays wrong"
fi
echo

# --- Final check ---
echo "Running drift check…"
"$REPO_ROOT/scripts/check-installs.sh"
