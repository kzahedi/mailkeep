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
blue "[1/7] Checking MailKeep is not running…"
if /bin/ps -axo comm | /usr/bin/grep -q '/MailKeep$'; then
  red "MailKeep is currently running. Quit it (Cmd-Q) and re-run this script."
  exit 1
fi
green "  ✓ not running"
echo

# --- 2. Build Release from current HEAD ---
blue "[2/7] Building Release from current HEAD…"
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

# --- 3. Sanity-check the new binary contains the file-storage fix ---
blue "[3/7] Verifying new binary contains the fix…"
if ! /usr/bin/strings "$NEW_APP/Contents/MacOS/MailKeep" | /usr/bin/grep -q 'MailKeep/accounts.json'; then
  red "New binary is missing the file-storage fix marker — refusing to deploy"
  exit 1
fi
if /usr/bin/strings "$NEW_APP/Contents/MacOS/MailKeep" | /usr/bin/grep -q '_TtC10IMAPBackup'; then
  red "New binary still uses pre-rename IMAPBackup module symbols — refusing to deploy"
  exit 1
fi
green "  ✓ has file-storage fix, uses MailKeep module"
echo

# --- 4. Install to canonical location ---
blue "[4/7] Installing to $CANONICAL…"
/bin/mkdir -p "$HOME/Applications"
if [ -e "$CANONICAL" ]; then
  backup="/tmp/MailKeep-old-$(/bin/date +%Y%m%d-%H%M%S).app"
  /bin/mv "$CANONICAL" "$backup"
  yellow "  ⚠ moved previous install to $backup (delete when satisfied)"
fi
/bin/cp -R "$NEW_APP" "$CANONICAL"
green "  ✓ installed"
echo

# --- 5. Remove every OTHER MailKeep.app bundle on the system ---
blue "[5/7] Removing stale MailKeep.app bundles…"
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

# --- 6. Refresh Launch Services registration ---
blue "[6/7] Refreshing Launch Services registration…"
"$LSREG" -f "$CANONICAL" >/dev/null 2>&1
green "  ✓ registered $CANONICAL"
echo

# --- 7. Re-point the Login Item ---
blue "[7/7] Repointing Login Item…"
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
