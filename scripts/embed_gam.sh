#!/usr/bin/env bash
# Xcode "Embed GAM" build phase: copy the vendored, checksum-pinned GAM into the app and sign it with
# the hardened runtime, as GamGUI's scripts/sign_app.sh does. Every Mach-O under lib/ is signed with the
# app's identity; then gam itself, with upstream GAM's own entitlements (Signing/gam.entitlements: it is
# a PyInstaller bundle that needs them); Xcode then seals the app around it. The app's own entitlements
# stay empty. Runs before Xcode's code signing. Fails, rather than shipping an app without GAM, when
# GAM isn't vendored.
set -euo pipefail
SRC="${SRCROOT}/Vendor/gam7"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/gam7"
if [ ! -x "$SRC/gam" ]; then
  echo "error: GAM isn't vendored — run scripts/fetch_gam.sh" >&2
  exit 1
fi
rm -rf "$DEST"
mkdir -p "$DEST"
# The grammar, changelog and catalog are build inputs, not runtime files; LICENSE ships (Apache-2.0).
rsync -a --exclude GamCommands.txt --exclude GamUpdate.txt --exclude command_catalog.json --exclude SHA256 \
  "$SRC/" "$DEST/"
ID="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$ID" ] || ID="-"
sign() { codesign --force --options runtime --timestamp=none --sign "$ID" "$@"; }
find "$DEST/lib" -type f -print0 | while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q '^Mach-O'; then sign "$f"; fi
done
sign --entitlements "${SRCROOT}/Signing/gam.entitlements" "$DEST/gam"
