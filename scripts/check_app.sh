#!/usr/bin/env bash
# Check a built GamGUI.app before anyone runs it with credentials:
# - the app: hardened runtime on, no entitlement outside the allowlist (none today; adding one is a
#   reviewed change, design doc §7), not debuggable (get-task-allow would let a same-user process read
#   the credentials out of its memory);
# - every Mach-O in the bundle: signed, verifying strictly, hardened runtime, and only where code
#   belongs (Contents/MacOS, Contents/Resources/gam7);
# - the embedded gam: exactly upstream GAM's three entitlements (listed here and in
#   Signing/gam.entitlements, so a change to either fails), and it runs as the pinned version.
# It checks how the app is assembled and signed, not where gam came from: provenance is
# scripts/fetch_gam.sh's pin and scripts/embed_gam.sh's checks. It checks the ad-hoc build CI makes; a
# team build also carries the entitlements Config/GamGUI-Team.entitlements claims.
# Usage: scripts/check_app.sh path/to/GamGUI.app
set -euo pipefail
APP="${1:?usage: check_app.sh path/to/GamGUI.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$APP/Contents/Info.plist"
GAM="$APP/Contents/Resources/gam7/gam"
GAM_ENTITLEMENTS="com.apple.security.cs.allow-jit com.apple.security.cs.allow-unsigned-executable-memory com.apple.security.cs.disable-library-validation"
fail() { echo "check_app: $*" >&2; exit 1; }
# Captured, never piped into `grep -q`: it exits at the first match, and under pipefail the writer's
# SIGPIPE would read as a failure.
runtime() { local info; info="$(codesign -dv "$1" 2>&1)" || return 1; grep -qE 'flags=0x[0-9a-f]+\(([^)]*,)?runtime' <<<"$info"; }
keys() {
  local xml
  xml="$(codesign -d --entitlements - --xml "$1" 2>/dev/null)" || return 1
  plutil -convert json -o - - <<<"$xml" 2>/dev/null \
    | python3 -I -c 'import json,sys; d=sys.stdin.read().strip(); print(" ".join(sorted(json.loads(d) if d else {})))'
}

codesign --verify --deep --strict "$APP" || fail "the app or its nested code doesn't verify"
runtime "$APP" || fail "the app: hardened runtime is off"
got="$(keys "$APP")" || fail "the app's entitlements can't be read"
[ -z "$got" ] || fail "the app carries entitlements [$got]; it should carry none"

# Every Mach-O, wherever it is: Resources are sealed as data, so an unsigned library there would verify
# with the app and then fail to load (or load, under disable-library-validation, unsigned).
count=0
while IFS= read -r -d '' f; do
  case "$(file -b "$f")" in Mach-O*) ;; *) continue ;; esac
  case "$f" in "$APP/Contents/MacOS/"* | "$APP/Contents/Resources/gam7/"*) ;; *) fail "code outside its places: ${f#"$APP"/}" ;; esac
  codesign --verify --strict "$f" 2>/dev/null || fail "unsigned or broken code: ${f#"$APP"/}"
  runtime "$f" || fail "hardened runtime is off: ${f#"$APP"/}"
  count=$((count + 1))
done < <(find "$APP" -type f -print0)

[ -f "$GAM" ] && [ ! -L "$GAM" ] || fail "no embedded gam"
want="$(plutil -convert json -o - "$ROOT/Signing/gam.entitlements" \
  | python3 -I -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))')" || fail "Signing/gam.entitlements can't be read"
[ "$want" = "$GAM_ENTITLEMENTS" ] || fail "Signing/gam.entitlements is [$want]; this check expects [$GAM_ENTITLEMENTS]"
have="$(keys "$GAM")" || fail "embedded gam: its entitlements can't be read"
[ "$have" = "$GAM_ENTITLEMENTS" ] || fail "embedded gam entitlements: got [$have], want [$GAM_ENTITLEMENTS]"
cfg="$(mktemp -d)"
version="$(GAMCFGDIR="$cfg" GAM_NO_UPDATE_CHECK=1 "$GAM" version 2>&1 | head -1)" || true
rm -rf "$cfg"
pin="$(sed -nE 's/.*expected = "([0-9.]+)".*/\1/p' "$ROOT/Packages/GamKit/Sources/GamEngine/GamVersion.swift")"
[ -n "$pin" ] || fail "can't read the pinned GAM version"
grep -qF "GAM $pin " <<<"$version" || fail "embedded gam reports [$version], pin is $pin"

# Siri: the intents ship as the code says (invariant 10). The title intent drafts in the app, in front
# (foreground, 2), never in the background, and every phrase names the app. Xcode checks these rules only
# when it builds the app, so the built metadata is what's read.
INTENTS="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
[ -f "$INTENTS" ] || fail "no App Intents metadata"
python3 -I - "$INTENTS" <<'PY' || fail "App Intents metadata (above)"
import json, sys
d = json.load(open(sys.argv[1]))
action = d.get("actions", {}).get("ChangeTitleIntent")
if not action:
    sys.exit("no ChangeTitleIntent")
if action.get("supportedModes") != 2:
    sys.exit(f"ChangeTitleIntent's modes are {action.get('supportedModes')}, not foreground (2)")
phrases = [p.get("key", "") if isinstance(p, dict) else str(p)
           for s in d.get("autoShortcuts", []) for p in s.get("phraseTemplates", [])]
if not phrases:
    sys.exit("no Siri phrases")
unnamed = [p for p in phrases if "${applicationName}" not in p]
if unnamed:
    sys.exit(f"phrases without the app's name: {unnamed}")
PY

[ "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" = "GamGUI" ] || fail "display name"
[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "27.0" ] || fail "minimum macOS"
echo "check_app: ok ($(plutil -extract CFBundleIdentifier raw -o - "$PLIST"); no app entitlements; $count signed Mach-O files; $version)"
