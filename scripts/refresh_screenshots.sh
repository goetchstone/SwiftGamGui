#!/usr/bin/env bash
# Refreshes docs/screenshots from one CI run's snapshots, all at once, so no picture in the README or the gallery
# goes stale: every PNG already in docs/screenshots, and any other name given, is replaced by that run's. Fails
# when the run lacks one of them. Needs gh signed in to an account that can read this repository's runs.
#
#   scripts/refresh_screenshots.sh <run-id> [name ...]
set -euo pipefail
cd "$(dirname "$0")/.."

run="${1:?usage: scripts/refresh_screenshots.sh <run-id> [name ...]}"
shift
case "$run" in *[!0-9]*) echo "a run ID is digits, not $run" >&2; exit 2 ;; esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
gh run download "$run" --name snapshots --dir "$tmp"

missing=0
for name in $(cd docs/screenshots && ls -- *.png | sed 's/\.png$//') "$@"; do
  if [ -f "$tmp/screens/$name.png" ]; then
    cp "$tmp/screens/$name.png" "docs/screenshots/$name.png"
    echo "$name"
  else
    echo "not in run $run: $name" >&2
    missing=1
  fi
done
exit "$missing"
