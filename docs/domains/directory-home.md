# The directory cache and Home

**One line:** the tenant's users, loaded by one `gam print users` on request and held for the tenant
they were loaded for; Home shows the connection, the bundled GAM and the directory's counts.

**Owns invariants:** the tenant generation (a screen never shows one tenant's data as another's).

**Changed 2026-10-09 (operator):** GamGUI's "no Google call on its own" for Home was a web page's rule
(no `gam` per page view). Here the directory loads once when a domain connects, and the app reconnects
at launch by checking the last connected domain again (`SetupModel.reconnect`, one Touch ID: a real
Check access, never an assumed connection). A load is marked running before the connect returns, so a
click meanwhile waits for it instead of starting a second.

**Startup, shown (operator, 2026-10-10):** the app looked disconnected while it reconnected. Now
`SetupModel.reconnecting` names the domain from the start of the reconnect to its end, and
`reconnectFailure` keeps why it failed until a domain connects or that one is removed. Home, Users and
the window's subtitle (every screen) say "Connecting to …", then "Loading the directory…", with a
spinner; a failure says why, with **Try Again**. VoiceOver hears each step, ending with the count of
accounts loaded.

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

## Users writes (phase 2, slice 4)
`Directory/UserChanges.swift`: the user page's first writes, GamGUI's `/users/organization` and
`/users/suspend/*`, each through ChangeCore (`Executor.preview`, then `run` on the operator's confirm).
- **Title and department:** GAM's `organization … primary` sets both together, so both are sent (an
  unchanged one as it is now), trimmed; an unchanged pair is no write. LOW.
- **Suspend / unsuspend:** GamGUI's `plan_suspend`: suspend is destructive (a Confirm click),
  unsuspend LOW.
- **On success** the cached user is patched (`GamUser.with`, `DirectoryStore.patch`: GamGUI's
  `patch_user`), only while the cache still belongs to the tenant and generation the write ran on;
  the reports are counted again. A failure patches nothing and says why, with GAM's remediation.
- **The screen** (`UsersView`): the detail panel's **Edit Title and Department…** and **Suspend… /
  Unsuspend…** open a preview sheet: the change in words, the command as GAM gets it (masked), and
  how much it can hurt. A destructive confirm is never the Return-key default.
- Held to `Tests/DirectoryStoreTests/UserChangesTests` against the strict mock: GamGUI's argv byte for
  byte, the audit record, the patch, a bare confirm refused, a failure patching nothing.
