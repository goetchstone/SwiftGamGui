# Rule feedback ledger

Low-friction notes on how [CLAUDE.md](../CLAUDE.md)'s invariants performed in practice. **Sessions
append here; they do not edit CLAUDE.md.** The `improve-rules` observer pass reads this pile later,
with distance, and proposes at most one focused constitutional edit as a PR. See
[FRAMEWORK.md](FRAMEWORK.md) §3.

When to add an entry: an invariant almost let something through, was in the wrong enforcement layer,
was worded loosely enough to permit a bad reading, or a failure hit a shape no invariant covers.

**Format**, newest first:

```
## <date> — <one-line title>
- **What happened:** <the incident / near-miss; link commit/PR/failure-log entry>
- **Invariant in force:** <#N and its name, or "none — new shape">
- **Why it didn't hold:** <wrong layer / weak wording / not covered / not a rules problem>
- **Would a rule have caught it?** <no / only if enforced differently / yes but unworded>
- **Enforcement home if changed:** <skill (soft) / hook (hard) / tripwire test (backstop)>
```

The most valuable answer is *"only if enforced differently"*: the invariant exists and lives in the
wrong layer, and moving it (skill → hook → tripwire) needs no text change.

## 2026-10-19 — A domain-wide read's parser failed open, and a mock helper's wording was older than GAM's
- **What happened:**
  - The Phishing screen's Find reads GAM's dry run of `trash messages` line by line. It counted only the lines
    it recognised, so an unknown per-user line (a token refused in GAM 7.48.30's `User x, User Trash Failed`
    form, or a reworded line after a bump) was set aside, and an empty list read as "No mailbox has a copy".
  - The mock's shared `not_a_user` prints the older `User:, X Failed` form. GAM 7.48.30 prints `User X Failed`,
    and the live onboarding capture (`onboarding.json`, 2026-09-30) agrees.
  - The adversarial review proved both before merge (docs/domains/phishing.md, "Review").
- **Invariant in force:** "the mock lies" (fail the way real GAM fails), and #9's spirit (a partial list never
  passes for the whole).
- **Why it didn't hold:**
  - The rule says to check the mock against the grammar, but wording comes from GAM's printers, not the grammar.
  - Two live captures of the same refusal disagree, and the helper kept the older one.
  - No rule says a parser of per-entity output must fail closed on a line it doesn't know.
- **Would a rule have caught it?** Only if enforced differently: a reader of an `all users` command must account
  for every user GAM listed ("Got N Users" and each `(i/n)`), and treat an unknown per-user line as unread, not
  absent. The mock's wording should be checked against the pinned source's printers, not only against an older
  capture.
- **Enforcement home if changed:** the `add-builder-command` skill (a step for domain-wide reads), and a tripwire
  that the shared helpers' wording matches the pinned version's printers.

## 2026-10-14 — Research fan-out inflated a plan past what was asked
- **What happened:** asked for four optional offboarding steps and "anything else useful", a 7-agent research
  workflow and a 12-agent review (about 3M tokens) produced a fifteen-step plan with a new per-item row model. The
  operator asked for KISS from micro to macro; the plan was cut to what was asked for or prevents a loss, and every
  step became one GAM command over a list (docs/plans/2026-10-13-offboarding-options.md).
- **Invariant in force:** the constitution's "KISS" and "Working here economically" sections.
- **Why it didn't hold:** a session-wide instruction to orchestrate by default outweighed them; breadth of research
  read as scope.
- **Would a rule have caught it?** Only if enforced differently: research answers "what could we do", and the plan
  keeps only what the operator asked for or what prevents a loss, the rest named "not planned unless asked".
- **Enforcement home if changed:** skill (start-session: scope check before a plan is written).

## 2026-10-13 — A live-proven routine went stale under a Google policy change
- **What happened:** GamGUI's delete was confirmed live on 2026-10-08, after its offboarding transferred Drive and
  Calendar. From 2026-10-05 Google deletes a Workspace user's secondary calendars with the account, and the
  Calendar transfer doesn't include them, so that routine now loses team calendars the leaver owned. Found by
  research for the offboarding options plan, not by any test (docs/plans/2026-10-13-offboarding-options.md).
  Separately, GAM's grammar file lists `calendars <id> transfer <user>` (1685) where its source needs
  `transfer ownership`: the grammar can lie as the mock can.
