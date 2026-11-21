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
`WriteRouteTests.anAuditRunIsNoWritePath`.

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
- **Not run on a real domain yet.** The mock answers only a bare `print datatransfers` (the form the Builder emits: an empty
  table, or a person's transfers from its state); the other eight it refuses as not modelled. A green run of those proves
  nothing about Google.

## Reports: audit runs (plan F3)
GamGUI #171 (`086d2f8`): ready-made lists of reads, each run when the operator asks, listed under **Audit runs** on Reports.
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
- `Packages/GamKit/Sources/Directory/AuditRuns.swift` (the runs, their tables, `inactiveToSuspend`), `AuditRunner.swift` (the
  runner), `InactiveSuspend.swift` (Suspend these…); `App/AuditRunsView.swift` (`AuditRunPanel`), `InactiveSuspendSheet` in
  `App/ChangePreviewSheet.swift`.
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
- **Suspend these… is reached from the Inactive users run only**: Reports' Inactive (90+ days) report here lists people and
  opens them; GamGUI's card has the same preview with its fixed 90 days.

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
- **The mock's directory had no `creationTime`**, though the app's read names it and GAM returns it: every inactive account
  would have read as "new account". A field a flag reads must be in the mock as GAM prints it.

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
  runs (`reports-run-inactive`, `reports-run-licenses`, `reports-run-suspend`), and their `narrow-` runs in the smallest
  window.
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
