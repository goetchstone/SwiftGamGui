# Compromised account

**One line:** the Incident screen (sidebar "Incident", `Screen.compromised`), in the order an incident is worked: 1 find
who's affected (Pull Incident Logs, Read the logs), 2 secure an account (Check Account reads what an attacker commonly
changes and changes nothing; the operator switches steps and ticks what to undo; one ChangeCore preview, the person's
address typed), 3 pull the email (Phishing), 4 afterwards (a checklist). Every step is a switch: any one runs alone. Built 2026-10-19: slice 1, then slice 2, Pull Incident Logs (every
activity log an incident needs, by account and attacker IP, with CSV export); 2026-10-21 slice 5, Chrome (its log by
the profile's account, and a person's Chrome profiles); slice 6, the Incident screen (the order, every step a switch, the
auto-reply and devices in the check, the other logs an incident needs). The plan and its defaults: [docs/plans/2026-10-19-compromised-account.md](../plans/2026-10-19-compromised-account.md).

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
- Chrome (slice 5): `GamEngine/ChromeProfiles.swift` (a profile in words), `Directory/ChromeProfileReads.swift` (a person's,
  kept per person), `UserAccess.chromeProfiles`, the Chrome cases in `ActivityLogs`; the Security tab's
  `ChromeProfilesSection` in `App/UsersView.swift`. Tests: `GamEngineTests/ChromeReadsTests.swift`.

## How it works
0. **From a person's page** (the operator, 2026-10-19: "a button to do that for anyone"): Users → Actions → **Secure
   Account…** hands the address to this screen (`ContentView.compromisedPerson`), which starts a new form for it
   (`Form(person:)`: nothing ticked, not even the reset) and checks it. Users holds no reference to this model
   (`WriteRouteTests.onlyItsScreenReachesTheCompromisedModel`).