- **Invariant in force:** none: invariants 1 and 11 hold the argv, not what Google does with it; the "mock lies"
  rule names the grammar as the source of truth.
- **Why it didn't hold:** not covered. "Confirmed live" has a shelf life when the platform changes underneath.
- **Would a rule have caught it?** Only if enforced differently: a destructive flow's runbook re-checked against
  Google's release notes (Workspace Updates) before each live use, and the source, not the grammar, as the last word.
- **Enforcement home if changed:** skill (`live-verify`: re-read the platform's changes for the flow first).

## 2026-10-13 — Parity held the error reader to GamGUI's misreading of GAM, a second time
- **What happened:** `GamError`, held to `gam_errors.json`, read GAM's per-entity progress lines
  ("Getting Reports for all users") as unknown failures, as frozen GamGUI does, so a refused report
  showed that line instead of the refusal. Found by reading GAM's source while building the calendar
  reads (failure-log 2026-10-13, "GAM's progress read as an error").
- **Invariant in force:** #11 (GamGUI parity is a test), with the "mock lies" rule.
- **Why it didn't hold:** the same shape as 2026-10-10's CSV escapes (see that entry): the oracle reads
  GAM wrongly. Every progress line in the fixture was one of the two shapes GamGUI's tests use, and the
  mock printed the one per-entity line it had on stdout, in words GAM never writes. The fix reused that entry's path unchanged: an in-memory swap in the
  generator and a `gamgui` field per deviating case, held narrow by a test. The first workaround went into
  one feature's code (the Calendars branch's `GettingLines`), not the shared reader.
- **Would a rule have caught it?** only if enforced differently: the generator could build its inputs
  from GAM's own strings as well as GamGUI's (every `Msg` a progress or error printer writes, read from
  the vendored build). A second occurrence makes the 2026-10-10 proposal (a line in #11 that a deviation
  is a documented, tested list) stronger, not different.
- **Enforcement home if changed:** tripwire test (the deviation list held narrow, as both fixtures now
  do); for `improve-rules`, the #11 wording 2026-10-10 proposed.
- **A third time, the same day:** GAM's command echo (`Command: gam … >>>x<<< …`) read as an unknown failure
  that outranked "User: x, Does not exist" (failure-log 2026-10-13, "GAM's command echo read as the failure").
  Found by writing the mock's transfer failures from GAM's source, the proposal's own method. Same path:
  an in-memory swap, `gamgui` readings, the deviation test widened to name both kinds of line.

## 2026-10-12 — One argv element, read by GAM as a list: GamGUI's guard was its browser field (calendars F5, D5)
- **What happened:** porting the calendar share, the target went to GAM as one argv element, as #1
  asks, yet GAM reads `<CalendarACLScopeEntity>` with `getEntityList` (gam/__init__.py:7338-7342): it
  splits the element at commas and whitespace into several rules, reads a local file for `file` or
  `csvfile`, gives a bare name the domain, and takes `group:`, `user:`, `domain` and `default` as other
  scopes. GamGUI passed the typed text straight through (`calendars.py:365`, `users.py:584-588`); only
  its browser's `type="email"` field stopped the rest. The native port has no browser, so it checks one
  address itself (`CalendarSharing.shareTargetProblem`). The plan said `Address.looksLikeEmail` refuses
  `group:`; it allows a colon in the local part, so the check adds that.
- **Invariant in force:** #1 (argv-only, every operator value exactly one element) and #11.
- **Why it didn't hold:** #1 is about the shell and argv boundaries; it says nothing about GAM's own
  parsing of an element, which can turn one element into many targets or a file read. Parity copied
  GamGUI's server code, whose guard lived in HTML the port doesn't have.
- **Would a rule have caught it?** only if enforced differently: #1 could say "one element GAM reads as
  one value": a builder argument GAM parses as an entity list or a selector gets a native check, listed
  in its runbook, with a test of the list and keyword shapes (as `aShareTargetMustBeOneAddress`).
- **Enforcement home if changed:** the `add-builder-command` skill (read the grammar's entity type for
  each operator value), with the test as the backstop.

