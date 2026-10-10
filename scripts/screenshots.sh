#!/usr/bin/env bash
# Renders every screen of a debug GamGUI.app to PNGs, from the demo tenant and the strict mock GAM only:
# credentials in memory, never the Keychain, and never the real gam (AppServices refuses anything but a
# regular file named mock_gam.sh). CI's macOS job runs it; the operator can too. Each image is the
# screen's own pane: the sidebar's and toolbar's system materials don't draw this way.
#
#   scripts/screenshots.sh path/to/Debug/GamGUI.app out-dir
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: scripts/screenshots.sh path/to/GamGUI.app out-dir}"
out="${2:?usage: scripts/screenshots.sh path/to/GamGUI.app out-dir}"
binary="$app/Contents/MacOS/GamGUI"
[ -x "$binary" ] || { echo "no executable at $binary" >&2; exit 1; }
mkdir -p "$out"

status=0
# name:screen[:person:tab[:window]] — the person page is captured once per tab, for alice@example.com.
# The narrow-* runs open it in the smallest window (ContentView's minimum) and at 900x572, where opening a
# person once crashed AppKit's layout (failure-log 2026-10-10): they are there to not crash.
for spec in home:home users:users setup:setup \
            person-profile:users:alice@example.com:profile person-groups:users:alice@example.com:groups \
            person-mail:users:alice@example.com:mail person-security:users:alice@example.com:security \
            narrow-profile:users:alice@example.com:profile:760x520 narrow-groups:users:alice@example.com:groups:760x520 \
            narrow-mail:users:alice@example.com:mail:760x520 narrow-security:users:alice@example.com:security:760x520 \
            narrow-900:users:alice@example.com:profile:900x572; do
  IFS=: read -r name screen person tab window <<< "$spec"
  file="$out/$name.png"
  rm -f "$file"
  # Each launch quits itself after the capture; give up on one that hangs.
  env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
    SWIFTGAMGUI_DEMO=1 SWIFTGAMGUI_SCREEN="$screen" SWIFTGAMGUI_SNAPSHOT="$file" \
    ${person:+SWIFTGAMGUI_SELECT="$person"} ${tab:+SWIFTGAMGUI_TAB="$tab"} ${window:+SWIFTGAMGUI_WINDOW="$window"} \
    SWIFTGAMGUI_GAM_BINARY="$PWD/Tests/Fixtures/mock_gam.sh" "$binary" &
  pid=$!
  for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  hung=0
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; hung=1; echo "::error::$name: no snapshot within 60 s" >&2; status=1; fi
  # A crash is a failure even when the image was written first.
  code=0; wait "$pid" || code=$?
  if [ "$hung" = 0 ] && [ "$code" != 0 ]; then echo "::error::$name: GamGUI exited with status $code" >&2; status=1; fi
  if [ -s "$file" ]; then echo "$name: $file"; else echo "::error::$name: no image written" >&2; status=1; fi
done
exit "$status"
