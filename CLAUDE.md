# Working on SwiftGamGui

**GamGUI as a native macOS app**: SwiftUI, macOS 27 only, driving the vendored GAM7 CLI exactly as the
Python GamGUI does. On screen and to Siri the app is **GAM GUI** (operator, 2026-10-10: Siri hears
"Gam Gooey" as "GAM GUI" and matches only the display name); its product, scheme and bundle stay
**GamGUI**, and this repo and the Xcode project are **SwiftGamGui**. Public repo, MIT. The design and phases are in
[docs/plans/2026-10-08-native-gamgui.md](docs/plans/2026-10-08-native-gamgui.md); read its Status line
first.

The credentials this app reaches are the reason it is careful: **`oauth2service.json` can impersonate
any user in the domain, and `oauth2.txt` is effectively an admin password.**

GamGUI (the Python app) is **frozen except GAM updates**. It is the parity reference: never edit it
from here; read it.

## Invariants — do not regress these

Numbered as in GamGUI so its failure log's citations still resolve. Each exists because something went
wrong there. A change that "simplifies" one is a bug.

1. **argv-only, never a shell.** `Process.executableURL` + `arguments`; every operator value is
   exactly one element. Builders emit the **byte-identical argv** GamGUI's live-proven builders emit,
   held to `Tests/Fixtures/argv.json` (#11).
2. **Every mutation goes through ChangeCore**: builder → Preview (holds the exact argv) → Guard (in the
   executor, the only path) → audited run. A confirm runs what its preview held, never a rebuild. The
   run function takes a ticket only ChangeCore can create (`package` access); a source-scan test
   holds that. There is no second write path.
3. **Only read-only commands become runnable automatically**: a catalog command is buildable iff it is
   confidently `READ_ONLY` and not `uncertain`. Write coverage is deliberate curation.
4. **Secrets live in the Keychain** (data-protection, this device only, user presence). Materialized
   only into a `0700` dir (`0600` files) for one `gam` call and wiped, with a launch-time sweep for a
   crash. Never persisted elsewhere; never logged.
5. **Credential files are read by descriptor**: the picked folder opened once, each file `openat` with
   `O_NOFOLLOW | O_NONBLOCK`, `fstat` regular file under a size cap, read from the same descriptor. No
   path string comparisons.
6. *(Retired by the platform: there is no loopback server, token or Origin check to defend.)*
7. **The vendored GAM pin fails closed.** `scripts/fetch_gam.sh` refuses an asset whose SHA-256 isn't
   in `scripts/gam_checksums.txt`; `bump_gam.py` writes a pin only after GitHub's build attestation
   verifies.
8. *(Retired by the platform: SwiftUI text is not HTML.)*
9. **Bound anything polled or streamed**: job feeds keep a fixed window and capped failure samples;
   `gam` output capture is capped per stream.
10. **A model or Siri only drafts a preview.** Nothing that changes the tenant runs from voice or a
    model, except the operator's optional **"Just do it"** allowlist (design doc §8): off by default,
    a fixed set of simple single-target actions, never deletes/offboarding/passwords/sign-outs/
    delegation/forwarding/transfers/sharing/bulk/sequences, spoken read-back, audited, with Undo.
11. **GamGUI parity is a test, not a promise.** `Tests/Fixtures/argv.json` and `exit_codes.json` are
    generated from frozen GamGUI by `scripts/gen_fixtures.py`; a Swift builder or exit-code mapping
    that differs fails the suite.

## The recurring failure mode: the mock lies

GamGUI's defining bug class is **"the mock passed, the live tenant broke."** `Tests/Fixtures/mock_gam.sh`
is GamGUI's strict mock, copied: when you touch it, make it **fail the way real GAM fails**, checked
against the vendored grammar `Vendor/gam7/GamCommands.txt`, not memory. A mock more permissive than
GAM converts a live break into a green test. **Passing tests do not mean a GAM write works.**

## Rules of engagement

- **Never run a mutation against a real tenant** without explicit, per-action permission from the
  operator in chat. Read-only checks are fine once the operator says go (`live-verify` skill).
- **Never touch credentials**: no `gam` from a shell against real config, no Keychain read of real
  items (`security find-*`), never print or paste a credential file. Spikes use throwaway items named
  `swiftgamgui-spike*` only.
- **macOS-only is deliberate.** Platform specifics live in the app and Vault, not in GamEngine.
- **Commits** happen when the operator asks; every change reaches `main` through a pull request whose
  `ci-ok` is green. **Publish as the repo owner**: this Mac's `gh` has more than one account, and the
  active one may not own this repo — check `gh auth status` before any push or `gh` write.
- **Tenant data never enters the repo**: placeholders stay generic (`example.com`, "Sales"); the local
  private-terms tripwire blocks the operator's terms.

## How we build: KISS, and learn every round

The simplest design that keeps the invariants wins; no speculative abstraction, no tooling before a
need. Each slice ends by writing down what it taught — a failure-log entry, a RULE-FEEDBACK note or a
runbook line — so the next round starts smarter. Security and code quality are part of done, not a
later pass.

## Working here economically

Subagent fan-out has cost millions of tokens in GamGUI sessions. Scale it to the stakes: adversarial
verification earns its cost on credentials, the chokepoint and path handling; ordinary feature work
needs one agent or none. Put a cheap deterministic check before an expensive one. Long procedures
live in `.claude/skills/`, not here. Summarize large tool output instead of re-reading it.

## Layout

```
App/                      SwiftUI app target "GamGUI" (thin: views over @Observable models; debug spikes)
Config/                   entitlements (empty: hardened runtime on, App Sandbox off until phase 6)
Packages/GamKit/          GamEngine · ChangeCore · Vault · Catalog · Jobs · Stores · Assist · TestSupport
Tests/Fixtures/           argv.json · exit_codes.json · mock_gam.sh + its data (shared by all tests)
Vendor/gam7/              vendored GAM (gitignored except VERSION, LICENSE, command_catalog.json)
scripts/                  fetch_gam.sh · embed_gam.sh · check_app.sh · bump_gam.py · build_command_catalog.py · gen_fixtures.py
Signing/                  gam.entitlements (upstream GAM's own set, for the embedded gam); reference/
docs/                     plans/ · failure-log/ · domains/ · FRAMEWORK.md · RULE-FEEDBACK.md
```

## Commands

```bash
swift test --package-path Packages/GamKit                       # package suite: mock gam, fixtures, spikes
xcodebuild -project SwiftGamGui.xcodeproj -scheme GamGUI build  # the app
scripts/fetch_gam.sh                                            # vendor GAM against the pin
../gamgui/.venv/bin/python -I -B scripts/gen_fixtures.py        # regenerate parity fixtures from GamGUI
../gamgui/.venv/bin/python -I -B scripts/bump_gam.py vX.Y.Z     # bump GAM (attested), then test
# Command-line builds go in build/DerivedData.noindex (-derivedDataPath): Spotlight skips a .noindex
# folder, and every indexed copy of the app is one more app Siri can pick by name (2026-10-10).
# Look at a screen (debug builds): renders the real window to a PNG and quits. The demo fills the screen
# from memory and the strict mock, never the real GAM. SWIFTGAMGUI_SCREEN picks it (home, the default,
# users or setup). The capture is the screen's own pane (the sidebar's and toolbar's system materials don't draw this way).
SWIFTGAMGUI_SCREEN=home SWIFTGAMGUI_SNAPSHOT=/tmp/home.png SWIFTGAMGUI_DEMO=1 \
  SWIFTGAMGUI_GAM_BINARY="$PWD/Tests/Fixtures/mock_gam.sh" \
  build/DerivedData.noindex/Build/Products/Debug/GamGUI.app/Contents/MacOS/GamGUI
```

Debug switches are **environment variables**, never launch arguments: AppKit reads `-key value`
arguments as defaults and opens a leftover bare path as a document, which once stopped SwiftUI from
opening any window.

GAM is pinned at `GamVersion.expected` (currently 7.48.22); `FixtureTests` fails if the fetch TAG, the
mock's version, the catalog stamp or the fixtures disagree.

## The layered system

As in GamGUI ([docs/FRAMEWORK.md](docs/FRAMEWORK.md)): this file is the **constitution**, loaded every
session; **domain runbooks** in [docs/domains/](docs/domains/README.md) are read before working in an
area; **skills** in `.claude/skills/` are procedures for a moment; **local hooks** (gitignored) inject
the orient digest, guard credentials and block a `fix:` commit without a failure-log entry. Sessions
don't edit the numbered invariants directly: log the incident in
[docs/failure-log/](docs/failure-log/README.md), note the strain in
[docs/RULE-FEEDBACK.md](docs/RULE-FEEDBACK.md), and let `improve-rules` propose one edit, with
distance. Invariant numbers are never reused.