## 2026-10-12 — Three places the calendar port reads GAM better than GamGUI did (F7, D6, exit 60, the "Getting" line)
- **What happened:** reading the vendored build for the calendar plan found where GamGUI's behavior is
  wrong for the operator, and the port departs, each listed in `docs/domains/calendars.md` and tested:
  GamGUI labels a writer "Make changes & manage sharing" (Google's writer can't share; its own picker says
  "Make changes"), and `CalendarTests` lists that one label as different from the fixture; when the
  group check failed, GamGUI guessed "person" and took an empty group for a person (`calendars.py:79-85`),
  where the port says it couldn't check, and refuses an empty group as a group; a calendar with no rules
  exits 60, which GamGUI's runner raised as a failure, and the port reads as none. And GAM prints
  "Getting Calendar ACLs for …" on stderr before a per-entity print (`show_gettings`, on by default),
  which GamError (held to GamGUI's `_PROGRESS_LINE`, "Getting all " only) reads as an unknown failure
  that outranks the real one: a person with Calendar off read as "GAM reported an error". The calendar
  branch first dropped the line in its own reads (`GettingLines`); GamError learned it for every read on
  2026-10-13 (the entry above), and that filter was removed.
- **Invariant in force:** #11 (parity is a test), and the "mock lies" rule (the mock printed no such
  line, so no test could see it).
- **Why it didn't hold:** as on 2026-10-10 twice: where the reference reads GAM wrongly, parity copies
  the defect, and a mock written from the reference's view of GAM shares its blind spot.
- **Would a rule have caught it?** only if enforced differently: a mock handler is written from the
  build's code for the command (its stdout, stderr and exit code, the progress lines included), never
  from the reference's handling of it; and a departure from the reference is a listed, tested deviation.
- **Enforcement home if changed:** the `pre-commit` skill's "the mock lies" item (stderr too, read from
  the build), and a GamErrorTests case once GamError itself learns the line (a deviation from
  `gam_errors.json` to record, as `gam_output.json` records the CSV ones).

## 2026-10-12 — A task list's id is the one argv element a run takes from outside its preview
- **What happened:** onboarding (O1, design D3c) puts a hire's checklist on a Google Tasks list the same
  run creates. Each task's `gam user <a> create task <list id> …` needs the list's id, which exists only
  after `create tasklist … returnidonly` has run. So the preview can't hold the whole argv: it holds a
  placeholder (`‹task list id from step N›`), and the run puts in the id the list printed.
- **Invariant in force:** #2, "a confirm runs what its preview held, never a rebuild". This is a rebuild.
- **Why it didn't hold:** a gap in the wording, not a break. Invariant 2 assumes every argv is known when
  the operator previews; one GAM write's input is another write's output. GamGUI never met the rule: it
  ran the tasks outside its preview, unpreviewed and audited as one record (`create_onboarding_runbook`).
- **Why this is the narrowest correct design:**
  - one element only (index 4, the id), and only in a step made by `WriteStep.task(…onListFrom:)`;
  - from one place only: the last non-empty stdout line of that same run's list step, which the task must
    require and which must be an earlier `createTaskList` for the same assignee (checked at preview);
  - only an id GAM reads as exactly one list id (printable ASCII without shlex syntax, not `tltitle:`, not
    a selector word, at most 256 characters), else the task doesn't run ("No task list id came back.");
  - through the builder (`GamCommands.createTask`), compared with the held argv in every other element;
  - audited as run, under the held digest.

  The alternatives were each worse: two previews (a second confirm, and a list made before the tasks are
  even shown), `tltitle:` selectors (not GamGUI's argv, and titles aren't unique), a general
  output-to-argv binding (speculative; one use), or GamGUI's way (a second write path).
- **Would a rule have caught it?** yes but unworded: the invariant could name this exception, or say
  "every element a run sends is held, or derived by ChangeCore from the same run under a test".
- **Enforcement home if changed:** tripwire test (`ExecutorTests`: `aTaskTakesTheIdItsListPrinted`,
  `aListIdWithACommaSpaceOrTitleSelectorIsRefused`, `aTaskOnAnotherAssigneesListIsRefused`,
  `aListThatPrintedNoIdRunsNoTask`; `WriteRouteTests.onlyTheBuildersMintCommands` still holds).

