# Audit and Reports

**One line:** two screens ported from GamGUI, read-only but for Inactive users' Suspend these…. **Audit** shows this app's audit log on this Mac (every change, and
every read run from the Builder, each naming its domain), 25 records a page, searched and narrowed to failures and to one
domain, with GamGUI's CSV export; it runs no `gam`. **Reports**
lists GamGUI's directory reports from the loaded directory, reads the storage and mail usage with one
`gam report users` walk, and (new to this app) every account's connected apps and AI agents with `gam print tokens`,
counted by code, worded on request by the on-device model; and GamGUI's audit runs (plan F3), fixed lists of reads run when
asked, with Stop between steps.

**Owns invariants:** #9 (the log is read a page at a time; the usage output is refused past the runner's
cap and only the top 25 kept), #11 (the page, the filter, the CSV bytes and the usage parsing are GamGUI's,
held to fixtures), #4 by not widening it (the screen shows records as they were written, already masked),
#10 for the connected apps' wording (the model is given counts only and reaches no change), and the tenant
generation for the usage report and the apps.

**Enforcement home:** `Tests/ChangeCoreTests/AuditScreenTests.swift` (`audit_screen.json`), `AuditLogTests` (`audit.json`: a
record's domain, and `reads`, the read record), `BuilderReadTests` (a read recorded end to end), `WriteRouteTests.theReadRecordIsNoWritePath`,
`Tests/DirectoryStoreTests/UsageReportTests.swift` (`usage_report.json` and the strict mock),
`Tests/GamEngineTests/MockReportTests.swift` (the mock's `report users`), `Tests/GamEngineTests/ConnectedAppsTests.swift`
and `CompromisedChangesTests.everyAccountsConnectedAppsAreRead` (the apps' summary, from the mock's `tokens.csv`),
`WriteRouteTests.theConnectedAppsPanelTalksToNoModel`; for the audit runs `Tests/DirectoryStoreTests/AuditRunsTests.swift`
(`audit_runs.json`), `AuditRunnerTests`, `InactiveSuspendTests`, `Tests/GamEngineTests/MockAuditRunTests.swift` and
`WriteRouteTests.anAuditRunIsNoWritePath`; for the named reports run on Reports `AuditRunsTests` (`audit_runs.json`'s `named`),
`Tests/DirectoryStoreTests/NamedReportRunTests.swift` (end to end on the mock) and the bare reads in `MockAuditRunTests`.

## Reports: domain-wide reads (named reports)
GamGUI #151 (roadmap 3.1, merged as `2286631`), ported in F2 (plan 2026-11-19). Nine reads the Builder already runs, named on
Reports with the access each needs: licenses, shared drives, their permissions and organizers, org units, mobile devices,
group memberships, data transfers and Google's alerts (`NamedReport.all`, GamGUI's `NAMED_REPORTS` in its order).
- **No builder of their own, and nothing runs on Reports.** Each pane's Open in the Builder opens that catalog read
  (`ContentView.builderCommand` → `BuilderView.requested`), where it runs, filters and exports like any read.
- **Named by grammar, not by id** (`NamedReport.command(in:)`): the syntax up to its first option, matched in bytes, wanting
  exactly one runnable read; a GAM bump that renames one or makes it ambiguous fails `NamedReportsTests`, and the pane says
  "GAM <version> has no single command for this read" rather than open another.
- **The access, from GAM's own tables** (`gamlib/glapi.py` at 7.52.04, checked against GamGUI's 7.52.03 reading): licenses,
  org units, mobile devices, group memberships and data transfers use the **admin token** (`_CLIENT_SCOPES`); the shared
  drive reads and the alerts use the **service account** (`_SVCACCT_SCOPES`). An admin-token row says whether `oauth2.txt`
  records the scope or its `.readonly` form (`adminScopeHeld`), from the scopes Check access read
  (`SetupModel.connectedAdminScopes`, so no Touch ID per page); unknown is said as unknown, never "held". A service-account
  row says whether Setup asks for the scope, since only GAM's own check sees delegation: verified with the others
  (`DelegationScopes.scopes`), or offered on Setup's link and never verified (`DelegationScopes.offered`, GamGUI's
  `OPTIONAL_DWD_SCOPES`: the devices scope and the Alert Center's `apps.alerts`), so a domain without it stays connected and
  only that read is refused. A failed Check Access shows Setup's own link, never GAM's: GAM's names only the checked scopes
  with `overwriteClientId=true` and would drop the offered ones (`AccessCheck.linkingEveryOfferedScope`, GamGUI's
  `_with_every_scope`).
- **Run on Reports too, so it can be scheduled** (plan F7a, GamGUI #178): see "Named reports run on Reports" below. The pane's
  Run or Schedule It Here (⌘⇧R) opens that run. The named `shared_drive_acls` is "Shared drive members", never the audit run's
  "Shared drive permissions": the notes that point to that run name it.
- **Not run on a real domain yet.** The mock models each bare read as GAM 7.52.04 prints it (below); check each by eye on its
  first live run. A green run proves nothing about Google.

## Reports: audit runs (plan F3)
GamGUI #171 (`086d2f8`) and #172 (`db579c7`): ready-made lists of reads, each run when the operator asks, listed under
**Audit runs** on Reports: Inactive users, Shared drive permissions, License usage, Classroom and the Admin token review.
A run changes nothing; Inactive users' Suspend these… is a write of its own.
- **The runs and their steps** (`AuditRuns`, GamGUI's `core/audit_runs.py`): Inactive users reads the directory (the cache's
  own read, `cacheFields`, suspended accounts included); License usage reads `print licenses` (no product named), then the
  directory. Each step's read is its run's own builder (`AuditRuns.read`).
- **The runner** (`AuditRunner`, GamGUI's `web/routes/audit_runs.py`): the steps one after another as the connected domain,
  Stop checked before each (the step in flight finishes and is recorded; the rest are not run). A failed step is unknown and
  the run goes on. One of each run at a time: Run while it goes is ignored. Each step's table is kept in memory for the
  tenant it was read on; a switch stops a run (GAM stopped, the step in flight recorded as interrupted) and hides what was
  kept. Only a `print` read without `todrive` runs (`AuditRuns.isAuditRead`, every spelling GAM reads as todrive).
- **A read record per step** (plan F1's `ReadAudit`, origin `audit_run`): command `<run>/<step>` (`license_usage/licenses`),
  no target, the domain, `rows`, or GAM's words as `error`; never the output. A read the log can't record isn't used.
- **Unknown, never none (invariant 10).** Any exit but 0 is unknown (`print users` that loses a page writes the rows it had
  and exits 50, doPrintUsers: never used). Output without the step's key column in its titles (`primaryEmail`, `userId`) is
  unknown ("GAM ended without writing the table"). No account, or no seat at all, is unknown: with no product named,
  `print licenses` passes over a product Google refuses without a word or a code (doPrintLicenses, `suppressErrorMsg`), so
  every license table carries that caveat too. Every table says which step it needs and why it's unknown, and an unknown
  table has no Export CSV…, never a sheet of titles.
- **The tables, on Google's fields** (cited in `AuditRuns`): Inactive is `DirectoryReport`'s bucket for the window, never
  signed in first; `new account` when `creationTime` is inside the window or missing, `admin` for `isAdmin` or
  `isDelegatedAdmin`. License usage joins `userId` (lowercased by GAM; "the user's current primary email address") to
  `primaryEmail`, lowercased: seats per SKU, seats held by a `suspended` account, seats on an address the directory read
  didn't list. An unknown directory leaves the per-SKU counts, "unknown" in the last two columns.
- **Bounded (invariant 9).** While a run goes only its steps are drawn, one line each; a finished table draws its first 100
  rows (`AuditRuns.rowsShown`), each wrapped to fit the smallest window, and Export CSV… (formula-safe, 0600, GamGUI's name
  `<run>-<table>.csv`, `AuditRuns.exportRows`) holds all of them. The header says when the run was read, as a time, never
  "now", so a pane left open never calls old tables fresh.
- **The keyboard, with the Mac's default settings** (Tab reaches only lists and text fields; review of F3, 2026-11-21, as
  Reports' ⌘O before it), each said in visible words beside its control: ⌘R runs the selected run, ⌘. stops it, ⌘1 to ⌘5
  pick Inactive users' window; each table is a list Tab reaches, where the arrows pick a row and Return or a double-click
  opens the person; ⌘E exports the table a row was last picked in (else the first with rows); ⌘Return previews Suspend
  these…, and in its sheet ⌘Return suspends (never Return alone; with fewer than ten accounts the sheet has no field to type
  in). A Suspend these… that ends without a sheet (nothing to suspend, or why not) is announced to VoiceOver.
- **Suspend these…** (`InactiveSuspend`, GamGUI's `/reports/inactive/preview` and `/apply`, roadmap 3.3, new here): the
  run's window, one of 30, 60, 90, 180, 365; the directory read again (`DirectoryStore.load`, so Users updates too) and the
  window's people held in address order (GamGUI's `inactive_to_suspend`); the connected admin left out by address and by
  account ID, and nothing offered without a confirmed admin; new accounts flagged. One preview through the executor
  (`confirmStep`, the guard's word from ten, the count above 25), run once in the jobs tray with Stop; each suspend that
  worked is patched into the cached directory, and any failure has the directory read again. The confirm sheet is
  `InactiveSuspendSheet` (ChangePreviewSheet.swift, where every confirmation is made). What it shows is kept with the domain
  and generation it was made on and the run (its read time) it was asked from (`InactiveSuspend.state(about:)`): a switch, or
  a newer run of the table, never shows another tenant's preview or an older run's outcome; a run that ends after a switch
  keeps the tenant it ran on.
- **Follow-up, not changed here (ChangeCore):** the executor's `lockoutRefusal` reads `info user` for every target, one after
  another, inside the write lock and before the first suspend. One target it can't read (deleted since the preview, or a
  Google error GAM gives up on) refuses the whole run: it fails closed, nothing wrong is suspended, but a large run waits
  minutes and is spent. GamGUI asks `cut_off_refusal` per write, so a bad target fails only its own. Suspend these… is the
  first bulk flow of writes that cut accounts off; a per-step check in the executor is the fix, on its own review.
- **Held to GamGUI's own code**: the generator runs GamGUI's `core/audit_runs.py` and `GAMConnector.audit_read` over edge
  cases (`audit_runs.json`): the steps, the windows, the unknown rules, the inactive table at every window (the cutoff to the
  microsecond, Python's stable sorts and code-point order), the license tables over every way the two steps end, the suspend
  targets, and the read record over each output, failure, cancel and refused argv.
- **The mock** answers `print licenses` (bare only) from `licenses.csv` (bob@, suspended, holds two seats; left@ isn't in the
  directory): `nolicensing` exits 15 as a token without the License Manager scope, `licenses_silent` is the titles alone,
  exit 0, `licenses_partial` drops Google Vault, exit 0. `print users` with `directory_fails` writes one row and exits 50.
  Every directory account says when it was made, as GAM prints `creationTime` (formatLocalTime), so the new-account flag
  isn't every row's.
- **Not run on a real domain yet.** `print licenses` has never run live: check the counts against Billing → Licenses on its
  first run. Then one Inactive users run, and its records on Audit.

### Shared drive permissions, Classroom, admin token review (GamGUI #172)
Each step says which exits are its answer (`Step.okCodes`: 60 is GAM's "no drive at all") and which keep the rows with the
accounts GAM named as unread (`Step.partialCodes`, 56 and 73: state `partial`, the read record's `extra.partial` true, the
accounts said in words, unknown never none). A warning exit that names nobody is unknown whole. A step that reads for what an
earlier step found (the admins' apps) doesn't run when that step has no answer, and is unknown (`AuditRuns.read(step,
tables:)` nil). `AuditRuns.answer` is GamGUI's `audit_read` after GAM ended, held to it over every exit in `audit_runs.json`.
- **Shared drive permissions:** `print shareddrives noorgunits formatjson`, `print shareddriveacls oneitemperrow
  shownopermissionsdrives true formatjson` (both as the admin, domain admin access), `print domains formatjson`, the
  directory. The ACL read is each drive's own permissions, its members, which Google's sharing guide says are users and
  groups only, so the run flags a member from outside the domain (an address in none of `print domains`' own domains or
  aliases, `AuditRuns.domainsFrom`) and claims nothing about "anyone with the link" or a whole domain: that is the sharing of
  files inside a drive, which it doesn't read (GamGUI's failure log 2026-11-21: its first fixture invented such members).
  printShowSharedDriveACLs drops a drive whose permissions Google refused without a word or a code, so a listed drive
  missing from the ACL table is in "Drives whose members weren't read". A drive is flagged when every organizer is a user
  who is suspended, gone from the directory (or `deleted`), or being offboarded here (`OffboardChanges.leaversStarted`: an
  offboarding started in this app since it opened, on this tenant, GamGUI's `offboard_jobs`); a group organizer isn't; a drive
  with no organizer is.
- **Classroom:** `print courses states <every state> show all countsonly fields … formatjson` (no `owneremail`: owners are
  joined by `ownerId` to the directory's `id`). A roster GAM couldn't read counts 0 without a word, so no table reads a 0 as
  an empty class. Stale: ACTIVE or PROVISIONED, `updateTime` more than 365 days ago. Read only; not yet checked on a school
  domain.
- **Admin token review:** `print admins recursive` (not `types user`: with `recursive` it drops a group's row and its members),
  the directory, then `print tokens users <every holder, one comma-joined argv element>` (`GamCommands.printTokens(users:)`:
  `users` is convertEntityToList, so suspended admins are read). A holder GAM couldn't name has `assignedToUnknown` True and
  `assignedTo` alone, exit 0: `AuditRuns.holder(of:users:)` joins it to the directory's `id`, and one neither can name stays in
  "Every admin" as `ID <id>` with everything unknown, and the run isn't complete (`Finding.partial`). Flags reuse
  `ConnectedApps` (AI by its name, broad reach). Revoking stays in Incident's previewed flow.
- **The mock:** `shared_drives.json`, `shared_drive_acls.tsv` (users and groups only; `nodrives` 60, `denied/drives` 50,
  `acl_dropped/<id>` the silent drop); `print admins recursive` (admin@ and alice@ direct, bob@, suspended, through
  it-admins@, a service account; `admin_unnamed` adds carol@'s ID and one no read names; `denied/admins` 12); `print tokens
  users` (bob@ has a broad-access grant; unknown or `tokens_gone/<u>` 56, outside the domain 73, `denied/tokens` 12); `print
  courses … show all countsonly` (counts from course_participants.tsv; `roster_gone/<id>` the silent 0).
- **Not run on a real domain yet**, none of them; the Classroom run can't be until an Education domain is there.
- **No row is "no drive" only at 60** (GamGUI #176, `Step.emptyCodes`): a service-account token Google refuses silently
  (`REFRESH_PERM_ERRORS`) makes both drive reads write the titles alone at exit 0, so `AuditRuns.answer` is `Incomplete` there
  ("GAM wrote no row and exited 0, …") and the step says `AuditRunner.noRowUnsaid` (failure-log 2026-11-24, a refused token
  read as no shared drive). Every drive's permissions dropped is GAM's 60, as for none: the drive list, read first, names
  each one unread. With any drive unread, or the drive list unknown, both member tables are `partial` (their note and CSV
  say so) and never compared by a schedule. The license tables and Classroom's class list carry `Finding.changeNote`, said
  beside every change since a kept run: GAM's silent skips make a gone seat or a count fallen to 0 look like a change.
  The mock: `drive_token_silent` (titles alone, 0, both reads); every `acl_dropped` drive exits 60.

## Reports: audit-run schedules (plan F7a)
GamGUI #176 (`73498c4`, its part A) and #178 (`82290f0`, part B: the named reports): a run, or a named report run on
Reports, can be given a cadence per domain, and then says when it's due, on Home and on its own pane. **Nothing runs on its
own**: no background runner, timer or notification; the run is the operator's Run (⌘R) on its pane, recorded as ever (`read`,
origin `audit_run`, or `named_report` for a named report). No write, no sensitive read, no Sheet export.
- **Files.** `Packages/GamKit/Sources/Stores/AuditSchedules.swift` (cadence, `Clock` and its due words, `changesSince`),
  `AuditScheduleStore.swift` (the schedules file, kept runs, `afterRun`, `setSchedule`, `deleteKept`, `forget`),
  `Directory/RunSchedules.swift` (what the screens read: the connected domain's schedules and kept runs, save, delete, a
  removed domain's), `AuditRunner` (`schedules`, `ended`, `keepChanged`), `App/ScheduledRunsView.swift` (Home's card, the due
  line, the pane's schedule section), `ChangeSinceView` in `App/AuditRunsView.swift`; tests `StoresTests/AuditSchedulesTests`
  (`schedules.json` and the store's rules), `DirectoryStoreTests/ScheduledRunTests` (end to end on the mock),
  `WriteRouteTests.aScheduleRunsNothing`.
- **Cadence and due.** Daily, weekly, monthly. A run *counts* when every step has an answer, `partial` included
  (`Outcome.answered`); stopped, or a step unknown, doesn't. Due now when none has counted since the cadence was set; else
  due from the local day (the Mac's time zone, `Clock`) 1 day, 7 days or one calendar month after the day it last counted
  (clamped to the month's last day). Changing the cadence keeps when it last counted. Counting records this run's time,
  never a later one kept: a time still to come (the clock was ahead) is due and says to check the Mac's clock. Words: GamGUI's
  (`<Title> is due` + `<Cadence>; no run of it has read every step since it was scheduled.` / `…its last run that read every
  step was on Wed 18 Nov 2026.`; not due: `<Cadence>, next due <day>`), held in two time zones by `schedules.json`.
- **Kept runs: tenant data at rest.** Only a scheduled run that counts is kept: its findings (what the pane shows, never the
  steps' raw reads) in `<app data>/schedules/kept/<sha256(domain)[:24]>/<run>/<seq>-<hex>.jsonl` (`AuditScheduleStore.defaultRoot`),
  a header line (each table's key, title, known, partial, count, kept: never its columns) then one line per kept table of its
  columns and rows. Version 2 (GamGUI #178): version 1 kept the columns in the header, which a flattened read (13 columns a
  member of the largest shared drive) could push past the 1 MB a header may take; a version 1 run is still read. A build from before this one reads a version 2 run as "It isn't whole.", which stops its comparisons until the kept runs are deleted (as in GamGUI): only a downgrade meets it. Named by a
  sequence, so the newest is the last kept whatever the clock said. `keep` per run: default 5, 1 to 12; a table over 50,000 rows isn't kept (its header says so), and a run's file past
  64 MB isn't kept at all (said; it still counts). The oldest beyond `keep` go after each kept run and when the count is
  lowered; all go when the run is unscheduled, on Delete the Kept Runs…, or when Setup removes the domain (its confirmation
  says so). The store's folder is excluded from Time Machine when it's made or written (`isExcludedFromBackup`), so a backup
  never keeps rows deleted here (review of F7a). The pane says this beside the schedule; SECURITY.md lists it.
- **Changed since.** Each table against the newest earlier kept run that holds it whole (known, not partial, kept) with the
  same window (`days`; 0 for every run but Inactive users). A kept run that can't be read, met before that one, stops the
  walk and says so. A run with any step unanswered compares nothing. Rows compared whole, as a multiset; a row with any cell
  changed is gone and new, cells compared as their bytes (as Python's `Counter`; a Swift `String` calls NFC and NFD equal).
  Both tables are compared on the union of their columns, a cell a table lacks being "" (GamGUI #178's `_aligned`): a read
  whose JSON GAM flattens grows or sheds columns between runs (`permissions.1.*` once a drive has a second member), and moved
  columns are no change. A column in `Finding.compareWithout` (mobile's `lastSync`, alerts' `updateTime` and
  `metadata.updateTime`) is left out of both sides first (`Change.leftOut`), and the pane says so (`compareNote`); every phone
  that synced read as gone and new (review of #178). The lists draw rows in the union's columns (`Change.columns`). Unknown or
  partial now, or nothing to compare with, says why and is never "no change". Each list draws 100 rows.
- **Store rules** (each by descriptor, `AuditScheduleStore`'s header): the store's folder is opened `O_DIRECTORY |
  O_NOFOLLOW`, and `kept`, the domain's and the run's folders each `openat` the same way from the one above, so a link
  anywhere is refused and said, never followed; each folder ours and `0700`. Files `openat` `O_NOFOLLOW | O_NONBLOCK`, `fstat`
  a regular file, read from that descriptor under a cap (1 MB the schedules file, 1 MB a kept run's header, 64 MB a kept run);
  written `0600` under a temporary name (`O_CREAT | O_EXCL | O_NOFOLLOW`), `F_FULLFSYNC`, then renamed in the held folder
  (a kept run never over another, `RENAME_EXCL`). No file is the empty store; a read the disk failed is unknown, said (Home
  never says "Nothing is due" then) and never saved over; a file that isn't a store is moved to
  `schedules.json.unreadable-<time>-<hex>` before an empty one starts, said on Home. A kept run that can't be read is listed
  as such ("It isn't whole.", "It isn't a file.", "It couldn't be read just now.", "It's larger than this app reads."), never
  dropped. A file or folder that can't be deleted (locked in Finder: EPERM; anything but already gone) is never said
  deleted: prune keeps the run and says its older runs couldn't all be deleted, Delete and Setup's Remove say so, and
  unscheduling says its kept runs couldn't all be deleted (review of F7a, 2026-11-24). One `flock` on the store's folder spans every change and a finished run's "still scheduled? keep, prune, count":
  a run finishing as it's unscheduled, or its domain removed, keeps nothing.
- **Per domain.** Everything is keyed by the connected domain (`Domain.name`, already lowercased): a switch drops what
  `RunSchedules` held, and the screens read the new domain's. A run that ends after a switch isn't kept. Nothing compares
  across domains.
- **The keyboard, with the Mac's default settings**, each said in visible words beside its control: on Home ⌥⌘1 to ⌥⌘5 open
  the runs listed (due first); on a run's pane ⌃⌘1 to ⌃⌘3 pick daily, weekly or monthly and ⌃⌘0 not scheduled, Tab reaches
  the count and Return saves, ⌘S saves, ⌘⌫ asks to delete the kept runs, ⌘R runs. "New since then" and "Gone since then" are
  lists Tab reaches. A save's or delete's notice is announced to VoiceOver. Screens: `home-scheduled`,
  `reports-run-scheduled` and their `narrow-` pair (`scripts/screenshots.sh`).
- **Not run on a real domain yet**, and the screens not looked at but in CI's pictures.

## Reports: named reports run on Reports (plan F7a, part B)
GamGUI #178 (`82290f0`): each F2 named report is also a one-step run of its catalog read built bare, listed on Reports under
**Named reports, run here**, so it can be scheduled, kept and compared like an audit run.
- **The run** (`AuditRuns.namedRun`, GamGUI's `named_run`): the report's catalog command (`NamedReport.command(in:)`) built with
  no value (`NamedReport.bareRead`: a runnable read, risk read, certain, no required slot, built by `GamCommands.catalogRead`,
  its argv starting `print`), one step `read` whose key column and exits are GamGUI's `NAMED_READS` (`AuditRuns.namedReads`,
  read from GAM's source at 7.52.04). A report with no entry there, or whose read this GAM version doesn't have in that form,
  isn't offered. `AuditRunner` runs it as any run (one at a time, Stop, a switch stops it), recorded as `read` of origin
  `named_report` whose `command` is the report's key (`licenses`); never the output.
- **Its one table** (`AuditRuns.namedFinding`, key `table`): the read's rows as GAM wrote them, columns in the order they first
  appear, a missing cell "". Its CSV is the whole read (`<report>-table.csv`).
- **Unknown, never none.** No row is an answer only where GAM says none its own way (`emptyCodes`: 60 for the drive reads, since
  a service-account token Google refuses silently writes the titles alone at 0); never for licences, drive members or
  organizers (`emptyWhy`: GAM says the same when every product or drive was refused). A group whose members Google refused is
  "Group: <g>, Does not exist (i/N)", exit 56 (73 outside the domain): named like an account (`AuditRuns.unreadAccounts`), the
  table `partial`, its CSV's first line says so, never compared. `changeNote` says what a change can't tell (a product, a drive,
  an owner's name or an aged-out alert passed over silently); `note` (organizers) that GAM lists one organizer per drive.
- **A schedule that can't run any more** (`RunSchedules.stranded`): a schedule, or kept runs, under a key nothing here runs (a GAM
  bump renamed a report's read, or a report was dropped) is never due: Home says "<Title> can't run here any more" and opens
  it on Reports under **Can't run here any more** (`StrandedRunPanel`), where Stop Scheduling It (⌘S, deleting what it kept)
  or, for kept runs alone, Delete the Kept Runs… (⌘⌫) clears it. `RunSchedules.clear` acts only on a key listed there and never
  on one a run here has; it can't be given a cadence. The kept runs' keys come from the store's folders (`runKeys`).
- **Review of #197.** A named run going is named in Setup's switch warning like an audit run (`AuditRunner.running`, which
  `SwitchStops` reads: it once looked only at `AuditRuns.all`, while a switch still stopped the named run). A stranded entry
  just cleared keeps its pane and notice (`RunSchedules.cleared`, "Not scheduled, and nothing of it is kept on this Mac.",
  GamGUI's `now`) until a switch or until it is stranded again. Only the schedules file unread is a `problem`: the stranded
  scan fails soft, and a key whose kept folder can't be read is still listed (`Stranded.keptProblem`), so one bad folder
  never hides every schedule or the pane that could delete it.
- **The catalog** is read once, off the main actor (`RunSchedules.catalog`, the Builder's `BuilderView.load`). If it can't be
  read, no named report runs, nothing is called stranded, and a schedule naming one says why its due is unknown
  (`namedUnknown`; Home never says "Nothing is due" then).
- **The mock** models each bare read as GAM prints it (GamGUI #178's handlers, on this mock's data): `print orgs` (four
  titles, the root never a row; `no_org_units`, `orgs_failed` 50 with no CSV, `org_units_refused` 12), `print group-members`
  (six titles; `members_gone/<group>` 56), `print mobile` (`email` the first owner; `no_mobile`, `denied/mobile` 12), `print
  alerts` (`no_alerts`, `denied/alerts` 73 with no CSV, `alerts_token_silent` nothing at all, `alerts_edited` the times alone,
  `alerts_closed` the status too), `print shareddrives` (with `orgUnit`; `orgs_failed` a traceback, no CSV), `print
  shareddriveacls` (flattened: `permissions`, then each member's three columns; a drive with no member left out), `print
  shareddriveorganizers` (the FIRST user organizer in the primary domain), all three with `drive_token_silent`, `nodrives`,
  `acl_dropped`; `print datatransfers` bare lists `datatransfers_all.csv`, `no_transfers` the `id` title alone,
  `denied/transferapps` 61 and `denied/datatransfers` 50 with no CSV (the apps are read before any option).
- **Screens**: `reports-run-named` (Google's alerts scheduled and run twice: its GAM line, Open in the Builder, and the columns
  left out said) and its `narrow-` pair, and `reports-stranded` (`scripts/screenshots.sh`).
- **Not run on a real domain yet.** Check each table by eye on its first live run.

## Files
- `Packages/GamKit/Sources/ChangeCore/AuditScreen.swift`: `AuditFilter` (GamGUI's `_keep`, `record_domain`), `AuditEntry` (a
  record in words), `AuditPage` (`_rows_context`, `_domain_choices`), `AuditExport` (`_export_csv`).
- `Packages/GamKit/Sources/ChangeCore/AuditLog.swift`: the reader, now streaming (`forEachRecord`); `record(domain:)`,
  `domainKey`, `readActions` (GamGUI's `DOMAIN_KEY`, `READ_ACTIONS`).
- `Packages/GamKit/Sources/ChangeCore/ReadAudit.swift`: the read record (GamGUI's `catalog_read`'s), written by
  `UserAccess.catalogRead` (runbook catalog-builder.md).
- `Packages/GamKit/Sources/GamEngine/PythonStr.swift`: Python's `str()` of a JSON value (`pythonText`).
- `Packages/GamKit/Sources/Directory/UsageReport.swift`: `UsageReport` (`parse_usage`, `_csv_from`, the walk's
  dates) and `UsageStore` (GroupStore's shape: a snapshot, a load and a problem, each tagged with the tenant).
- `Packages/GamKit/Sources/GamEngine/ConnectedApps.swift`: the grants grouped by app (`apps`), broad access by kind (`Area`),
  and `Summary` (the counts and their sentences); `Packages/GamKit/Sources/Directory/ConnectedAppsRead.swift` (the read, kept
  for the tenant).
- `Packages/GamKit/Sources/GamEngine/NamedReports.swift`: `NamedReport` (GamGUI's `NAMED_REPORTS`, `named_report_command`,
  `admin_scope_held`).
- `Packages/GamKit/Sources/Directory/AuditRuns.swift` (the runs, their tables, `inactiveToSuspend`; the named reports' runs,
  `namedReads`, `namedFinding`), `AuditRunner.swift` (the runner), `InactiveSuspend.swift` (Suspend these…);
  `App/AuditRunsView.swift` (`AuditRunPanel`), `InactiveSuspendSheet` in `App/ChangePreviewSheet.swift`, `StrandedRunPanel` in
  `App/ReportsView.swift`.
- `App/AuditView.swift`, `App/ReportsView.swift` (`NamedReportPanel`), `App/ConnectedAppsView.swift` (the apps' panel and `AppRow`, which Incident's
  Check Account also uses), `App/DemoAudit.swift` (the Audit screenshot's log, debug only), `App/UsersView.swift` (`requested`:
  Reports' Show in Users), `App/GamGUIApp.swift` (the sidebar).
- `scripts/gen_fixtures.py` (`audit_fixture` and `read_record_cases`, `audit_screen_fixture`, `usage_fixture`,
  `audit_runs_fixture`),
  `Tests/Fixtures/mock_gam.sh` (`report users`).

## Audit: how it works
- **The log** is `AppServices.auditURL`, this app's own (design doc §11: each app writes only its own). The
  design doc also wants GamGUI's log shown read-only, labelled by source: **not built yet**.
- **A page** is GamGUI's: the whole log filtered, newest first, then 25 a page; a page past either end shows
  the nearest. One pass, holding only the page asked for and the page being filled, never the log (GamGUI
  materializes every record, up to about a million). The header's counts (records, failures) are the whole
  log's, from the same pass. The read runs detached and stops when a newer read replaces it.
- **The filter** is GamGUI's and only GamGUI's: the search (stripped, Python's `str.lower()`, a scalar
  substring of the action, the target, `extra.error`, `extra.detail`, the domain or the command, each read as
  `str(field or "")`), Failures Only (`ok` exactly `false`) and the domain (the toolbar's Domain picker: All Domains, each
  domain the log names, sorted, then "Unknown (older records)" when a record names none). There is no action or date filter:
  GamGUI has none. A new search waits 300 ms for the typing to stop and starts at page 1, as GamGUI's form does.
- **Every record names its domain** (plan F1, GamGUI #170): `extra.domain`, stripped and lowercased, added by
  `AuditLog.record(domain:)`, which every caller must pass (nil only for the debug demo's older records and tests). The
  executor's begin and end name the preview's domain; an acknowledgement names its begin's; the roster's local events theirs;
  a read its own. A record written before F1 names none: Unknown, never filed under some domain (`AuditFilter.unknownDomain`,
  `unknown`: no domain is spelled without a dot). Each row says its domain ("domain unknown" for none).
- **A read record** (`read`, plan F1): one per catalog read the operator runs from the Builder, once it ended; its target,
  argv (masked), `ok`, and `extra.command` (the catalog id), `extra.origin` (`builder`), `extra.rows` (only when GAM printed a
  table: `CatalogResult.tableRows`, a header alone 0) or `extra.error`. Its row shows the count beside the command
  ("· 2 rows", GamGUI's). GamGUI's `sensitive_read` reads the same; this app writes none (runbook catalog-builder.md).
  Home's Recent failures and the incident report's changes pass over both (`AuditLog.readActions`): a read changed nothing.
- **Records in words.** This app writes a begin and an end record per step (ChangeCore), GamGUI one record
  per write. Each record shows its outcome in words with a symbol: Succeeded, Failed, Started (a begin; its
  end is the record after it), **Outcome unknown — check** (a begin Home lists: `Executor.unfinished`, the
  newest 20,000 records), Marked as checked (the operator's acknowledgement), No result recorded (GamGUI's
  "Unknown"). Mark as Checked on an outcome unknown is Home's `Executor.acknowledge`, for that one write.
  Its action is named in words: this app's by `WriteAction.displayName` (also the jobs tray's and a preview's title; a run of
  capitals one word as written, `imap` and `pop` said as acronyms: "Remove all calendar ACLs", "IMAP off"), GamGUI's snake
  case by `AuditEntry.words`. The search still matches the action as written (`removeAllCalendarACLs`).
- **The details** behind each disclosure are the record's fields as written (already masked): time, action,
  target, exit code, command, error, detail, who ran it, connector, then `extra`'s other keys. A value is cut at
  4,000 characters. The row's summary is GamGUI's Detail column: the error, else the command, else the detail,
  cut at 160.
- **Export** writes GamGUI's columns (`ts, action, target, ok, exit_code, error, argv, detail, domain, origin, rows`; the
  domain `unknown` for a record naming none, the origin and rows as written, blank when absent), `csv_safe`'s
  `'` before a formula lead, in Python's `excel` dialect (CRLF, quoted only for a comma, quote, CR or LF), as
  UTF-8, every generation newest first. The file is the operator's, from a save panel (GamGUI's name
  `audit-export.csv` suggested): written to a hidden file beside it, 0600 (it says who was changed), and
  renamed over it once whole, so a failed export leaves the old file as it was.
- **The reader's bound:** a line past 1 MiB (`AuditLog.maximumLineBytes`) is skipped as it is read, never
  assembled. Neither app writes a record near it; a log with no line breaks would otherwise be read whole.

## Reports: how it works
- **The list shows whenever a domain is connected.** Only the directory's reports wait on the directory: until it loads,
  their row says so and their pane is the directory's status (loading, or not loaded with Load the Directory and why it
  failed). Storage and mail and the connected apps need no directory and open meanwhile (they once sat behind it, so a
  directory that failed to load hid them too); without a connected domain the apps' Read is off, saying why. The bottom line
  (accounts, refreshing, a refresh's failure) shows once the directory has loaded, on its own background: the list scrolls
  beneath it.
- **The directory reports** are `DirectoryReport` (already held to `reports.json`), counted once per load. The
  screen lists them with their counts and descriptions; a report's people are a table (name, address, and
  "Admin" or "Suspended" in words outside the report about it, as GamGUI's badges). Show in Users (or a
  double-click) opens the person's page on Users (`UsersView.requested`). No GAM call of its own; ⌘R reloads
  the directory.
- **Export CSV…** saves everyone a report counts (GamGUI's `/reports/list.csv`: email, name, org_unit, suspended), and the four
  completeness reports' **Export to Fill In…** the columns Change from a CSV reads back (GamGUI's `/reports/fill-in.csv`,
  `FILL_IN_COLUMNS`), both by address, formula-safe, private (0600), from the same cached directory
  (`DirectoryReport.listRows`, `fillInRows`; 2.10's sweep). Held to `DirectoryReportTests`.
- **The usage report** is GamGUI's `/reports/usage`: `report users date <D> parameters
  accounts:used_quota_in_mb,gmail:num_emails_received,gmail:num_emails_sent,drive:num_items_created`, D two
  days ago (UTC), then a day earlier while a day has no rows, six days at most; a failure stops the walk. The
  default timeout, as GamGUI's call. Read when its row is first shown for a tenant (GamGUI reads it with every
  page view), then held for that tenant and generation; ⌘R on the row reads again.
- **Parsing:** `_csv_from` (from the first line starting "email,"), then `parse_usage`: each count is Python's
  `int(float(v))`, 0 where that raises TypeError or ValueError; storage is `round(mb / 1024, 1)`, shown with
  `%.1f`; largest storage first, rows alike in GAM's order; the top 25.
- **Words:** "Loading usage…"; GamGUI's "Usage data isn't available yet — Google's reports lag a few days.
  Check back later." when six days had no rows; a failure is GAM's remediation for its kind with GAM's line
  beside it (a refused report: "The authorized account lacks permission for this action. Check the admin
  role and scopes.").

## Reports: connected apps and agents
A check of the whole tenant, not of an incident (the operator, 2026-10-22: it was on Incident's step 1 until then). New to
this app; GamGUI has no such page. Reads only.
- **The read** is `gam print tokens` for every account but the suspended ones (GAM's default), with the long timeout, when
  the operator asks (Read Connected Apps, or ⌘R on its row): never on its own, as it is one Directory API call per account.
  Kept for the tenant and generation it was read on (`ConnectedAppsRead`).
- **The list** is grouped as Incident had it: AI assistants and agents (by name: `looksLikeAI`), then the broadest access,
  then the rest, each app with what it may do in words and who granted it (six names, then "and N more"). The per-person
  list stays in Incident's Check Account.
- **The summary** is code's (`ConnectedApps.Summary`): how many apps and people, the apps that look like AI and who granted
  them, broad access by kind (all of Gmail or reading and changing mail, forwarding and delegates, all of Drive, admin, Google
  Cloud; one kind is said without its count: "1 app has broad access, to all of Drive"), the apps only one person granted
  (and the AI and broad ones among them), and the most people who granted one app. The summary is code's own sentences; a
  model reworded them until 2026-11 and was retired: it added nothing they didn't say (plan 2026-11-18, R1).
- **What the model taught us** (2026-10-22, sampled on this Mac): left to compose from bare counts it tied them to the wrong
  group about half the time ("1 of those was granted by only one person"; "one of them with broad access" where none had),
  which a number check can't catch; an instruction to lead with "AI apps with broad access" made it claim some existed; the
  most people who granted one app read as other things; its own suggested checks were nonsense; and unbounded, one answer ran
  until its 8,192-token context was full (198 s). What works: the counts as whole sentences, one group each, a zero said as
  "None", and the model told to reword them and add nothing. It then rewords faithfully, which adds little over the code's
  sentences: the code's summary is the one to trust, and the screen says to check the model's against it.

## Deviations from GamGUI, and why
- **The usage date** shown is the day GAM's rows are for (their `date` column), not the day asked for. GAM
  walks back to the newest day with data on its own (doReport, `_checkDataRequiredServices`, and
  `_adjustTryDate` on Google's "not yet available"), so GamGUI's "as of" can name a day the data isn't from.
  The day asked for is kept (`Report.requested`) and held to GamGUI's walk.
- **Export applies the screen's search and filter** ("Export Matches…"; "Export All…" with none). GamGUI's route
  takes both, but its page links to the export without them ("filters aren't applied to the download in v1").
- **The page holds one page**, not the log; **a line past 1 MiB is skipped**.
- **Python's repr** of a list or object where text is expected (an `action` that is a list) is written as JSON:
  neither app writes one there. An `int(float(v))` Python would overflow (an infinity, past `Int`) reads 0 where
  GamGUI's page would fail.
- **Audit counts records**, not actions: this app records a begin and an end for each step.
- **The domain list holds at most 100** (`AuditPage.domainsListed`, invariant 9), the first the log names newest first;
  GamGUI lists every one. A domain past it is still found by the search. A log of the app's own names a handful.
- **A read the app quits during leaves no record**: at a quit `applicationWillTerminate` stops GAM and the app exits before
  the read's code resumes to write one (GamGUI records its cancelled read, then cancels). Reads get no begin record, by choice:
  a read changed nothing, so there's no outcome to check. A read whose task is cancelled is recorded as interrupted in this
  app's words ("Stopped before GAM finished, so nothing was read."), not GamGUI's `INTERRUPTED`; nothing cancels a Builder
  read today, so that is for a Stop when one comes.
- **No `sequence` origin:** this app has no Builder sequences, so every read record's origin is `builder` (`ReadAudit.Origin`
  has no other case; an origin GamGUI refuses can't be spelled at all).
- **The acknowledgement names a domain** (the begin's): GamGUI has no Mark as Checked.

- **Audit runs aren't in the jobs tray.** GamGUI lists each run there as a job; here the tray lists the executor's writes
  (its Stop is the executor's), so a run shows its steps and Stop on its own pane, and goes on while another screen shows.
- **A domain switch stops a run**: GAM is stopped and the step in flight recorded as interrupted, as a directory load is.
  GamGUI reads on to the end on the old connector, then doesn't keep the result.
- **A table's notes name this app** ("an offboarding started in GAM GUI", "GAM GUI changes nothing in Classroom") where
  GamGUI's name itself; the parity test reads GamGUI's name as this one's and holds every other word.
- **A table known only in part exports with a first line saying what wasn't read** (`AuditRuns.exportRows`: "Part of this
  table is unknown. GAM couldn't read the apps of …"), so an admin whose apps GAM couldn't read, or a holder no read could
  name, never reads as "no apps" in the file (review of F3, 2026-11-21). For GamGUI: its `table_csv` writes the columns and
  rows alone for a `partial` table, the same gap; the fix there is the same leading line.
- **A warning exit that names nobody** says so in its own words ("GAM said it couldn't read an account but not which"), where
  GamGUI's panel says its "no table" sentence; the read record's error is GamGUI's.
- **Schedules** (plan F7a): the store is held by descriptor all the way down (GamGUI checks the kept folders by path with
  `lstat`), its lock is an `flock` any process honours (GamGUI's two are per process), and a kept run is read under a cap
  (GamGUI reads one whole). A count is typed as ASCII digits only (GamGUI's `int()` also takes a sign, underscores and other
  scripts' digits). Columns are compared on their union, as GamGUI #178 does (part A here passed over a table whose columns
  changed; GamGUI's union replaced that, so the deviation is gone: a reworded column still reads every row as gone and new, as
  in GamGUI). Fields are typed strictly in a kept run's header (GamGUI coerces with `str()` and `int()`): only this
  app writes them, and a kept row not as long as its columns isn't whole. Kept runs aren't shared with GamGUI's (each app has its own data folder). **No notification**: GamGUI, a
  web app, says due only on Home and the run's page, and so does this app (a local notification while the app runs is a
  follow-up, plan F7a As built).
- **Named reports run on Reports** (GamGUI #178): listed in Reports' own list under "Named reports, run here" (GamGUI's Audit
  runs page has a "Named reports" heading), and a named report's pane says Run or Schedule It Here (GamGUI's "Run or schedule
  it" link). Its GAM line names no Sheet export: this app has none. GamGUI's "licence" in the licences report's description is
  "license" here, as everywhere in this app (`AuditRunsTests` reads one as the other). A catalog that can't be read is said
  (`namedUnknown`), where GamGUI's page would fail.
- **Suspend these… is reached from the Inactive users run only**: Reports' Inactive (90+ days) report here lists people and
  opens them; GamGUI's card has the same preview with its fixed 90 days.

## Back-port gaps (for GamGUI)
Found here, true of GamGUI too; to be fixed there from a GamGUI-rooted session, never from this repo.
- **The mock's bare `print shareddriveacls` titles** (GamGUI's `tests/fixtures/mock_gam.sh` ~3088, review of #197): it writes
  `permissions` among the titles even when no drive row is written, where GAM 7.52.04 writes only `User,id,name,createdTime`
  (the list's length is a title only once WriteRowTitles writes a flattened row). Fixed in this mock; tripwire in
  `MockAuditRunTests.eachNoneAndEachFailureIsGAMs`.
- **A table known only in part exports without saying so** (`table_csv`), as under Deviations.

## What F1 taught
- **Make the rule a parameter, not a scan.** GamGUI holds "every record names its domain" with a source scan; here
  `AuditLog.record`'s `domain:` has no default, so a new record can't leave it out without the compiler saying so.
- **The generator records what's new, or the port guesses.** `audit.json` had no case for a domain or a read; the generator
  now runs GamGUI's own `catalog_read` over chosen outputs (a header alone, JSON, text, nothing, a U+2028 in the first line, a
  failure, a cancel, a refused origin), which found that `CatalogResult` split its first line on LF where GamGUI's
  `splitlines()` splits on U+2028 too.

## What F3 taught
- **Record the logic, not just the argv.** The generator running GamGUI's audit-run code over edge cases held the port to
  Python's stable sort with code-point order, the cutoff to the microsecond, `str.strip()` on a whole sentence and
  `splitlines()` on GAM's titles, none of which a reading of the code would have pinned down.
- **A recorded error held a second parity for free**: GamGUI's `audit_read` writes `str(GAMError)` as a failed step's
  error, and the fixture holds this app's `GamError.message` to it, over GAM's own failure lines.
- **The mock's directory had no `creationTime`**, though the app's read names it and GAM returns it: every inactive account
  would have read as "new account". A field a flag reads must be in the mock as GAM prints it.

## What F7a part B taught
- **A fixture generator meets the GamGUI it is pointed at, not the one it was written for.** Regenerating from #178's merge
  also brought #182 (group settings): a hypothesis `flatmap` the generator couldn't enumerate, and a read the mock didn't model.
  The generator now walks `flatmap`, list and fixed-dict strategies, and an unported builder is listed (`notPorted`,
  `NOT_MODELLED`) rather than worked around.
- **A strict check that a port added can be the wrong strictness.** Part A refused to compare tables whose columns changed;
  GamGUI's flattened named reads change columns every time a drive gains a member, so the union is the right rule, and the
  part A deviation went.

## What F7a taught
- **Record the scenario, not just the functions.** The generator runs GamGUI's own store over a scratch folder, a run at a
  time (keeps, a clock set back, a lowered count, a delete, a removal), and records what each says and which kept runs stay:
  the port is held to the order and the words, not to a reading of `prune`.
- **A time zone is part of a day.** The due fixture runs in UTC and in New York across a change to summer time; `Day`
  arithmetic is on day numbers, never on seconds, so a 23-hour day can't move a due date.

## Gotchas / mock-lies traps
- **The mock's `report users`** took any words and answered every one (GamGUI's reports runbook names the
  trap). It now takes only GamGUI's shape and fails a field without a service, or a service outside
  USER_REPORT_SERVICES, as GAM does, before the progress line; another shape GAM takes isn't modelled. **Still
  lies:** it prints all four parameters whatever was asked for (GAM prints those asked for), kept so the
  output `gam_output.json` recorded stays the same; it answers 2026-06-16's data for any date (true of GAM
  for any later date, which walks back to it; not for an earlier one); the date's error words are
  approximate. The walk back past an empty day is exercised by a wrapper in `UsageReportTests`, not the mock:
  real GAM walks back itself and prints a header alone only when it gives up.
- **Not live yet:** the usage report has never run on the operator's tenant from this app. It is a read.
- **The mock's `tokens.csv`** (carol@'s Mail Sync Pro with all of Gmail, dana@'s ChatGPT and Read AI, Zoom for several, bob@
  suspended so left out) is what the apps' summary and screenshot count.
- The fixture generator reads `report users` through the mock: re-run it after changing that handler.
- **A page's text set the window's height.** Audit's header and a report's description were
  `fixedSize(vertical: true)` in a page that may shrink to zero width, so SwiftUI measured them one character
  a line: Audit asked for a window 1,755 points tall (drawn in part), and Reports for 808 at the smallest
  width. Outside a scroll view, let text wrap in the space it's given; the snapshots now fail any page that
  needs the window taller than its own 520-point minimum.

## Testing / live-verification status
- Package tests as above; every fixture case and the CSV bytes match GamGUI's. The screens are checked in CI's
  screenshots: `reports`, `reports-usage`, `reports-apps`, `audit`, `audit-domain` (narrowed to example.org), the audit
  runs (`reports-run-inactive`, `reports-run-licenses`, `reports-run-suspend`, `reports-run-drives`, `reports-run-classroom`,
  `reports-run-admins`), and their `narrow-` runs in the smallest window.
- **Not live yet:** a read record from a real tenant. Run any Builder read, then open Audit: one `read` record, the domain
  connected, the command and its row count, nothing of the output.
- **Audit needs no tenant.** **Live check of the usage report** (read-only): open Reports, choose Storage and
  mail; it should list up to 25 people with the day the counts are for, matching the Admin console's
  reports for that day.
- **Live check of the connected apps** (read-only): open Reports, choose Connected apps and agents, Read Connected Apps; the
  apps should match the Admin console's Security → API controls → App access control (Accessed apps), and the summary's
  counts the list beneath it. Explain on a Mac with Apple Intelligence: its sentences should say only what the summary does.

## To do common tasks here
- **Another usage column:** GamGUI's `USAGE_PARAMS` first (argv parity), then `UsageRow`, the table, and the
  mock's CSV (which changes `gam_output.json`: regenerate it).
- **GamGUI's log beside this one** (design doc §11): a source picker, the path read by descriptor, labelled
  read-only.

## Forwarding & mail delegates (roadmap 3.2, 2026-11-27)
GamGUI's #154. Reports → Access → Forwarding & mail delegates (`App/MailReviewView.swift`, `Directory/MailReviewRead.swift`,
`UserAccess.mailReview`, pure `GamEngine/MailReview.swift`): `all users print forward enabledonly` and `all users print delegates
shownames`, neither with `formatjson`. Read only when asked, kept per tenant and generation (a switch mid-read keeps nothing).
- **Every account GAM listed is accounted for** (`MailReview.accountFor`, GamGUI's `account_for`): each "Getting … for <u>"
  is read, a "User: <u>, …" warning is unread with fixed words (Gmail off, or couldn't read), and the rest of "Got N Users" were
  skipped without a word (a refused token). "None" is said only of accounts read.
- Exit codes are GAM's per-user ones (`MessageCopies.perUserExitCodes`); any other, no announced account, no table, or output
  past the runner's cap is a problem, never "none".
- Not covered, and the panel says so: Gmail filters that forward. Each row opens the person.
- The mock answers as GamGUI's does (ported): Gmail off by `nogmail/<u>` (exit 73), a silent skip by `quiet/<u>`.
- Held to `MailReviewTests` and `MailReviewReadTests`. Not run live.
## No 2SV / No recovery → a reminder email (roadmap 3.3, 2026-11-27)
GamGUI's #157. The two cards carry **Email Them a Reminder…** (`ReminderSheet` in `App/ChangePreviewSheet.swift`, model
`Directory/BucketReminders.swift`): a subject and message starting from GamGUI's `REMINDERS`; Preview reads the directory again
and holds the bucket's people in address order with that exact text (an edit drops the preview); Send runs one `sendemail` a
person through the executor, a confirm always and the count typed past 25. The text is escaped with its line breaks kept
(`BucketReminders.html`, GamGUI's `reminder_html`, with `PythonText.splitlines`). Held to `BucketRemindersTests`. Not run live.
Still to come in 3.3: Suspended → remove the licence, with 4.3.
