# Compromised account

**One line:** for a person who stays employed but whose account was taken over: Check Account reads what an attacker
commonly changes (and changes nothing), the operator ticks what to undo, and the lock plus the picks run as one
ChangeCore preview, the person's address typed. Built 2026-10-19: slice 1, then slice 2, Pull Incident Logs (every
activity log an incident needs, by account and attacker IP, with CSV export). The plan and its defaults: [docs/plans/2026-10-19-compromised-account.md](../plans/2026-10-19-compromised-account.md).

**Owns invariants:** #1 (each pick one argv element: a delegate or send-as address must be one plain address, a filter
ID list offboarding's checked one), #2 (one held preview, the precondition at the run), #10 (nothing from Siri or a
model: the screen only).

**Enforcement home:** `Packages/GamKit/Tests/GamEngineTests/CompromisedTests.swift` (the core and the mock),
`Packages/GamKit/Tests/DirectoryStoreTests/CompromisedChangesTests.swift` (the check, the plan and the run against the
strict mock), `NativeArgvTests` (each new argv), `WriteRouteTests.onlyTheRoutineLoosensTheRunsRules` (this model may
let only `requires` stop a step; it may not tolerate failures).

## Files
- `Packages/GamKit/Sources/GamEngine/Compromised.swift`: the pure core. `Step` (names shared with `Offboarding.Step`),
  `steps(...)` (each `Planned` one `GamWrite`), `header`, `whatStopsWhat`, and the reads in words: `Filter`,
  `Forwarding`, `ForwardingAddress`, `SendAs`, `AdminRole`, `Account`, `findings`.
- `Packages/GamKit/Sources/Directory/CompromisedChanges.swift`: the model (check, plan, run, stop).
- `Packages/GamKit/Sources/Directory/UserAccess.swift`: the check's reads (`compromisedAccount`, `filters`, `forwarding`,
  `forwardingAddresses`, `sendAs`, `adminRoles`; `delegates` is offboarding's).
- `App/CompromisedView.swift` (sidebar "Compromised"); `CompromisedConfirmSheet` in `App/ChangePreviewSheet.swift`, where
  every confirmation is made (`WriteRouteTests`).

## How it works
0. **From a person's page** (the operator, 2026-10-19: "a button to do that for anyone"): Users → Actions → **Secure
   Account…** hands the address to this screen (`ContentView.compromisedPerson`), which starts a new form for it
   (`Form(person:)`: nothing ticked, not even the reset) and checks it. Users holds no reference to this model
   (`WriteRouteTests.onlyItsScreenReachesTheCompromisedModel`).
