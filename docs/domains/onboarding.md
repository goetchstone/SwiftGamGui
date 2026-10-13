# Onboarding

**One line:** one new hire through one ChangeCore preview: create the account (with a one-time password
shown once on a sign-in card), the role's signature, groups and calendars, and a checklist of tasks in
someone's Google Tasks, in GamGUI's order and with its gates. Built: slice O1 (2026-10-12), from the
onboarding plan (D1–D8, §2), and O2 (2026-10-13), this app's own roles, created and edited on Onboard. Next:
W (the welcome email), and the live stages B and C (below). The CSV of hires (O3) and the Siri and model drafts (O5) wait until the operator asks. GamGUI's
runbook of the same name, and its failure log, are the history this inherits.

**Owns invariants:** #2 (one preview, one confirm, the run is the preview; the one derived argv element is
below), #4 (the temporary password: one argv element, masked everywhere, never persisted), #9 (the
retry's rounds and lifetime, the retries kept), #11 (the plan's argv and order, the words, the role file's
migration, held to `Tests/Fixtures/onboarding.json`).

**Enforcement home:** `Packages/GamKit/Tests/GamEngineTests/OnboardingTests.swift` (the pure core against
the fixture) and `MockOnboardingTests.swift` (the mock fails as GAM fails);
`Packages/GamKit/Tests/ChangeCoreTests/ExecutorTests.swift` (the derived list id, the wait, the retry);
`Packages/GamKit/Tests/DirectoryStoreTests/OnboardChangesTests.swift` (the model against the strict mock,
including `thePlanIsGamGUIsOrderAndGates` against `provision_hire`'s own calls);
`Packages/GamKit/Tests/StoresTests/GamGUIRolesTests.swift` (the reader); `WriteRouteTests`
(`onlyTheCardShowsATemporaryPassword`, and the one confirm screen).

## Files
- `Packages/GamKit/Sources/GamEngine/Onboarding.swift`: the pure core. `splitName`, `checklistTitle`,
  `signatureHTML`, the waits and their reasons, `Waiting.label` and `waitingNote`, `roleFile` (GamGUI's
  load and migrations), `RoleTemplate`, `Hire`, `TemporaryPassword`, D7's `createRefusal`, and
  `GamError.saysNewAccountNotReady` (GamGUI's `not_ready_yet`).
- `Packages/GamKit/Sources/Stores/RoleStore.swift`: this app's roles and welcome emails (O2, below).
- `Packages/GamKit/Sources/Stores/GamGUIRoles.swift`: GamGUI's roles file, read by descriptor, never written:
  what the one-time copy reads.
- `Packages/GamKit/Sources/ChangeCore/ChangeCore.swift`: D3 a–g (below).
- `Packages/GamKit/Sources/Directory/OnboardChanges.swift`: the model.
- `App/OnboardView.swift` (the screen), `App/OnboardCredentialSheet.swift` (the card and its print
  view: the only reader of the password text), `OnboardPreviewSheet` in `App/ChangePreviewSheet.swift`,
  `App/OnboardRoles.swift` (the store for the screen), `App/OnboardRolesView.swift` (the role editor), the quit
  guard in `App/AppDelegate.swift`, Home's create line in `App/HomeView.swift`.
- `scripts/gen_fixtures.py`'s `onboarding_fixture` → `Tests/Fixtures/onboarding.json`;
  `Tests/Fixtures/demo/onboarding.json` holds the demo's roles, in GamGUI's format, saved into a temporary store at
  a demo launch.

## The roles (O2, 2026-10-13)
- **This app's own:** `onboarding.json` beside the signature templates, `{"version": 1, "roles": {…}, "welcomes":
  {…}}` with GamGUI's key names. GamGUI's file is read only by **Copy Roles from GamGUI** (in the editor, never in
  demo): names this store lacks are copied, one with other contents keeps this store's, one it wouldn't save is
  refused and said. One store for every domain, as in GamGUI.
- **GamGUI's rules** (`Onboarding.savable`, `welcomeName`; held to `onboarding.json`'s `store` cases, from
  GamGUI's own `RunbookStore`): its seed (Salesperson and the Default welcome), the name required and stripped,
  blank steps dropped, groups and calendars stripped, "Default" stored as blank, a welcome the store has (by
  exact text); a welcome name that differs only by case saves over the existing one, Default can't be deleted,
  nor one a role picks.
- **Native, each tested:** a group or calendar is one address, each once (GAM reads a comma or a space in one
  argument as more than one); a name of at most 60 characters; at most 100 steps, groups or calendars; replacing a
  role asked, and a rename saved in one write; the file read by descriptor, written atomically `0600` in a `0700`
  folder, and one it can't read (including a role it wouldn't save as it stands) moved aside, never replaced.
- **The editor** (`OnboardRolesSheet`, "Edit Roles…" on Onboard): the roles beside the one being edited; the
  checklist one step a line (no smart substitutions), the org unit, a saved signature (one that isn't saved any
  more is shown and said), the groups (suggested from the tenant's groups) and calendars, each with Remove; Save
  (⌘S), Revert, Delete (asked), New Role, Duplicate; leaving unsaved edits is asked. Deleting a signature template
  on Signatures names the roles that use it. The welcome email a role sends is kept as saved; its editor comes
  with W.

## How one hire runs (GamGUI's `provision_hire`, `routes/onboarding.py` single flow)
- **The plan** (`OnboardChanges.plan`), in GamGUI's order and gates:
  1. `create user` when ticked (`changepassword on`, the role's org unit; never `notify` in this flow);
  2. the role's signature, only for an account this run creates, rendered for the hire and **held in
     the argv at preview** (GamGUI read the template again at run time, D6); a missing or empty
     template, or a render GAM reads as a file keyword, is left out and said before the confirm;
  3. each group, as a member (only with an address);
  4. each calendar (only with an address);
  5. the checklist on the assignee (blank is the hire): `create tasklist … returnidonly`, then one
     `create task` per role step on that list.
  After a create every step requires it, so a failed create runs nothing else. Held to `provision_hire`'s
  own calls through a recording connector (`onboarding.json`'s `provision`).
- **Checked before the first write**, in GamGUI's words: the address, a role with steps, first and last
  names for a create, the assignee; plus GAM's 60-character name limit (GAM would refuse it as a usage
  error that echoes the password). The cached directory adds warnings: the address is already a user or
  an alias, isn't in the directory, or the assignee isn't.
- **One preview, `confirmStep`**, with the tenant the directory was read on. The sheet says "One new
  hire: N steps" (the guard counts steps as targets). Cancel, or a new preview, discards the held one at
  once (D3g), its password with it.
- **The run** shows each step as it ends (D3f). The card appears the moment the create ends.
- **The wait for Google** (D3a, b, d): on an account this run created, a signature, calendar, task list
  or task that Google refuses with `not_ready_yet`'s words waits; the model sleeps GamGUI's waits
  (20, 40, 60, 120, 180 s) and asks the executor to retry; Stop cancels the sleep at once and abandons
  the retry; what still waits after the last round is "not done" with GamGUI's `NOT_READY_REASON` and
  GAM's last error. Group adds never wait (live 2026-09-30).
- **After:** GamGUI's tallies; "Retry the N That Failed…" previews exactly those steps again (D8), from
  the plan held: the same signature, tasks on the list that exists (by the id it printed), or the list
  and every task again. Never the create: a new account needs a new password, from the form.

## ChangeCore for onboarding (D3)
- **a, b: `.waiting` and `newAccountFrom`.** A step may wait only if it's in
  `WriteAction.canWaitForNewAccount` and names an earlier `createUser` step it requires (else
  `.badPrerequisite`); it waits only if that create succeeded in this run and
  `GamError.saysNewAccountNotReady`. Its dependents wait unrun and unaudited.
- **c: the derived task-list id**, the one argv element a run takes from outside its preview. The held
  argv carries `‹task list id from step N›`; the run takes the list step's last non-empty stdout line,
  only when GAM would read it as exactly one list id (printable ASCII without shlex syntax, not
  `tltitle:`, not a selector word, at most 256 characters), rebuilds the task through
  `GamCommands.createTask`, and refuses it unless it equals the held argv in every other element and the
  list was made for the same assignee. Audited as run, under the held digest.
  `docs/RULE-FEEDBACK.md` (2026-10-12) says why this strains invariant 2 and is the narrowest design.
- **d: `retry`/`abandon`.** Single-use opaque handles; five rounds, fifteen minutes after the run on
  `ContinuousClock`; the tenant, the targets in flight and the held digest checked each round; the write
  lock for the round only; every attempt audited with `attempt: n`. At most 8 waiting runs kept.
- **e:** outcome unknown is keyed `preview/step/attempt`.
- **f:** `run(…progress:)` reports each result as it ends.
- **g:** `discard(_:)`.
- Also: `RunOutcome.Step.mayHaveChanged` (a timeout or an interruption) and `Executor.taskListID`, and a
  held `WriteStep` prints masked.

## The temporary password (D4)
- GamGUI's `generate_temp_password`: 3×4 from 56 symbols without `0 O 1 l I` (about 69.7 bits), drawn
  uniformly with the system CSPRNG; single use (`changepassword on`).
- Its text reaches one argv element (`TemporaryPassword.createUser`, through the builder) and the card
  (`shownOnTheSheet`, only in `App/OnboardCredentialSheet.swift`). The step masks it by value
  (`secrets:`) in the shown argv, the summary, GAM's output and errors and the audit; the positional
  masks are the second layer. GAM hashes it before calling Google. The leftover exposure is GamGUI's:
  the argv is visible to the same user's processes for the seconds `gam` runs, and on a managed Mac an
  endpoint-security agent may log every process's command line, this one included. A printed card leaves
  a spooled copy that CUPS may keep for a day, readable only by root and `_lp`. Neither is the app's to
  prevent; both are why the password is single-use (security review, 2026-10-13).
- **The card** shows the name, address, password, org unit and the signature's status, and how to sign
  in. Print (`NSPrintOperation`; Save as PDF is the operator's choice), Copy, Done. It isn't
  selectable, and VoiceOver spells it out.
- **Copy** puts the details on this Mac's clipboard only (`.currentHostOnly`: Universal Clipboard would
  offer them to the operator's other devices, where no clear reaches), as concealed text, with the app's
  own mark. It's cleared after two minutes if nothing was copied over it, and a marked copy is also
  cleared at quit and, after a crash or a force-quit, at the next launch (`SignInCopy`; security review,
  2026-10-13).
- It lives only in memory: in the pending preview, then the card; dropped at Done, after fifteen minutes,
  or at quit (quitting mid-run, mid-wait or with the card still up asks first: the card is the only place
  the password is shown). A new create is refused while an unhanded card is
  held, so a password is never stranded by the next hire. A create that didn't finish still shows the
  card, marked unsure. The executor holds the run's held preview (and so the password) while steps wait
  for Google, at most until the wait ends or fifteen minutes after the run.
- A crash mid-create: Home's "Outcome unknown" says the password was never shown.

## What GAM does (7.48.22, read from its source; plan §0 F1–F8)
- **F1** a duplicate create: `User: <e>, Create Failed: Duplicate, User: <e>` (or `User Alias: …, User: …`,
  or `Group: …`), exit 57. Said as "An account, alias or group already uses <e>." (D7).
- **F2** a missing org unit: `ERROR: User: <e>, Create Failed: Invalid Organizational Unit`, exit 50, the
  path made absolute first. Said as "The role's org unit “/X” doesn't exist in Google." (D7).
- **F3** GAM hashes the password before calling Google. **F4** a `notify` mail, and `sendemail`, go out
  from the admin's mailbox (O3 and W). **F5** the welcome email's line breaks collapse (W).
- **F6** `waitformailbox` polls the mailbox, not what the live failures were; not used.
- **F7** `create task`'s list is a `<TasklistEntity>`: commas split it, `tltitle:` picks by title, a
  selector word reads a file.
- **F8** the calendar refusal exits 73; a missing calendar `Add Failed`, exit 50.
- GAM refuses a first or last name over 60 characters while parsing, echoing the command line.

## Gotchas and mock-lies traps
- **The mock lied about the duplicate** (failure-log 2026-10-12): a 409 GAM never prints. Fixed with
  M1, M2, M4–M7 (`MockOnboardingTests`), each read from GAM's source. Still **assumed, not captured**:
  Google's own "Not Found" texts for a missing list and calendar, and the task list's "not ready" wording.
- **Assignees must be users**: a task list for a non-user fails on its token (mock and GAM). The demo's
  admin isn't a directory user, so its default assignee would fail a run; the demo never runs one.
- **`GAM_MOCK_STATE` decides list ids**: one per call with it, one per user without it.
- **GamGUI's checkout can move**: on 2026-10-12 an automated GAM bump moved `../gamgui` to `7d2b23c`
  (GAM 7.48.26) mid-session, and regenerating against it restamped every fixture. Regenerate from a clone
  pinned at the commit the fixtures name until SwiftGamGui's own pin moves.

## Departures from GamGUI, each deliberate
- The signature is rendered and held at preview, and a missing one is said before the confirm (D6).
- The tasks run inside the preview, each one audited, on the derived id (D3c); GamGUI ran them outside it.
- Everything that doesn't write is checked at preview, not at run; plus the 60-character name limit.
- An unreadable GamGUI roles file is reported, not replaced by GamGUI's starter role (D5); a list or
  object where text belongs is refused rather than read as Python's `repr`.
- The roles are this app's (O2), with the bounds above; GamGUI's are copied in only when asked.
- A new create is refused while the last card is unhanded; GamGUI replaced its result panel.

## Testing and live verification
- **Not yet run live.** Every O1 argv is GamGUI's and live-proven there (create account, signature, group
  add, calendar subscribe, task checklist), so each is argv-identical (README). The new-account wait has
  never run live, in either app.
- **Stage A, read-only:** copy the operator's GamGUI roles in (Edit Roles… → Copy Roles from GamGUI), check them,
  and preview the next hire
  without confirming: check the commands, that the role's groups exist, that the signature renders;
  Cancel discards it.
- **Stage B, license-free, the operator's own account** (each write needs the operator's yes): a role
  "Live check" with one step and nothing else; Create unticked; the hire and the assignee are the
  operator. One task list and one task: the derived-id path, proven live. Delete the list by hand after.
- **Stage C, the next real hire:** the first native create and the first live wait. Print the card before
  Done; note how many rounds Google needed, here; don't onboard the same hire in GamGUI at the same time.

## To do common tasks here
- **Add a step a hire gets:** a builder in `GamCommands` held to `argv.json`, a row kind and a step in
  `OnboardChanges.plan` in GamGUI's order, a case in `thePlanIsGamGUIsOrderAndGates`'s fixture
  (`onboarding_fixture`'s roles and hires), and the mock's strict handler.
- **Change a word:** GamGUI's words come from the fixture; change the Swift only with the fixture.
