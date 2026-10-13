# Offboarding

**One line:** the ordered "a user is leaving" routine GamGUI runs, reset password, revoke access, turn
off forwarding, delegate and auto-reply the mailbox, transfer Drive and Calendar, sweep the leaver off
every active user's primary calendar, and a dated reminder on the manager's calendar, plus the separate,
later account delete. Built (2026-10-13): **Off1**, the plan (exactly what GamGUI's offboarding runs for a
leaver and a manager, every step's `gam` line); **templates** (native) that fill its form with the
operator's routine; and **Off2**, the run, through ChangeCore, adversarially reviewed and fixed. **Added steps**
(native, 2026-10-13, docs/plans/2026-10-13-offboarding-options.md slices 0-1): clear recovery info and hide from
the directory, the owned secondary calendars and Vault holds read and warned, and the typed `confirm` a long
routine needs. Next: the live checks L1 and L2, the plan's next slices, then **Close Out** with **Off3**, the delete
(below). GamGUI's runbook
of the same name (`docs/domains/lifecycle-offboarding.md` in GamGUI, 42 KB) is the history this inherits:
its step table, its "when a step fails" rules, its 2026-09-23 incidents and its first live run
(2026-10-07, all eight steps ok) all carry over.

**Owns invariants:** #1 (each step's argv is GamGUI's, `drive,calendar` one element), #2 (Off1 can't
write at all), #9 (the sweep is the only domain-wide call and alone gets the long timeout), #11 (the
routine, the checks and the words are held to GamGUI by a fixture).

