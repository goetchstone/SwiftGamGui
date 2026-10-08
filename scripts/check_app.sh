#!/usr/bin/env bash
# Check a built GamGUI.app: hardened runtime on, entitlements within the allowlist, identity as
# configured. An entitlement added without updating this list fails CI (design doc §7: adding one is a
# reviewed change). It checks the ad-hoc build CI makes; a team build also carries the provisioning
# entitlements Config/GamGUI-Team.entitlements claims. Usage: scripts/check_app.sh path/to/GamGUI.app
set -euo pipefail
APP="${1:?usage: check_app.sh path/to/GamGUI.app}"
PLIST="$APP/Contents/Info.plist"
fail() { echo "check_app: $*" >&2; exit 1; }

codesign --verify --strict "$APP" || fail "signature does not verify"
# Captured first: `grep -q` exits at the first match, and under pipefail the writer's SIGPIPE would
# read as a failure.
info="$(codesign -dv "$APP" 2>&1)"
grep -qE 'flags=0x[0-9a-f]+\(([^)]*,)?runtime' <<<"$info" || fail "hardened runtime is off"

ALLOWED="com.apple.security.get-task-allow"   # Xcode adds it to development builds; export strips it
got="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | plutil -convert json -o - - 2>/dev/null \
  | python3 -c 'import json,sys; d=sys.stdin.read().strip(); print("\n".join(sorted(json.loads(d) if d else {})))')"
for key in $got; do
  case " $ALLOWED " in *" $key "*) ;; *) fail "unexpected entitlement: $key" ;; esac
done

[ "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "GamGUI" ] || fail "display name"
[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "27.0" ] || fail "minimum macOS"
echo "check_app: ok ($(plutil -extract CFBundleIdentifier raw -o - "$PLIST"); entitlements: ${got:-none})"
