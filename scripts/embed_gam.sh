#!/usr/bin/env bash
# Xcode "Embed GAM" build phase: copy the vendored, checksum-pinned GAM into the app and sign it with
# the hardened runtime, as GamGUI's scripts/sign_app.sh does. Every Mach-O under lib/ is signed with the
# app's identity; then gam itself, with upstream GAM's own entitlements (Signing/gam.entitlements: it is
# a PyInstaller bundle that needs them); Xcode then seals the app around it. The app's own entitlements
# stay empty. Runs before Xcode's code signing. Fails, rather than shipping an app without GAM, when
# GAM isn't vendored.
#
# Vendor/gam7 is trusted as scripts/fetch_gam.sh left it (the download verified against the pin before
# extraction), so this checks it is still that tree: the pinned version from a pinned download, and
# nothing but files and folders. A link would be copied as a link and codesign would follow it,
# signing (with GAM's entitlements) a file outside the app. Anyone who can rewrite Vendor/gam7 can
# rewrite this script too: this guards against a stale or odd tree, not that.
#
# Xcode's user-script sandbox is off for this target (ENABLE_USER_SCRIPT_SANDBOXING = NO): the phase
# reads a whole tree and writes into the bundle, which the sandbox would need every file declared for.
set -euo pipefail
fail() { echo "error: $*" >&2; exit 1; }
SRC="${SRCROOT}/Vendor/gam7"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/gam7"
FETCH="run scripts/fetch_gam.sh"

[ -f "$SRC/gam" ] && [ ! -L "$SRC/gam" ] && [ -x "$SRC/gam" ] || fail "GAM isn't vendored: $FETCH"
odd="$(find "$SRC" ! -type f ! -type d -print -quit)"
[ -z "$odd" ] || fail "Vendor/gam7 holds a link or special file ($odd): $FETCH"
pin="$(sed -nE 's/.*expected = "([0-9.]+)".*/\1/p' "${SRCROOT}/Packages/GamKit/Sources/GamEngine/GamVersion.swift")"
[ -n "$pin" ] || fail "can't read the pinned GAM version from GamVersion.swift"
[ -f "$SRC/VERSION" ] && [ "$(cat "$SRC/VERSION")" = "v$pin" ] || fail "Vendor/gam7 isn't GAM $pin: $FETCH"
[ -f "$SRC/SHA256" ] || fail "Vendor/gam7 has no SHA256 record: $FETCH"
grep -v '^#' "${SRCROOT}/scripts/gam_checksums.txt" | grep -qxF "$(cat "$SRC/SHA256")" \
  || fail "Vendor/gam7 came from a download that isn't pinned in scripts/gam_checksums.txt: $FETCH"

rm -rf "$DEST"
mkdir -p "$DEST"
# The grammar, changelog and catalog are build inputs, not runtime files; LICENSE ships (Apache-2.0).
rsync -a --exclude GamCommands.txt --exclude GamUpdate.txt --exclude command_catalog.json --exclude SHA256 \
  "$SRC/" "$DEST/"
ID="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$ID" ] || ID="-"
# No secure timestamp: an ad-hoc or development signature can't carry one. A Developer ID build for
# notarization (not made yet) needs --timestamp, as GamGUI's sign_app.sh passes.
sign() { codesign --force --options runtime --timestamp=none --sign "$ID" "$@"; }
find "$DEST/lib" -type f -print0 | while IFS= read -r -d '' f; do
  case "$(file -b "$f")" in Mach-O*) sign "$f" ;; esac
done
sign --entitlements "${SRCROOT}/Signing/gam.entitlements" "$DEST/gam"
