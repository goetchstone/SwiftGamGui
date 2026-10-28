# GAM GUI

[![CI](https://github.com/goetchstone/SwiftGamGui/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/goetchstone/SwiftGamGui/actions/workflows/ci.yml)
[![CodeQL](https://github.com/goetchstone/SwiftGamGui/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/goetchstone/SwiftGamGui/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/goetchstone/SwiftGamGui/badge)](https://scorecard.dev/viewer/?uri=github.com/goetchstone/SwiftGamGui)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**A native Mac app for Google Workspace admins**, built on [GAM7](https://github.com/GAM-team/GAM). Run the directory day
to day, and when an account is taken over, work the incident from the first suspicious sign-in to the report you hand
anyone. Every change shows its exact `gam` command first, runs only when you confirm it, and is logged.

![Incident, Respond: where each account stands, what's left to do, and a button for each fix](docs/screenshots/compromised-todo.png)

## Incident response

Built after a real account takeover, around the six steps of incident response (preparation, identification,
containment, eradication, recovery, lessons learned).

- **Investigate.** Pull the activity logs a takeover needs, narrow first: the people reported, then the attacker's
  addresses across every account. Rules in code read them: who the attacker got into and how, what they changed, the
  computers that joined, what they sent, and the email that let them in.
- **Respond.** Where each account stands, from the logs' own timeline: locked, half-locked, or signed in to again after
  the lock. Still to do, with a button for each fix. Each step leaves the list once the logs show it done, or once you
  mark it done by hand when no log can show it. Who the attacker's emails reached, each person once, with whether a
  warning reached them, to copy or export for the warning email.
- **Report.** Every number opens the list behind it. What was done, each step beside the record that shows it. The
  post-incident review and its plan going forward. Export a PDF, Markdown, text and CSVs, with every saved log copied and
  fingerprinted. Apple's on-device model can draft the summary from the facts; you check it.

## Everyday admin

- **People**: browse the directory; change a title, department, groups, mail delegates, auto-reply or signature;
  suspend, sign out, or set a temporary password.
- **Groups and calendars**: a group's members and roles; rooms, a person's calendars and who can see them.
- **Onboard and offboard**: a new hire from a role (account, signature, groups, calendars, checklist, welcome email);
  a leaver from a saved routine, every step's command shown before it runs.
- **Phishing**: find every copy of an email by its Message-ID, see who it went to, and trash them all from one preview.
- **Reports and audit**: the people behind the directory's counts, storage and mail usage, every connected app and AI
  agent, and this app's own audit log.

| | |
|---|---|
| ![The incident report: its numbers, what was done, and the review](docs/screenshots/compromised-report.png) | ![Everyone the attacker's emails got to, once each, with Copy Addresses and Export for Import](docs/screenshots/compromised-reached.png) |
| ![Users: the directory as a table](docs/screenshots/users.png) | ![Offboard's plan: each step and its exact gam command](docs/screenshots/offboard-plan.png) |

Rendered by CI from a demo domain and a mock of GAM, so every name is made up. [Every screen](docs/screenshots.md).

## Why it's safe to point at your domain

- **You see the command first.** A change is a preview holding the exact `gam` arguments; confirming runs that, never
  a rebuild. Only commands that read can run without a preview.
- **Big changes wait for you to type.** A destructive step needs the person's address, or the number of steps, typed.
- **Every change is audited**, with its command and result, passwords redacted.
- **Credentials stay in your Keychain**, behind Touch ID or your password, written to disk only for one `gam` call and
  wiped after.
- **Nothing runs in the cloud.** It's GAM on your Mac. The on-device model only words what code found; it never
  changes anything.

## How it's built

- **Parity is a test.** Commands ported from [GamGUI](https://github.com/goetchstone/gamgui), the web app this began
  as, are held byte for byte to fixtures generated from it.
- **The mock fails the way GAM fails.** Tests run against a strict mock of GAM checked against GAM's own grammar. A
  write counts as proven only once it has run on a real domain ([live verification](docs/live-verification.md)).
- **There is one way to change anything.** Every write goes through one executor, and a test scans the source to
  keep it that way.
- **GAM is pinned and verified.** The build refuses a GAM release whose checksum isn't pinned, and a new pin needs
  GitHub's build attestation.
- **Mistakes are written down.** The rules are in [CLAUDE.md](CLAUDE.md); each regression gets a
  [failure log](docs/failure-log/) entry and, where a rule fell short, [feedback](docs/RULE-FEEDBACK.md).
- **Written with [Claude Code](https://claude.com/claude-code)**, designed, directed and checked by its author.

## Status

Early, and in use on a real domain; what has run live is in [docs/live-verification.md](docs/live-verification.md).
Still only in GamGUI: the Builder (any GAM command, sequences, and one-offs such as forwarding, aliases, a new group,
undeleting an account and a data transfer), the jobs tray, anything run for many people at once (onboarding from a
CSV, a department or a signature for many), deleting a leaver's account, and finding a calendar by name, sharing one
with a group, or deleting a calendar or an event. The plan is in
[docs/plans/2026-10-08-native-gamgui.md](docs/plans/2026-10-08-native-gamgui.md).

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
4. Open `SwiftGamGui.xcodeproj` and build the **GamGUI** scheme once (⌘B), so Xcode sets up signing. After that,
   `xcodebuild -project SwiftGamGui.xcodeproj -scheme GamGUI build` works too.

A free Personal Team's signing expires after 7 days, so rebuild at least once a week; your stored credentials survive
it. There are no downloadable builds yet: macOS blocks a downloaded app unless it's signed with a paid Developer ID and
notarized.

## Tests

`swift test --package-path Packages/GamKit`. CI runs the same tests, then builds the app and checks how it's signed.
The parity fixtures are generated from a GamGUI checkout beside this one:
`../gamgui/.venv/bin/python -I -B scripts/gen_fixtures.py` ([where the two read GAM's output differently](docs/domains/gam-runner.md#reading-output)).

## License

Apache License 2.0, the same as GAM ([LICENSE](LICENSE), [NOTICE](NOTICE)). Versions before the change were MIT.
Not affiliated with Google or the GAM team.
