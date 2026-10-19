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
# name:screen[:selected:tab[:window[:template[:calendar]]]] — the person page is captured once per tab, for
# alice@example.com, and a group's page for sales@example.com, alone and under a sheet (for a group the tab
# names the sheet: `add`, the Add Members form; `remove`, the preview of removing its first member; the
# picture is then the sheet). Calendars lists the rooms, then alice's calendars with Team Calendar's page
# open. Signatures opens on nobody (the demo admin
# isn't in the directory), then on alice@example.com with the saved template Classic loaded, in a window
# tall enough to show the current and new signatures side by side. Onboard opens on the demo role
# Salesperson with Create and the welcome email ticked, onboard-result on a made-up finished run (no gam
# runs), onboard-roles on the role editor and onboard-welcome on its Default welcome email (a sheet; its
# picture is the sheet). The narrow-*
# runs open a page in the smallest window with the sidebar and the page dragged to their widest, where
# clicking a name once crashed AppKit's layout (failure-log 2026-10-10, person-page layout loop): they
# fail when the page has too little room to spare, and on any non-zero exit.
# Offboard is filled in for carol@example.com leaving and alice@example.com taking over: the form, then (tab
# `plan`) the plan it runs, scrolled into view; `confirm`, the confirm sheet over it; `result`, a finished
# run's panel (made up: nothing runs); `-added`, with this app's own steps added (ten steps: the sheet asks for
# `confirm` too). Compromised checks carol@example.com (the mock's taken-over account), then (`plan`) plans with
# every filter that hides or forwards mail, her delegate and her other send-as address ticked; `confirm`, the confirm
# sheet; `result`, a made-up finished run; `reports`, Pull Incident Logs for her, then every account's by the address on
# her flagged sign-in; users-secure, carol's page in Users taking Actions → Secure Account…, which opens Compromised
# and checks her; person-search, her Mail tab searched for what she sent lately (the phish, with its Bcc list).
# Reports opens on its first report, then on its
# usage row (`usage`, the mock's report); Audit on a demo log AppServices writes fresh in the temporary folder.
# Phishing opens empty, then with the mock's phishing email found by its Message-ID, then (tab `recipients`) who its
# sender sent it to, (`confirm`) the confirm sheet over the copies, and (`result`) a finished run (made up: nothing runs).
for spec in home:home users:users groups:groups setup:setup \
            person-profile:users:alice@example.com:profile person-groups:users:alice@example.com:groups \
            person-mail:users:alice@example.com:mail person-security:users:alice@example.com:security \
            group-sales:groups:sales@example.com group-sales-add:groups:sales@example.com:add \
            group-sales-remove:groups:sales@example.com:remove \
            signatures:signatures signatures-alice:signatures:alice@example.com::1100x940:Classic \
            offboard:offboard:carol@example.com offboard-plan:offboard:carol@example.com:plan \
            offboard-confirm:offboard:carol@example.com:confirm offboard-result:offboard:carol@example.com:result \
            narrow-offboard:offboard:carol@example.com:plan:smallest \
            offboard-added:offboard:carol@example.com:plan-added offboard-confirm-added:offboard:carol@example.com:confirm-added \
            compromised:compromised:carol@example.com compromised-plan:compromised:carol@example.com:plan \
            compromised-confirm:compromised:carol@example.com:confirm compromised-result:compromised:carol@example.com:result \
            narrow-compromised:compromised:carol@example.com:plan:smallest \
            users-secure:users:carol@example.com:secure person-search:users:carol@example.com:search \
            narrow-person-search:users:carol@example.com:search:smallest \
            compromised-reports:compromised:carol@example.com:reports \
            narrow-compromised-reports:compromised:carol@example.com:reports:smallest \
            narrow-profile:users:alice@example.com:profile:smallest narrow-groups:users:alice@example.com:groups:smallest \
            narrow-mail:users:alice@example.com:mail:smallest narrow-security:users:alice@example.com:security:smallest \
            narrow-group-sales:groups:sales@example.com::smallest narrow-group-sales-add:groups:sales@example.com:add:smallest \
            narrow-signatures:signatures:alice@example.com::smallest:Classic \
            calendars:calendars calendars-alice:calendars:alice@example.com::::c_team@group.calendar.google.com \
            person-calendar:users:alice@example.com:calendar narrow-person-calendar:users:alice@example.com:calendar:smallest \
            narrow-calendars-alice:calendars:alice@example.com::smallest::c_team@group.calendar.google.com \
            reports:reports reports-usage:reports:usage audit:audit \
            narrow-reports:reports:::smallest narrow-reports-usage:reports:usage::smallest narrow-audit:audit:::smallest \
            onboard:onboard:Salesperson:create onboard-result:onboard:Salesperson:result \
            narrow-onboard:onboard:Salesperson:create:smallest \
            onboard-roles:onboard:Salesperson:roles narrow-onboard-roles:onboard:Salesperson:roles:smallest \
            onboard-welcome:onboard:Salesperson:welcome \
            phishing:phishing phishing-found:phishing:CAPh1sh+Invite=0001@mail.example.com \
            phishing-recipients:phishing:CAPh1sh+Invite=0001@mail.example.com:recipients:1100x1100 \
            phishing-confirm:phishing:CAPh1sh+Invite=0001@mail.example.com:confirm \
            phishing-result:phishing:CAPh1sh+Invite=0001@mail.example.com:result \
            narrow-phishing:phishing:CAPh1sh+Invite=0001@mail.example.com::smallest; do
  IFS=: read -r name screen person tab window template calendar <<< "$spec"
  file="$out/$name.png"
  rm -f "$file"
  # Each launch quits itself after the capture; give up on one that hangs.
  env -i HOME="$HOME" PATH="/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
    SWIFTGAMGUI_DEMO=1 SWIFTGAMGUI_SCREEN="$screen" SWIFTGAMGUI_SNAPSHOT="$file" \
    ${person:+SWIFTGAMGUI_SELECT="$person"} ${tab:+SWIFTGAMGUI_TAB="$tab"} ${window:+SWIFTGAMGUI_WINDOW="$window"} \
    ${template:+SWIFTGAMGUI_TEMPLATE="$template"} ${calendar:+SWIFTGAMGUI_CALENDAR="$calendar"} \
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