- **Groups and mail delegates** (`UserAccess`, `UserChanges`): the person's groups (`print groups
  member`, the `email` column) and delegates (`print delegates`, `delegateAddress`) are read live when
  their page opens, kept only for that tenant, generation and person, and read again after a change of
  theirs lands (`UserChanges.finished`). Joining a group is LOW; leaving needs the confirm step
  (GamGUI's `confirm_step`). Adding a delegate runs GamGUI's `_check_delegate` against the cached
  directory: an error blocks it (not an address, the owner, an alias of someone else), a warning is
  shown on the preview and confirming it is "Add Anyway" (not in the directory, suspended). A group
  address must pass `Address.looksLikeEmail` (GamGUI's `looks_like_email`, held to `setup.json`): GAM
  reads a bare name or a comma-joined list as something else. The group is typed for now; a picker
  comes with the Groups screen.
- **Auto-reply and sign-out:** the person's auto-reply is read with their lists (`show vacation`,
  `Vacation(showText:)`, GamGUI's `from_show_text`). Turning it on sends the typed text as GamGUI's HTML
  body (`HTMLText.autoreplyHTML`), with every setting named; the editor pre-fills the stored reply's
  text, not its markup (`HTMLText.autoreplyText`). Both rest on Python's `html.unescape` and
  `HTMLParser` (CPython 3.14), ported as far as these helpers use them, with the HTML5 entity tables
  generated from GamGUI's Python (`scripts/gen_html_entities.py`). `HTMLTextTests` holds all of it to
  `Tests/Fixtures/vacation.json`: 1,816 bodies (curated and seeded random over tags, comments, raw-text
  elements, references and the letters `re.IGNORECASE` folds) and 7,525 references (every HTML5 name).
  Turning it off and signing out are LOW, as GamGUI rates them.
- **From the first live day's audit log (2026-10-09):** a reply went out with no message (the operator
  blanked it on purpose) and with dates left over from an earlier setting that had passed. Neither is
  refused (GamGUI allows both); the preview now says each, and its button reads "Turn On Anyway". An
  end date before the start date is refused. Every record named `actor: null`: the executor now asks
  for the connected admin at each run (`SetupModel.connectedAdmin`).
- **Signature** moves to the Signatures screen (templates, the rendered preview, the Siri intent);
  **account delete** comes with offboarding (destructive, proven on the next real leaver).
- **The person page (2026-10-10):** the operator found the single long column hard going. The page is
  wider and resizable, with the name, address and status in words at the top, an **Actions** menu for
  what changes the account (suspend apart and marked destructive), the last change's result as a
  banner VoiceOver announces, and tabs (Profile, Groups, Mail, Security; mail delegates sit with the
  auto-reply under Mail). A preview leads with the change in words; the command is under **Show
  command**. CI renders each tab (`SWIFTGAMGUI_SELECT`, `SWIFTGAMGUI_TAB`).
- **The list's columns (2026-10-10):** the same six whether or not a page is open. Dropping four
  when a name was clicked read to the operator as lost headers, and rebuilt the table while the page
  slid in. The operator hides, shows, reorders and resizes them (right-click a header, or the toolbar's
  **Columns** menu for the keyboard and VoiceOver, with Show All Columns and Restore Column Order).
  Name can't be hidden. Which columns are hidden is saved in the app's preferences (`UserColumn`) the
  moment the operator hides or shows one; widths and order last the session. The table rewrites widths
  by itself whenever the list narrows or widens (17 times in three openings of a page), so a saved
  whole layout kept squeezed widths as the operator's choice (failure-log 2026-10-10, "table saved its own widths"). A debug snapshot
  touches none of it. Beside an open page the list scrolls sideways, and a sideways scroll takes Name
  out of view: an NSTableView has no frozen column.
- **Opening a page (2026-10-10):** it appears at once, without the inspector's slide. A copy of the
  layout timed frame by frame on the operator's Mac (transparent, click-through window, no Dock icon,
  `NSView.displayLink` plus a run-loop observer) dropped frames in 7 or 8 runs per opening below about
  1,300 pt, with a plain List as with the Table and with a one-line page: macOS 27 lays the window's
  content out wider than the window on every frame of the slide (the sidebar counted twice again).
  Without the slide: none, at 920 pt, 1,100 pt and 3,000 rows; the page shows about 60 ms after the
  click (about 200 ms the first time after launch). New windows open at 1,200 × 760. The page's
  three reads start a quarter second after it opens, so arrowing down the list starts no `gam` for the
  people passed over. `UserAccess` keeps the last eight people's lists, each read on its own, so pages
  in two windows never evict each other; a page shows "Reading…" only while a read of its person is
  waiting or running, and otherwise "Not read" with **Read Again**.
- **Rows (2026-10-10):** `DirectoryStore.rows(_:sortedBy:)` filters and sorts once per list (a
  revision bumped on load and patch), filter and order. Sorting in the view's body re-sorted the whole
  directory on every click (about 19 ms at 500 users, 185 ms at 5,000), which held up the page's
  opening. `GamUser.fullName` is stored, and the search's query is prepared once per search.
- **Widths (failure-log 2026-10-10, "person-page layout loop"):** on macOS 27 an open inspector adds its width, and the floating
  sidebar's a second time, to the list's minimum without raising the window's; when the window can't
  hold the sum, AppKit loops until the app crashes. `ColumnWidths` bounds the sidebar (150–190) and
  the inspector (320–400) and sets the window's minimum (920) so both at their widest leave 100 pt
  to spare; the page's content may shrink rather than widen the inspector. The screenshot runs open
  the page in the smallest window with both dragged wide (`SWIFTGAMGUI_WINDOW=smallest`) and fail
  without that margin. Apple has acknowledged the bug on its forums; nothing here relies on a fix.
- **Live (2026-10-09):** title and department **confirmed**: the operator changed a title through the
  app's preview and confirm, and checked the change in Google. Suspend stays argv-identical: it is
  destructive, so (no spare license) it is first proven on the operator's next real leaver.
  Later that day the operator also ran, through the app, and saw the effect: removing someone from a
  group, adding a mail delegate, turning on an auto-reply, and a sign-out (**confirmed**). Adding to a
  group, removing a delegate and turning an auto-reply off stay argv-identical until run once.

## Testing / live status
- Mock-tested through the strict mock's `print users`.
- **Not live yet:** the first real load is the operator's, with Touch ID and an explicit go for a live
  read.
- The demo (`SWIFTGAMGUI_DEMO=1`, `SWIFTGAMGUI_SCREEN=home`) connects example.com and loads it.
