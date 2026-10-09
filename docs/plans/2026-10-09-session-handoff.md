# Session handoff (2026-10-09)

For the next session working on SwiftGamGui. Read this first, then `CLAUDE.md`, the runbook for the
area you touch (`docs/domains/`) and `docs/RULE-FEEDBACK.md`. The design is
`docs/plans/2026-10-08-native-gamgui.md`; this note supersedes its progress sections where they differ.

## Before anything else

- **Run from the SwiftGamGui main checkout's settings.** The local enforcement is gitignored and lives
  only in the main checkout's `.claude/`: `settings.json` (a Read deny-list for credential files and
  `~/.gam`), `hooks/` (credential guard, the `fix:` gate, the session-start digest) and
  `private-terms`. A worktree made with `git worktree add` doesn't have them. If your working directory
  lacks `.claude/settings.json` or `.claude/hooks`, copy those three from the main checkout's `.claude/`
  (they stay gitignored), tell the operator the hooks load from the next session start, and follow
  them by hand until then. Then run the `start-session` skill.
- **Standing instruction (operator, 2026-10-08):** keep going unattended. Committing, opening PRs,
  reviewing and merging on green CI are fine. Stop for anything that needs Touch ID, an Allow prompt
  or a live tenant read, and for any design change to the write path. If unsure it still holds, ask
  before committing.
- **GitHub as `goetchstone`.** The `gh` CLI's active account is another one that must never appear in
  this repo. An `export` doesn't survive between tool calls, so set the token in the same command as
  every push, PR or merge:
  `export GH_TOKEN="$(gh auth token --user goetchstone)"; [ "$(gh api user --jq .login)" = goetchstone ] && git push ...`

## Where things stand

`main` has #1 to #10. #11 is open with green CI and holds this note: merge it first.

| PR | What |
|---|---|
| #1 | Vault: Keychain with user presence, per-call config directories, authenticated runs |
| #2 | Setup core: credential import, copying GamGUI's Keychain items, Check access; `posix_spawn` |
| #3 | Setup screen; GAM embedded and signed (`embed_gam.sh`, `check_app.sh`) |
| #4 | 58 of GamGUI's 59 argv builders, byte-identical (`todrive_args` left out: Sheet export dropped) |
| #6 | GAM error classification (#5 was closed when its base branch was deleted; #6 replaced it) |
| #7 | Reading GAM's output (JSON, NDJSON, `formatjson` CSV, plain CSV); users, groups, members |
| #8 | Home (connection, GAM version, counts, GamGUI's nine reports); read-only Users list |
| #9 | ChangeCore's guard: GamGUI's `evaluate`, `enforce`, `alias_deletes` |
| #10 | ChangeCore's audit log, writing GamGUI's line format byte for byte |
| #11 | README trim, badges, OpenSSF Scorecard workflow, this note (open) |

- **Reviews:** #1 to #8 each merged after an adversarial review whose real findings were fixed with
  tests. #9 and #10 have had no review: they wait for the single ChangeCore review the plan budgets,
  which must cover them with slice 3.
- **What works:** the app sets up a domain, checks access, shows Home and browses users. Nothing has
  run against a real tenant, and nothing writes. The guard and the audit log exist; nothing calls them.

## How the work has been done (keep doing it)