1. **Check Account:** `info user P fields <Compromised.accountFields> formatjson` first (an alias reads as its owner; a
   failure stops the check, in GAM's words), then at once: `print filters labelidsonly formatjson`, `print forward`,
   `print forwardingaddresses`, `print delegates`, `print sendas verifyonly`, `print admins user P`. Each failure is said
   beside its list, never taken as "none". `findings` says what to look at first. The connected admin as P is shown and
   blocks the plan.
2. **Pick:** a box per filter (delete), delegate (remove) and send-as address but the primary (remove). None ticked.
3. **Preview:** `steps` in run order: reset, clear recovery (switched, off), sign-out, forwarding off, the filters (one
   command), each delegate, each send-as address, IMAP off and POP off (switched, on). "Password already reset" ticks
   the reset as done. When the reset runs, every other step `requires` it; otherwise nothing stops anything.
   `stopsAtAccountWideFailure: false`: a refused sign-out (the admin token's scope) mustn't stop forwarding off (the
   service account's). The person's address is typed; ten steps with a destructive one also ask for `confirm`.
4. **Run:** the precondition reads P fresh (`info user`): the same primary address, suspension and admin flags, and
   not the connected admin, or nothing runs. Stop between steps. Then the account is **checked again**, and ticks on
   what's gone are dropped. Preview the Rest ticks the lock steps that succeeded as done.

## Grammar and source (GAM 7.48.30)
| Command | Grammar | Source |
|---|---|---|
| `user P print forward` | 8003 | printShowForward: `User,forwardEnabled,forwardTo,disposition` |
| `user P print forwardingaddresses` | 7997 | printShowForwardingAddresses: `User,forwardingEmail,verificationStatus` |
| `user P print sendas verifyonly` | 8297 | printShowSendAs: each signature a bool with `verifyonly` |
| `user P delete sendas S` | 8293 | deleteInfoSendAs: an <EmailAddressEntity> split on commas and whitespace |
| `print admins user P` | 1579 | doPrintShowAdmins: PRINT_ADMIN_TITLES; `_SEED_ADMIN_ROLE` is Super Admin; no group roles without `recursive` |
| `user P delete delegate D` | 7919 | processDelegates: Gmail's notFound for one they don't have, exit 50 |
| `info user P fields …recoveryPhone,isEnforcedIn2Sv…` | 5780-5810 | USER_FIELDS_CHOICE_MAP |

## Gotchas / mock-lies traps
- **The mock's Gmail reads act as the person** (`gmail_read`): a non-user fails at the token (exit 50), `nogmail/<u>` is
  exit 73 with the titles alone, and any option the app doesn't send isn't modelled. Until 2026-10-19 `print
  forwardingaddresses` answered `fwd@example.com` for anyone, and removing a delegate the person didn't have passed.
- **carol@ is the mock's taken-over account:** forwarding on to carol.home@example.org, two forwarding addresses (one
  pending), three filters (two forward), helpdesk@ as a delegate, billing.desk@example.net as a send-as address, and a
  recovery email and phone (`info_user_carol.json`, so the directory's reports don't change). alice@ is the super
  admin in `print admins`.
- **`forward` keeps state** (`GAM_MOCK_STATE/forward/<u>`), so `print forward` after `forward off` says off.
- **Not modelled, for the live check to tell:** Gmail's exact words for a refused send-as delete; whether `print
  admins user` lists a role held through a group (not without `recursive`, per the source).
- **User labels show as IDs** (`labelidsonly`): the system labels an attacker's filter uses are named.
- **"Already done" belongs to one person** (review 2026-10-19): Preview the Rest ticks the lock steps that succeeded,
  and those ticks once carried to the next person typed, whose plan then skipped the reset and the sign-out. Now a new
  address clears every tick and pick, and `plan` refuses lock steps ticked by another person's run (`Form.restOf`).
- **A removal is one address GAM acts on as given** (`GamCommands.isOneAddress`): GAM reads `Name <a@b>` as `a@b` and
  `id:`/`uid:` as an ID, so those are refused too.

## Testing / live verification
`swift test --package-path Packages/GamKit --filter "Compromised|NativeArgv"`.

**L1 (read-only, the operator's go):** Check Account on the real taken-over account: every list matches what the Admin
console and Gmail's settings show (filters, forwarding, delegates, send-as, recovery, 2SV, roles). Pull Incident Logs
for the person, then for every account by the attacker's address: each log's rows match the Admin console's Reporting →
Audit and investigation export of the same log (user log, OAuth, Gmail, Access evaluation, Chat, user accounts), and a
log the edition lacks says so in GAM's words. Nothing runs.

**L2 (the operator's yes in chat for "secure P"):** tick the reset as done if it was; tick what the attacker made; run.
Then in Google: sessions ended, no app passwords or connected apps, forwarding off, the ticked filters, delegates and
send-as addresses gone, IMAP and POP off. Mark the README rows confirmed.

## Leftover drafts (slice 4)
The operator, 2026-10-19: the attacker's Gmail session left about 2,480 draft events, and six phishing batches started but
blocked by Google left drafts anyone signed in could still send. "I just need to clear the drafts on their own."
- **The check** lists the person's drafts, the newest 5,000, with their subject and Gmail's own time (`listMessages`:
  `print messages query in:drafts max_to_print 5000 headers subject showlabels showdate`). GAM has no drafts command of its
  own: a draft is a message with the DRAFT label. Only the subject is read: a phishing draft's Bcc list runs to hundreds,
  and thousands of those passed the runner's 8 MiB cap in review, listing none. None is GAM's exit 60, "No drafts."
- **The removal:** keep them (the start), delete every listed draft, or only those whose subject contains some text
  (`Form.Discard`, `Compromised.drafts(_:subjectMatching:)`; one that matches nothing is refused in words). One held step
  `deleteMessages` (`delete messages ids <list>`, 8170-8174; with ids GAM needs no `doit` and checks no count), its own
  action `.deleteMessages`, destructive, needing the reset when it runs, confirmed by the typed address as every run here
  (Guard counts steps, so the number of drafts isn't typed: it's in the step and the sheet, which says it can't be undone).
- **Delete, not Trash** (review 2026-10-19): Gmail's own Discard deletes a draft; a draft in Trash may still be a draft
  (drafts.list takes includeSpamTrash), sendable, while the check, which lists without Trash, would then say "No drafts."
  GAM deletes with Gmail's batchDelete, 50 at a time (`message_batch_size`); a batch holding an ID Gmail refuses fails
  whole, the other batches done. The listing and the delete each get ten minutes (`Draft.timeout`): thousands meet
  Gmail's per-user quota. The IDs are `GamCommands.idList` (deleteFilters' check, shared). Gmail's log keeps the record.
- **The screen** draws the newest 50 and says how many will be deleted; a command line of thousands of IDs is shortened
  where it's shown and spoken (the held argv is whole). A new address resets the choice to keep.
- **The mock:** two strict blocks ahead of the Phishing screen's search handler: the drafts listing (the DRAFT label in
  messages.csv, a deleted one left out, none exit 60, `max_to_print 0` no limit, Gmail off 73, a non-user's token 50) and
  the delete by IDs (batches of 50, a batch with an ID the mailbox lacks failing whole with "Invalid message id(s)", exit
  50; state in `deleted/<id>`). carol@ has three drafts, two of them leftover phish.
- **Not modelled, for the live check to tell:** Gmail's words for a valid-looking but missing ID in a batch, and a draft
  that changes ID while it's listed (an autosave: GAM's 404 fails the listing; Check Again reads it again).

## Pull Incident Logs (slice 2)
- `ActivityLogs` (GamEngine): `Row` from a `report <application>` row in the one shape (`id.time`, `actor.email`,
  `name`, `ipAddress`, then every other column by name; a nested parameter, Gmail's, named by its chain from the
  `parameters.N….name` columns), its words, its details (the sign-in's type, challenge and outcome; the app and its
  access; else its first parameters), whether Google flagged it; `addresses(in:)` (flagged first); `table` (the CSV's
  shape). `GamCommands.ActivityApplication` is the application list, in GamCommands.swift so the Linux fuzz build has it.
- `IncidentLogs` (Directory): one pull, each log read (three at once) and kept in the query's order; a newer pull
  replaces one still reading; `csv(_:)` through `AuditExport.csv` (spreadsheet-safe cells) and
  `AuditExport.writePrivately` (0600, whole or not at all). `UserAccess.activity(...)` is the read.
- The builder: `reportActivity(_:users:hours:ip:events:maxActivities:)`. 1 hour to 180 days; at most 20 accounts, each
  `isOneAddress`, joined for `select users`; `ip` is `Address.isIP` (in Address.swift, which the fuzz build compiles).
- **The mock's logs** (`report_<application>.csv`): carol@'s sign-ins include a flagged one from 198.51.100.23, dana@
  signed in from it too, and the same address granted an app, sent the phish (Gmail), was denied a cookie validation
  (access evaluation) and changed carol@'s recovery phone (account changes). A log without a fixture prints the titles
  alone. `nolog/<application>` is an edition without it (exit 4). Gmail over 30 days is exit 56 (an account) or 53
  (all); an address outside example.com is 73; the admin log's accounts are the actor only with `userisactor`. A known
  lie: every fixture event is answered whatever the window.
- **Not modelled, for the live check to tell:** the parameter names each log carries today, whether every log has the
  actor's IP (the `ip` filter is server-side), Google's words for an edition without a log, and a refusal when the
  admin token lacks the Reports audit scope.
- **Ways a log could miss events silently, each closed** (review 2026-10-19): a read past the runner's 8 MiB cap failed
  only its oldest rows (newest first: when the compromise began) and parsed a half-written last one, so
  `UserAccess.outcome` now refuses any truncated read; the cap note hid behind the 300-row note and counted all accounts
  together, so it stands alone and counts per account; Gmail over 30 days is the API's refusal, so Gmail reads at most
  30 days and says so; the admin log for an account reads what was done to it unless `userisactor`, so it's sent; one
  address that isn't a user fails the whole log in GAM, so the screen checks the accounts against the directory first.
  Each read is pinned to the tenant the pull began on and may take ten minutes (GAM reads one account after another).

## Next
- Slice 3: search a mailbox on the person's page.
- Not built (the plan says why): 2SV off, suspend, deleting forwarding addresses, a signature check.
