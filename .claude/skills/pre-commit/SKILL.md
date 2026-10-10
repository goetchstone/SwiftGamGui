---
name: pre-commit
description: The checklist before a `git commit` in SwiftGamGui — catches the failure classes GamGUI kept hitting (the mock lying, a write slipping the chokepoint, a secret reaching a log, argv drifting from GamGUI's). The pre-commit hook injects the items relevant to your changed files.
---

# Pre-commit checklist

Act on the items your diff touches.

## Always
1. **Green**: `swift test --package-path Packages/GamKit`, and the app builds
   (`xcodebuild -project SwiftGamGui.xcodeproj -scheme GamGUI build`). Swift 6 strict concurrency
   warnings are errors in spirit: fix them, don't silence them.
2. **Read before you wrote.** Verify claims against the code and the SDK's `.swiftinterface`, not memory.
3. **Docs follow code in the same commit**: the area's runbook; a failure-log entry for a regression
   (the hook blocks a `fix:` commit without one); the design doc's Status for a closed plan item.

## If your diff touches GAM
4. **argv-only (#1)** and **byte-identical to GamGUI (#11)**: every builder is checked against
   `Tests/Fixtures/argv.json`; never regenerate the fixture to make a Swift builder pass. Compare
   bytes (`Array($0.utf8)`), never `String ==`, which treats "é" and "e" + U+0301 as equal.
5. **One write path (#2)**: a write runs only from a held preview through ChangeCore's executor.
6. **The mock lies**: `Tests/Fixtures/mock_gam.sh` must fail the way real GAM fails — check
   `Vendor/gam7/GamCommands.txt`. A green mock is not a live proof.
7. **The pin (#7)**: bump only with `scripts/bump_gam.py`; `FixtureTests` must stay green.

## If your diff touches secrets, models, Siri or anything streamed
8. **Secrets (#4, #5)**: Keychain only; materialized `0700`/`0600` for one call and wiped; credential
   files read by descriptor. No secret in a log line, an audit record, a test fixture or a screenshot.
9. **Drafts only (#10)**: a model or intent fills a preview; "Just do it" stays inside its allowlist.
10. **Bounded (#9)**: feeds and captures keep their caps.

## If your diff touches a screen (`App/`)
- **Accessible as built** (operator, 2026-10-09), not left to phase 6: VoiceOver reads every control
  and every status in words (an icon-only button gets an `accessibilityLabel`; a pass or fail is said,
  not only drawn red or green); text uses system styles, never fixed sizes; everything works from the
  keyboard (⌘R refreshes a screen that loads); a tooltip (`.help`) never holds the only explanation.
  Say in the PR what was checked.
- **Screenshots as we go**: CI renders each screen (`scripts/screenshots.sh`); a PR that changes one
  refreshes its image in `docs/screenshots` from that run's artifact.
- **Fits the smallest window**: a new column, panel or inspector, or a wider one, gets bounds in
  `ColumnWidths` and a `smallest` run in `scripts/screenshots.sh`. On macOS 27 an inspector that can't
  fit crashes the app on a Mac and only clips on CI (failure-log 2026-10-10, "person-page layout loop").

## Before the PR
11. `/code-review medium` on every diff; `high` plus `/security-review` when it touches Vault,
    GamEngine's runner, ChangeCore, credential import or anything parsing GAM or operator input; the
    `gam-command-reviewer` agent for builders, catalog or Builder changes. A finding an invariant should
    have stopped → one RULE-FEEDBACK entry.
