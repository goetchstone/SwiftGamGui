# Audit and Reports

**One line:** two read-only screens ported from GamGUI. **Audit** shows this app's audit log on this Mac,
25 records a page, searched and narrowed to failures, with GamGUI's CSV export; it runs no `gam`. **Reports**
lists GamGUI's directory reports from the loaded directory, reads the storage and mail usage with one
`gam report users` walk, and (new to this app) every account's connected apps and AI agents with `gam print tokens`,
counted by code, worded on request by the on-device model.

**Owns invariants:** #9 (the log is read a page at a time; the usage output is refused past the runner's
cap and only the top 25 kept), #11 (the page, the filter, the CSV bytes and the usage parsing are GamGUI's,
held to fixtures), #4 by not widening it (the screen shows records as they were written, already masked),
#10 for the connected apps' wording (the model is given counts only and reaches no change), and the tenant
generation for the usage report and the apps.

**Enforcement home:** `Tests/ChangeCoreTests/AuditScreenTests.swift` (`audit_screen.json`),
`Tests/DirectoryStoreTests/UsageReportTests.swift` (`usage_report.json` and the strict mock),
`Tests/GamEngineTests/MockReportTests.swift` (the mock's `report users`), `Tests/GamEngineTests/ConnectedAppsTests.swift`
and `CompromisedChangesTests.everyAccountsConnectedAppsAreRead` (the apps' summary, from the mock's `tokens.csv`),
`Tests/AssistTests/AppsExplainerTests.swift` (the prompt, the miscount check), `WriteRouteTests.theAppsExplainerCanRunNothing`.

## Files
- `Packages/GamKit/Sources/ChangeCore/AuditScreen.swift`: `AuditFilter` (GamGUI's `_keep`), `AuditEntry` (a
  record in words), `AuditPage` (`_rows_context`), `AuditExport` (`_export_csv`).
- `Packages/GamKit/Sources/ChangeCore/AuditLog.swift`: the reader, now streaming (`forEachRecord`).
- `Packages/GamKit/Sources/GamEngine/PythonStr.swift`: Python's `str()` of a JSON value (`pythonText`).
- `Packages/GamKit/Sources/Directory/UsageReport.swift`: `UsageReport` (`parse_usage`, `_csv_from`, the walk's
  dates) and `UsageStore` (GroupStore's shape: a snapshot, a load and a problem, each tagged with the tenant).
- `Packages/GamKit/Sources/GamEngine/ConnectedApps.swift`: the grants grouped by app (`apps`), broad access by kind (`Area`),
  and `Summary` (the counts and their sentences); `Packages/GamKit/Sources/Directory/ConnectedAppsRead.swift` (the read, kept
  for the tenant); `Packages/GamKit/Sources/Assist/AppsExplainer.swift` (the model's wording);
  `Packages/GamKit/Sources/Assist/OnDeviceModel.swift` (why the model can't answer, or why an answer failed, in words: shared
  with the log reader's `LogExplainer`).
- `App/AuditView.swift`, `App/ReportsView.swift`, `App/ConnectedAppsView.swift` (the apps' panel and `AppRow`, which Incident's
  Check Account also uses), `App/DemoAudit.swift` (the Audit screenshot's log, debug only), `App/UsersView.swift` (`requested`:
  Reports' Show in Users), `App/GamGUIApp.swift` (the sidebar).
- `scripts/gen_fixtures.py` (`audit_screen_fixture`, `usage_fixture`), `Tests/Fixtures/mock_gam.sh` (`report users`).

## Audit: how it works
- **The log** is `AppServices.auditURL`, this app's own (design doc §11: each app writes only its own). The
  design doc also wants GamGUI's log shown read-only, labelled by source: **not built yet**.
- **A page** is GamGUI's: the whole log filtered, newest first, then 25 a page; a page past either end shows
  the nearest. One pass, holding only the page asked for and the page being filled, never the log (GamGUI
  materializes every record, up to about a million). The header's counts (records, failures) are the whole
  log's, from the same pass. The read runs detached and stops when a newer read replaces it.
- **The filter** is GamGUI's and only GamGUI's: the search (stripped, Python's `str.lower()`, a scalar
  substring of the action, the target, `extra.error`, `extra.detail` or the command, each read as
  `str(field or "")`) and Failures Only (`ok` exactly `false`). There is no action or date filter: GamGUI has
  none. A new search waits 300 ms for the typing to stop and starts at page 1, as GamGUI's form does.
- **Records in words.** This app writes a begin and an end record per step (ChangeCore), GamGUI one record
  per write. Each record shows its outcome in words with a symbol: Succeeded, Failed, Started (a begin; its
  end is the record after it), **Outcome unknown — check** (a begin Home lists: `Executor.unfinished`, the
  newest 20,000 records), Marked as checked (the operator's acknowledgement), No result recorded (GamGUI's
  "Unknown"). Mark as Checked on an outcome unknown is Home's `Executor.acknowledge`, for that one write.
- **The details** behind each disclosure are the record's fields as written (already masked): time, action,
  target, exit code, command, error, detail, who ran it, connector, then `extra`'s other keys. A value is cut at
  4,000 characters. The row's summary is GamGUI's Detail column: the error, else the command, else the detail,
  cut at 160.
- **Export** writes GamGUI's columns (`ts, action, target, ok, exit_code, error, argv, detail`), `csv_safe`'s
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
  (and the AI and broad ones among them), and the most people who granted one app.
- **Explain** (`AppsExplainer`) has the on-device model reword the summary. It is given counts and kinds only: `Facts` holds
  numbers and an `Area` enum, so an app's name or scopes (its maker's words, or an attacker's) can't reach it. The answer is at
  most three sentences, greedy (the same counts word the same way) and capped at 400 tokens; a sentence holding a number the
  counts don't, in digits or words ("Nine"), is dropped. Without the model (no Apple Intelligence, a Mac that can't run it,
  CI), the button is replaced by why, in words; a failed answer is said in words too (`OnDeviceModel.failure`: too long,
  declined, busy, timed out).
- **macOS 27's API:** `GenerationOptions(samplingMode:…)` (27 renamed `sampling:`) and `LanguageModelError` (27 deprecated
  `LanguageModelSession.GenerationError`). Read from the SDK's `.swiftinterface`, not memory: PR #101 shipped the
  deprecated `sampling:` unseen (RULE-FEEDBACK 2026-10-23).
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
  screenshots: `reports`, `reports-usage`, `reports-apps`, `audit`, and their `narrow-` runs in the smallest window.
- **The model** is checked by hand on a Mac that has it: `SWIFTGAMGUI_MODEL=1 swift test --package-path Packages/GamKit
  --filter OnDeviceAppsModel` prints its wording for three tenants' counts (all three right on 2026-10-23).
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
