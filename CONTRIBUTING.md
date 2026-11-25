# Contributing to GAM GUI

Thanks for helping out. GAM GUI is a native macOS app (SwiftUI, macOS 27) for managing Google Workspace with
[GAM7](https://github.com/GAM-team/GAM). Its sibling, [GamGUI](https://github.com/goetchstone/gamgui), is the same app
as a local web app in Python, and its [CONTRIBUTING](https://github.com/goetchstone/gamgui/blob/main/CONTRIBUTING.md)
keeps the same rules with its own homes.

**Read [CLAUDE.md](CLAUDE.md) first.** It is addressed to an AI coding agent, but it is the shortest route to the
invariants this codebase enforces: argv only, never a shell; one write path, through ChangeCore; only read-only
commands become runnable on their own; secrets in the Keychain; parity with GamGUI as a test; and why a mock more
permissive than real GAM is worse than no mock. Each one is there because something broke once. If a change of yours
contradicts one, that is the conversation to have in the PR.

What's next is in [docs/plans/2026-11-05-filling-the-gaps.md](docs/plans/2026-11-05-filling-the-gaps.md).

Taking part here is under the [code of conduct](CODE_OF_CONDUCT.md). Questions go to
[Discussions](https://github.com/goetchstone/SwiftGamGui/discussions) ([SUPPORT.md](SUPPORT.md) says what goes where),
and issues use the forms on **New issue**: a bug, a feature request, or *I tried it on a real domain* when you've run
something against a real domain (two minutes; Classroom reports are the most wanted). A pull request fills in the
template's checklist, and the `main` ruleset requires CI to pass before it merges.

## Rules, and what enforces each

Each rule below has a home that holds it: a test or CI job fails, the `main` ruleset refuses the merge, or review
catches it. A rule enforced only by review says so.

| Rule | Enforced by |
| --- | --- |
| Every change reaches `main` through a pull request; no force-push, no deleting `main` | rulesets `main: PR gate` and `main: history` |
| A PR merges only with CI green: `ci-ok`, CodeQL (and no high alert), Dependency review | the `main: PR gate` ruleset's required checks |
| A `fix:` adds an entry to [docs/failure-log/](docs/failure-log/) (symptom, cause, why not caught, fix, prevention) | review (the maintainer's local hook blocks it in a commit) |
| Every `gam` call is `executableURL` + `arguments`; an operator's value is exactly one element | `Golden argv`, `Native argv`, `Write routes` (only `GamRunner` starts a process, only the builders mint commands) |
| A builder GamGUI also has emits GamGUI's argv byte for byte | `Golden argv` against `Tests/Fixtures/argv.json`; `Fixtures and pin` |
| Every write goes builder → preview → guard → audited run, and a confirm runs what its preview held | `Write routes` (a source scan), `ExecutorTests`, `GuardTests` |
| Only a confidently read-only command becomes runnable on its own; a write is curated by hand | `Command catalog`, `Command kinds` |
| The mock `gam` fails the way GAM does; its words and exit codes come from GAM's source at the pin | `Native argv` against the vendored grammar, and review |
| Credentials live in the Keychain only; each `gam` call gets a `0700` copy that is wiped | `VaultTests`, `EphemeralConfig`, `Build exposure`; secret scanning with push protection |
| Credential files are read by descriptor, never by path | `Credential import`, `Setup folder` |
| GAM is pinned: a release whose checksum isn't pinned is refused, and a new pin needs GitHub's attestation | `scripts/fetch_gam.sh` in `build + test (macOS 27)`; `Fixtures and pin` |
| No credential or local-only file is tracked; no invisible or bidirectional characters in source | `hygiene` |
| The built app runs with the hardened runtime and only the listed entitlements, and its GAM is signed | `scripts/check_app.sh` in `build + test (macOS 27)` |
| Every wait in a test is bounded | `TestWaitsTests` |
| A model or Siri only drafts a preview; nothing it says changes the tenant | `Write routes`, and review |
| A read that failed or stopped short is never an answer ("none", "not found") | review, and a test on the failing exit for any read that drives a decision |
| A screen works with VoiceOver and the keyboard, never by colour alone, and with larger text | review, and the screenshots CI renders |
| A write isn't called working until it has run on a real domain | [docs/live-verification.md](docs/live-verification.md), and review |
| Nothing private in an issue or PR: no credentials, real domains or real people | the forms' required checkbox, secret scanning, review |

The invariants behind these, and the incidents that made them, are in [CLAUDE.md](CLAUDE.md). A rule that strains is
recorded in [docs/RULE-FEEDBACK.md](docs/RULE-FEEDBACK.md), and changed by a PR of its own.

**A good first contribution:** run something on a real domain and send the [I tried it
form](https://github.com/goetchstone/SwiftGamGui/issues/new?template=live_verification.yml) (it moves
[live verification](docs/live-verification.md)), an issue labelled
[good first issue](https://github.com/goetchstone/SwiftGamGui/labels/good%20first%20issue), or an accessibility fix.

## Quick start

You need macOS 27 and Xcode 27. The [README](README.md#build-from-source) has the signing setup for running the app
with your own Keychain.

```bash
git clone <your-fork-url> && cd SwiftGamGui
scripts/fetch_gam.sh                                                # vendor the pinned GAM (checksum-verified)
swift test --package-path Packages/GamKit                           # the package suite: offline, on the mock gam
xcodebuild -project SwiftGamGui.xcodeproj -scheme GamGUI \
  -derivedDataPath build/DerivedData.noindex build                  # the app
```

You do **not** need GAM credentials to run the tests: the suite drives a strict mock `gam`
(`Tests/Fixtures/mock_gam.sh`) and an in-memory Keychain, so it is fully offline. To look at a screen without a
tenant, a debug build renders one to a PNG from a demo domain and the mock (CLAUDE.md, **Commands**);
[docs/screenshots.md](docs/screenshots.md) shows every screen CI renders.

**Working with Claude Code (or another agent).** The repo carries what the maintainer's own agent sessions use:
[CLAUDE.md](CLAUDE.md) (the invariants, loaded every session), the area runbooks in
[docs/domains/](docs/domains/README.md), the skills in [.claude/skills/](.claude/skills) and two agents in
[.claude/agents/](.claude/agents) (`gam-command-author`, `gam-command-reviewer`). [docs/FRAMEWORK.md](docs/FRAMEWORK.md)
explains how they fit together. The maintainer's local hooks are not published; the rule that matters most for you is
never to run `gam` from a shell against a real config or read the Keychain from an agent.

## Project layout

```
App/                 SwiftUI app target "GamGUI": views over @Observable models
Packages/GamKit/     GamEngine · ChangeCore · Vault · Directory · Setup · Jobs · Stores · Assist · TestSupport
Tests/Fixtures/      argv.json · exit_codes.json (from GamGUI) · mock_gam.sh and its data
Vendor/gam7/         the vendored GAM (fetched, not committed, except VERSION, LICENSE and the command catalog)
scripts/             fetch_gam.sh · bump_gam.py · gen_fixtures.py · check_app.sh · screenshots.sh · check_text.py
docs/                plans/ · domains/ · failure-log/ · live-verification.md · RULE-FEEDBACK.md
```

## Coding standards

Write like the surrounding code: a reviewer shouldn't be able to tell which lines were generated.

- **KISS.** The smallest change that does the job. No speculative abstraction, no settings nobody asked for, no dead
  code.
- **Comments explain *why*, not *what*.** Names carry the meaning, so comments stay sparse.
- **Reuse before adding**: look for an existing builder, ChangeCore helper or store before writing one.
- **Errors surface, never crash**: a failed `gam` call becomes words on the screen, never a silent success or an empty
  list that reads as "none".
- **Tests never touch the operator's data**: stores take an explicit temporary location, and a wait in a test is
  bounded (`yieldWhile`).

## Adding a Builder command

Every write the Builder runs is curated by hand. The recipe is in
[.claude/skills/add-builder-command](.claude/skills/add-builder-command): check the syntax against the vendored
`Vendor/gam7/GamCommands.txt` and GAM's source; add the builder to `GamCommands` (each slot value exactly one argv
element); if GamGUI has the same builder, regenerate the fixtures and let `Golden argv` hold it; give the mock a
strict handler that fails the way GAM fails; route the write through ChangeCore.

## Before opening a PR

```bash
swift test --package-path Packages/GamKit
xcodebuild -project SwiftGamGui.xcodeproj -scheme GamGUI -derivedDataPath build/DerivedData.noindex build
```

CI runs `hygiene`, the package suite and a Release build on macOS 27 (checked by `scripts/check_app.sh`), renders the
screenshots from the demo domain, and fuzzes the output parsers; `ci-ok` passes only when every job did.