## 2026-10-10 — The template store departs from GamGUI where GamGUI loses data (D2's quarantine)
- **What happened:** porting GamGUI's signature store (S1b), its `_load` showed the starters over a
  corrupt or unreadable file, and its next save replaced that file: the operator's templates were gone
  with no trace (`core/signatures.py:205-213`). The port moves such a file aside to
  `signatures.json.unreadable-<UTC time>` (never over another), says so on the Signatures screen (S1c),
  and refuses to open at all when the file can't be read, so nothing saves over it. Its writes are
  atomic and private from creation, and replacing or deleting a template is asked first. No incident
  had hit GamGUI here; the design pass found it by asking what a faithful port would destroy.
- **Invariant in force:** #11 (parity is a test) for the names, messages and order, which are
  GamGUI's byte for byte; nothing for the data-loss path, which parity would have copied.
- **Why it didn't hold:** not a failure, a pressure on #11: as with the 2026-10-09 wipe and today's
  CSV reader, the frozen reference is the oracle for what the operator sees, but for code that writes
  or destroys the operator's own data, matching it only proves we share its blind spot.
- **Would a rule have caught it?** only if enforced differently: a port of anything that writes the
  operator's data starts by listing how the reference can lose it (a failed write, a corrupt read, a
  concurrent save), and each native departure is named in the domain runbook and tested.
- **Enforcement home if changed:** skill (the `pre-commit` "read before you wrote" item, or a "port an
  area" checklist); `SignatureStoreTests`' mutants (`anUnreadableFileIsQuarantinedNeverOverwritten`) are
  the backstop for this store.

## 2026-10-10 — Parity held the reader to GamGUI's defect, and no test came from GAM
- **What happened:** GAM writes its CSV with a backslash escape. GamGUI's parser has none, and the Swift
  port, held byte for byte to it by `gam_output.json`, dropped rows whose JSON held a quote, as GamGUI
  does. Found by reading GAM's source, not by any test (failure-log 2026-10-10, "GAM's CSV escapes").
- **Invariant in force:** #11 (GamGUI parity is a test), with the "mock lies" rule.
- **Why it didn't hold:** #11 makes the frozen reference the oracle for outputs as well as argv. Where
  the reference reads GAM wrongly, parity faithfully copies the defect. Every input the parity fixture
  held came from GamGUI's own writer and mock, which share the blind spot. The second time a faithful
  port carried a GamGUI defect (2026-10-09, the wipe rules).
- **Would a rule have caught it?** only if enforced differently: for code that reads GAM's output, the
  oracle is GAM's own writer (its source at the pinned tag, CPython's csv module), and GamGUI parity is
  held where GamGUI reads correctly. This change added that path without editing #11: the fixture keeps
  frozen GamGUI's records beside each case where they differ, and a test holds that list narrow (each
  holds a backslash and reads as CSV). #11 says nothing about how a deliberate deviation is recorded.
- **Enforcement home if changed:** tripwire test (a deviation list held narrow, as `gam_output.json`'s
  is), plus a line in #11 that a deviation from the reference is a documented, tested list, never a
  hand-edited fixture.

## 2026-10-10 — Session builds became apps Siri could pick by name
- **What happened:** spoken, Siri couldn't find the app. Spotlight indexed four apps named GamGUI: the
  original, the operator's Xcode build, and two command-line builds this session made under `build/`
  (one an old Release without the intent). Siri resolves a spoken name over that index.
