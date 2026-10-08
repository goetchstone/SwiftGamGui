# The directory cache and Home

**One line:** the tenant's users, loaded by one `gam print users` on request and held for the tenant
they were loaded for; Home shows the connection, the bundled GAM and the directory's counts.

**Owns invariants:** the tenant generation (a screen never shows one tenant's data as another's), and
"no Google call on its own" for Home.

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

## Testing / live status
- Mock-tested through the strict mock's `print users`.
- **Not live yet:** the first real load is the operator's, with Touch ID and an explicit go for a live
  read.
- The demo (`SWIFTGAMGUI_DEMO=1`, `SWIFTGAMGUI_SCREEN=home`) connects example.com and loads it.
