# 2026-10-10 — GAM's CSV escapes: the reader dropped and mangled escaped values

- **Symptom:** found by reading GAM's source, not yet seen live. GAM writes every CSV with a backslash
  escape character, and our reader had none. Over GAM's own bytes, a `print … formatjson` row whose
  JSON holds a quote (a name like `Ann "Q" Lee`, a group description) was dropped without a word. A
  backslash came back doubled (`C:\\dir`), and a newline in a value came back as the two characters
  `\n`. Frozen GamGUI reads the same way: its `parser.py`, run under its own Python 3.14.6 on four rows
  written as GAM writes them, returned 3 records with the same damage. The operator's GamGUI has this
  defect today.
- **Cause:** GAM 7.48.22's `setDialect` (`gam/__init__.py:8830-8839`) sets `escapechar='\\'` unless
  `csv_output_no_escape_char` is on, and it is off by default. CPython 3.14's writer then doubles every
  backslash and writes a quote inside a JSON string as `\\""`. GamGUI's `csv.DictReader` and our port of
  it used Python's default dialect, which has no escape character.
- **Why not caught:** every test was built from the same blind spot.
  - The mock never escaped: `csv_cell` only doubled quotes, and `print users` printed NDJSON, not GAM's
    CSV.
  - GamGUI's property-test writer (`tests/test_props_parsing.py::_csv`) says it writes CSV as GAM's
    Python 3.14 does, but it never doubles a backslash.
  - `gam_output.json` was GamGUI's reader over those inputs, so invariant 11 held the port faithfully
    to the reference's defect. Parity proves we match GamGUI, not that either matches GAM.
  - No test input came from GAM's writer.
- **Fix:** branch `fix/gam-csv-escaping`.
  - `CSVReader` is a literal port of CPython 3.14.6's `_csv.c` reader with GAM's escape character.
  - `gen_fixtures.py` generates every fixture with GamGUI's parser reading in GAM's dialect, an
    in-memory swap with no GamGUI file changed. `gam_output.json` keeps frozen GamGUI's records beside
    each case it reads differently, and the test holds that list narrow.
  - The mock writes every `formatjson` read it models as GAM does (`gam_row`; users, groups, group
    members, domains, ChromeOS devices), from data files that hold each record as GAM prints it, with a
    user (Dana) and a group description that need the escapes. It refuses the reads whose shape it doesn't
    model (Drive files, resources, calendars, calendar ACLs, events) instead of printing NDJSON.
  - The argv is unchanged, so invariant 1's byte-identical argv still holds. The rejected alternative
    was `redirect csv - noescapechar true`, which changes every read's argv away from GamGUI's
    live-proven one.
  - **GamGUI keeps the defect** (frozen except GAM updates): reported to the operator, not fixed here.
    It affects every `print … formatjson` read GamGUI makes (users, groups, group members, ChromeOS
    devices, resources, calendars, events, domains, Drive files). In its plain-CSV reads (delegates,
    messages and the rest) a backslash comes back doubled. The one-line fix there is
    `csv.DictReader(…, escapechar="\\")` in `gamgui/core/gam/parser.py`.
- **Prevention:**
  - `CSVReader` is held to CPython's own output for the escape edges, to GAM's writer by seeded round
    trips, and by the fuzzer's `csvRoundTrip` target, seeded from `Fuzz/corpus/escaped-quote`.
  - `gen_fixtures.py` reads `setDialect`, the `csv_output_no_escape_char` default and the bundled
    Python (3.14) from the vendored build, and refuses to generate if one moved: a GAM bump can't
    change the dialect silently.
  - `gen_fixtures.py` also refuses a mock whose `formatjson` bytes differ from Python's csv writer in
    GAM's dialect over the same records, or a data line not in GAM's JSON form; `MockCSVTests` checks
    the bytes in Swift. `DirectoryStoreTests` and `GroupStoreTests` compare whole records and IT's
    description, so a dropped row or a doubled backslash fails.
  - Not live-proven: a live read-only check of a user or group whose fields hold a quote, a backslash
    or a newline is still owed (`live-verify`).
