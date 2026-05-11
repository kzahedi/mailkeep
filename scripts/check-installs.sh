#!/bin/bash
# Detect MailKeep install drift: multiple MailKeep.app bundles registered with the
# same bundle ID cause Launch Services to pick a stale one for manual launches,
# which silently triggers the "accounts disappearing on restart" bug.
#
# Exits 0 if exactly one canonical install exists at ~/Applications/MailKeep.app.
# Exits non-zero on any drift, with a punch list of what's wrong.
#
# Avoids `set -e` / `set -o pipefail` on purpose — `grep -q` + pipefail produces
# spurious failures (grep closes stdin → upstream gets SIGPIPE → pipeline "fails").

set -u

BUNDLE_ID="com.kzahedi.MailKeep"
CANONICAL="$HOME/Applications/MailKeep.app"
ACCOUNTS_FILE="$HOME/Library/Application Support/MailKeep/accounts.json"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"

# Colorize only when stdout is a TTY (avoids escape codes in hook/log output).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  red()    { printf '\033[31m%s\033[0m\n' "$*"; }
  green()  { printf '\033[32m%s\033[0m\n' "$*"; }
  yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
else
  red()    { printf '%s\n' "$*"; }
  green()  { printf '%s\n' "$*"; }
  yellow() { printf '%s\n' "$*"; }
fi

problems=0
report_problem() { red "  ✗ $*"; problems=$((problems + 1)); }
report_ok()      { green "  ✓ $*"; }

# `strings BIN | grep -F PATTERN` without pipefail-induced false negatives.
binary_contains() {
  local bin="$1" pattern="$2"
  /usr/bin/strings "$bin" 2>/dev/null | /usr/bin/grep -F -q -- "$pattern"
}

echo "Checking MailKeep install state…"
echo

# 1. mdfind: how many MailKeep.app bundles with this ID exist on disk?
echo "[1/5] MailKeep.app bundles on disk (mdfind):"
mdfind_out=$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == $BUNDLE_ID" 2>/dev/null)
if [ -z "$mdfind_out" ]; then
  report_problem "no MailKeep.app found anywhere — expected one at $CANONICAL"
else
  count=$(printf '%s\n' "$mdfind_out" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  if [ "$count" -eq 1 ] && [ "$mdfind_out" = "$CANONICAL" ]; then
    report_ok "exactly one: $mdfind_out"
  else
    report_problem "$count bundle(s) found, expected only $CANONICAL:"
    printf '%s\n' "$mdfind_out" | /usr/bin/sed 's/^/      - /'
  fi
fi
echo

# 2. Launch Services: how many paths registered for the bundle ID?
echo "[2/5] Launch Services registration for $BUNDLE_ID:"
ls_paths=$("$LSREG" -dump 2>/dev/null | /usr/bin/awk -v id="$BUNDLE_ID" '
  /^----/             { path=""; ident=""; next }
  /^path:/            { sub(/^path:[[:space:]]+/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path=$0 }
  /^identifier:/      { sub(/^identifier:[[:space:]]+/, ""); ident=$0 }
  ident==id && path!=""  { print path; path=""; ident="" }
' | /usr/bin/sort -u)
if [ -z "$ls_paths" ]; then
  report_problem "no Launch Services registration for $BUNDLE_ID"
else
  ls_count=$(printf '%s\n' "$ls_paths" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  if [ "$ls_count" -eq 1 ] && [ "$ls_paths" = "$CANONICAL" ]; then
    report_ok "exactly one path: $ls_paths"
  else
    report_problem "$ls_count path(s) registered, expected only $CANONICAL:"
    printf '%s\n' "$ls_paths" | /usr/bin/sed 's/^/      - /'
  fi
fi
echo

# 3. Canonical install: exists, has the file-storage fix, post-rename module name
echo "[3/5] Canonical $CANONICAL contents:"
if [ ! -d "$CANONICAL" ]; then
  report_problem "missing — nothing at $CANONICAL"
else
  bin="$CANONICAL/Contents/MacOS/MailKeep"
  if [ ! -x "$bin" ]; then
    report_problem "executable missing at $bin"
  else
    if binary_contains "$bin" "MailKeep/accounts.json"; then
      report_ok "contains file-storage fix (accounts.json path)"
    else
      report_problem "missing file-storage fix string — pre-988c522 binary"
    fi
    if binary_contains "$bin" "_TtC10IMAPBackup"; then
      report_problem "Swift symbols still use IMAPBackup module — pre-rename binary"
    else
      report_ok "Swift symbols use MailKeep module (post-rename)"
    fi
    version=$(/usr/bin/defaults read "$CANONICAL/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
    built=$(/usr/bin/stat -f "%Sm" "$bin")
    echo "      version=$version, built=$built"
  fi
fi
echo

# 4. Login Item: should point at the canonical path (if set at all)
echo "[4/5] Login Item:"
login_path=$(/usr/bin/osascript -e \
  'tell application "System Events" to get the path of every login item whose name is "MailKeep"' \
  2>/dev/null)
if [ -z "$login_path" ] || [ "$login_path" = "missing value" ]; then
  yellow "  ⚠ no Login Item set (manual launch only)"
elif [ "$login_path" = "$CANONICAL" ]; then
  report_ok "points at $CANONICAL"
else
  report_problem "points at $login_path, expected $CANONICAL"
fi
echo

# 5. accounts.json: present and valid JSON
echo "[5/5] $ACCOUNTS_FILE:"
if [ ! -f "$ACCOUNTS_FILE" ]; then
  yellow "  ⚠ missing — fresh install or never launched after fix"
else
  count=$(/usr/bin/python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$ACCOUNTS_FILE" 2>/dev/null || echo "INVALID")
  if [ "$count" = "INVALID" ]; then
    report_problem "exists but JSON is invalid"
  else
    report_ok "$count account(s) stored"
  fi
fi
echo

if [ $problems -eq 0 ]; then
  green "OK — single canonical install, no drift detected."
  exit 0
else
  red "$problems problem(s) found. Run scripts/install.sh to rebuild and consolidate."
  exit 1
fi
