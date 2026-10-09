# The directory cache and Home

**One line:** the tenant's users, loaded by one `gam print users` on request and held for the tenant
they were loaded for; Home shows the connection, the bundled GAM and the directory's counts.

**Owns invariants:** the tenant generation (a screen never shows one tenant's data as another's).

**Changed 2026-10-09 (operator):** GamGUI's "no Google call on its own" for Home was a web page's rule
(no `gam` per page view). Here the directory loads once when a domain connects, and the app reconnects
at launch by checking the last connected domain again (`SetupModel.reconnect`, one Touch ID: a real
Check access, never an assumed connection). A load is marked running before the connect returns, so a
click meanwhile waits for it instead of starting a second.

**Enforcement home:** `Tests/DirectoryStoreTests`.

## Files
- `Packages/GamKit/Sources/Directory/DirectoryStore.swift`: `@MainActor @Observable`, shared by Home and
  (phase 2) Users.
- `Packages/GamKit/Sources/GamEngine/GamVersion.swift`: `GamVersion.running`, `gam version` in an empty
  private config directory.
- `App/HomeView.swift`, and `App/GamGUIApp.swift` (the sidebar).
- `App/AppServices.swift`: one runner shared by Setup and the directory.

## How it works
- **Loading.** `load()` runs `print users` with GamGUI's cache fields as `SetupModel.active`, with the
  domain-wide timeout. It parses the output off the main actor (`GamOutput`, then `GamUser`).
- **Failures.** A failure becomes a `Problem`: a `GamError`'s remediation, with its message as detail;
  a timeout reads as GAM's timeout kind; anything else is worded by `SetupModel.message(for:)`.
- **Tenant generation.** Users and a problem both belong to the domain and `SetupModel.generation`
  they were met under, and are hidden once either changes. A load that was running when the tenant
  changed is dropped.
  - The suite found the second half as a race: a load failing while its domain was being removed
    showed its error under the next tenant.
  - GamGUI learned the first half from failure-log 2026-09-25.
- **Truncated output.** Output cut at `GamRunner.outputCap` (8 MiB) is refused rather than counted:
  a partial list would report a smaller directory as the whole one. Large tenants need paging, which
  is phase 2's.
- **Home's GAM call.** Home runs one `gam` on its own: `gam version`. It needs no credentials, but it
  runs in an empty private config directory so GAM never reads or writes `~/.gam`.
  - **Observed with the real build:** every run writes `gam.cfg` and a `gamcache/` folder into its config
    directory (the wipe removes both; checked: nothing left), and creates `~/Downloads` if it's missing.
  - The real `gam version` takes about 6 s (PyInstaller start-up). Home shows "Checking…" meanwhile.

## Fixed in PR #8's review
- **A load's token write-back undid a re-import.** The refreshed `oauth2.txt` replaced whatever was
  stored, so a re-import during a load ended with the old admin's token beside the new key. Write-backs
  are now a compare-and-swap in the store (`replace(…, ifCurrent:)`, read and replaced under one lock):
  a token changed or removed mid-call stays as it was.
- **GAM's first-run banner.** Each call gets a fresh config directory, so real GAM prints
  `Created: <dir>/gamcache` and `Config File: <dir>/gam.cfg, Initialized` on stdout before its data
  (checked on the 7.48.22 build). `AuthenticatedRunner` drops lines naming the call's directory, as
  GamGUI's runner does. It splits at "\n" scalars, not `Character`s: "\r\n" is one `Character`, and a
  CRLF banner line took the data after it along. The mock now prints the banner too.
- **A dropped load held "Loading…" under the next tenant**, up to the hour-long timeout. Loading belongs
  to the tenant it runs for, and a tenant change cancels the old load, so its `gam` is stopped and its
  credentials wiped.
- **A failed Refresh was silent on Users.** The bottom line shows the refresh running, or why it failed.
- **Search parity:** Python's `str.lower()` (with its final sigma) and a scalar substring. Swift's
  `contains` missed "राम" in "रामू" and "i" in "İpek".
- **Login times:** `ISOTime` reads the forms Python does, held to a table of Python's own answers; three
  forms GAM never prints are named as known differences.

## Reports
`DirectoryReport.swift` ports GamGUI's `core/reports.py`: the nine report counts Home lists (no 2SV,
inactive 90+ days, admins, no recovery, suspended, no title/department/phone/location). Suspended
accounts form their own report; the others describe active accounts. They are counted once per load,
off the main actor.
- A login time is read as Python's `datetime.fromisoformat` reads the forms GAM prints (`ISOTime`).
  Anything else is no date, so the account reads as inactive, as in GamGUI.
- `DirectoryReportTests` holds the reports to `Tests/Fixtures/reports.json`: GamGUI's `build_reports`
  over the mock's users and 200 seeded variants at a fixed time, with the 90-day boundary to the second.

## Users (read-only)
`App/UsersView.swift` is a table of the loaded directory:
- sorted by any column, the macOS way (`localizedStandard`);
- scoped (All, Active, Suspended) and searched as GamGUI's `_filter_users` does (`UserFilter`: a
  case-insensitive substring of the address, name, title, department or unit);
- with the selected person's fields in an inspector.

It reads only through `DirectoryStore`, so it shares Home's tenant rules. Writes come with ChangeCore
(phase 2).

## Testing / live status
- Mock-tested through the strict mock's `print users`.
- **Not live yet:** the first real load is the operator's, with Touch ID and an explicit go for a live
  read.
- The demo (`SWIFTGAMGUI_DEMO=1`, `SWIFTGAMGUI_SCREEN=home`) connects example.com and loads it.