1. **Check Account:** `info user P fields <Compromised.accountFields> formatjson` first (an alias reads as its owner; a
   failure stops the check, in GAM's words), then at once: `print filters labelidsonly formatjson`, `print forward`,
   `print forwardingaddresses`, `print delegates`, `print sendas verifyonly`, `print admins user P`, the drafts, `show
   vacation` (an attacker's auto-reply phishes everyone who writes), `print mobile query email:P` (a phone that syncs
   the mail may be the attacker's; shown, not changed: the wipe is the Admin console's) and `print devices query email:P`
   (a computer signed in with the account, which an attacker's sign-in can leave behind; slice 8) and `print filelist
   showmimetype gscript` (the person's Apps Script projects; slice 9). Each failure is said
   beside its list, never taken as "none". `findings` says what to look at first. The connected admin as P is shown and
   blocks the plan.
2. **Pick:** a box per filter (delete), delegate (remove) and send-as address but the primary (remove), the auto-reply
   (turn off) when it's on, and the drafts (none, all, by subject). None ticked.
3. **Preview:** `steps` in run order: reset, clear recovery, sign-out, forwarding off, the filters (one command), each
   delegate, each send-as address, the auto-reply off, the drafts, IMAP off and POP off. **Every step but the picks is a
   switch** (2026-10-21, "ways to do things on an individual basis"): the lock (reset, sign-out, forwarding, IMAP, POP)
   is on to start, clear recovery off; All Off and The Lock set them at once; nothing switched or picked is refused in
   words. Off when the reset was done in the Admin console. When the reset runs, every other step `requires` it;
   otherwise nothing stops anything.
   `stopsAtAccountWideFailure: false`: a refused sign-out (the admin token's scope) mustn't stop forwarding off (the
   service account's). The person's address is typed; ten steps with a destructive one also ask for `confirm`.
4. **Run:** the precondition reads P fresh (`info user`): the same primary address, suspension and admin flags, and
   not the connected admin, or nothing runs. Stop between steps. Then the account is **checked again**, and ticks on
   what's gone are dropped. Preview the Rest ticks the lock steps that succeeded as done.

## Grammar and source (GAM 7.48.30)
| Command | Grammar | Source |
|---|---|---|
| `user P print forward` | 8014 | printShowForward: `User,forwardEnabled,forwardTo,disposition` |
| `user P print forwardingaddresses` | 8008 | printShowForwardingAddresses: `User,forwardingEmail,verificationStatus` |
| `user P print sendas verifyonly` | 8310 | printShowSendAs: each signature a bool with `verifyonly` |
| `user P delete sendas S` | 8306 | deleteInfoSendAs: an <EmailAddressEntity> split on commas and whitespace |
| `print admins user P` | 1579 | doPrintShowAdmins: PRINT_ADMIN_TITLES; `_SEED_ADMIN_ROLE` is Super Admin; no group roles without `recursive` |
| `user P delete delegate D` | 7930 | processDelegates: Gmail's notFound for one they don't have, exit 50 |
| `info user P fields …recoveryPhone,isEnforcedIn2Sv…` | 5790-5820 | USER_FIELDS_CHOICE_MAP |
| `user P show vacation`, `user P vacation off` | 8325-8331 | GamGUI's builders (Users' auto-reply), held to argv.json |
| `report admin user P start -Nh end now maxactivities M` (no `userisactor`) | 4738-4752 | doReport :14779-14788: read as `user all` with the filter `USER_EMAIL==P`, what admins did to P; a non-user reads none |
| `print mobile query email:P fields resourceid,… formatjson` | 4563-4570 | doPrintMobileDevices: CSV `resourceId,JSON`, the row written from `resourceId`; _validateDeviceQuery; a refusal ClientAPIAccessDeniedExit, exit 12 |
| `user P print filelist showmimetype gscript fields … formatjson` | 7804-7833 | printFileList: the type put in Drive's query beside `'me' in owners`, My Drive only, the bin included; CSV `Owner,id,name,JSON`; exit 60 whenever no row was printed, none and every failure alike (`ScriptProject.list` reads none only from GAM's "Got 0 … for P") |
| `print devices query email:P fields … userfields … formatjson` | 4367-4375 | doPrintCIDevices: the service account as the admin (before any argument is read); every view; each device's users attached; CSV `name,JSON`; the scope not delegated is "User: <admin>, Cloud Identity API - Devices Service/App not enabled", exit 73; a scope list without the API, exit 12 |

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
- **The auto-reply's own text is the attacker's** (review 2026-10-21): the reader takes settings only above `Message:`,
  which GAM prints last; GamGUI's reader (and its parity fixture) let a line `Enabled: False` in the reply hide it.
- **"Already done" belongs to one person** (review 2026-10-19): Preview the Rest ticks the lock steps that succeeded,
  and those ticks once carried to the next person typed, whose plan then skipped the reset and the sign-out. Now a new
  address clears every tick and pick, and `plan` refuses lock steps ticked by another person's run (`Form.restOf`).
- **A removal is one address GAM acts on as given** (`GamCommands.isOneAddress`): GAM reads `Name <a@b>` as `a@b` and
  `id:`/`uid:` as an ID, so those are refused too.

## Testing / live verification
`swift test --package-path Packages/GamKit --filter "Compromised|NativeArgv"`.

**L1c (read-only, the operator's go):** a person's Security tab → Check Chrome: their profiles match the Admin console's
Devices → Chrome → Managed browsers' profiles; a person with none says none; a missing scope says so. Pull Incident Logs
with Chrome ticked for that person: their events (if Chrome reports any) match the Admin console's Chrome log filtered by
"Profile user".

**L1 (read-only, the operator's go):** Check Account on the real taken-over account: every list matches what the Admin
console and Gmail's settings show (filters, forwarding, delegates, send-as, recovery, 2SV, roles). Pull Incident Logs
for the person, then for every account by the attacker's address: each log's rows match the Admin console's Reporting →
Audit and investigation export of the same log (user log, OAuth, Gmail, Access evaluation, Chat, user accounts), and a
log the edition lacks says so in GAM's words. Search the taken-over mailbox for `in:sent newer_than:3d`: the phish is
there, its Bcc list matches the message's own. Nothing runs.

**L2 (the operator's yes in chat for "secure P"):** tick the reset as done if it was; tick what the attacker made; run.
Then in Google: sessions ended, no app passwords or connected apps, forwarding off, the ticked filters, delegates and
send-as addresses gone, IMAP and POP off. Mark the rows confirmed in docs/live-verification.md.

## Leftover drafts (slice 4)
A taken-over account can be left with thousands of drafts, and phishing batches Google blocked leave drafts anyone
signed in can still send. The operator: "I just need to clear the drafts on their own."
- **The check** lists the person's drafts, the newest 5,000, with their subject and Gmail's own time (`listMessages`:
  `print messages query in:drafts max_to_print 5000 headers subject showlabels showdate`). GAM has no drafts command of its
  own: a draft is a message with the DRAFT label. Only the subject is read: a phishing draft's Bcc list runs to hundreds,
  and thousands of those passed the runner's 8 MiB cap in review, listing none. None is GAM's exit 60, "No drafts."
- **The removal:** keep them (the start), delete every listed draft, or only those whose subject contains some text
  (`Form.Discard`, `Compromised.drafts(_:subjectMatching:)`; one that matches nothing is refused in words). One held step
  `deleteMessages` (`delete messages ids <list>`, 8181-8185; with ids GAM needs no `doit` and checks no count), its own
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

## Scheduled sends (2026-10-23)
Asked for (2026-10-23): find and stop anything scheduled to send. **A scheduled email is not a draft** (the drafts' listing never shows it), and Gmail sends
it at its time on its own, with nobody signed in: the lock doesn't stop it. Slice 4 had left it out.
- **The check** lists every one with its recipients: GamGUI's mailbox search (`searchMessages`, Spam and Trash included,
  `headers all`, read by `MailboxSearch`) for `in:scheduled`, at most `Compromised.ScheduledSend.cap` (500, above the
  100 guides to Gmail say one person can schedule; Gmail's own help doesn't say). A finding says it first, with how many
  recipients: these go out on their own.
- **The removal:** keep them (the start: one may be the person's own) or delete every one listed, one held step
  `deleteMessages` (the drafts' command and action, destructive, needing the reset when it runs), run **right after the
  reset**, before the sign-out and the rest: one comes due while the run goes on. Deleted, not trashed, as the drafts
  are. **Only a message plainly in Gmail's Scheduled is deleted as one** (`Compromised.ScheduledSend.isScheduled`): the
  `SCHEDULED` label, its labels told apart by GAM's own `LabelsCount` (a user label's name may hold the word: SpamCopies'
  rule), and never `SENT`. `steps` refuses any other; the screen says how many it left alone. To keep one, the operator
  cancels the others in the person's Gmail instead (Cancel send leaves each a draft, for the drafts' step after Check
  Again).
- **Read again at the confirm** (review 2026-10-23): the plan holds the check's IDs, and one Gmail sent since may be its
  Sent copy under the same ID, the only copy with the whole Bcc list, which Phishing's List Recipients reads. The
  preview's precondition lists the scheduled sends again; one held that isn't there any more refuses the run before
  anything runs, and the screen checks the account again at once, so a preview after holds what's scheduled now (else
  previewing the same check would hold the same IDs). The refusal says the lock can run without the delete meanwhile.
- **Bounds:** at the cap, the screen says "at least" and that Check Again lists the rest. The mock's search stops at
  `max_to_print` as GAM does (it once ignored it: review 2026-10-23).
- **The mock:** the search's strict `in:<label>` term; carol@ has one scheduled phish (`19a0c0ffee000014`, three Bcc).
- **Not modelled, for the live check to tell:** whether Gmail's API honours `in:scheduled` (a third party's support says it
  does), that the label is named `SCHEDULED`, whether `showdate` is the send time or the time it was written (the screen
  says "Gmail's time"), and that a batchDelete of a scheduled message stops the send. **The live check** (the operator's
  yes for the delete): schedule a test email to yourself in Gmail from an account of yours that isn't the one this app
  connects as (its plan is refused: the sign-out would delete the app's own authorization), Check Account on it (it
  lists the test email, labelled), delete it alone (every switch off), then check Gmail's Scheduled no longer has it and
  it never arrives.

## Pull Incident Logs (slice 2)
- **The logs** (2026-10-21, "add any other logs that should be looked at"): sign-ins, OAuth, SAML (sign-ins to other apps
  through Google), Gmail, Access, Chat, account changes, Takeout and Devices on by default; Chrome, Drive, Calendar
  (invitation phishing), Groups (members added, a group opened to outsiders), Admin, Rules, Context-aware access and
  Vault (what matters when an admin was taken) to tick. GAM's REPORT_CHOICE_MAP spells each; the mock answers each, those
  without a fixture with GAM's titles alone, and capitalizes the events of admin, chrome, context-aware access, mobile
  and takeout as doReport's REPORT_ACTIVITIES_UPPERCASE_EVENTS does.
- `ActivityLogs` (GamEngine): `Row` from a `report <application>` row in the one shape (`id.time`, `actor.email`,
  `name`, `ipAddress`, then every other column by name; a nested parameter, Gmail's, named by its chain from the
  `parameters.N….name` columns), its words, its details (the sign-in's type, challenge and outcome; the app and its
  access; else its first parameters), whether Google flagged it; `addresses(in:)` (flagged first); `table` (the CSV's
  shape). `GamCommands.ActivityApplication` is the application list, in GamCommands.swift so the Linux fuzz build has it.
- `IncidentLogs` (Directory): one pull, each log read (three at once) and kept in the query's order; a newer pull
  replaces one still reading; `csv(_:)` through `AuditExport.csv` (spreadsheet-safe cells) and
  `AuditExport.writePrivately` (0600, whole or not at all). `UserAccess.activity(...)` is the read.
- **Export All** (`IncidentLogs.exportAll`): every log that was read, into a new folder (0700, never an existing one:
  " (2)" and on) named for when, in the folder the operator picks, with `about.txt` (window, accounts, address, each
  log's count; the CSVs alone don't say what was pulled). A log that wasn't read is said, never an empty CSV that
  would pass as no events; a file that can't be written removes the folder. Enabled once the pull has ended.
- The builder: `reportActivity(_:users:hours:ip:events:maxActivities:)`. 1 hour to 180 days; at most 20 accounts, each
  `isOneAddress`, joined for `select users`; `ip` is `Address.isIP` (in Address.swift, which the fuzz build compiles).
- **The mock's logs** (`report_<application>.csv`): carol@'s sign-ins include a flagged one from 198.51.100.23, dana@
  signed in from it too, and the same address granted an app, read a message of carol@'s and sent the phish (Gmail:
  every event is `delivery`, `event_info.mail_event_type` says which, 31 and 1), was denied a cookie validation
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
- **Past the cap** (`IncidentLogs.paged`; asked for when a pull for every account stopped at 1,000 events
  short of the attack, 2026-10-22): a read at the cap (`ActivityLogs.cap`, per account when accounts are named) is
  read again over the same window up to where it stopped. The window is fixed as times when the log's first read runs
  (`start <now less the hours> end <now>`, `yyyy-mm-ddThh:mm:ssZ`, `GamCommands.isReportTime`, which GAM passes on as
  given): GAM's `-72h` counts from each read and rounds to the minute, and a Gmail log queued behind others would drift
  past 30 days. A later read is `start <the same> end <its oldest event's second, plus one>`: the end's own second is read
  again, as Google doesn't say whether endTime includes it, and the repeats are dropped by event (`Row.identity`). It goes
  on until a read comes back short, at most `ActivityLogs.pages` (10) reads a log (invariant 9); named accounts each go on
  by themselves (GAM's `maxactivities` is per account), and an address at the cap that isn't one asked for (an alias, an
  old name) is capped, as there's no telling which to go on with. Still at the cap after the reads, or a later read
  failing, is capped: what came back is kept and said as such, never a failure of the whole nor a part passed as all.
  GAM's cap counts activities and the rows are events, so a read can look full early: an extra read, never a missed one.
  Not paged: Chrome's and the admin log's two-way reads for named accounts (1,000 activities an account each way, capped
  past that), and a read of several event names (GAM caps each name on its own). A pull replaced mid-read lets its logs
  finish their pages: read-only and bounded, their rows dropped.
- **Read whole, oldest first** (`IncidentLogs.complete`; asked for 2026-10-23, after a 30-day pull for every account read
  only Gmail's last 19 hours: "I need it all … the oldest first, then the newer"). This replaces the newest-first paging for
  every log but the Chrome and admin logs' reads for accounts (low volume; still `paged`, newest first). One read of the
  window first: most logs come back short of the cap and are whole. One at the cap is read a day at a time from the
  window's start, each day read back from its end until it's whole (`paged`, its `pages` the day's budget), each day's end a
  second past the next day's start, an event read twice kept once. Bounded (invariant 9): 100 reads a day and 200 a log
  (`ActivityLogs.readsPerDay`, `readsPerLog`: 100,000 and 200,000 events). Past either, a read that fails, or a day still at
  its cap, it stops at that day's start: the older days are whole and the newer unread, which is the order that matters
  (the attack is the oldest part, and the newest is the easiest to read again). The log says "Read completely through
  <time>" (`Log.through`) with **Read the Rest**, a pull of that log from there to now (`Query.from`/`to`), added to what's
  shown or saved to the incident open. While it reads, each log says how far it's got (`IncidentLogs.readThrough`). The
  export's `about.txt` says it ("read completely through …, later events weren't read"), and reading an export back
  understands it; a merge is read through the later of two such reads, or whole when either read was.
- **Windows:** 1, 3, 10, 15 and 30 days, and 6 months (`ActivityLogs.hours`; the Gmail log reads 30 days at most, so its
  start is held there).
- **What's realistic** (a small domain's every-account Gmail log runs to thousands of events a day): every account's Gmail for 10 or 15 days fits one pull (well over a hundred reads); 30 days is two (the
  oldest half, then Read the Rest). A large organisation's every-account Gmail runs to hundreds of thousands of events a day:
  read whole by every account, only a day or so fits. There, filter by the attacker's address (`ip`, which Google applies
  before it counts, so every account's events from that address are few) or name the accounts that matter (20 at once): both
  stay whole over 30 days. Each read is one GAM call, and Google's API quotas slow very long reads.
- **Nothing a pull's size runs on the main thread** (failure log 2026-10-23: a whole pull's reading stopped the app for
  minutes). Each read's parse (`UserAccess.activity`), the paging, repeats dropped and sorts (`IncidentLogs.read`,
  `@concurrent`), Pull Again's merge (the pull stays reading until it's done, so the read alone never shows or is saved),
  saving a pull to the open incident (`Incidents.keep`), Export CSV and Export All, and Read the logs (`LogReaderView.Memory`, once per pull, "Reading
  the logs (N events)…" meanwhile) all run off it. While a pull reads, each log says where it is after every GAM read
  (`IncidentLogs.Progress`: waiting its turn, reading with its events so far and its reads, whole through a time, done or
  couldn't be read), so a busy log reading a day in a dozen reads still moves. The reader is linear: each account's rules read only its own events and
  the admin's done to it (`LogReading.Accounts`); 200,000 events read in about 2 seconds in a Debug build.
- **A read's columns are worked out once, not for each row** (`ActivityLogs.Columns`; watched on the operator's 30-day pull,
  2026-10-27): every row of one GAM call has the header's columns in its order, and each row was sorting its own, `padded`
  twice a comparison. A Gmail read of 1,000 events was then about 2 s in GAM and 6 to 8 s of a Debug build's parse, one log
  after another a day at a time, so Gmail was most of the pull. Now `rows` makes one plan a header (the order, the count
  columns, each nested column's name chain) and reads each row's values by it; a record whose columns differ (JSON's can) gets
  its own. 1,000 Gmail-shaped rows of 93 columns, the whole read (best of 3, background priority): Debug 17.3 s → 1.4 s,
  Release 4.9 s → 0.43 s. `ActivityColumnsTests` holds it to the parser as it was (kept there as `reference`) on every mock
  report and on rows made for each case. What's left is mostly the shared `CSVReader` (held to GamGUI's parsing, left alone).
- **Mock lie, handled where it matters:** the mock ignores a read's start (its events are on fixed dates, and the tests read
  at today's time). Paging back now stops once a read reaches the window's start (nothing earlier is in it, and an end
  before the start is GAM's usage error), which real GAM never needs and the mock's extra rows did. A day's read in the
  mock returns the older days too; they're dropped as repeats. `aLogIsReadWholeOldestFirst` holds the order and the bounds
  with a stand-in that keeps the window as Google does.
- **The mock:** a window as two times, both or neither (with `-<N>h`, only `end now`), each a real time (`date -j` must
  read it back the same), the end after the start (before it is GAM's usage error, 2); the end keeps the events before it
  (`id.time`), its own second left out, the strict guess; Gmail's 30 days counted between the two. The start still keeps
  every fixture event (the mock's dates are fixed), so tests pull at a fixed time (`IncidentLogs(… clock:)`).
- **Live check (L2p, read-only):** pull every account's sign-in log for 30 days; the capped note is gone (or says the
  bound), and the oldest event is near the window's start; the Admin console's export for the same window has as many.

## Search a mailbox (slice 3)
- Users → a person → Mail → **Search this mailbox**: GamGUI's `searchMessages` (`print messages query <q> includespamtrash
  max_to_print 50 headers all showlabels showdate`), read by `MailboxSearch` (GamEngine) one row per message with
  `MessageRecipients`' header rules: To, Cc and Bcc by name with GAM's numbered repeats, never `Delivered-To`. The query
  starts as `in:sent newer_than:3d`: a taken-over account's Sent mail shows the phishing and its Bcc list. None found is
  GAM's exit 60, read as no messages; a read past the runner's cap is incomplete, never all there is.
- `MailboxSearches` (Directory) keeps each person's last search for the tenant, the last eight people.
- **The mock:** the Phishing screen's strict `print messages` handler answers it too, for the terms it models
  (`rfc822msgid:`, `in:`, `from:`, `to:`, and `newer_than:`, a known lie: the fixture dates are fixed); any other term, a
  glob character, or a message whose headers the fixtures lack is not modelled. The canned pair of rows that answered
  every other `print messages` until 2026-10-19 is gone.
- **Not modelled, for the live check to tell:** Gmail's own search semantics beyond those terms.

## Chrome (slice 5)
After a takeover: does the person use Chrome signed in with their work account, and sign in to websites with it? What
that Chrome saved was within the attacker's reach. Two reads, nothing changes.
- **Chrome's log in Pull Incident Logs** (`ActivityApplication.chrome`, off by default): Chrome's own events, its
  warnings flagged (`PASSWORD_REUSE`, `PASSWORD_BREACH`, `UNSAFE_SITE_VISIT`, `MALWARE_TRANSFER`), each in words with
  its URL, the name signed in with, the computer and Chrome's result. No accounts typed reads the whole tenant's (`user
  all`). **An account is read both ways** (`GamCommands.ChromeMatch`, merged by `Row.identity`, each event once):
  - by the profile's account, `user all filter PROFILE_USER_NAME==<address>` ("GSuite user name of the profile");
  - by GAM's own `user <address>`, which doReport (:14790-14797) turns into `DEVICE_USER==<address>`: a Chromebook's
    account, but on a Mac or PC the computer's login name ("carol"), so alone it finds none of a Mac's events.
  Neither alone finds every event: ChromeOS sign-ins, data-protection events and extension requests carry no profile
  (Google's appendix, review 2026-10-21), and on a Mac or PC such an event names no account at all, so it shows only when
  every account is read (the log's `about` says so). Each read is its own; one that fails fails the log, one at the cap
  marks it capped. A row's person (`Row.who`) is the profile's account, else the actor, else the device's user.
- **Case and typos** (review 2026-10-21): GAM passes a filter as given, and Google may match it exactly, so the address
  goes lowercased (`GamCommands.filterAddress`: Google's address characters only, nothing a filter could read as more
  than the value), and the mock compares exactly. Chrome's per-account reads never fail for an address that isn't a
  user (no "Does not exist" path): they read none, as if nothing happened, so with Chrome picked Pull Incident Logs waits
  for the directory and checks typed accounts against it (other logs refuse such an address themselves). Each account's
  two reads run at once; an event the second repeats is dropped, never two alike in one read.
- **A person's Chrome profiles** (Users → a person → Security → **Check Chrome**; `ChromeProfileReads`, kept per person
  as the mailbox searches are): `print chromeprofiles filter user_email="<address>" fields … formatjson`
  (`GamCommands.printChromeProfiles`), the Chrome Management API's own field name (customers.profiles.list; GAM's wiki
  writes the same fields camel-cased), the address quoted and lowercased. Each profile's name, computer (hostname, else
  model), system, Chrome, last used, first seen, and whether the computer is the organization's (`AFFILIATED_…`). Never
  saved passwords: no API gives them.
- **What it needs:** GAM's "Chrome Management API - Profiles" scope (read-only is enough; authorized again from Setup's
  fresh setup) and managed profile reporting on in the Admin console's Chrome settings. With no Chrome Management scope
  at all GAM exits 15 before any request ("There are no scopes authorized for the API(s): Chrome Management API"); with
  another Chrome Management scope but not Profiles the API refuses, exit 50. Either is said in GAM's words, never "no
  profiles", and only those (exit 15 or a scope refusal) add how to authorize the scope (`ChromeProfiles.scopeNote`): an
  invalid filter or a timeout can't be fixed by a scope. **Empty is not "doesn't use Chrome":** the screen says reporting
  may be off.
- **The mock:** `report_chrome.csv` (carol@'s Mac: her profile's login to erp.example.net, her password typed on the
  phishing page, an extension request naming only "carol"; dana@ going past Chrome's phishing warning on her Mac, and on
  her Chromebook a failed sign-in and a breached password, the second found both ways; alice@'s login);
  `chrome_profiles.json` (carol@ on two computers, one the organization's; dana@ on one; alice@ none). The report handler
  models GAM's `DEVICE_USER` match and the app's `PROFILE_USER_NAME` filter, compared exactly, and refuses any other
  filter, a filter with a named user, and Chrome's `select`. `noscope/chromemanagement` is exit 15,
  `denied/chromeprofiles` exit 50.
- **Not modelled, for the live check to tell:** whether the API takes `user_email` with the address quoted (the API's
  list) or wants `userEmail` (GAM's wiki): the wrong one fails loudly (exit 50, invalid argument); whether Google
  matches a filter's case; whether Chrome's events carry an IP address (the mock's have none, so an `ip` keeps none);
  whether `actor.email` is set on them; which events this tenant reports at all (website logins and password events need
  Chrome's event reporting turned on).

## Apps and AI agents (slice 7)
Who has apps and AI agents connected, and what they did. Reads only.
- **Who acted, on every log row** (`ActivityLogs.Row.agent`, `.app`, `.via`): the Reports API says when an AI agent acted
  (`isAgenticAction`, `actor.agentAttributionInfo`: its name, type, ID and owner) and when an app acted for the person
  (`actor.applicationInfo`: its name, OAuth client ID, and whether it impersonated them). GAM's report prints them as
  columns; they're never parameters. Each row says it in words ("by the AI agent …", "through …"), and the CSV has a `via`
  column. The Admin console's exports call these "By an agent", "Agent info" and "Actor application info".
- **Every log GAM's report reads** (2026-10-21, "add any logs we are missing"): the ones above, and Gemini (on by default:
  an assistant an attacker can ask to search a mailbox), Meet, Contacts, Keep, Tasks, admin data actions, Access
  Transparency, Looker Studio, Groups (Cloud Identity), Profiles, Secure LDAP, directory sync, Google Cloud, Cloud Search,
  Classroom, data migration, Meet hardware, Assignments and Graduation. Not Currents (`gplus`) or Jamboard, whose services
  ended. The mock answers each, and capitalizes events where doReport does (REPORT_ACTIVITIES_UPPERCASE_EVENTS).
- **Connected apps** (`ConnectedApps`, `GamCommands.printTokens`, `ConnectedAppsRead`): `user P print tokens` in Check Account,
  and `print tokens` for every account but the suspended ones (GAM's default), which moved to its own row on Reports on
  2026-10-22 (a check of the whole tenant, not of an incident: [audit-reports.md](audit-reports.md)). Grants grouped by
  app: who granted it, what it may do in words (`describe`: all of Gmail, Gmail forwarding, all of Drive, admin and Cloud
  are broad), and whether its name looks like an AI assistant or agent (`looksLikeAI`: whole words, so "Promotion
  Manager" isn't Motion). AI first, then the broadest reach, then the most people. Revoking stays the lock's sign-out
  (every app at once) or the Admin console's App access control (an app for everyone).
- **Read the logs:** an app acting from a suspect address, and anything else a suspect address did as an account
  (Gemini, Drive, Contacts…), draft Secure Account; an AI agent acting for someone is said, and called out when the
  attacker had that account.
- **The mock:** `tokens.csv` (carol@'s Mail Sync Pro with all of Gmail, dana@'s ChatGPT and Read AI, Zoom for several, bob@
  suspended so left out of every account's read); `report_drive.csv` (a download through Mail Sync Pro from the attacker's
  address); `report_geminiinworkspaceapps.csv` (Gemini asked from the attacker's address, and an agent's action for dana@).
  `denied/tokens` is exit 12; an address that isn't a user is GAM's "Does not exist", 56.
- **Not modelled, for the live check to tell:** which logs carry `actor.applicationInfo` or agent attribution today, the
  agent types Google reports, and the Gemini log's parameters beyond `action` and `app_name`.

## Computers, and a device joined at a sign-in (slice 8)
An attacker's sign-in can register their own computer to the account (often a Windows "Virtual Machine", registered in
the same second as the sign-in), and the phones list never shows a computer. Reads only.
- **Check Account's computers** (`GamCommands.printDevices`, `Compromised.Computer`, `UserAccess.computers`): Google's
  endpoint management by the person's address. The `email:` search matches a prefix, so only devices whose users include
  the person exactly are kept, and only Windows, Mac, Linux and ChromeOS (phones are the phones list's). Each says what
  it is and is called, when the person first signed in to it (their own `createTime`: Google moves `firstSyncTime` at each
  registration) and last synced it, whose it is, its serial number, its state (blocked, wiped, waiting for approval), and a
  virtual machine (by model or maker: Hyper-V, VMware, VirtualBox, Parallels, QEMU and KVM, Xen, the clouds') or a
  compromised report in words. The findings count only those still signed in; one blocked or wiped stays listed until
  it's deleted, said as such. Block it, or take the account off it, in the plan ("Undo from the app" below).
- **The scope:** GAM reads devices as the admin through the service account, so domain-wide delegation needs
  `https://www.googleapis.com/auth/cloud-identity.devices` (GAM's default service account scope, or its `.readonly` form
  when the service account was set up read-only; Setup's check doesn't test it). Each cause has its own fix
  (`Compromised.Computer.note(for:)`), never "no computer", and the rest of the check reads as before:
  - "User: <admin>, Cloud Identity API - Devices Service/App not enabled" (73): the delegation, in the Admin console.
  - "API access Denied" (12): the service account's own list of APIs (in its file) lacks it, and GAM refuses before it
    asks Google, so delegating can't fix it: set the service account up again and import the folder. It wins when both
    are missing.
  - A dead key or a clock off is exit 12 too ("Authentication Token Error"): no scope note.
- **The Devices log in words:** `DEVICE_REGISTER_UNREGISTER_EVENT` is "Registered a device" (or unregistered, by
  `ACCOUNT_STATE`), with the device's kind, model and OS; a sync says so. Its `actor.applicationInfo.applicationName` is
  "Device", the device itself, so no app is said to have acted; a real app that synced it (Gmail's) is.
- **The Devices log's other events** (an action such as an account wipe, a property changed) say their own parameters
  beside the device, and a sync its warnings in words (not encrypted, no screen lock); never its identifiers.
- **Pull Incident Logs by address:** the Devices log has no address, so a pull by one would drop it whole. It reads the
  log's registrations instead (`DEVICE_REGISTER_UNREGISTER_EVENT`), for the accounts asked; its description says so.
- **Read the logs** (`deviceAtSuspectSignIn`): a device registered to an account from a minute before to ten minutes after
  that account's successful sign-in is tied to the sign-in nearest it, from any address, and said as the attacker's own
  when that one is from a suspect address, with Secure Account drafted. The Devices log carries no IP address, so only the
  account and the time tie them: a person's own new computer beside their own sign-in, an even tie, an unregistration, or
  one near only a failed sign-in, isn't one.
- **The mock:** `ci_devices.json` (carol@'s virtual machine registered the second after the suspect sign-in, her MacBook
  Pro and Pixel, alice@'s MacBook Air, and carol@example.com.au's PC that the prefix answers); `report_mobile.csv` (that
  registration and a sync, alice@'s Mac long before, dana@'s phone through Gmail's app). `noscope/devices` is exit 73,
  `denied/devices` exit 12, both before any argument, as GAM builds the service first.
- **Not modelled, for the live check to tell:** Google's `email:` matching for devices beyond a prefix; whether the
  device users attached are only the person's or every user of a matched device (the reader takes the person's own);
  whether Google fills a device user's `createTime` for an Endpoint Verification computer; the time format GAM prints for
  the times; how long a blocked device user stays listed; and how soon after a sign-in the Devices log records a
  registration.
- **Live check (L1d, read-only):** Check Account on an account with a known computer: the computers match the Admin
  console's Devices › Endpoints for that user; without the scope, the note. Pull Incident Logs with Devices for an
  account that just registered a computer: the registration is said in words.

## Apps Script projects (slice 9)
A script someone authorized keeps acting for them, on its triggers, for as long as that access lasts: an attacker can leave
one that reads or forwards mail. Reads only.
- **Check Account's Apps Script projects** (`GamCommands.printScriptProjects`, `Compromised.ScriptProject`,
  `UserAccess.scriptProjects`): the person's own standalone projects, Drive files of type `gscript`, the latest changed
  first, each with when it was made and changed and by whom, and whether it's in the bin. One made or changed in the two
  weeks before the check is called out, and the findings name those. The person can open one at script.google.com; one
  they don't recognise can be deleted from their Drive.
- **Exit 60 is "none" only on GAM's word:** printFileList exits 60 whenever it printed no row, which overwrites a
  failure's own code (Drive off, a refused token, a refresh error it drops without a word). So `ScriptProject.list` reads
  60 as no project only with GAM's "Got 0 Drive Files/Folders … for P…" (written once Drive answered; `show_gettings` is on
  in the app's fresh config) and no other line; anything else is said as a failure. Found by review before commit: the
  first cut read GAM's exit as 0 for none, and a fix by exit code alone would have read every failure as none.
- **What GAM can't show:** GAM has no Apps Script commands, so nothing here lists a project's triggers or deployments. A
  script bound inside a Sheet or Doc isn't a Drive file, and one in a shared drive isn't the person's, so neither shows;
  once authorized each is a connected app (slice 7), often named "Untitled project", and the lock's sign-out revokes it.
- **Not built:** a Read the logs finding for a script made from a suspect address. The Drive log's word for a script file
  (`doc_type`) hasn't been seen in a real log yet; add it once it has.
- **The mock:** `script_projects.tsv` (carol@'s "Inbox Helper" made at the incident's sign-in, an untitled one in the bin,
  an old timesheet script; alice@'s expenses script; none for dana@, GAM's 60 with "Got 0"). `nodrive/<user>` is Drive off
  and `quiet/<user>` a refusal with no word, both 60, as is an address that isn't a user. Any other `print filelist` is
  refused as not modelled.
- **Not modelled, for the live check to tell:** whether a revoked grant stops a project's triggers at once, and whether a
  real run puts anything but progress on stderr for none (which would read as a failure). Times are GAM's UTC with whole
  seconds on a fresh config (formatLocalTime), as the fixture holds.
- **Live check (L1s, read-only):** Check Account on an account with a known script: it's listed with its dates, matching
  the person's Drive filtered to Apps Script.

## Where each account stands (incidents plan, slice 1)
Read the logs opens with each account the attacker had and where it stands, read from the logs in time order
([docs/plans/2026-10-22-incidents.md](../plans/2026-10-22-incidents.md)). Nothing is typed: the "I know when the account
was locked" switch is gone. Reads only.
- **Who is a suspect** (`LogReading.marksAttacker`, from Google's real logs): Google's `suspicious_*`
  warnings, an account disabled as hijacked, and a sign-in it marked `is_suspicious`, unless that sign-in was proved with a
  passkey or security key (only when the account added no passkey in these logs before it: an attacker can enroll their
  own, security review 2026-10-22), or re-proves a session (`login_type` `reauth`) from an address the account signs in from
  unmarked. Every one of that attacker's sign-ins was a password one; the false ones were a passkey re-sign-in through a
  relay's address and a person re-proving themselves at the office. **Google's account warnings have no actor**: the
  account is `affected_email_address`, which `ActivityLogs.Row.who` takes for a sign-in log row with no actor (failure
  log 2026-10-22).
- **The lock** (`LogReading.status`): since the account's first event from a suspect address, the first password reset
  (`CHANGE_PASSWORD`, or the person's own `password_edit` from an address they signed in from before the attack; one
  from a new address may be the attacker's, review 2026-10-22), sign-out (`RESET_SIGNIN_COOKIES`, or Google's `user_signed_out_due_to_suspicious_session_cookie`)
  and suspension (`SUSPEND_USER`, or Google's `account_disabled_*`). A reset and a sign-out, or a suspension, is the lock;
  one half alone is *partly locked*, said with what's missing and Secure drafted. An admin's event done from a suspect
  address isn't a lock (an attacker with an admin's account), nor is a reset from before the attack, nor the attacker's own
  `password_edit`.
- **After it:** a sign-in from a suspect address is *still in* (the first finding, Secure drafted again); a failed one is
  the lock holding, said in the status. A sign-in from an address these logs didn't show before the attack is said, to
  check: attackers change addresses. A lock after such a sign-in is a new lock, read the same way, so securing again
  clears *still in* (review 2026-10-22: the first version read only the first lock, and said "still in" forever). No lock
  seen says why when the pull couldn't show one: pulled by an address (the lock is done from the operator's), without the
  admin log, or a lock that came before the window's first suspect sign-in (the window may start after the attack did).
- **What a lock leaves in place**, from a suspect address: `passkey_enrolled` and `blocked_sender` (the sign-in log; an
  attacker blocks the bounce address before a mass send, and the blocked address is `affected_email_address` there),
  `2sv_enroll` and the `recovery_*_edit` events (account changes), each said with how to remove it; the recovery ones
  draft Secure for its "Clear recovery email & phone" step. The same event from the person's own address is theirs: that
  is a rule on the address, never a guess.
- **Contacts printed during the attack** (`print_contacts` in the Contacts log, now on by default, between the account's
  first suspect event and its lock): said, with the count, as who gets the phish next. The Contacts log names no address,
  so only the time ties it to the attack.
- **Another app's session:** a SAML sign-in from a suspect address recommends signing the person out of that app too.
- **The admin log is read both ways** for typed accounts (`GamCommands.AdminMatch`, merged as Chrome's two reads are):
  what admins did to them (`report admin user P`, which doReport turns into `user all` with the filter `USER_EMAIL==P`,
  :14779-14788) and what they did as admins (`userisactor`). It is on by default now. A row's person is the admin who
  acted; its details start "to <account>".
- **The words carry no time of their own:** `Status.words(_:)` takes the caller's date formatting (the screen's
  abbreviated date and time; the tests' "minute N").
- **The mock:** `report_admin.csv`: alice@ (from 203.0.113.50) resets carol@'s password, deletes her backup codes, revokes
  Mail Sync Pro and signs her out at 15:05 on 2026-10-19, and reset bob@'s a week before. `report_login.csv`: the attacker's
  address added a passkey to carol@ at 14:21, blocked the bounce address at 14:30 and tried her old password at 15:20,
  after the lock; its `suspicious_login` has no actor, as Google's real rows have none, so a read of carol@ alone leaves it
  out (the strict guess). `report_contacts.csv`: carol@'s 312 contacts printed at 14:25. The admin read without
  `userisactor` never refuses an address (GAM reads `user all` with a filter); with it, a non-user is "Does not exist".
  The builder holds that read's accounts to `filterAddress`, as Chrome's filter is. A known lie, older than this slice
  (review 2026-10-22): with `select users` the mock prints each account's rows in turn, where GAM sorts them all newest
  first (`SortRows('id.time')`, :14948); the app's merges sort by date, so nothing here depends on it.
- **Seen in Google's real logs (read-only):** the lock as GAM ran it is `CHANGE_PASSWORD`, a
  `REVOKE_3LO_TOKEN` per app, then `RESET_SIGNIN_COOKIES`, within seconds, each naming the person in `USER_EMAIL`; the
  Admin console's reset adds `CHANGE_PASSWORD_ON_NEXT_LOGIN` beside `CHANGE_PASSWORD`; a person's own change is
  `password_edit` in both the sign-in and account changes logs.
- **Not modelled, for the live check to tell:** whether Google returns an account warning (no actor) to a read of that
  one account; the event names for exporting contacts beyond `print_contacts`; how far the admin log lags.
- **Live check (L1l, read-only):** on an incident, pull by the affected accounts over a window from before the
  attack: each status matches what was done and when (the audit log and the Admin console's admin log), and Google's
  "disabled the account: hijacked" appears in the taken-over account's own pull.

## The rundown: where each account stands, its timeline, what's left (incidents plan)
Read the logs opens with every account the attacker touched, each with its status and a timeline, then **Still to do**,
then the findings ("What the logs show"). Asked for after real logs were run through it (2026-10-22): the
first version gave a status only to accounts the attacker got into, and only its first reset and sign-out, so
accounts whose passwords were only tried showed no lock and still offered Secure, and several forced sign-outs on one
account read as one on a later day. Code decides what's done and what's left; the model only words it.
- **Every account touched** (`LogReading.read`): an event from a suspect address in the sign-in, SAML, OAuth or account
  changes logs (a sign-in, a failed one, Google's warning), or a password Chrome saw typed on a phishing site. Never a Gmail
  row's account (whose mailbox it is isn't certain). In the order each was first touched.
- **The status says each step at its own time** ("Locked: signed out by … at …, then password reset by … at …").
- **The timeline** (`Status.timeline`, `Moment`, at most 200): the attacker's sign-ins with how each got past Google's
  challenge (a prompt approved, a phone code entered, a previous password answered), failures, Google's blocks and the
  attacker's changes; the computer that joined at a sign-in; contacts printed; every admin step done to the account
  (each forced sign-out and reset, apps revoked in the same minute said once, recovery removed, suspended, unsuspended;
  `CHANGE_PASSWORD_ON_NEXT_LOGIN` folded into its reset); Google's disabling; the person's own changes, said with the
  address when it isn't one they used before the attack. An IPv6 address counts by its /64 (`LogReading.network`): a
  home's devices change the rest.
- **Still to do** (`Reading.toDo`, `Task`, most urgent first): secure an account not locked, secure it again after a
  sign-in past the lock, finish half a lock, pull logs again that stopped short of the attack (`Context.capped`: a log read
  for every account that hit its cap, with its oldest event), remove what the attacker added, clear recovery, unblock a
  sender, delete a computer, pull an email, sign out of another app, warn contacts or Chat recipients, treat exported data
  as taken, confirm a new address, check a password, look at what was done, check a shared address. An item leaves once
  the logs show it done: a lock, a device unregistered or blocked, wiped or deleted by an admin (`deviceWord`), recovery
  removed by an admin. An email to pull leaves once this app's audit log shows Phishing trashed it from every mailbox, or
  Phishing's Find showed nobody here has it, and is listed under Done ("Done from the audit log", below). What no log can show
  (a sender unblocked with the person, contacts warned by phone) is marked done by hand ("Marked done by hand", below). A
  finding about a locked account drafts no lock again.
- **The model** (`LogExplainer`): its prompt is what happened in time order (each moment's `plain` words, which leave out
  an app's or a device's name and a blocked address), each account's state and the steps done counted by kind, and each
  to-do item's fixed meaning by kind. It answers three sentences on what happened, two on what's done, and at most three
  on what's most urgent, each citing to-do IDs; one citing none is dropped, so it can't add a task. Tried on the real
  export (2026-10-22): the first prompt's answer listed one account's steps and repeated the to-do list; the time-ordered
  story gave a readable account, and a vague "undo what was left" task let it claim a passkey that wasn't there, so the
  leftover task is three kinds.
- **What may never count as done** (security review 2026-10-22): a lock from before the account's attack (an account
  phished through Chrome only is attacked from when Chrome saw its password, and with no attack time nothing is a lock); a
  suspension later undone; an admin step done through an account the attacker held at the time (statuses are read twice to
  know those); the person's password change from anywhere but the very address they used before the attack, or from a
  suspect's (a later sign-in is theirs by its /64 only when no suspect address shares it); a device's task cleared by
  another account's word or an action not done (that account's latest word decides); a recovery detail cleared by another
  detail's removal (the question is its own item). Two emails with one subject are two items. An account reaching a status
  or the model must be an address's shape (`isAccount`): a Chrome event's account is what the browser reports.
- **Live check (L1t, read-only):** pull an incident's logs by the affected accounts and check each timeline against the
  Admin console's admin and login logs for that account.

## Undo from the app: the attacker's computers, and Do It Here (incidents plan)
Asked for after the operator found three attacker computers still joined to accounts (2026-10-22): block them or take the
account off them from the plan, and a to-do item's fix one press away.
- **The writes** (`GamCommands.blockDeviceUser`, `deleteDeviceUser`): `block deviceuser <name>` and `delete deviceuser
  <name>`, the name exactly `devices/<id>/deviceUsers/<id>` (ids `[A-Za-z0-9_-]`, checked before any argv). A name is one
  computer's sign-in for one person; GAM acts on it without `doit` (that's for a query). Taking the account off is
  destructive (`minimumRisk`); a block is undone in the Admin console. GAM always prints a device user's `name` (and the
  print names it too); a name that fails the check leaves that computer unpickable, never the whole plan refused. `-` is
  never an id: it's the API's wildcard for every device.
- **The plan** (`Form.computers`, `Compromised.steps(computers:)`): each computer still signed in has Keep it, Block it or
  Take the account off it; its step comes after the send-as steps, and a check again after a run drops the picks of what's
  no longer active.
- **Do It Here** (`Draft.undo`, `Form.pickOnly`): a computer's and a recovery detail's to-do item opens Check Account for
  that person and, after the check, picks only that fix with the lock steps off (the lock is a to-do item of its own).
  The computer is matched by the Devices log's `RESOURCE_ID` as Google's device ID; one found that way but no longer
  signed in picks nothing. With no ID match, the computer first signed in within two minutes of the registration. When
  nothing matches, nothing is picked and the computers say so, to pick by hand. A pick waits only for its own check: a
  check by hand, another person, or a run going on drops it.
- **Done** (`LogReading.deviceWord`): the item leaves once the account's latest word on the device is an unregistration,
  a Devices-log block, wipe, unenroll or refused access that's `EXECUTED`, Google's "blocked by the admin", or the Admin
  log's `MOBILE_DEVICE_BLOCK`, `_DELETE`, `_WIPE` or `MOBILE_ACCOUNT_WIPE` for that device and account. Pending, sent to
  the device, a lock or a sign-out isn't gone; approved (either log) or registered again is back, from any address, and
  gone never counts from a suspect's. Names from the Reports API's references (failure log 2026-10-22, a guessed
  device-action status).
- **The scope:** these write through Cloud Identity's devices API, so the delegation needs
  `https://www.googleapis.com/auth/cloud-identity.devices` itself; the `.readonly` form reads but can't block.
- **The mock:** `block|delete deviceuser` builds the service first, as GAM does (`denied` 12, `badkey` 12, `noscope` 73,
  before any argument), then checks the name's shape (usage, exit 2), not found 56 ("Device User … Does not exist"), `refused/deviceusers` 50 ("Block Failed" / "Delete Failed"); a block
  makes the computer `BLOCKED` to the next print and a removal drops that person from it.
- **Not modelled, for the live check to tell:** whether the Devices log's `RESOURCE_ID` is Google's device ID (else the
  match falls back to time); what Google logs for a block or removal done through the API, and whether a Windows
  computer's block shows `EXECUTED` while the computer is off; how GAM words a scope refusal for a write.
- **Live check (L1u, a write: the operator's yes for each one):** block one attacker computer from the plan; the Admin
  console shows it blocked, and Read the logs drops it from Still to do. The operator's own Admin-console blocks of
  2026-10-22 check the Done rule first, read-only: read the logs again and the three should leave the list.

## That was them (incidents plan, moved up at the operator's ask)
A sign-in Google marked that was the person, closed as theirs: on a suspect address's finding, "That Was Them…" (or a
menu when it marked several accounts there) asks how the operator knows, and the mark is kept. Reads and this Mac only.
- **Files:** `Stores/KnownSignInStore.swift` (`known-sign-ins.json` beside the templates: domain, account, address,
  note, when; the signature store's descriptor reads and atomic `0600` writes; at most 500; one account and one IP address
  with a 1 to 500 character note, else refused in words, and a file holding anything else moved aside); `App/KnownSignIns.swift`
  (the screen's model, as `OnboardRoles` is); `App/LogReaderView.swift` (the button, the note sheet, Marked as Theirs with
  Undo). Tests: `StoresTests/KnownSignInStoreTests.swift`, `LogReadingTests.aSignInMarkedAsTheirsMakesNoSuspect`.
- **What a mark does:** `LogReading.Context.theirs` (`LogReading.key(account:address:)`): that account's sign-ins from that
  address make no suspect (the very address: a network may be a relay's or a VPN's, shared with the attacker), and it's never
  asked about as a new address after the lock. For that question only, an IPv6 mark counts by its /64 (`LogReading.network`),
  as the reader's other per-address rules do: a phone or a home keeps its network while the rest changes, and an exact match
  asked about the same phone again (2026-10-28, failure log "Still to do kept asking"). Never a network a suspect address
  shares: there only the very address (review 2026-10-28: a mark through a relay's /64 cleared the attacker's address). The
  address can still be one through anyone else's.
- **From Respond too:** "Ask … whether … is theirs" (`confirmAddress`, `Task.theirs`) has That Was Them… (a menu for several
  addresses), which marks the address with a note and answers it. A mark never counts toward the lock: a password change does
  only from the very address used before the attack. Only an account's own sign-in Google
  marked is offered, never its warning that it blocked one (review 2026-10-22), and the operator's own pulled-by address
  is never markable. A mark is never hidden: Marked as Theirs lists each with its note and an Undo.

## A kept incident (incidents plan, slice 3's record and evidence, first at the operator's ask)
Asked for (2026-10-23): something that works after the fact, because the app is rebuilt often and everything a pull found
was gone at each relaunch, and the Gmail log reaches back 30 days only. An incident is kept on this Mac with its details,
notes and every pull of the logs; open, its saved evidence is what the logs and Read the logs show, with no pull needed.
Reads and this Mac only: nothing here changes the tenant.
- **Files:** `Stores/IncidentStore.swift` (each incident a folder in `<Application Support>/SwiftGamGui/incidents/`, named
  by its ID, the day it was opened plus six hex digits: `incident.json` holds the title, opened (when it was identified,
  which can be before it was saved), by whom, how it was reported, and notes; `evidence/` holds one folder per saved read,
  exactly as Export All writes them); `App/Incidents.swift` (the screen's model; the open incident's ID, never its
  contents, is remembered in the app's defaults, so it opens again after a relaunch or a rebuild);
  `App/IncidentRecordView.swift` (the section at the top of Incident, and the details sheet). `ActivityLogs.rows(exported:)`
  and `Row(exported:)` read an export back; `IncidentLogs.evidence(_:)` puts an incident's exports together as one pull;
  `IncidentLogs.show(_:)` shows it. Tests: `StoresTests/IncidentStoreTests.swift`, `GamEngineTests/ExportedLogsTests.swift`,
  `DirectoryStoreTests/IncidentEvidenceTests.swift`, `CompromisedChangesTests.savedEvidenceReadsBackAsThePull`,
  `.aPullAddedToAnIncidentIsWhatReadingItBackGives` (in memory is the read-back) and `.aPullIsKeptBeforeItEnds`.
- **Make one:** New Incident…, or From an Export… (a folder Export All wrote: `about.txt` and a CSV a log, headed as the
  export heads it; other files are left out). Its files are read by descriptor, never through a link, each a regular file of
  at most 256 MB, and copied in byte for byte: the evidence is exactly what was exported, which is what to hand anyone. An
  export whose events have an actor and none at the connected domain is refused (one tenant's logs never go into another's
  incident). An incident opens only while connected to its domain.
- **While it's open:** each pull of the logs that read something is exported into its evidence before it ends (Export
  All's folder, named for when; `IncidentLogs.keep`, `Incidents.add`): only what was read from Google, never what's shown
  from the evidence again. It's then added to the evidence shown in memory (`IncidentLogs.adding`, the step reading the
  exports back takes for each), from the very text written, and the pull ends as that: the logs' tables, Read the logs
  (once), Still to do. No saved pull is read again (failure log 2026-10-23, "each pull re-read every saved pull"). Read
  back whole instead, as when an incident opens, only when that could differ: the evidence wasn't read yet or is being
  read, the new folder isn't last by name (an export added with a later name), or a cap would be reached
  (`IncidentStore.readsBackLast`). Under the logs: "Saving this pull to the incident…", then Read the logs' "Reading the
  logs…"; "Reading the incident's saved logs…" when one opens.
  Add an Export… copies another in; Show in Finder opens the evidence folder; notes take a time, which can be earlier than
  now ("told the insurer at 9").
- **Reading the exports back** (the export's own format, not GAM's): the export's CSV dialect has no escape (GAM's has a
  backslash: `CSVReader.records(_:escaping:)`), the `'` the export puts before a spreadsheet formula's lead is taken off,
  `via` splits back into the agent ("by …") and the app ("through …"), and the parameters split on " | ", a piece that isn't
  `name: value` joined back to the value before it (a subject can hold " | "). Not kept by the export, so not read back:
  Google's unique qualifier, and whether a value began with `'` before a formula's lead.
- **Put together:** rows newest first; the same event in two exports once (by its content, the qualifier being gone),
  every row of one export kept; the widest window, every account if any export was, the first address given; a log stopped
  at its cap only while every export of it was (a later read for just the accounts that matter reaches further back, which
  clears Still to do's "pull again"). An export that can't be read is named, the rest still shown.
- **Opening fast** (2026-10-24, asked for: an incident took long to open): saved logs are read back four at once
  (`IncidentLogs.readBackAtOnce`, invariant 9: each holds its CSV's whole table while read, and a file can be 256 MB),
  each on a core of its own, and all are put together once (`IncidentLogs.evidence`, async; `merged(_:)` over every pull,
  held to the old two-at-a-time fold by `pullsPutTogetherAtOnceAreThemAddedOneByOne`). The parameters cell is split on its bytes
  (`parameters(exported:)`, held to the Foundation reading by `theParametersCellReadsAsBefore`; it now also reads back a
  value beginning with a combining mark, which Foundation folded into the parameter before). Each log's flagged and
  account counts are made with it (`Log.flagged`, `.accounts`), never counted by the screen. Measured on 10 saved pulls of
  40,000 Gmail-shaped events (220,000 in all): Release 10.7 s → 2.6 s, Debug 25.3 s → 9.7 s (every log at once was 1.9 s
  and 5.8 s, holding a table a core); 200,000 events read back in 1.9 s Release (4.6 s before), 11 s Debug. **Measure in the build that runs:** Foundation's string searches are compiled optimized even
  in a Debug build and a byte loop isn't, so the splitter is 20× faster in Release but no faster in Debug. What's left is
  the shared `CSVReader` (GAM's output reader too, held to GamGUI's parsing: invariant 11), left alone.
- **Bounded** (invariant 9): 200 incidents, 500 notes each, 100 saved reads each, 256 MB a file and 1 GB an export.
- **Gotchas** (review before commit): a new incident takes the pull just made (else New Incident… after a pull lost it);
  showing the evidence waits for a pull still reading (`IncidentLogs.show` replaces the last pull, which drops one
  reading); an ID is never one kept already (a save over it would replace that record); a note's time is now unless
  changed. A saved pull is added in memory, not by reading every export again (2026-10-23).
- **Not built yet** (the plan's next): the tabs (Investigate, Respond, Report), a button on every to-do item and Select All
  for the logs, the incoming phish and an attack-anchored pull, who to warn and whether they were, the checklist and the
  report. Deleting a kept incident is the Finder's for now.
- **Live check (L3k, reads and this Mac only):** From an Export… on a real export: the logs, Read the logs and Still to do
  match what the pull showed; quit, rebuild and relaunch: the incident is open again with the same.

## Tabs, and a button on every to-do item (incidents plan, at the operator's ask)
Asked for (2026-10-23): the screen organized better, a button for each recommendation, and Select All for the logs.
- **Three tabs**, in the order an incident is worked (the standard's steps): **Investigate** (the order of work, Pull
  Incident Logs and the logs, What the logs show with Explain and Marked as Theirs), **Respond** (a run under way, Where
  things stand: where each account stands and Still to do, then Secure an account and Pull the email), **Report** (the
  incident's evidence and notes, then the checklist). The open incident's header is above every tab. A plan, a run, a
  Secure or Do It Here from anywhere, and Users' Secure Account… switch to Respond; Show the Events and Pull Again to
  Investigate. What a tab doesn't show is kept by the screen: the pull's form (`PullForm`), the narrowing, and the reader's
  reading and explanation (`LogReaderView.Memory`), so a change of tab loses nothing but a half-typed note.
- **Show the Events** on every to-do item that names an account (`LogReading.Task.shows`, a `Shown`): the account's events
  from the attacker's addresses (a lock to do), from the new addresses (one to confirm), or, for "See what …", only the
  app's, the logs' or the agent's. Investigate's logs narrow to them (`IncidentLogs.Filter`), said in words ("Showing only
  carol@example.com's events from 198.51.100.23, through Mail Sync Pro"), with Show All; each log's Export CSV then saves just
  those events.
- **Pull Again** on "pull … again for just …" (`Task.pullsAgain`, the logs that stopped short): those logs for those accounts
  (those in the directory, 20 at most) over the window shown. With an incident open the read is saved to it and everything
  saved shown; otherwise it's put together with the pull shown (`IncidentLogs.pull(adding:)`, `merged`): a narrower read
  never takes away what the wider one found. A read: nothing changes.
- **Select All:** the logs' list has All, Recommended (`ActivityLogs.incidentDefault`) and None.
- **One merge** (`IncidentLogs.merged`): an incident's exports and Pull Again's read are put together the same way: rows
  newest first, an event both read once (`identity`), a log at its cap only while both reads were, a log one read couldn't
  read taken from the other.
- **WriteRouteTests still hold:** only `LogReaderView.swift` names the reader (`LogReading`), so the reader draws both its
  parts (`LogReaderView.Part`: `.findings` on Investigate, `.toDo` on Respond) and hands the screen a `Filter` and log names,
  never its own types; the screen names `LogReaderView.Memory`, never the model's module.

## Done from the audit log (incidents plan, the checklist's first piece)
Asked for (2026-10-23): after Pull All trashed the attacker's emails, Still to do still listed
every one, so what was left couldn't be told. The plan's "a step already done shows done, with its time and who did it",
first for the emails pulled. Reads only: the audit log is read, never written here.
- **Done** (`LogReading.Pulled.isDone`, from `PhishingAudit.latestRuns`; phishing.md D13): the email's latest Phishing
  run ended trashed on every step it held for that email, and Find had searched every mailbox and its Spam for it. Respond
  lists it under **Done** after Still to do (`Reading.done`, "D1"): "Pulled “…” (id): trashed from the 2 mailboxes that had
  it, every mailbox searched first", then "Done <time> by <admin>, as this app's audit log shows". The check mark is
  beside those words, never alone, and VoiceOver reads the whole row. Pull All N Emails… counts only what's left
  (`Reading.emailsToPull`), and the finding on Investigate drafts no pull again.
- **Still to do, said in words** on the item: a step failed, a step never ended (a Stop, a quit, a run still going), or
  Find couldn't search a mailbox: "Phishing's last run by … trashed 2 of its 3 steps, but 1 failed: find it again there to
  see what's left."
- **Pure, as the reader is:** `LogReaderView.Memory` reads the audit log with the pull, off the main thread, and hands
  the reader values (`Context.pulled`) as it hands it events. Incident makes a new reading each time it opens, so coming
  back from Phishing reads the run; a second window left open on Respond doesn't, until Incident is opened again.
- **Nobody here has it** (phishing.md D14): an email Phishing's Find showed no mailbox has, every mailbox and its Spam
  searched, is done too, said as checked: "Nobody here has “…” (id): …", then "Checked <time> by <admin>, as Phishing's
  Find showed". Kept on this Mac (`NobodyHasStore`, through `NobodyHasChecks`), since a read is never audited. Unsure or
  unsearched stays to do. The latest of a run and a check decides. If the check can't be kept, Respond says so.
- **Never shown done:** a run made before this build that Find Again hasn't since shown gone, and anything done outside
  this app. The hand tick is for those.
- **Marked done by hand** (asked 2026-10-28: "I did that with her the other day, not sure why it still shows"): Mark Done… on a
  to-do item asks how it was done and keeps it with the incident (`IncidentStore.Record.ticks`: its kind and words, how, when,
  and the connected admin), applied where the reading is shown (`Reading.ticking`, cheap, so a tick never reads the pull
  again). It's listed under Done with how, when and by whom and an Undo, and in the report's What was done as "Done by hand",
  shown by the incident, beside what the logs show. Matched by kind, words and what the item stands on (`Task.basis`: for an
  item a finding points to, how many events and from where; for the warn item, exactly who's to warn), so once the logs say
  more (the attacker's second passkey, a different five to warn) it's to do again (review 2026-10-28: words alone didn't
  change). **Never on a lock, recovery email and phone cleared, a computer, or a read of the logs or the directory**
  (`Task.Kind.tickable`): Google's logs show the first three done whoever did them, and this app does the reads, so a tick
  could only hide a way back in or a list left unfinished; Respond says so. "Read the directory" (`readDirectory`) and the
  recovery question (`recoveryQuestion`, which no log shows) are their own kinds for that.
- `LogReaderView.swift` names `PhishingAudit`, a reader of the log: still no changes model or executor (`WriteRouteTests`).
- Tests: `LogReadingTests.anEmailPhishingPulledIsDoneWithWhenAndByWhom`; `PhishingChangesTests.theAuditShowsEachEmailsLatestRun`,
  `.theAuditSaysAFailedStepAndAnUnsearchedMailbox` and `.aRecordThatCantSayItsRunIsPassedOver`, on the records the
  executor wrote; `.findHandsOnWhatNobodyHas`, `.pullAllNeverCallsAnUnsearchedEmailClear`; `NobodyHasStoreTests`.

## Who it reached (incidents plan: who to warn, and whether they were)
Asked for (2026-10-24): "export a list of who it got out to and not bounced", then "Build the who-it-reached list for a
pulled email: every recipient from the sender's copy, delivered inside per Find, bounced per the bounce notices, warned per
a warning email I pick, with a CSV export. Reads only.", from the app, all in one place, "to double check we did all the
things". During the attack the list was made by hand from the Admin console's Gmail log events export (one row per
recipient per Event: Send, Receive, Bounced; `To (Envelope)`, `Owner`, `Message ID`), and the app reads that same log
through GAM for every part of the ask: the sender's copy is its Send (every recipient, Bcc too), delivered inside is a
mailbox's Receive, the bounce notices are its Bounced events, and the warning is another email's Sends and Receives.
Phishing's Find isn't the source: it shows who has a copy now, which after Pull is no one. Reads only: nothing is sent.
- **The source** (Google's "Schema for Gmail logs in BigQuery", which says `mail_event_type` is the Gmail log events' Event):
  `event_info.mail_event_type` 1 Send, 35 send begun, 2 Receive, 6 released from quarantine, 30 Bounced, 5 quarantined, 34
  rejected or slowed for too much mail, and `event_info.success` false; `message_info.flattened_destinations` every recipient
  as `service:selector:address`, comma-separated; `message_info.rfc2822_message_id` ties each to the email. The app names the
  field by its chain, as the real pulls show (`ActivityLogsTests.gmailsNestedParametersAreNamedByTheirChain`).
- **The principle** (second adversarial review, 2026-10-24): **over-warning is safe, under-warning the harm.** Everyone an
  email of the attacker's was addressed to or received by is to warn; only an address that bounced and isn't a person's
  mailbox here (outside, or no one's) is left out: a warning to it would bounce too. A quarantine, a rejection, a failed
  event, a bounce Gmail tried past (a later failure that isn't one wins), or a person here whose copy bounced keeps someone
  on. A warning counts only on the log's positive word: for a person here, the log's last word of it in their mailbox is a
  receipt (received, then quarantined, isn't; quarantined, then released, is); outside, or no one's mailbox, a send Google
  didn't mark failed naming them with nothing failing. Done needs that for everyone to warn, the directory read, and no
  entry unreadable nor send naming no one.
- **The list** (`LogReading.Reach`, worked out with the reading for each email the attacker sent, pure): every address its
  sends named (sends begun too), Bcc included, an alias or a plus-address (`alice+news@`) as its person (`people`, with
  Google's `nonEditableAliases` from the directory record), then any mailbox that received it unnamed or whose own
  quarantine or rejection names no one; each **received** (a receipt, whatever a retry's bounce says; a receipt Google marked
  failed is none), **bounced**, **quarantined or rejected**, **sent**, or inside **no one's mailbox here** (a group, or an
  address no account has, only with the directory read; a directory read empty is none). Inside: a domain a person has an
  address at, a directory address, or anyone with a receipt since the attacker's first email. A failure naming no one is a
  mailbox's own unless it's a sender's (then, and when its actor doesn't read, the whole email's). Addresses are read loosely
  (`LogReading.address`, on bytes for ASCII); an entry that isn't one is counted (`unreadable`), said, and keeps the to-do
  from done; a send naming no recipient (`unnamed`) does too. The model is never given any of it.
- **A group's members** (2026-10-27; before, a member whose Gmail log wasn't pulled was invisible and the group counted on
  the warning's send): a group here it went to (no one's mailbox, not bounced from) is read for its members
  (`GroupsReached`, GamGUI's `print group-members group <g> formatjson`, the builder the group page uses), then the groups
  among them, each once though groups hold each other, **at most 20 while the screen is open** (invariant 9); a read that
  failed, an address GAM finds no group at, and one past the limit aren't read again until the screen is left and opened
  again, and each is said under its email with why. A group read counts by its members (`Context.groups`, `.everyone`):
  each is listed after everyone the log names, through the group (`Recipient.via`), an alias as its person, GAM's CUSTOMER
  member as everyone in the directory; the group's own row (`expanded`) is neither warned nor to warn nor counted among who
  it reached. A person here among them needs their own receipt (and is pulled again without one); an outside member, or a
  group not read, counts on the warning's send to it or to a group read that holds it. The reading is asked once without the
  members and once with them (the group key joins the directory's, so, as for a directory change, "Reading the logs…"
  shows until the reading with them comes: `staleIsSafe`); while they're read, the first counts the group on the send, as
  it says, and the email's section says they're being read. A suspended member is listed like anyone (warning too many is safe).
- **Whose Gmail log the pull has** is read off the data: a person with a receipt of anything since that email went
  (receipts carry no address, so a read filtered by the attacker's address has none, and a merged pull is judged by what it
  holds), or a person a read holds whole past it (`IncidentLogs.Log.whole`, `Context.gmailWhole`: a read with no address filter
  holds every event of its accounts from its oldest event to its newest, or to where it was read through when it stopped at
  its cap; none for a read newest first to a cap, or a saved read whose `about.txt` doesn't say whose and from where; kept
  through the merge, worked out from the rows, never from a window the read claims; review 2026-10-28). Without that, every account's Gmail read whole still asked for quiet
  mailboxes (2026-10-28). A person here still to warn with neither is to pull again (`Reach.unread`); none while the directory isn't read, since
  a group can't be told from a person then and GAM refuses a whole read naming one: "Read the directory" is said instead.
  Investigate's narrow pulls (the person, the attacker's address) hold the phish's Send; who received it and the warning
  come with each recipient's Gmail log (Pull Again) and the warning sender's.
- **The warning:** code offers the emails an account here sent after it (type 1, not marked failed) to someone it reached,
  or that someone it reached received (a send to a group names the group, not its members), from an address that isn't the
  attacker's, by how many of them it went to: up to `candidatesShown` (100), the first 10 in **Pick the Warning** and the rest
  under More Emails Sent After It. One whose sender's Gmail log isn't in the pull can't be offered, and the menu says so. The
  pick is kept with the open incident (`IncidentStore.Record.warnings`, bare Message-IDs) and checked again at every reading:
  the attacker's own, one from before, one only begun or not in the logs read doesn't count, and says why. With none
  counting, warned is unknown, never "no".
- **To do and done:** one item across every email for each of these (asked 2026-10-28: one an email made five, "condense
  that to one list to warn like on the report page"): "Warn the N people the attacker's emails got to …", counted as Report
  counts (`IncidentReport.gotIt`: each address once, a bounce, quarantine or rejection not among them); "Pull the Gmail log
  again for …" (Pull Again, Gmail only, 20 at a time) for every email's `Reach.unread`; and the directory not read. A pick that
  doesn't count, unreadable entries and a send naming no one stay each email's own. An email is done once everyone it got to
  is shown warned, said "Warned everyone … got to: N people" (Who it reached's own lists keep over-warning: bounces stay on
  them). Done names every warning that counted and
  reached someone, with the latest one's sender and time, and how many of those reached are a group whose members weren't
  read or an address no account has, which count on the warning's send as outside does (a group read is its members).
- **Where:** Respond, a section per email under Where things stand (`LogReaderView`'s `ReachSection`): a line in numbers,
  every address (300 shown; what's still to warn stands out and says "to warn"), the warnings picked and whether they count,
  **Export CSV…** (`Reach.columns`: address, where, reached, when, warned, to warn; private 0600, off the main thread, in
  `LogReaderView` since only it may name the reader). A pick added keeps the last reading on screen, its email's section
  saying "Updating…" (`reachKey`, `picksChanged`); a pick cleared, or the directory changed, shows "Reading the logs…" until
  the new reading comes (`staleIsSafe`: an old reading could show someone warned who isn't); after a clear, VoiceOver hears
  it back. One reading runs at a time: a pick while one is under way waits for it, the newest asked only (`Memory.queued`),
  and the one that ends shows only where `staleIsSafe` allows; one no longer wanted (the reading shown asked again) ends
  unshown. A directory revision that changes no address keeps the key (`DirectoryIndex`).
  Two passes: the attacker's emails and the picks, then only the emails here after the first that went to, or were received
  by, someone those reached, each once; recipients read on their bytes in place (`memchr` for the commas: walked as an
  array, a Debug build spent most of a reading there), each ASCII address text read once per reading (strings compare by
  canonical equivalence, so text beyond ASCII is read each time and keeps its own bytes), a warning's reach worked out only
  for a pick, and of candidates sharing a count only the earliest kept, never all of them sorted. Measured on 300,000 Gmail events among 1,000 people, best of three, by a
  scratch program linking only `Assist` (a Release test bundle takes most of an hour to build), Release then Debug: no email
  of the attacker's 0.14 s, 0.82 s; one to 50 of them 0.54 s, 1.77 s (4.9 s Debug before); one to all 1,000 1.43 s, 3.9 s
  (10.1 s Debug before). `LogReadingTests.whoItReachedIsReadInSeconds` holds the shape in thread CPU time.
- **Known limits:** a group whose members can't be read (GAM's failure, or past 20 groups) still counts on the warning's
  send, and Done says how many did. Members are read as they are now, not as they were when the email went. The receipt
  rules rest on
  Google's schema and the mock's rows (a Receive's actor is the recipient, with no IP), not yet on a live row (L3w). A build
  from before this one, saving an incident, drops its picks (its writer doesn't know them; bumping the format would make it
  set the whole incident aside instead). A Details save writes onto the record as kept now, so a pick made in another window
  stays.
- Tests: `LogReadingTests.whoThePhishReached`, `.whetherTheyWereWarned`, `.whatTheLogsShowAndWhatTheyCant`,
  `.whatTheThirdReviewFound`, `.whatTheFinalReviewFound`, `.whoAGroupReached`, `.aGroupNotReadCountsOnTheSend`,
  `.whoItReachedIsReadInSeconds`, `IncidentStoreTests.theWarningsPickedAreKept`,
  `GroupStoreTests.theGroupsAnEmailWentToAreReadWithTheGroupsInThem`, `.pastTheLimitAGroupIsSaidNotRead`.
- **Live check (L3w, reads only):** on the real incident, Who it reached for the phish against the list made from the Admin
  console's export on 10-19 (recipient, where, bounced): the same addresses, the same bounces; and a Receive row's actor and
  IP, and a domain alias in `nonEditableAliases`, as the rules assume; and a group it went to listed by its members, with
  a nested group's and the "Does not exist" wording and exit code the mock assumes for an address that isn't a group.

## Narrow first, and how far a wide read gets (incidents plan, slice 7)
Asked for 2026-10-24 ("Investigate leads with the narrow pulls … and an every-account pull says up front how far it will
get"), built 2026-10-27 after watching the operator's 30-day pull: every account's Gmail, a day at a time, 1,000 events a GAM
call, is hours on a large tenant ("with a larger tenant it would take days"). Reads only.
- **Each attacker address, across every account** (`LogReading.Task.Kind.sweep`, `Task.sweeps`): a to-do item for each address
  the reader found suspect (`acting`: never one set aside as shared, an office or a VPN), with **Pull Every Account From …**:
  the recommended logs, every account, that address, the window shown (`CompromisedView.sweep`). Google filters on the address
  before it reads, so the read stays small at any size: whom else it signed in to, sent from or changed. Code finds the
  addresses; the model only words the item ("read every account's logs from the attacker's address").
- **Done** (`Context.swept`): once a saved read of the open incident read every account from that address, as its `about.txt`
  says (`IncidentLogs.sweptAddress`, by `About`; "Accounts: every account." must be said), never the merged query, which keeps
  only the first address; or the read shown, when it isn't the evidence. So an address is never swept twice.
- **How far a wide read gets** (`IncidentLogs.Estimate`, said in the log's progress line while it reads): from a log's first
  read of the whole window when it comes back full, the events an hour over that read's span (its newest, so the time of day
  sways it) and that read's time; then how much of the window, oldest first, the bounds (`cap` a read, `readsPerDay`,
  `readsPerLog`) read whole, in how many reads and minutes: "About 900 events an hour: it will read the oldest 9 days of the
  30 days whole, in about 200 reads (about 7 minutes), then stop. Narrow it (an account, or the attacker's address) to read it
  all." Too busy for even a day says so. The operator's real 30-day Gmail (about 900 an hour) stopped after about 9 days.
- **Not built** from the plan: a wide read waiting with Read the Oldest N Hours and Narrow Instead (it's said, and it reads);
  reading several days at once and more events per GAM call (each a speed-up for the wide read, not a change of its scale).
- Tests: `AssistTests/NarrowFirstTests.swift`, `IncidentEvidenceTests.whichAddressAReadOfEveryAccountWasFrom`,
  `.howFarAWideReadWillGet`.
- **Live check (L1n, reads only):** on the real incident, Pull Every Account From the attacker's address: it ends in seconds
  to minutes, its item leaves Still to do, and a 30-day every-account Gmail pull's estimate is near where it stops.

## Where it started (incidents plan: the incoming phish)
Asked for (2026-10-27): the operator's account was that a vendor was compromised, their designer fell for an email from it,
and the attacker then sent as the designer; "trace the vendor's email that started it". Investigate's section under the
findings. Reads and this Mac only.
- **The candidates** (`LogReading.wayIn`, `WayIn`, pure): the first account the attacker got into (`attackerGotIn`, earliest
  `attackedAt`: a password typed on a phishing site counts, as Chrome saw it), and the emails its mailbox received (Gmail
  `mail_event_type` 2 or 6, not marked failed) from a sender outside the tenant's domains in the `wayInHours` (72) before that,
  newest first, at most `wayInShown` (50), each with everyone here the logs read show receiving it. A receipt naming no sender
  is counted, never listed. Two passes over the Gmail events. Code lists them; only the operator says which it was.
- **The sender:** `message_info.source.address`, else `.from_header_address`: GAM keeps a nested messageValue parameter whole
  (`purge_parameters` False, GAM 7.48.34 :14865-14899) and flattens it, so the reader's name chain reads it one level below
  `message_info`. The names inside `source` are Google's Gmail log schema's, not yet seen on a live row (L3o).
- **That's the Phish** (kept as `IncidentStore.Record.phish`, a bare Message-ID, since 2026-10-27; a file without it reads;
  `Incidents.pickPhish`): the pick shows with its sender, when it came, and who else here received it ("they may have fallen
  for it too"), with Pull from Every Mailbox… (Phishing, previewed there) and Not This One. A pick outside the window is still
  shown; one no one here is shown receiving says so, with what to pull. It's a line of the reading's key ("phish <id>",
  `reachKey`): picking keeps the last reading on screen until the new one comes, as a warning pick does.
- **In the report:** a Where it started paragraph before What was done, "Got the email that started it" (who here received
  it, those the attacker touched marked), and the review agenda's "How they got in" naming it.
- **Named WayIn, not Origin:** `WriteRouteTests.noIntentReachesAWrite` holds that no model-side screen names ChangeCore's
  `Origin`; a reader type called that failed it (2026-10-27).
- Tests: `AssistTests/IncidentWayInTests.swift`, `IncidentStoreTests.theEmailThatStartedItIsKept`,
  `ActivityLogsTests.gmailsNestedParametersAreNamedByTheirChain` (the mock's vendor receipt). The mock: the vendor's email to
  carol@ and alice@ on 10-19 before the attack, an outside newsletter, a colleague's email and an email from four days before.
- **Live check (L3o, reads only):** on the real incident, pull the designer's Gmail log from 3 days before the attack:
  Where it started lists the vendor's email with its sender (the field names `message_info.source.address` hold), and who
  else received it matches the Admin console's Gmail log search for its Message-ID.

## The report (incidents plan, slice 4, moved up at the operator's ask)
Asked for (2026-10-27, a week after the takeover): "a nice report I can run on the incident and export", drilling into its
numbers ("like who does not have 2 factor on"), who was emailed, bounced and reached, verifying "someone from here contacted
them", and "due diligence … the logs to support it and the records we need", then the review meeting, its lessons learned and
the plan going forward. Report's first section, once the incident's logs are read. Reads and this Mac only.
- **Files:** `Assist/IncidentReport.swift` (pure: `make` from the reading, the audit log's changes, the record, the evidence and
  the directory's 2SV; `text` the whole report as plain text; `agenda` the meeting's), `App/IncidentReportView.swift` (the
  section, a count's list sheet, the review sheet, Export Report…, the PDF), `LogReaderView`'s `.report` part (only it names
  the reader: it makes the report, at most once for each change of what it's made of, `Memory.report`), `IncidentStore.Review`
  and `copyEvidence`. Tests: `AssistTests/IncidentReportTests.swift`, `IncidentStoreTests.theReviewIsKept`,
  `.theEvidenceIsCopiedWithItsFingerprints`.
- **In numbers:** every number is a button that opens its list (a table, Export CSV…): accounts touched and those not locked;
  the attacker's emails (a row each); **everyone they got to**, once each, and those outside; still to warn, warned,
  contacted from here after, and still to warn with no contact seen; with the directory read, accounts touched and people it
  got to here with 2-Step Verification off (Reports' "No 2-step verification": active, not enrolled); emails pulled; steps
  taken; still to do. No bounce is a number of its own (the operator, 2026-10-27: "if it bounced, they did not get it").
- **Everyone it got to** (`IncidentReport.gotIt`, asked 2026-10-27 after many emails of one subject made the lists messy: "a
  clean way to know who actually got a message and needs to be warned", and "a list that can be imported so we can send the
  email either way, even if we did warn already"): each address once, however many of the attacker's emails got to it: a
  receipt here, or a send nothing in the logs read says failed (outside, a person here whose Gmail log isn't read, a group
  here not read). A bounce, a quarantine or a rejection didn't get through; a group read is its members. It's still to warn
  when a warning that counts isn't shown reaching it for any of them, warned when it is for all, and its first contact from
  here is the earliest. On Respond above Who it reached, with **Copy Addresses** (comma-separated, for a Bcc) and **Export
  for Import…** (the CSV's first column is `Email`, for a mail merge or a contacts import), and as the report's "Got an email
  of the attacker's". Who it reached's own lists, bounces too, are unchanged: over-warning stays its rule for to-warn.
- **Contacted from here after** (`Reach.Recipient.contacted`, two more CSV columns on Who it reached too): the first email an
  account here sent, from an address that isn't the attacker's, that reached them after the attacker's (by its send naming
  them, or their mailbox's receipt; for one that isn't a mailbox here, through the group it was listed by), and how many.
  Any email, picked or not, so it never makes anyone *warned*: that still takes the warning picked.
- **What was done** (`Action`, oldest first, each with what shows it): an admin's steps to each account and Google's own
  (the timeline's, from Google's Admin and sign-in logs); the changes this app's audit log shows it ran to an account touched
  or a person here reached, since the attack (ended steps only; Phishing's trash steps are said once a email, as pulled);
  emails pulled; each warning that counts (the Gmail log); the notes. The app's record and Google's side by side are what to
  hand anyone. The audit log is read with the reading, off the main thread, newest first, stopping at the attack.
- **The review** (`IncidentStore.Review`, kept in `incident.json` since 2026-10-27; a file without it still reads): type,
  severity, the meeting's time and who attended, how they got in, what went well, what to do better, and the plan going
  forward (a line an item, with who and by when). The meeting's agenda is filled from the numbers.
- **One document, three formats** (asked 2026-10-28: "ensure we can create the MD and a PDF too"): `IncidentReport.blocks`
  (title, headings, lines, items, the timeline as a table, the fingerprints fixed-width) is drawn as text (`text`), Markdown
  (`markdown`) and the PDF (`IncidentReportView.pdf`, Core Text from the blocks, so it no longer guesses headings from a rule of
  `=`), so the three always say the same. In the Markdown every piece is escaped (`markdown(escaping:)`): the inline marks
  anywhere, a list's dash or number and a heading's `=` at the start, leading spaces dropped; a subject an attacker wrote is
  its words, never a link, an image, HTML, a heading or a list. A URL stays as written (its text is its target).
- **The summary** (asked the same day: "can we get the model to help generate the report"): at the report's top, typed or
  drafted (`IncidentStore.Review.summary`, `summaryDrafted`; a summary alone isn't a review written). Draft with the On-Device
  Model is the log reader's rundown (`LogExplainer.summary`: the same facts, plus what's done, hand ticks said as such but never
  how, and the report's numbers), as paragraphs without the to-do IDs. A sentence holding a number written nowhere in the
  facts (digits of any script) is dropped and counted, as a point citing no to-do item is. Coarse: the facts hold times and
  addresses too, so a small wrong count can pass; the sheet says to check the draft against the report. The draft fills the editor; nothing is kept until Save, and the
  report then says it was first drafted by the model and checked. Only `LogReaderView` names the model (`WriteRouteTests`): it
  hands the report the draft as a closure.
- **Export Report…** (a new folder, never an existing one: `0700`, files `0600`; a failure removes it): `Incident report.pdf`,
  `Incident report.md`, `Incident report.txt`, `who-got-it.csv` (everyone it got to,
  once each), `who-it-reached.csv` (every email's every address, bounces too), `emails.csv`, `accounts.csv`,
  `steps-taken.csv`, `still-to-do.csv`, `emails-pulled.csv`, `timeline.csv`, `evidence/` (every saved read copied by
  descriptor, never through a link) and `evidence-sha256.txt` (each file's SHA-256, listed in the report too, to show the
  evidence unchanged). Times in the report say the Mac's time zone.
- **Coming back reads nothing again** (asked the same day: "it still takes a bit to read the logs when we already have
  one"): Incident's reading is kept by the window (`ContentView`), not the screen, so leaving Incident no longer forgets it,
  and an incident's saved logs are read from disk once per opening (`Incidents.shownKey`). What would make it different reads
  again: a new pull, a mark, a pick, the directory, a group read, or the audit log's size or time
  (`LogReaderView.auditStamp`, looked at when the screen appears and after a run), so a Phishing run or a Secure here still
  shows. The groups read are kept too; only a read that failed is tried again on leaving (`GroupsReached.forgetFailures`).
- **Not built:** the sign-off (slice 5's Close Incident).
- **Live check (L4r, reads and this Mac only):** on the real incident, Export Report…: the PDF opens and reads in order, and
  the Markdown reads the same in a Markdown viewer;
  who-it-reached.csv matches Who it reached and the 10-19 list made by hand; `shasum -a 256` of an evidence file matches
  evidence-sha256.txt; leave Incident and come back: no "Reading the logs…".

## Log reader (Read the logs)
Under Pull Incident Logs once a pull has ended: what the logs show, by rules in code, each finding with the fixes it
points to, and on request the on-device model's explanation. Plan and rules: docs/plans/2026-10-19-on-device-log-reader.md.
- **Files:** `Assist/LogReading.swift` (the rules, the findings, the drafts; pure), `Assist/LogExplainer.swift`
  (FoundationModels: a guided `Answer`, the citation filter, availability in words), `App/LogReaderView.swift` (the
  section; rows become `LogReading.Event`s there). Tests: `AssistTests/LogReadingTests.swift` (a stand-in model; CI has
  none), `WriteRouteTests.theLogReaderCanRunNothing`.
- **A fix is a hand-off, never a change:** Secure sets this screen's `requested` (the same path as Users' Secure
  Account…: a new form, checked, nothing ticked); Pull … from Every Mailbox opens Phishing with the Message-ID (and
  Respond's Pull All N Emails…, with two or more, opens it with every one, a line each: phishing.md D12), which
  finds who has it (its dry run, a read). Each screen's preview and confirmation are where anything changes.
- **Only mail sent is pulled** (2026-10-23, failure log "Every Gmail event read as a send"): every Gmail event is
  `delivery`, and its `event_info.mail_event_type` says what happened (Google's appendix "Gmail Activity Events"; GAM's
  `gmaileventtypes` reads the same field). A pull is drafted for 1 (sent) and 35 (send begun) only; what the attacker
  viewed (31), opened (7), drafted (29) or trashed (13) from their address is the person's own mail. Each Gmail row says
  its type in words (`ActivityLogs.gmailWords`, Google's 36 types); an event with no type is "A Gmail event", never a send.
- **Gotchas:** `LogReaderView.swift` is model code to `WriteRouteTests`: it may not name the executor, a changes model,
  `AppServices` or a confirmation, even in a comment, and the screens it sits in may not name `Assist` or the model's
  framework. The model's answer is shown as the model's, beside the findings it cites; the findings and drafts are code's.
- **Live check (L1r, read-only):** on this Mac with Apple Intelligence on, pull an incident's logs and Explain: every
  point cites a finding shown, and nothing names an account or address the findings don't.

## Next
- The live checks L1, L1c, L1d, L1r, L1s, L1l, L1t, L1u, L2 and L2p.
- The live checks of 2026-10-27's slices: L4r (the report's export), L3o (Where it started's sender fields), L1n (Pull
  Every Account From, and a wide read's estimate).
- After any change to Still to do: a run through Respond on a real incident a week in, each item read against what was
  actually done (failure log 2026-10-28: made-up incidents never showed a week of real use).
- **Ask the operator which items T10 to T14 were** in that run (2026-10-28: "should have been in the logs already"). They rank
  after the address questions, so likely `look` or `checkShared`: if the logs the pull holds can answer one, that's a rule to
  add rather than a tick.
- **A read that fails partway says so** (seen 2026-10-27): `IncidentLogs.complete` stops at a failed read and returns what it
  had with `through`, dropping the error, so the log reads as stopped at its bound. The operator's 30-day every-account Gmail
  stopped at the window starting Oct 6 after about 90 reads (under the 200 bound), with no reason on screen: keep the
  failure and say it beside Read the Rest.
- **Picture Pull Every Account From:** the Still to do snapshot (`compromised-todo`) ends at T2, before it.
- **The wide read's own speed-ups** (each a constant factor, not its scale): read several days of one log at once, and more
  events per GAM call (`maxactivities` past 1,000 needs `GamRunner.outputCap`, 8 MB, raised: a Gmail event is about 2 KB).
- The rest of [docs/plans/2026-10-22-incidents.md](../plans/2026-10-22-incidents.md): a pull anchored on the attack, watching
  and the sign-off, Look for Trouble.
- Not built (the plan says why): 2SV off, suspend, deleting forwarding addresses, a signature check.