- **Parity is a test (invariant 11).** Every port since #4 is held to a fixture that
  `scripts/gen_fixtures.py` generates from frozen GamGUI. The setup-era ports
  (`CredentialFacts.adminEmail`, AccessCheck's `verify`) are held only to hand-written cases.
  - Run the generator with GamGUI's virtualenv. From the main checkout:
    `../gamgui/.venv/bin/python -I -B scripts/gen_fixtures.py`. From a worktree
    (`.claude/worktrees/<name>`):
    `../../../../gamgui/.venv/bin/python -I -B scripts/gen_fixtures.py --gamgui ../../../../gamgui`.
    The same applies to `bump_gam.py` and `build_command_catalog.py`.
  - Never edit a fixture to pass. After a change, regenerate it and check it moved only where you meant
    it to. GamGUI is read-only.
- **Prove the tests bite.** Break the code on purpose, one rule at a time, and check that a test fails.
  Several real gaps were found this way.
- **Scale review to the stakes** (`pre-commit` skill, step 11):
  - ChangeCore slice 3: `/code-review high`, `/security-review`, plus an adversarial agent; then one
    adversarial review of ChangeCore as a whole (phase 2's "done when").
  - A builder reshape also gets the `gam-command-reviewer` agent.
  - Ordinary screens get `/code-review medium`.
  - Fix each real finding with a test that fails without the fix. Merge after green CI with
    `gh pr merge N --merge --delete-branch`.
- **Write down what a slice taught**, in the same PR:
  - a `docs/RULE-FEEDBACK.md` entry when an invariant should have stopped a finding;
  - the runbook's "Fixed in PR #N's review" list;
  - the design doc's Status line.

  A `fix:` commit needs a `docs/failure-log/` entry first (the `post-failure` skill). The hook checks
  the main checkout's folder, not a worktree's.
- **Parallel branches go in worktrees** under `.claude/worktrees/<name>` (gitignored), so a reviewer's
  checkout never changes under it. Copy `Vendor/gam7` into a new worktree, or run
  `scripts/fetch_gam.sh` there.
- **Don't stack a PR on a branch that `--delete-branch` removes:** GitHub closes the stacked PR. Retarget
  it to `main` first (`gh pr edit N --base main`), or wait and branch from `main`.

## Traps already hit

- **Escapes:** the file editing tools decode `\u` escapes into the characters themselves. Write such
  text through a script, or build the characters with `chr()`. `scripts/check_text.py` (CI's hygiene
  job and the local pre-commit hook) refuses invisible and bidirectional characters.
- **Private terms:** the private-terms hook refuses home-directory paths and the operator's company
  terms. Keep docs free of absolute paths.
- **Splitting lines:** `String.split(separator: "\n")` treats "\r\n" as one `Character`; split on
  `unicodeScalars`.
- **Comparing strings:** Swift's `String ==` is canonical equivalence. Compare bytes (`utf8`) wherever
  parity matters.
- **Unicode versions:** Swift has Unicode 17 and GamGUI's Python has 16. Every Unicode-derived table must
  go through `PythonText` and its version gate. The setup-era code doesn't yet:
  `CredentialFacts.adminEmail`, SetupModel's typed admin and `Credential`'s name parsing use Swift's own
  tables.
- **Hypothesis draws** in `gen_fixtures.py` use `@seed` with local constants turned off. With
  `derandomize` alone, the fixture moved whenever the generator was edited.
- **GAM's banner:** real GAM prints a first-run banner on stdout on every call, since each call gets a
  fresh config directory. `AuthenticatedRunner` strips it, as GamGUI's runner does, and the mock
  prints it. When porting a path, check what the real binary prints locally against the mock.
- **Debug switches** are environment variables, never launch arguments: `SWIFTGAMGUI_DEMO`,
  `SWIFTGAMGUI_SNAPSHOT`, `SWIFTGAMGUI_SCREEN`, `SWIFTGAMGUI_SPIKE`, `SWIFTGAMGUI_GAM_BINARY`. The
  snapshot leaves the sidebar and toolbar blank: that's the capture, not the app.
- **Shell safety:** an `rm` on a variable path must use `"${VAR:?}"`, or the safety check refuses it.

## Waiting on the operator

1. **The first live round — DONE 2026-10-09.** The operator's build copied GamGUI's credentials,
   Touch ID worked, it connected to the domain and the directory listed. Not separately confirmed:
   the token write-back's Keychain compare-and-swap (it only runs when GAM refreshes the token).
   The original plan for the round, following `.claude/skills/live-verify` (and GamGUI's, which it defers to).
   - The operator launches the app (a team-signed build: `Config/Local.xcconfig` with their team,
     built once in Xcode) and answers every Touch ID and Allow prompt. You never start it against the
     real tenant.
   - The round: import, or copy from GamGUI; Check access; a directory load.
   - It is the first real test of the banner strip, and of the Keychain side of the token write-back's
     compare-and-swap.
   - CI can't run the Keychain part. A debug build run with `SWIFTGAMGUI_SPIKE=vault`,
     `SWIFTGAMGUI_GAM_BINARY=<repo>/Tests/Fixtures/mock_gam.sh` and `GAM_MOCK_REFRESH=1` exercises its
     unchanged-token path.
2. **The model spike:** `SWIFTGAMGUI_SPIKE=model`.
3. **The Siri spike:** Siri recognising "GamGUI" (§12, §13 risk 3) has never been run, and there is no
   App Intents code yet. The operator has to speak, and it comes before phase 2's
   signature-template intent.
4. **DECIDED 2026-10-09: option A** (`docs/plans/2026-10-09-write-path-options.md`). **A design call before any write path:** ChangeCore's held preview, executor and write ticket (§6).
   - Today `AuthenticatedRunner.run` is public, and beneath it so are `GamRunner.run`,
     `Vault.credentials(for:)` and `EphemeralConfig.materialize`. So the app target could start a
     credentialed `gam` call by more than one route.
   - The options must close every route, and allow §8's voice-confirm ticket that only allowlisted
     "Just do it" classes accept.
   - One option is typed commands: a read command any caller can run, and a write command only the
     executor can run. It changes all 58 builders, the golden test's adapter, and their callers
     (AccessCheck, DirectoryStore, `Guard.deletedAccount`).
   - Lay out the options in a short doc and get a decision before building.
5. **Open questions** in the design doc's §14: phase 0 (signJwt), the first destructive run, Private
   Cloud Compute, the cut-over policy.

## Unattended until the operator answers

1. Merge #11 (this note) on green CI.
2. Write item 4's options as a short doc for the operator.
3. Fold the process lessons that live only in `RULE-FEEDBACK.md` into the skills (not `CLAUDE.md`):
   - regenerate a fixture after an unrelated edit;
   - retarget a stacked PR;
   - a parallel branch goes in a worktree;
   - start a port from the area's failure-log entries;
   - check real GAM output against the mock.
4. When the improve-rules nudge fires (`RULE-FEEDBACK.md` has many unprocessed entries), mention it to
   the operator rather than running it.
5. End with the `end-of-session` skill.

## Next, once the design call is made

- **ChangeCore slice 3**, built to §6 and §10's test list in full:
  - **The held preview:** the exact argv, a SHA-256 digest, the tenant and generation, its origin, a
    `ContinuousClock` creation time. It is single use, expires after 15 minutes (time asleep counts),
    and is refused after a tenant switch.
  - **The executor:**
    - it calls `Guard.refusal` before any write;
    - it allows no second run in flight for the same target;
    - it re-reads the preview's preconditions, and shows a new preview when they changed;
    - it writes begin and end records with `AuditLog`, with the native fields in `extra`.
  - **"Outcome unknown"** on the next launch for a begin record with no end.
  - **Secrets** typed so they can't be logged.
  - **Multi-step plans** declare `requires`.
  - **A source-scan test** that nothing else starts a write (the port of GamGUI's
    `test_write_routes_guarded.py`).
  - Start from the GamGUI failure-log entries that `guard-audit.md` and §6 cite, each a failing Swift
    test before the code.
- **Then phase 2's screens:** Users writes, Groups, Calendars, Signatures, and the signature-template
  Siri intent.

## GAM bumps

Run `scripts/bump_gam.py vX.Y.Z` with GamGUI's virtualenv, never `--allow-unattested`. Then
`swift test`, read `Vendor/gam7/GamUpdate.txt`, and run a live acceptance pass with the operator
(`live-verify`). GamGUI bumps separately with its own script.

## Housekeeping

- After #11 merges, from the main checkout:
  - check that `git -C .claude/worktrees/home status` is clean;
  - `git worktree remove .claude/worktrees/home` (never `--force`);
  - `git branch -d phase1/home`.
- **Commands:**
  - tests: `swift test --package-path Packages/GamKit`;
  - the app: open `SwiftGamGui.xcodeproj`, scheme **GamGUI**;
  - the release check: `scripts/check_app.sh path/to/GamGUI.app`.
