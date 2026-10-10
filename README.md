# SwiftGamGui

[![CI](https://github.com/goetchstone/SwiftGamGui/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/goetchstone/SwiftGamGui/actions/workflows/ci.yml)
[![CodeQL](https://github.com/goetchstone/SwiftGamGui/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/goetchstone/SwiftGamGui/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/goetchstone/SwiftGamGui/badge)](https://scorecard.dev/viewer/?uri=github.com/goetchstone/SwiftGamGui)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A native macOS version of [GamGUI](https://github.com/goetchstone/gamgui), the Google Workspace admin
app built on [GAM7](https://github.com/GAM-team/GAM). It runs the same `gam` commands GamGUI runs, and
the tests check that they match GamGUI's exactly.

**Status: early.** You can import credentials (or copy them from GamGUI), check access, see the
directory's counts and reports, browse users, and change a person: title and department, suspend,
groups, mail delegates, auto-reply, sign-out. Every change shows what it will run first and runs only
when you confirm it ([Live verification](#live-verification) lists what has run on a real tenant).
Groups, calendars, signatures, onboarding and offboarding are still GamGUI's. The plan is in
[docs/plans/2026-10-08-native-gamgui.md](docs/plans/2026-10-08-native-gamgui.md).

Not affiliated with Google or the GAM team.

## Screenshots

Rendered by CI from a demo tenant and the test mock of GAM (`scripts/screenshots.sh`), so the names are
placeholders. Each screen's pull request refreshes its own.

| Home | Users | Setup |
|---|---|---|
| ![Home: the connected domain, GAM's version and the directory's counts](docs/screenshots/home.png) | ![Users: the directory as a table](docs/screenshots/users.png) | ![Setup: the domains on this Mac and a failed check of delegation](docs/screenshots/setup.png) |

A person's page, opened from Users: an Actions menu for what changes the account, and tabs.

| Profile | Groups | Mail |
|---|---|---|
| ![A person's profile: title, department and details](docs/screenshots/person-profile.png) | ![A person's groups, each with Remove, and a field to add one](docs/screenshots/person-groups.png) | ![A person's auto-reply, with Change and Turn Off, and their mail delegates](docs/screenshots/person-mail.png) |

## Siri

Say **"Change a title in GamGUI"**. Siri asks whose title and the new one (a department too, if you
like), and GamGUI opens on Users with that person selected and the change drafted. Nothing changes
until you check it and click **Save**: Siri only drafts. The same action is in Shortcuts as **Change
a Title**. If more than one person matches the name, the list shows them and nothing is drafted.

**Confirmed through Shortcuts (2026-10-10):** the action drafted a title and department change on a
real tenant, the operator saved it with a click, and the audit recorded `origin: siri`. Not yet tried
with a voice: Siri hearing "GamGUI" is the plan's open Siri spike.

## Build from source

You need macOS 27 and Xcode 27.

1. Open Xcode once, or run `sudo xcodebuild -runFirstLaunch`, so its components are installed.
2. Download the pinned GAM: `scripts/fetch_gam.sh`.
3. In Xcode → Settings → Accounts, add your Apple ID (a free Personal Team is enough). Then create
   `Config/Local.xcconfig` (it's gitignored) with your team ID:
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   CODE_SIGN_IDENTITY = Apple Development
   CODE_SIGN_ENTITLEMENTS = Config/GamGUI-Team.entitlements
   ```
   Without this file the app still builds, but it can't save credentials to the Keychain.
4. Open `SwiftGamGui.xcodeproj` and build the **GamGUI** scheme in Xcode once (⌘B). Xcode sets up
   signing with your account on that first build. After that you can also build from the command
   line: `xcodebuild -project SwiftGamGui.xcodeproj -scheme GamGUI build`.

A free Personal Team's signing expires after 7 days, so rebuild in Xcode at least once a week. Your
stored credentials survive a rebuild. If you switch to a different team, import them again.

There are no downloadable builds yet: macOS blocks a downloaded app unless it's signed with a paid
Developer ID and notarized by Apple.

## Tests

`swift test --package-path Packages/GamKit`. CI runs the same tests, then builds the app and checks
how it's signed.

The fixtures the tests compare against are generated from GamGUI. To regenerate them you need a GamGUI
checkout next to this one: `../gamgui/.venv/bin/python -I -B scripts/gen_fixtures.py`.

## Live verification

Each write will be listed here. **argv-identical** means it sends exactly the command a GamGUI write
already proven live sent; **confirmed** means this app has itself run it against a real tenant.

| Write | Status |
|---|---|
| Title and department (Users) | **confirmed** (2026-10-09) |
| Suspend and unsuspend (Users) | **confirmed** (2026-10-09) |
| Remove from a group (Users) | **confirmed** (2026-10-09) |
| Add to a group (Users) | argv-identical |
| Add a mail delegate (Users) | **confirmed** (2026-10-09) |
| Remove a mail delegate (Users) | **confirmed** (2026-10-10) |
| Turn on or change an auto-reply (Users) | **confirmed** (2026-10-09) |
| Turn off an auto-reply (Users) | **confirmed** (2026-10-10) |
| Sign out of all sessions (Users) | **confirmed** (2026-10-09) |

## License

MIT. GAM is Apache-2.0 (`Vendor/gam7/LICENSE`).
