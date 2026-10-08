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

# The embedded GAM: present, hardened runtime, exactly upstream's entitlements, and it runs.
GAM="$APP/Contents/Resources/gam7/gam"
[ -x "$GAM" ] || fail "no embedded gam"
codesign --verify --deep --strict "$APP" || fail "the bundle and its nested code don't verify"
gaminfo="$(codesign -dv "$GAM" 2>&1)"
grep -qE 'flags=0x[0-9a-f]+\(([^)]*,)?runtime' <<<"$gaminfo" || fail "embedded gam: hardened runtime is off"
keys() { plutil -convert json -o - - 2>/dev/null | python3 -c 'import json,sys; d=sys.stdin.read().strip(); print(" ".join(sorted(json.loads(d) if d else {})))'; }
want="$(keys < "$(dirname "$0")/../Signing/gam.entitlements")"
have="$(codesign -d --entitlements - --xml "$GAM" 2>/dev/null | keys)"
[ "$have" = "$want" ] || fail "embedded gam entitlements: got [$have], want [$want]"
cfg="$(mktemp -d)"
version="$(GAMCFGDIR="$cfg" GAM_NO_UPDATE_CHECK=1 "$GAM" version 2>&1 | head -1)"
rm -rf "$cfg"
pin="$(sed -nE 's/.*expected = "([0-9.]+)".*/\1/p' "$(dirname "$0")/../Packages/GamKit/Sources/GamEngine/GamVersion.swift")"
grep -qF "GAM $pin " <<<"$version" || fail "embedded gam reports [$version], pin is $pin"

[ "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "GamGUI" ] || fail "display name"
[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "27.0" ] || fail "minimum macOS"
echo "check_app: ok ($(plutil -extract CFBundleIdentifier raw -o - "$PLIST"); entitlements: ${got:-none}; $version)"
