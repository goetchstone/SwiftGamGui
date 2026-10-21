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
   vacation` (an attacker's auto-reply phishes everyone who writes) and `print mobile query email:P` (a phone that syncs
   the mail may be the attacker's; shown, not changed: the wipe is the Admin console's). Each failure is said
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
| `user P print forward` | 8003 | printShowForward: `User,forwardEnabled,forwardTo,disposition` |
| `user P print forwardingaddresses` | 7997 | printShowForwardingAddresses: `User,forwardingEmail,verificationStatus` |
| `user P print sendas verifyonly` | 8297 | printShowSendAs: each signature a bool with `verifyonly` |
| `user P delete sendas S` | 8293 | deleteInfoSendAs: an <EmailAddressEntity> split on commas and whitespace |
| `print admins user P` | 1579 | doPrintShowAdmins: PRINT_ADMIN_TITLES; `_SEED_ADMIN_ROLE` is Super Admin; no group roles without `recursive` |
| `user P delete delegate D` | 7919 | processDelegates: Gmail's notFound for one they don't have, exit 50 |
| `info user P fields …recoveryPhone,isEnforcedIn2Sv…` | 5780-5810 | USER_FIELDS_CHOICE_MAP |
| `user P show vacation`, `user P vacation off` | 8283-8286 | GamGUI's builders (Users' auto-reply), held to argv.json |
| `print mobile query email:P fields resourceid,… formatjson` | 4555-4562 | doPrintMobileDevices: CSV `resourceId,JSON`, the row written from `resourceId`; _validateDeviceQuery; a refusal ClientAPIAccessDeniedExit, exit 12 |

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
send-as addresses gone, IMAP and POP off. Mark the README rows confirmed.

## Leftover drafts (slice 4)
A taken-over account can be left with thousands of drafts, and phishing batches Google blocked leave drafts anyone
signed in can still send. The operator: "I just need to clear the drafts on their own."
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
The operator, during an incident: does this person use Chrome, signed in with their work account, and do they sign in to
websites with it? Two reads, nothing changes.
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

## Log reader (Read the logs)
Under Pull Incident Logs once a pull has ended: what the logs show, by rules in code, each finding with the fixes it
points to, and on request the on-device model's explanation. Plan and rules: docs/plans/2026-10-19-on-device-log-reader.md.
- **Files:** `Assist/LogReading.swift` (the rules, the findings, the drafts; pure), `Assist/LogExplainer.swift`
  (FoundationModels: a guided `Answer`, the citation filter, availability in words), `App/LogReaderView.swift` (the
  section; rows become `LogReading.Event`s there). Tests: `AssistTests/LogReadingTests.swift` (a stand-in model; CI has
  none), `WriteRouteTests.theLogReaderCanRunNothing`.
- **A fix is a hand-off, never a change:** Secure sets this screen's `requested` (the same path as Users' Secure
  Account…: a new form, checked, nothing ticked); Pull … from Every Mailbox opens Phishing with the Message-ID, which
  finds who has it (its dry run, a read). Each screen's preview and confirmation are where anything changes.
- **Gotchas:** `LogReaderView.swift` is model code to `WriteRouteTests`: it may not name the executor, a changes model,
  `AppServices` or a confirmation, even in a comment, and the screens it sits in may not name `Assist` or the model's
  framework. The model's answer is shown as the model's, beside the findings it cites; the findings and drafts are code's.
- **Live check (L1r, read-only):** on this Mac with Apple Intelligence on, pull an incident's logs and Explain: every
  point cites a finding shown, and nothing names an account or address the findings don't.

## Next
- The live checks L1, L1c, L1r and L2.
- Not built (the plan says why): 2SV off, suspend, deleting forwarding addresses, a signature check.