**Enforcement home:** `Packages/GamKit/Tests/GamEngineTests/OffboardingTests.swift` (the pure core, held to
`Tests/Fixtures/offboarding.json`, `scripts/gen_fixtures.py`'s `offboarding_fixture`),
`Packages/GamKit/Tests/DirectoryStoreTests/OffboardChangesTests.swift` (the reads, the checks and the plan
against the strict mock, and `offboardingCantWrite`, the source scan), `MockDelegatesTests.swift`, and
ChangeCore's `ExecutorTests.aStepsCommandLineIsGamGUIs`.

## Files
- `Packages/GamKit/Sources/GamEngine/Offboarding.swift`: the pure core. `Step` (GamGUI's keys and
  `STEP_NAMES`, `leftOutCost`), `optionalSteps`, `requires`/`effectiveRequires`, `fillAutoreply`,
  `checkAddresses`, `steps(...)` (GamGUI's `build_offboard_steps`, each `Planned` one `GamWrite` from
  `GamCommands`), the preview's helpers (`displayName`, `managerContact`, `composeAutoreply`,
  `delegateWarning`, `tickProblem`) and words (`intro`, `header`, `whatStopsWhat`, `notes`), and `Day`
  (Python's `date`: proleptic Gregorian, years 1 to 9999).
- `Packages/GamKit/Sources/GamEngine/GamCommandLine.swift`: GamGUI's `command_line`, the `gam …` line
  shown for an argv. `WriteStep.commandLine` (ChangeCore) is it, over the step's masked argv.
- `Packages/GamKit/Sources/Directory/OffboardChanges.swift`: the model. No executor.
  `UserAccess.delegates(of:)` is the leaver's delegates, read live.
- `App/OffboardView.swift`: the screen (sidebar "Offboard").
- Templates: `Offboarding.Template` and `starterTemplates` (GamEngine), `OffboardTemplateStore` (Stores, the
  file), `OffboardChanges.Form.apply(_:)` and `.template`, `App/OffboardTemplates.swift` (the screen's store).

## What GamGUI's offboarding does
Two parts: the eight-step routine, and a separate, later account delete (GamGUI's user page; here Off3).
**No suspend and no group removal**: the leaver keeps a live mailbox so the delegate, the auto-reply and
the transfer work (GamGUI `core/lifecycle.py:312-316`, `:253-258`).

### Reads and checks before the plan (GamGUI `routes/lifecycle.py:163-209`)
1. **The form's own refusals, before any read:** both addresses entered; a step ticked both as already
   done and as doesn't apply ("pick one"); every step ticked or left out ("nothing to run"). Off1 also
   refuses an invitee that isn't one address (`Address.looksLikeEmail`); GamGUI sends whatever was typed.
2. **Both addresses against the directory** (`checkAddresses`), never an old list: one older than five
   minutes is read again first (`DirectoryStore.load`), and a failed read blocks ("Couldn't read the
   directory to check the addresses — …"); the old list is not a fallback (GamGUI plan U12b).
   - **Blocks:** an unknown address; an alias (the message names the primary); the same account twice;
     the connected admin as the leaver (revoking would delete the app's own token mid-run).
   - **Warns:** a super-admin or delegated-admin leaver (offboarding doesn't remove the role); an
     already-suspended leaver; a suspended manager.
   - The steps act on the directory's primary addresses, whatever case or spaces were typed.
3. **The leaver's delegates** (`print delegates`, GamGUI's `_delegate_warning`), unless the delegate step
   is ticked or left out: the manager already a delegate warns (GAM fails a second add, "Delegate already
   exists", exit 50, and a failed delegate stops the hand-over); a read that fails warns, quoting GAM,
   because the delegate step uses the same Gmail access and would fail after the irreversible reset.
4. **Display names** for the auto-reply's text: the leaver's full name, the manager as "Name (address)".
5. **Not read by GamGUI:** groups, calendars, forwarding state, Drive ownership. Forwarding is always turned off.
6. **Native reads, each a warning whatever the steps** (run at once with the delegates read):
   - the secondary calendars the leaver owns, hidden ones too: `user L print calendars ownedsecondary showhidden
     fields id,summary formatjson` (6287-6288; `showhidden` because GAM filters the person's own list, which
     leaves hidden entries out). Google deletes them with the account (Workspace accounts, from 2026-10-05) and
     the transfer doesn't move them, so the warning names them;
   - the Vault holds that cover the leaver: `user L print vaultholds` (5704, CSV only; holds on an org unit above
     them count). Google doesn't transfer held data, and a held account can't be deleted;
   - a refused read (Calendar off, no Vault access) is said in GAM's words, never taken as "none".

### The steps (`Offboarding.steps`, GamGUI's `build_offboard_steps`)

| # | Step | argv | Builder | `requires` | If it fails |
|---|---|---|---|---|---|
| 1 | Reset password | `update user L password random changepassword off` | `resetPassword` | — | nothing after it runs |
| 2 | Revoke access & sign out | `user L deprovision signout` | `deprovisionUser` | password | reported; stops nothing |
| 3 | Turn off forwarding | `user L forward off` | `forwardOff` | password | reported; stops nothing |
| 4 | Set delegate | `user L add delegate M` | `addDelegate` | password | the auto-reply, transfer and reminder don't run; the sweep does |
| 5 | Set auto-responder | `user L vacation on subject S message <html> html contactsonly false domainonly false start Started end NotSpecified` | `setVacation` (message through `HTMLText.autoreplyHTML`) | password, delegate | reported |
| 6 | Transfer Drive & Calendar ownership | `create datatransfer L drive,calendar M all` | `createDataTransfer(privacy: .all)` | password, delegate | the reminder doesn't run |
| 7 | Remove from everyone's calendars | `all users delete calendaracls primary L` | `removeAllCalendarACLs` | password | reported |
| 8 | N-day reminder for M | `user M add event primary summary … start allday D end allday D+1 description … [attendee I sendupdates all]` | `addCalendarEvent` | password, delegate, transfer | (last) |

- The argv is `argv.json`'s for each builder (`reset_password`, `deprovision_user`, `forward_off`,
  `add_delegate`, `set_vacation`, `create_datatransfer`, `remove_all_calendar_acls`, `add_calendar_event`)
  and `offboarding.json`'s for the routine; `drive,calendar` is one element (a second same-user transfer
  409s while the first runs).
- Risk floors (`WriteAction.minimumRisk`): the reset, the revoke, the transfer and the sweep are
  destructive; the rest low.
- Only the sweep runs under `GamRunner.domainWideTimeout` (an hour): one call that visits every user.
- **Added steps** (native, `Step.addable`, run only when the form or template adds them, each needing only the
  reset): **Clear recovery email & phone** after the reset, `update user L recoveryemail '' recoveryphone ''`
  (`clearRecovery`, destructive: the old values aren't kept; shown and audited masked, as GamGUI masks those
  keywords, so its words say what it does); **Hide from the directory** last, `update user L gal off`
  (`hideFromDirectory`, low; always the explicit `off`, since a bare `gal` means on). No GamGUI builder:
  `NativeArgvTests` holds each exact argv, checked against the grammar (5831, 5842-5843, 5942) and GAM's
  source. With nothing added, every routine is GamGUI's (`everyRoutineIsGamGUIs` unchanged); the first step's
  audit names what was added (`added`) beside what was left out.
- **Leaving a step out** (only the five optional ones): it never counts as succeeded, so
  `effectiveRequires` routes the others around it (no delegate: the auto-reply and the transfer need only
  the reset). The reminder says "nothing transferred" when the transfer is left out.
- **Already done** (any of the eight, for a run again after a failure): not run, counts as succeeded.
- The plan's `WriteStep`s are the steps that run, each about the leaver (`about["offboard"]`, the
  transfer also `new_owner`), the reminder targeting the manager, `requires` as indices of the earlier
  steps that run (a ticked step needs nothing).

### What stops what
Worked out from `effectiveRequires` for the steps that run (`whatStopsWhat`), not written beside it.
GamGUI's template sentence went stale twice: it still says a failed delegate stops the routine (the sweep
stopped needing the delegate on 2026-09-24) and never names forwarding. A deliberate deviation in words;
the commands are unchanged.

## Typed confirm for a long routine
Ten or more steps with a destructive one is GamGUI's "destructive bulk change": the guard asks for the word
`confirm` (Guard counts steps as targets). GamGUI's eight never reach it; GamGUI's eight plus both added steps
do. The confirm sheet asks for the word beside the leaver's address whenever the held preview's decision says
so, and the executor checks it whatever the sheet sends (`addedStepsRunAndALongRoutineNeedsConfirmTyped`).

## Grammar check (GAM 7.48.22, `Vendor/gam7/GamCommands.txt`)
Re-read 2026-10-13; GamGUI's runbook cites 7.48.11's line numbers. No mismatch.

| Step | Grammar line |
|---|---|
| Reset password | 5942 `update user <UserItem> [ignorenullpassword] <UserAttribute>*`; 5838 `(password (random …`; 5825 `changepassword` |
| Revoke | 7901 `<UserTypeEntity> deprovision\|deprov [popimap] [signout] [turnoff2sv]` |
| Forwarding | 8000 `<UserTypeEntity> forward <FalseValues>` |
| Delegate | 7912 `<UserTypeEntity> create\|add delegate\|delegates [convertalias] <UserEntity>` |
| Auto-reply | 8285 `<UserTypeEntity> vacation [<Boolean>] [subject <String>] …` |
| Transfer | 3598 `create\|add datatransfer\|transfer <OldOwnerID> <DataTransferServiceList> <NewOwnerID>`; 3593 the list is one comma-joined element |
| Sweep | 6328 `<UserTypeEntity> delete calendaracls <UserCalendarEntity> <CalendarACLRole>] <CalendarACLScopeEntity>` (the lost `[`: the role is optional) |
| Reminder | 6470 `<UserTypeEntity> create\|add event <UserCalendarEntity> [id <String>] <EventAttribute>+ [<EventNotificationAttribute>]` |
| Delegates read | 7922 `<UserTypeEntity> print delegates\|delegate [todrive …] [shownames]` |

## Off1, the plan
- **A plan belongs to its form and its tenant:** the screen shows it only while the form is the one it
  was made from ("The form changed since the last plan"), and a domain switch drops it.
- **The screen:** a template (below), the leaver and manager completed from the directory
  (`textInputSuggestions`), the eight steps (the lock's three marked "Always runs"; the five others a
  switch each, on when it runs, with what leaving it out costs; VoiceOver hears "Runs: Set delegate"),
  subject and message with GamGUI's defaults and a live "Senders will receive" block from the directory as
  loaded (no read while typing), days (at least one), an optional invitee, eight "Already done" toggles
  behind a disclosure that opens whenever one is ticked (VoiceOver hears "Already done: Reset password"),
  then the plan: GamGUI's header ("Offboarding L — 8 steps", or "N of 8 steps (k ticked as already done,
  j left out)"), warnings with a symbol and words, each step with its summary and its `gam` line in
  selectable monospace (struck through, with why, when it won't run), what stops what, the auto-reply,
  and the notes (the account stays active; don't delete until the transfer finishes). A banner says
  "Read-only preview — this build can't run offboarding yet."
- **Deviations from GamGUI, each deliberate:** the derived "what stops what"; the invitee checked; the
  live block reads the loaded directory rather than re-reading a stale one; the directory's age is
  counted from the end of its read (GamGUI's from the start: a read of a minute counts a minute fresher);
  the words say a delete is "a separate step, later" rather than naming GamGUI's user page.

## Off2, the run (2026-10-13)
- **Held as shown:** the plan's steps are one ChangeCore preview (`confirmStep`), held when the plan is
  made and dropped when the form changes under it (`formChanged`: the plan stays on screen, only shown), a
  newer plan replaces it, or the screen clears. The confirm runs that preview, never a rebuild.
- **The run's rules (ChangeCore's additions, guard-audit.md "Built for offboarding"):** the leaver's
  primary address typed (D, checked by the executor); only `requires` stops a step (B), so a refused
  sign-out is a ✗ that stops nothing; the sweep tolerates GamGUI's notices (A); Stop between steps (C).
- **Checked again at the run (stricter than GamGUI):** the preview's precondition reads `info user` for
  the leaver and the manager on the plan's domain, fresh, after the write lock: either one's primary
  address, suspension or admin roles changed since the plan, or the leaver now the connected admin, or a
  read refused, and nothing runs ("preview again").
- **One at a time:** no new plan while a run goes on; the executor serializes writes and refuses a target in
  flight. Quitting mid-run asks (`AppDelegate.interruptible`), and the Mac doesn't idle to sleep under it
  (`beginActivity`).
- **The screen:** "Offboard L…" under the plan opens `OffboardConfirmSheet` (who leaves and who takes over,
  what runs, what stops what, the time and Touch ID note, the address field; Run is destructive and never
  the default button). The run panel lists each step with a symbol and words ("Done", "Failed", "Not run:
  stopped") and GAM's line for a failure, "Offboarding… N of M · step", and Stop After This Step (asked).
  Finished: GamGUI's heading (complete, interrupted, stopped or incomplete, with what failed, didn't run and
  was left out), "The leaver may still be signed in" when the sign-out didn't finish, what to do next, and
  **Preview the Rest**, a new plan with exactly the steps that succeeded ticked as done. The directory is
  read again after the run. VoiceOver hears each step as it ends.
- **The audit:** every step's record carries `offboard: L`, the transfer's `new_owner`, and the first
  step's `not_applicable` (GamGUI's `offboard_plan` record) when steps were left out; the sweep's end record
  `tolerated` and `tolerated_kinds`.
- **Tests:** `OffboardChangesTests` (the run executes exactly the previewed commands; the typed address; an
  edited form; a failed delegate stops only the hand-over, end to end, and the rest previews what's left;
  the accounts unchanged; what was left out), `ExecutorTests` (A-D), `MockOffboardingTests` (the mock).

## Templates (native: GamGUI has none)
- **What one holds:** the optional steps it leaves out, the native steps it adds, the auto-reply's subject and message, the reminder's
  days and its invitee: the whole form but the two addresses and the "already done" ticks, which are one
  leaver's. Picking one fills the form, and nothing else: the plan is the form's, so every line is still
  GamGUI's (`aTemplateFillsTheFormAndThePlanIsTheFormsOwn`). The lock can't be left out by a template either.
- **The starters**, on first use, each the operator's to change or delete: **Hand-over**, the default, the
  operator's own routine (2026-10-13: reset, sign-out, delegate, transfer, auto-reply, reminder; forwarding
  off comes with the lock), GamGUI's eight without the domain-wide calendar sweep; **All eight steps**,
  GamGUI's routine; **Lock only**, the reset, the sign-out and forwarding off, for a leaver whose hand-over
  waits. The screen opens on the default; a domain switch starts a new form from it.
- **The screen:** a Template picker that fills the form; "Runs N of 8 steps: …" in words; "Changed from
  “X”" once the form differs, with **Update “X”**; **Save as New Template…** (a name; an existing name asks
  before replacing); **More**: open with it by default, or delete it (asked). A form that couldn't run
  (no reminder day, an invitee that isn't one address) can't be saved, and says why.
- **The file:** `offboarding-templates.json` beside the signature templates in the app's folder,
  `{"version": 2, "default": name, "templates": {name: {"leave_out", "add", "subject", "message", "days",
  "invitee"}}}`. Version 1 (no `add`) reads as adding nothing and is never moved aside; the next save writes
  version 2, which an older build moves aside as a format it doesn't know. The starters add nothing until an
  added step has run live. Handled as the signature templates' file is, by the same code (`SignatureStore.load`,
  `writeFile`): read by descriptor, written atomically `0600` in a `0700` folder, and a file it can't read,
  or one holding a template that couldn't run, moved aside whole and the starters shown, never saved over.
  One set for every domain, as the signature templates are.

