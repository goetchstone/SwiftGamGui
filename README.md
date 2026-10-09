# SwiftGamGui

[![CI](https://github.com/goetchstone/SwiftGamGui/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/goetchstone/SwiftGamGui/actions/workflows/ci.yml)
[![CodeQL](https://github.com/goetchstone/SwiftGamGui/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/goetchstone/SwiftGamGui/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/goetchstone/SwiftGamGui/badge)](https://scorecard.dev/viewer/?uri=github.com/goetchstone/SwiftGamGui)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**GamGUI, rebuilt as a native macOS app.** A SwiftUI front end for
[GAM7](https://github.com/GAM-team/GAM), the Google Workspace admin CLI — the successor to the Python
GamGUI, with the same engine underneath: every operation is the same `gam` command GamGUI runs, held
byte-for-byte to GamGUI's live-proven commands by the test suite.

> **Status: early, read-only.** Phase 1: Setup (import credentials, copy them from GamGUI, Check
> access), Home (the directory's counts and GamGUI's reports) and a read-only Users list, over the GAM
> runner and parity fixtures. None of it has run against a real tenant yet, and nothing writes. Use the
> Python GamGUI for real work until a screen here says otherwise. Plan:
> [docs/plans/2026-10-08-native-gamgui.md](docs/plans/2026-10-08-native-gamgui.md).

Not affiliated with Google or the GAM team. GAM is their project; this app drives it.

## Build from source

Requires macOS 27 and Xcode 27.

1. Open Xcode once (or run `sudo xcodebuild -runFirstLaunch`) so its components are installed.
2. Clone this repo next to a checkout of [GamGUI](https://github.com/goetchstone/gamgui) (the parity
   reference and fixture generator).
3. Vendor GAM against the pin: `scripts/fetch_gam.sh`.
4. Add your Apple ID in Xcode → Settings → Accounts (a free Personal Team works), then create
   `Config/Local.xcconfig` (gitignored) with your team:
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   CODE_SIGN_IDENTITY = Apple Development
   CODE_SIGN_ENTITLEMENTS = Config/GamGUI-Team.entitlements
   ```
   The team entitlements claim a keychain access group, which makes Xcode provision the app. Without
   this file the app signs ad-hoc ("Sign to Run Locally"): it builds and runs, but it can't use the
   data-protection Keychain, so it can't store credentials.
5. Open `SwiftGamGui.xcodeproj` and build the **GamGUI** scheme **once in Xcode** (⌘B): that's when
   Xcode creates the provisioning profile with your account (`xcodebuild` alone reports "No
   Accounts"). After that, `xcodebuild -project SwiftGamGui.xcodeproj -scheme GamGUI build` works.

Tests: `swift test --package-path Packages/GamKit`. CI runs the same on GitHub's macOS 27 / Xcode 27
image, builds the app, checks its signature and entitlements (`scripts/check_app.sh`), and vendors the
pinned GAM; `ci-ok` is the one required check.

### No downloadable builds yet

A build you make yourself runs. A downloaded one would be blocked by Gatekeeper unless it's signed
with a Developer ID and notarized, which needs a paid Apple Developer membership. Until then, build
from source.

A free Personal Team's provisioning profile **expires after 7 days**. Rebuild in Xcode at least
weekly (a build renews it); the credentials you stored stay, because they belong to the team and the
bundle ID, not to the profile.

If you later switch to a different signing team, the app can no longer see the credentials the old
build stored; re-import them once.

## Live verification status

Every write will be audited, and this table will come from the audit log. **argv-identical** means
the native app emits exactly the command a GamGUI-confirmed write ran; **confirmed** means the native
app itself has run it against a production tenant.

| Write | Native status |
|---|---|
| *(none yet — phase 2)* | |

## License

MIT. GAM is Apache-2.0 (`Vendor/gam7/LICENSE`).
