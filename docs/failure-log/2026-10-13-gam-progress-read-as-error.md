# 2026-10-13 — GAM's progress read as an error: a per-entity "Getting …" line hid the real failure

- **Symptom:** found by reading GAM's source while building the calendar reads, not yet seen live.
  - With `show_gettings` on (GAM's default), GAM 7.48.22 prints a progress line on stderr before each
    entity it reads.
  - `GamError` read such a line as an unknown failure. Unknown outranks not-found, permission-denied,
    own-ACL and service-not-enabled, so the real failure lost.
  - A refused `report users` reads as `GAM failed (unknown, exit=61): Getting Reports for all users`,
    with the generic remediation.
  - A person with Calendar off reads as unknown, not as the per-user refusal a sweep tolerates.
  - A refused sign-out inside `deprovision` keeps its kind, but `kinds` also holds unknown, which a
    best-effort caller refuses.
  - Frozen GamGUI reads all of these the same way today.
- **Cause:** GamGUI's `_PROGRESS_LINE` (`core/gam/errors.py`) is `(Getting all |Got \d+ )`. That covers
  two of GAM's six printers (`gam/__init__.py:2681-2722`), and `GamError.isProgress` ported it exactly.
  The two it misses:
  - `printGettingEntityItem` prints "Getting Group sales@example.com (1/3)".
  - `printGettingEntityItemForWhom` prints "Getting Reports for all users" and "Getting Access Tokens
    for alice@example.com".

  Reads that print one with the argv the builders emit:
  - `report users` (doReport :14505);
  - the calendar reads (:41835, :55757);
  - `deprovision` (:74192, :74213, :74232);
  - `print groups` given specific groups (:37068, :37107, :37123, :37135).
- **Why not caught:**
  - `gam_errors.json` is GamGUI's own reading, so invariant 11 held the port to the reference's
    blind spot. This is the second time, after 2026-10-10's CSV escapes.
  - GamGUI's chatter cases (its `_CHATTER` property strategy, and the generator's) only ever used
    "Getting all …" and "Got N …".
  - The mock lied:
    - It printed the report's progress on **stdout**, in words GAM never writes ("Getting Reports for
      the customer"), and `gam_output.json` recorded that read's records keyed by that line.
    - It printed nothing for `deprovision`.
    - So no test ever put a per-entity "Getting …" line on stderr.
  - The Calendars branch met it first and worked around it in its own code (`GettingLines`), which is
    the wrong layer: every read that prints such a line needs the fix.
- **Fix:** branch `fix/getting-lines`.
  - **`isProgress`:** a stripped line that starts "Getting " or "Got <digits> " is progress, matched
    case-sensitively at the start, scalar by scalar.
    - From GAM's source: `Msg.GETTING`, `GETTING_ALL` and `GOT` are the only messages that start that way
      (every `glmsgs` constant read from the vendored build).
    - Errors start "ERROR:", "WARNING:" or an entity's name, and no `writeStderr` call site writes
      "Getting" otherwise.
    - "Got 0 …" in `badRequestWarning` is prefixed "WARNING: ".
  - **`gen_fixtures.py`:** `gam_progress` swaps GamGUI's `_PROGRESS_LINE` in memory, as `gam_reader`
    does for the CSV. No GamGUI file changes.
    - New cases: each printer's shape, with and without the counter, alone, before a real failure, and
      in case and position variants.
    - `gam_errors.json` keeps frozen GamGUI's reading (`gamgui`) beside the 71 of 1,958 cases where it
      differs.
    - The generator refuses a difference that has no missed progress line, and `GamErrorTests` holds
      the list narrow.
  - **The mock:** `report users` prints GAM's words on stderr (the progress line, then the page count
    after a CR, ended with CR LF). A `noreports` state marker refuses it as `accessErrorExit` does.
    `deprovision` prints its three "Getting …" lines. `gam_output.json`'s report case now reads its
    three rows.
  - **GamGUI keeps the defect** (frozen except GAM updates): reported to the operator, not fixed here.
    Its usage report and offboarding's deprovision are affected. The one-line fix there is
    `_PROGRESS_LINE = re.compile(r"(Getting |Got \d+ )")`.
- **Prevention:**
  - `GamErrorTests`:
    - each progress shape is progress;
    - a real failure after one keeps its kind and message;
    - lookalikes are errors;
    - the deviation list is only missed progress lines, under a tenth of the cases.
  - `MockProgressTests` runs the refused report and a deprovision with a refused sign-out through the
    mock.
  - Five mutants all fail the suite: GamGUI's rule, case-insensitive, anywhere in the line, a counter
    refused, no space after "Getting".
  - The Calendars branch's `GettingLines` filter comes out in a later change.
  - Not live-proven: a refused report or a deprovision on a real tenant is still owed (`live-verify`).