## Gotchas / mock-lies traps
- **The mock's per-user reads answer for that user** (`print delegates`: Alice has assistant@ and
  backup@, Carol has helpdesk@, Bob none), and an address that isn't a user fails as GAM does.
- **`nogmail/<user>`** (a `GAM_MOCK_STATE` marker) now refuses `print delegates` as GAM 7.48.22 does:
  "Getting all Delegates for x", then "User: x, Gmail Service/App not enabled", exit 73, the CSV header
  with no rows (failure-log 2026-10-13, "Gmail off hid a person's groups": the mock answered it before,
  and the person page hid their groups behind it). Its other refusals exit 1, where GAM's warning exits
  73; checked against the source for `print delegates` only.
- The routine's run-time triggers carry over from GamGUI's mock (`SIGNOUTFAIL`, `FWDFAIL`, `CONFLICT409`,
  `OWNACL`, `SWEEPFAIL`, `SWEEPBENIGN`, `SWEEPMIXED`, `SWEEPSLOW`, `*missing*`, `*exists*`); the model's
  tests use real directory people and `GAM_MOCK_STATE` instead (a delegate already there, a transfer in
  progress), since a trigger address isn't in the directory the checks read.
- **The mock runs these writes as GAM does** (failure-log 2026-10-13, "offboarding mock lies"): a transfer
  resolves its owners (same account, non-user and a second transfer refused as GAM refuses them), a
  suspended user's deprovision exits 51, and the default sweep walks the active directory.
