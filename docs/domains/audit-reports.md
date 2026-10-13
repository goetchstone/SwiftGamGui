# Audit and Reports

**One line:** two read-only screens ported from GamGUI. **Audit** shows this app's audit log on this Mac,
25 records a page, searched and narrowed to failures, with GamGUI's CSV export; it runs no `gam`. **Reports**
lists GamGUI's directory reports from the loaded directory, and reads the storage and mail usage with one
`gam report users` walk.

**Owns invariants:** #9 (the log is read a page at a time; the usage output is refused past the runner's
cap and only the top 25 kept), #11 (the page, the filter, the CSV bytes and the usage parsing are GamGUI's,
held to fixtures), #4 by not widening it (the screen shows records as they were written, already masked),
and the tenant generation for the usage report.

**Enforcement home:** `Tests/ChangeCoreTests/AuditScreenTests.swift` (`audit_screen.json`),
`Tests/DirectoryStoreTests/UsageReportTests.swift` (`usage_report.json` and the strict mock),
`Tests/GamEngineTests/MockReportTests.swift` (the mock's `report users`).

## Files
- `Packages/GamKit/Sources/ChangeCore/AuditScreen.swift`: `AuditFilter` (GamGUI's `_keep`), `AuditEntry` (a
  record in words), `AuditPage` (`_rows_context`), `AuditExport` (`_export_csv`).
- `Packages/GamKit/Sources/ChangeCore/AuditLog.swift`: the reader, now streaming (`forEachRecord`).
- `Packages/GamKit/Sources/GamEngine/PythonStr.swift`: Python's `str()` of a JSON value (`pythonText`).
- `Packages/GamKit/Sources/Directory/UsageReport.swift`: `UsageReport` (`parse_usage`, `_csv_from`, the walk's
  dates) and `UsageStore` (GroupStore's shape: a snapshot, a load and a problem, each tagged with the tenant).
- `App/AuditView.swift`, `App/ReportsView.swift`, `App/DemoAudit.swift` (the Audit screenshot's log, debug
  only), `App/UsersView.swift` (`requested`: Reports' Show in Users), `App/GamGUIApp.swift` (the sidebar).
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
- The fixture generator reads `report users` through the mock: re-run it after changing that handler.

## Testing / live-verification status
- Package tests as above; every fixture case and the CSV bytes match GamGUI's. The screens are checked in CI's
  screenshots: `reports`, `reports-usage`, `audit`, and their `narrow-` runs in the smallest window.
- **Audit needs no tenant.** **Live check of the usage report** (read-only): open Reports, choose Storage and
  mail; it should list up to 25 people with the day the counts are for, matching the Admin console's
  reports for that day.

## To do common tasks here
- **Another usage column:** GamGUI's `USAGE_PARAMS` first (argv parity), then `UsageRow`, the table, and the
  mock's CSV (which changes `gam_output.json`: regenerate it).
- **GamGUI's log beside this one** (design doc §11): a source picker, the path read by descriptor, labelled
  read-only.
