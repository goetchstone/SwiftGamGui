# The standard

**v0, 2026-11-20: this repo only, while it proves itself.** The page every repo of the operator's is meant to follow,
drafted from a survey of the coding rules seven repos hold in three languages and the failures that earned them. It
grows only when a failure-log entry shows a need, never from an idea. This repo's own rules stay in
[CLAUDE.md](../CLAUDE.md); [FRAMEWORK.md](FRAMEWORK.md) says how the layers fit.

**Rule 0: a rule counts only when something enforces it and that thing has been seen to fire.** Otherwise it is a
lesson, and says so. The survey's commonest finding, in every language: rules stated but not enforced (warn-only lint,
hooks that print where nobody reads, checks that run only on one machine), believed to protect for months.

## How we work

| Rule | Enforced here by | Seen to fire |
|---|---|---|
| **KISS, micro to macro.** Build what was asked or what prevents loss; a plan, a rule list and this page grow from a failure, not an idea. | `improve-rules`: one CLAUDE.md edit per PR, never on `main` | lesson: nothing blocks a speculative build |
| **Plan first, with a parking lot.** A written plan: goal, every assumption listed (checked or guessed), tasks in order, a "done when" each. A new ask mid-plan gets "add, park, or interrupt?", written into the plan before work starts. | the plan's Status line, updated in each task's PR | lesson until the session-start check names the active plan |
| **One task, one branch, one PR.** Off `main`, never stacked; merged only on a green `ci-ok`; the branch deleted after the merge is confirmed. | the `main: PR gate` ruleset: a pull request, `ci-ok` and CodeQL required | every PR since the ruleset |
| **Honest both ways.** Say what was checked (and how) apart from what was assumed, the cost before any fan-out, and what wasn't verified. The operator's facts about their own systems are ground truth. | lesson | the operator, reading |
| **Prove the rules load.** A hook prints to stdout or `additionalContext` (stderr reaches nobody at exit 0), runs from where the work happens (a worktree too), and is called installed only once its output is seen there. | `session-start-check.sh`: the orient digest every session, with a line saying whether any hook command is relative | yes, probed from the main checkout and a worktree (failure log 2026-11-20: they hadn't fired in worktrees); no hook tests yet |

## Code, in every language

Each was earned by a failure in more than one repo; this column is where this repo enforces it.

| Rule | Here |
|---|---|
| An external program runs from an argv list, never a shell; each value is one element. | invariant 1: `GamRunner` (`posix_spawn`), `GoldenArgvTests`, the fuzz job |
| Every change goes through one guarded path, and a test enumerates the paths. | invariant 2: the `package` `WriteTicket`, `WriteRouteTests` |
| A failed, partial or unread read is "unknown", never "none", and the screen says so. | lesson here (failure log 2026-11-06); held per read, by that read's tests |
| A fake fails the way the real service fails, read from its source or reference, not memory. | `mock_gam.sh` and its `Mock*Tests`; a write is proven only live (`live-verify`) |
| A secret is never in code, a log, an echo or a fixture; it lives where the platform protects it. | invariants 4 and 5: `VaultTests`, `BuildExposureTests`; the local credential guard |
| Everything polled, streamed or kept is bounded. | invariant 9: `JobsTests` (the window, the failure cap), capped captures |
| What is fetched is pinned by hash and fails closed (binaries, Actions, dependencies). | invariant 7: `fetch_gam.sh` + `gam_checksums.txt`, `FixtureTests`; every Action pinned to a SHA |
| A gate blocks or it doesn't count: no warn-only lint, no check that runs on one machine only. | CI's `ci-ok`; not yet: warnings as errors (RULE-FEEDBACK) |

## Swift

| Rule | Here |
|---|---|
| Swift 6 language mode with complete concurrency checking; a warning is fixed, never silenced. | tools 6.2, `SWIFT_STRICT_CONCURRENCY=complete`; lesson until warnings are errors |
| No invisible or bidirectional characters in source. | `scripts/check_text.py` in CI |
| Compare bytes (`Array($0.utf8)`) where Unicode equivalence would hide a difference. | lesson (pre-commit item 4) |
| A time bound in a test measures thread CPU time, never a process's wall clock. | lesson (failure log 2026-10-16, 10-20, 11-03, 11-13) |
| Debug switches are environment variables, never launch arguments. | lesson (CLAUDE.md, Commands) |