- **The mock's native reads:** `user_owned_calendars/<u>.json` (and `<u>.hidden.json`, only with `showhidden`),
  `vault_holds.csv` (dana@ is held), and `GAM_MOCK_STATE/novault` for a Vault refusal (exit 50; GAM's wording
  approximate). `update user … gal [<Boolean>]` is GAM's optional Boolean.
- **Not proven offline:** anything about a real tenant. The plan's lines are argv-identical to GamGUI's,
  which ran all eight live on 2026-10-07 (GAM 7.48.14); the reminder with an invitee is still unproven
  live there.

## Testing / live verification
`swift test --package-path Packages/GamKit --filter "Offboard|MockDelegates"`.

**L1 (read-only, the operator's go):** for the next real leaver L and manager M, enter both in GamGUI's
Lifecycle page (its preview is read-only) and in Offboard here, then Preview. Every `gam` line must match
byte for byte: pick **All eight steps** here, or leave the same steps out in GamGUI as the template here does
(Hand-over leaves out the calendar sweep). Check: the header's step count; the leaver in every step and the manager in the delegate,
the transfer and the reminder; `drive,calendar` one element, then `all`; the auto-reply block reads as
senders should see it; the reminder's date and invitee; each warning dealt with. Nothing runs.

**L2 (the routine, after the adversarial review; the operator's yes in chat for "offboard L with M"):** GamGUI
not used on L at the same time; stay at the Mac (Touch ID may be asked again after the sweep); don't quit.
After: the panel says complete; Audit has a begin and an end for each step, the sweep `tolerated: true` with
its `tolerated_kinds` (record those counts: the first real sweep either app has seen in this form). Then in
Google, as GamGUI's runbook lists: the old password fails, no app passwords or connected apps, forwarding
off, the manager's account switcher offers the mailbox, an outside sender gets the auto-reply, the transfer
`completed`, a colleague's calendar no longer lists L, the reminder on M's calendar (and the invitee's
email). Mark the README rows confirmed. A failed step: fix the cause, Preview the Rest (a new yes).

**Off2's review (2026-10-13)** found the own-admin check failing open after another domain's failed check, a
Stop before the first step dropped, a reminder-only rest that couldn't run, and gaps in the tests of the run-time
re-check; all fixed with tests (failure-log 2026-10-13, "offboarding could offboard its own admin"). The admin
is now the connected domain's own (`SetupModel`), required to plan and read again at the run; the address to type
is the leaver's while a step acts on the leaver, none for the reminder alone; the run panel stays, with Stop, if
the domain changes mid-run.

## Next
- The options plan's next slices (docs/plans/2026-10-13-offboarding-options.md): secondary calendars handed to the
  manager (`calendars <id> transfer ownership M`: the grammar line 1685 lacks `ownership`, GAM's source needs it),
  forwarding filters, POP/IMAP, other delegates, forward to the manager, admin roles, transfer options.
- **Close Out** (the operator, 2026-10-13): groups, org unit, suspend, aliases and archive, after the transfer
  finishes, with **Off3**, the account delete (GamGUI's pending-transfer warning plus a precondition; refused
  under a Vault hold or while secondary calendars remain).
- Extra read-only warnings, to decide: a transfer already running for L, and the sign-out scope missing
  from the token.