- **Invariant in force:** none — new shape (build products are part of what the operator's Mac sees).
- **Why it didn't hold:** not covered; a build folder looked private to the repo.
- **Would a rule have caught it?** yes but unworded: command-line builds go in a `.noindex` folder (now
  in CLAUDE.md's Commands) and are deleted when done.
- **Enforcement home if changed:** CLAUDE.md Commands (done); a hook could refuse `-derivedDataPath`
  outside `.noindex`.

## 2026-10-10 — An investigating agent relaunched a test app on the operator's screen, over and over
- **What happened:** while diagnosing the person-page crash (failure-log 2026-10-10, "person-page layout loop"), a workflow agent
  built a standalone copy of the layout and launched it dozens of times at different sizes. Each launch
  opened a visible window that crashed; the operator saw windows flash "hundreds of times" and had to
  ask what was doing it. The local hook that keeps the app itself from being launched didn't apply to
  a separate test binary.
- **Invariant in force:** none — new shape (the operator's machine as shared space, not a sandbox).
- **Why it didn't hold:** not covered. The rules guard credentials and the tenant; nothing says a
  session or its agents must not put windows, Dock icons or crash dialogs in front of the operator.
- **Would a rule have caught it?** yes but unworded: GUI experiments run on CI or invisibly
  (transparent, off-screen, accessory activation), and a subagent prompt that may launch GUI code says so.
- **Enforcement home if changed:** skill (the investigation prompt, `start-session`), or a hook that
  flags GUI launches from agents.

## 2026-10-08 — The mock never printed GAM's first-run banner, so every live read would have broken
- **What happened:** PR #8's review read GamGUI's runner and found `strip_cfgdir_noise`. Handed a fresh
  config directory on every call, real GAM prints `Created: <dir>/gamcache` and `Config File: <dir>/gam.cfg,
  Initialized` on stdout before its data. The Swift runner passed them on, so the first live directory
  load would have parsed the banner as its CSV header. Every test was green: the mock never printed it.
- **Invariant in force:** "the mock lies" (CLAUDE.md), and #11.
- **Why it didn't hold:** the port read GamGUI's parsers but not the runner step between GAM and them,
  and the mock, copied from GamGUI, didn't print what real GAM prints (GamGUI's own tests fed the
  banner straight to `strip_cfgdir_noise` instead).
- **Would a rule have caught it?** only if enforced differently: a port covers the whole path from the
  process to the parser, and what the real binary prints locally (credential-free, `gam version` or a
  call that fails on the missing key) is checked against the mock. The mock now prints the banner; a
  test proves the load depends on stripping it.
- **Enforcement home if changed:** tripwire (done: the mock), and a skill step for the next port.

## 2026-10-08 — Parity with Python held only for Python's Unicode version
- **What happened:** PR #5's review found that a character added in Unicode 17 (`U+10940`) let an
  echoed password past the Swift scrub where GamGUI's masks it. Swift 6.4 has Unicode 17, and GamGUI's
  Python 3.14 has 16. To Python the character is unassigned (not a letter, so a word boundary
  before "password"); to Swift it is a letter. The parity test of `\w` skipped exactly the code points
  Python has no data for.
- **Invariant in force:** #11 (GamGUI parity is a test), and #4 for the password.
- **Why it didn't hold:** the test excluded the gap it should have covered: "Python doesn't assign
  it" was read as "no opinion", when it is an answer (not a letter).
- **Would a rule have caught it?** only if enforced differently: a parity test over Unicode covers
  every code point, the ones only one side assigns included. `PythonText.unicodeVersion` now gates
  Swift's tables to Python's version.
- **Enforcement home if changed:** tripwire (done: the test checks every code point).
- **Recurred in PR #7:** `uppercased()` used Swift's Unicode 17 case mappings, so U+A7D3 got an
  uppercase Python 16 doesn't give it. The fix was per table, not per feature: every Unicode-derived
  table (`\w`, `\d`, case) goes through `PythonText` and its version gate, each tested over every code point.

## 2026-10-08 — Seeded test data still moved when the generator changed
- **What happened:** `gen_fixtures.py` drew GamGUI's Hypothesis strategies with `derandomize=True`. An
  unrelated edit to the generator changed 140 drawn cases, then, with `@seed`, adding string literals
  still changed some: Hypothesis also draws constants it finds in local source.
- **Invariant in force:** none: tooling.
- **Why it didn't hold:** "seeded" assumed the seed was the only input.
- **Would a rule have caught it?** yes but unworded: a generated fixture is proven stable by
  regenerating it after an unrelated edit, not only twice in a row. The generator now seeds explicitly
  and turns local constants off.
- **Enforcement home if changed:** skill (pre-commit: "regenerate after an unrelated edit").

## 2026-10-08 — Merging the base of a stacked PR closed the PR on top
- **What happened:** PR #5 was opened against `phase1/builders` (PR #4's branch). Merging #4 with
  `--delete-branch` deleted that base, and GitHub closed #5 instead of retargeting it; it was reopened
  as #6.
- **Invariant in force:** none: process.
- **Why it didn't hold:** not covered.
- **Would a rule have caught it?** yes but unworded: before merging a PR another PR stacks on,
  retarget the upper one to `main` (`gh pr edit N --base main`), or don't stack: wait, then branch
  from `main`.
- **Enforcement home if changed:** skill (pre-commit or a merge checklist).

## 2026-10-08 — An editing tool wrote invisible characters into a script
- **What happened:** while adding the validators' boundary cases to `scripts/gen_fixtures.py`, the
  file-editing tool decoded `\u00a0`, `\u200b`, `\u2028` and others in the new text into the
  characters themselves. The script still ran, so nothing failed. A non-ASCII scan before committing
  caught it. Writing this entry, the same tool did it again, and `check_text.py` caught it.
- **Invariant in force:** none: a new shape. The same characters are how Trojan Source hides code
  from a reviewer.
- **Why it didn't hold:** not covered. Nothing checked tracked text for invisible characters.
- **Would a rule have caught it?** only if enforced differently: `scripts/check_text.py` now refuses
  format, separator, non-ASCII space, control and default-ignorable characters in tracked text (the
  generated argv fixture exempt), run by CI's hygiene job and the local pre-commit hook. Write such characters as escapes, or derive them (`gen_fixtures.py`'s
  `PY_WHITESPACE`).
- **Enforcement home if changed:** tripwire (done, CI).

## 2026-10-08 — Release builds were debuggable, by an exception written for a step we don't take
- **What happened:** PR #3's review found every locally signed Release build carried
  `get-task-allow`, and `check_app.sh` allowed it: "Xcode adds it to development builds; export strips
  it". This app is built from source and never exported, so the credential-holding app shipped open to
  any same-user process that can read memory. A symlink in `Vendor/gam7` also let `embed_gam.sh`
  sign a file outside the app with GAM's entitlements, and `check_app.sh` passed unsigned and
  planted Mach-O files.
- **Invariant in force:** #4 (secrets live only in the Keychain and memory); the signing rules in
  the design doc's section 7.
- **Why it didn't hold:** the allowlist exception was justified by a distribution step (export) the
  project doesn't take, and the check verified the assembly the scripts meant to produce, not every
  file the bundle holds.
- **Would a rule have caught it?** only if enforced differently: a check's exception names the step
  that removes the risk, and that step must be one this project runs. `check_app.sh` now refuses any
  app entitlement and checks every Mach-O; Release turns injection off.
- **Enforcement home if changed:** tripwire (done, CI's `check_app.sh`).

## 2026-10-08 — A reviewer's checkout changed under it
- **What happened:** while the PR #3 review agent read the main checkout, this session
  checked out another branch there to start PR #4. The reviewer noticed and worked from a `git archive`
  instead; a less careful one would have reviewed the wrong code.
- **Invariant in force:** none: process.
- **Why it didn't hold:** not covered.
- **Would a rule have caught it?** yes but unworded: work on a second branch while anything reads
  the first happens in a `git worktree` (as the PR #3 fixes then did, under `.claude/worktrees/`).
- **Enforcement home if changed:** skill (start-session or pre-commit: "parallel branch, new worktree").

## 2026-10-08 — The golden-argv tripwire couldn't see the bytes it guards
- **What happened:** PR #2's review proved Foundation's `Process` sends arguments decomposed ("é" as
  "e" + U+0301): 171 elements of `argv.json` would reach GAM as different bytes than GamGUI sends. A
  NUL aborted the app.
- **Invariant in force:** #11 (GamGUI parity is a test) and #1.
- **Why it didn't hold:** the test compared `[String]`, and Swift `String ==` is canonical
  equivalence, so the tripwire was blind to exactly the difference it exists to catch.
- **Would a rule have caught it?** only if enforced differently: a test of bytes compares bytes
  (`Array($0.utf8)`). Fixed in the golden test and the runner's argv test; GamRunner now uses
  `posix_spawn`.
- **Enforcement home if changed:** tripwire (done). Also added to the pre-commit skill.

## 2026-10-08 — The port of the credential code missed lessons GamGUI had already paid for
- **What happened:** PR #1's adversarial review proved nine defects in the new Vault/EphemeralConfig
  code before merge. Two repeated GamGUI incidents the port should have carried:
  - quitting leaves `gam` running (GamGUI failure-log 2026-09-23)
  - "only absence is a no-op" applied to writes as well as deletes (2026-10-01)

  Others were new shapes no GamGUI rule covered: hard links, a folder swapped by path, ACLs,
  composed characters in a name check.
- **Invariant in force:** #4 (secrets), #2 in spirit (the GAM child is part of the write).
- **Why it didn't hold:** the GamGUI history lived in runbooks and the failure log, and the port read
  the code but not every incident behind it. Nothing tied a GamGUI incident to a Swift test.
- **Would a rule have caught it?** only if enforced differently: porting an area should start from
  that area's failure-log entries, turning each into a Swift test before writing code.
- **Enforcement home if changed:** skill (`add-builder-command`-style "port an area" checklist). The
  tests added in PR #1 are the backstop for these nine.

## 2026-10-08 — The first publish would have gone out under the wrong GitHub account
- **What happened:** before creating this repo, `gh auth status` showed the active account was not the
  repo owner. `gh repo create` would have made the repo there. Caught by reading the status by hand;
  pushed with the owner's token for that one command instead of switching the global account.
- **Invariant in force:** none here; GamGUI's failure-log 2026-09-23 ("two handoff plans published
  the operator's second GitHub account") taught the related rule, and it lived only in prose.
- **Why it didn't hold:** not covered — no hook looks at which account a `gh` write or `git push` uses.
- **Would a rule have caught it?** only if enforced differently: a PreToolUse check that refuses
  `gh repo create` / `git push` unless the account in use owns the target.
- **Enforcement home if changed:** hook (hard). CLAUDE.md's rules of engagement now say it in words.

## 2026-10-09 — Closing the write path left raw secret bytes public
- **What happened:** the typed-commands refactor (PR #13) made `Vault.credentials(for:)` `package` and
  called the secret route closed. Two reviews found the app could still read credential bytes through
  `KeychainStore.read`, GamGUI's `legacyRead` and `Secret.bytes`, and could pass the first source scan
  with `Process.init()`, `.init([...])` or a different variable name.
- **Invariant in force:** #4 (secrets never leave the Keychain path) and #2 (one write path).
- **Why it didn't hold:** the options doc listed routes by the functions that ran `gam`, not by every
  public symbol that yields secret bytes or starts a process. The scan matched spellings, not types.
- **Would a rule have caught it?** yes, as a test: the boundary is GamKit's public surface, so a test
  could list every public symbol of Vault and GamEngine that returns `Data` or `Secret` contents.
  Short of that: put each guarantee in the compiler first (`package`/internal, unique names) and keep
  a scan only for what the compiler can't see.
- **Enforcement home if changed:** test (an API-surface check) or the `pre-commit` skill's secrets item.

## 2026-10-09 — A faithful port carried GamGUI's own latent wipe bugs
- **What happened:** the guided-setup port (PR #16) copied GamGUI's `_wipe_file` rules exactly. The
  adversarial review proved two holes in those rules themselves: a hard-linked credential got the
  operator's own file zeroed, and a credential rewritten in place after the read was destroyed while
  the Vault kept an older copy. Both exist in frozen GamGUI today.
- **Invariant in force:** #4 (secrets) and #11 (parity), pulling in opposite directions here.
- **Why it didn't hold:** parity is held to GamGUI's *outputs*; for code that destroys data, matching
  the reference only proves we share its blind spots. The port read the failure log's incidents but
  not the cases no incident had hit yet.
- **Would a rule have caught it?** only if enforced differently: for credential and deletion code, the
  adversarial review is asked to attack the reference's rules too, not just our port's fidelity.
- **Enforcement home if changed:** skill (`pre-commit` step 11's review prompt for the secrets area).
  GamGUI is frozen except GAM updates, so its copy is reported to the operator rather than fixed here.

## 2026-10-09 — Invariant 10 was written down but enforced nowhere
- **What happened:** ChangeCore slice 3 recorded a preview's origin (form, Siri, model) only for the
  audit. The review ran a model-origin preview with an empty confirmation: one LOW write succeeded.
  `OperatorConfirmation` has a public init, so an intent could also confirm a destructive change.
- **Invariant in force:** #10 (a model or Siri only drafts a preview).
- **Why it didn't hold:** no intent exists yet, so nothing exercised the rule; it lived in the design
  doc and CLAUDE.md, and the executor's checks were written from §6's list, which doesn't repeat it.
- **Would a rule have caught it?** yes, as a test: each numbered invariant that names the executor
  should have a case in `ExecutorTests` before the executor merges. Now: a non-form origin forces the
  Confirm click, and `WriteRouteTests` keeps the confirmation out of intent and model code.
- **Enforcement home if changed:** the `pre-commit` skill's ChangeCore item ("one test per invariant
  the executor enforces").
