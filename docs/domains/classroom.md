# Domain: Google Classroom (read only)

**One line:** Reads Google Classroom for school domains (classes, who teaches and who is in each), and reads a student
information system's roster export on this Mac (Plan an Import), compares that roster with Classroom into one change
list, and hands the changes over as files someone runs with GAM outside the app (the two-app
[Classroom plan](https://github.com/goetchstone/gamgui/blob/main/docs/plans/2026-11-11-classroom-and-rostering.md), C1–C4).
**The app never writes to Classroom.**

**Owns invariant(s):** none of its own. It leans on #1 (course IDs and addresses validated, one argv element each), #9
(the index, teachers and cards kept bounded) and #11 (both builders held to GamGUI's argv), and on #2 by having no write.
**Enforcement home:** `GoldenArgvTests` (`print_courses`, `print_course_participants`, `print_all_course_participants`),
`ClassroomTests` (builders, the mock, the reader), `ClassroomReadsTests` (the screen's reads, a person's classes, who can
create classes, the classes someone owns), `OffboardChangesTests` (the leaver's classes), `GamErrorTests` and
`GuidedSetupTests` (`only_unknown_owners` and `classroom_readable`, held to `gam_errors.json` and `setup.json`),
`RosterParityTests` (the roster reader, held to `roster.json` and `roster_mapped.json`'s uploads),
`RosterMappedParityTests` (Clever's reader and the column map, held to `roster_mapped.json` and the shared
`Tests/Fixtures/roster/clever/`), `RosterMapStoreTests` (the saved maps), `RosterStoreTests` (the kept roster, the picker, the
issues), `ClassroomStateTests` (the compare's read, held to `roster_plan.json`'s `managed_from`), `RosterPlanTests` (the
change list, held to `roster_plan.json`), `RosterHandoverTests` (the hand-over, byte for byte with `Tests/Fixtures/handover/`
and the grammar) and `RosterCompareTests` (the compare and the hand-over end to end through the mock).

GamGUI's runbook of the same name (`docs/domains/classroom.md` in its repo) is the reference: this app ports each piece from
GamGUI's merge commit, GamGUI first. Status by item is the plan's table, in GamGUI's repo.

## Files
- `GamEngine/GamCommands.swift`: `printCourses` (with `aliases`), `printCourseParticipants`, `printAllCourseParticipants`,
  `CourseState`, `courseFields`, `isCourseID`.
- `GamEngine/Classroom.swift`: `Course`, `Participant`, `Roster`; `courses`, `roster`, `records` (a shortfall is never
  complete), `matching` (the index search), `scopes`, `scopesMissing`, `scopeNote`, `notRun`, `classLink`; `personStates`,
  `owned(_:by:)`, `ownedRows`, `ownedFileName` (C1.4, C1.5).
- `GamEngine/GamError.swift`: `onlyUnknownOwners` (GamGUI's `only_unknown_owners`, #113).
- `Setup/SetupModel.swift`: `classroomReadable` (GamGUI's `classroom_readable`), from the admin token read at Check access.
- `Directory/UserAccess.swift`: `courses`, `course`, `roster`, `coursesOwned(by:)`, each failure in words.
- `Directory/ClassroomReads.swift`: the screen's store: the index, a teacher's classes, a class's card, a person's classes
  (`readPerson`, `PersonClasses`), the teachers group (`teachersGroup`).
- `Directory/OffboardChanges.swift`: `OwnedClasses`, the plan's Classroom warning.
- `App/ClassroomView.swift` (the screen, who can create classes), `App/UsersView.swift` (`PersonClassesSection`),
  `App/OffboardView.swift` (`OwnedClassesNote`).
- `Stores/Roster/`: `Roster.swift` (`Roster.read`, the upload's flow, OneRoster 1.1 and 1.2, `RosterCaps`),
  `RosterZip.swift` (the ZIP reader, `CRC32`), `RosterCSV.swift` (`RosterLines`, `RosterCSV`, `Roster.rows`, `clean`),
  `RosterSnapshot.swift` (the model, `issueWords`), `RosterStore.swift` (the kept roster), `RosterImport.swift` (the
  picker's reads, the issues grouped, the Issues CSV's rows), `RosterClever.swift` (Clever's CSV, C5.2),
  `RosterMapped.swift` (`RosterColumnMap`, `RosterMapped`: one spreadsheet read by its column map, C5.3),
  `RosterMapStore.swift` (the saved maps). `App/RosterImportView.swift` (`RosterKeeper`, the held spreadsheet, the
  screen), `App/RosterMapView.swift` (`RosterMaps`, `RosterMapStep`, the map step).
- `GamEngine/ClassroomState.swift` (`Classroom.Managed`, `Classroom.state`, `aliases`: GamGUI's `managed_from`),
  `Directory/UserAccess.swift` (`classroomState`, `directoryAddresses`), `Stores/Roster/RosterPlan.swift` (the planner, the
  list's pages), `Stores/Roster/RosterHandover.swift` (the files and the ZIP), `Directory/RosterCompare.swift` (the compare
  and the hand-over held per tenant and roster, audited), `App/RosterCompareView.swift` (the screen's part).
- `Tests/Fixtures/roster_plan.json` (GamGUI's `plan` over every call its planner tests make and its web test's compare,
  with `roster_handover`'s files for each), `Tests/Fixtures/roster_handover.json` and `Tests/Fixtures/handover/` (GamGUI's
  own hand-over fixture, byte for byte), all from `scripts/gen_fixtures.py`.
- `Tests/Fixtures/roster.json` (GamGUI's `read_upload` over 158 packages, from `scripts/gen_fixtures.py`),
  `Tests/Fixtures/roster_mapped.json` (every call GamGUI's Clever and column-map tests make, recorded as they run, with
  the map step's readers), `Tests/Fixtures/roster/clever/` (GamGUI's Clever fixture, copied byte for byte by the
  generator, which checks it), `Tests/Fixtures/demo/roster/` (the snapshots' OneRoster export: made-up people, a problem
  of each common kind), `Tests/Fixtures/demo/schedule.csv` (the map step's spreadsheet).
- `Tests/Fixtures/mock_gam.sh` (`print courses`, `print course-participants`), `mock_gam/courses.json`,
  `mock_gam/course_participants.tsv`, `mock_gam/course_aliases.tsv`: GamGUI's handlers and data at 07c505d.

## How GAM reads Classroom (read from the 7.51.00 build by GamGUI, not seen live)
- **With the admin token**, not the service account (`buildGAPIObject(CLASSROOM)`): the scopes are GAM's "Classroom API -
  Courses", "- Rosters" and "- Profile Emails" (read-only will do), picked when the admin token is made. Without them GAM
  exits 15 with "There are no scopes authorized for the API(s): Classroom API", read as `scopeMissing` for any API.
- **Output.** `print courses … formatjson` is `id,JSON`; with `aliases`, `id,JSON,JSON-aliases`, each alias an object as the
  API gives it, `[{"alias": "d:gg-C1"}]` (GamGUI's mock once printed strings: review 2026-11-11). `print course-participants
  … formatjson` is one row per class: `courseId,courseName,JSON-teachers,JSON-students`, each `JSON-` cell a list of
  people; by `states … show all`, one row for every class in those states. The two domain-wide reads are built and held
  to GamGUI's argv for its roster compare (C3), not yet read by any screen here.
- **An owner GAM can't look up keeps the read** (GamGUI #113, now parity). With `owneremail`, a deleted owner is GAM's
  warning `Course: <id>, Owner ID: <id>, Does not exist (i/n)`, exit 56, after it printed every class with that owner as
  "Unknown user" (`_convertCourseUserIdToEmailName` → `entityDoesNotHaveItemWarning`). `records` reads the table when every
  error line is that warning (`GamError.onlyUnknownOwners`), and "Unknown user" is never kept as an address (the owner is
  named from the directory by ID). The mock models it: `$GAM_MOCK_STATE/ownergone/<owner id>`.
- **Not found.** A teacher, student or class Classroom doesn't know is `<Entity>: <x>, Does not exist`, exit 56.
- **Never the join code.** `courseFields` leaves out `enrollmentcode`.
- **`owneremail` costs a Directory read per owner.** The index leaves it off and names owners from the directory as cached,
  by ID, never a fetch; a teacher's classes and a class's card ask for it.

## The screen
- One field. Text filters the index of open classes (`active,provisioned`) by name, section or room, case aside. A teacher's
  address reads that teacher's classes, archived ones too, only on Return: as it's typed the screen says "Press Return".
- The index loads after the screen shows, once per tenant. A failed index read is said again, not re-run, for 60 seconds;
  Refresh (⌘R) and Try Again read at once. A tenant switch shows none of the old reads.
- The card: section, room, state, owner, class ID; "Open the Class in Classroom" only for an address starting
  `https://classroom.google.com/`; teachers beside students, each capped at 200 with a count past it. A roster that failed,
  came back short (`unreadable`) or without addresses (`emailsHidden`) says so above the lists.
- The screen says once that it only reads Classroom and hasn't been checked on a real school domain.

## Beside the people screens (C1.4–C1.6, from GamGUI 07c505d)
- **Whether to read at all: `SetupModel.classroomReadable`** (GamGUI's `classroom_readable(vault, domain)`): false on an
  admin token whose recorded scopes are known to lack Classroom's (a domain that doesn't use it), nil when they can't be
  read, true when they're there. Only false skips a read; nil tries. Read from the token at Check access, never by a
  Keychain read per page (each would ask for Touch ID). Held to `setup.json`.
- **A person's classes** (`PersonClassesSection` on a person's Profile, left off when `classroomReadable` is false): reads
  nothing until **Show Their Classes**, then what they teach (the ones they own marked "Owner", in words) and what they're
  in, `Classroom.personStates` (active, not yet accepted, archived), 50 a side with a count past it. Each opens its class
  card on Classroom (an archived class too, which the open-class list doesn't hold). One cause for both reads is said once
  (`PersonClasses.oneCause`). The reads are `ClassroomReads.readPerson`, kept per tenant, the last few people only.
- **Offboarding** (`OffboardChanges.OwnedClasses`; [offboarding.md](offboarding.md)): the classes the leaver owns
  (`UserAccess.coursesOwned(by:)`: every state; Classroom not knowing them as a teacher, exit 56, is none) named with a note
  that GAM GUI doesn't change Classroom, the first 10 listed and the rest counted, and **Download the List (CSV)**: GamGUI's
  columns (`courseId,name,section,state,owner,link`) and file name (`classes-owned-by-<local part>.csv`, filename-safe), each
  cell formula-safe and the file 0600 (`AuditExport`). A failed read is said, never taken as none; a token known to lack the
  scopes reads and says nothing. A warning, not a step: nothing in ChangeCore.
- **Who can create classes** (`CreatorsPanel` under the class list, left off where `classroomReadable` is false): the group
  named "Classroom Teachers" or at `classroom_teachers@`, from the group list as cached (read once if none is), its direct
  member count, and a button to it on Groups, where adding a staff group is the existing write. None found says the Admin
  console's Classroom settings name the group. GAM GUI reconciles nothing.
- **Refusals are fixed words** (GamGUI's rule, CodeQL `py/stack-trace-exposure` there): every Classroom path says a fixed
  sentence or GAM's own scrubbed message, never a Swift error's text (`Classroom.notRun`, the CSV save's "Couldn't save").

## The roster upload (C2.1, C2.3, C5.1, from GamGUI 07c505d)
- **`Roster.read(uploads)`** is GamGUI's `read_upload`: one ZIP or loose CSV files, the export told by its file names
  alone (`detect`; nothing unpacked), OneRoster 1.1 or 1.2 read into one `RosterSnapshot` (schools, terms, courses,
  classes, people, enrolments, in the export's order). Every refusal is GamGUI's `PackageError` in its words, "GamGUI"
  included (as the offboarding port keeps it), and **`roster.json` holds every one**: the generator builds each package
  GamGUI's `tests/test_roster.py` builds (the adversarial run's cases among them) and the ZIP and CSV shapes behind them,
  runs GamGUI's reader at the pin, and the Swift reader must give the same words or the same snapshot. A cap a case
  lowers is recorded and passed as `RosterCaps`, as GamGUI's tests monkeypatch it.
- **Clever is read; one picked CSV is a spreadsheet to map** (C5.2, C5.3, below): Clever's names read through
  `filesFromZip`/`filesFromCSVs` with `RosterClever.layout`, and one CSV, whatever its name, is `Refusal.needsMap(name:,
  bytes:)` (GamGUI's `NeedsMap`), the screen's map step.
- **The ZIP reader (`RosterZip`) never extracts.** Foundation has none, and a shelled `ditto`/`unzip` writes files. It is
  `zipfile` 3.14 as GamGUI drives it, read to the end of each function: the end record (`_EndRecData`, the ZIP64 locator
  and record checked as `_EndRecData64` checks them), the directory's size and entry count capped **before** it is walked,
  the walk by size (cp437 or strict UTF-8 names, the Unicode Path field 0x7075 honoured when its CRC matches, a version
  past 6.3 or a malformed extra field refusing), `_end_offset` against overlapping members, the local header's signature
  and name. A member is inflated by zlib's own raw `inflate` (windowBits -15, `import zlib`), the decoder Python's
  `zlib.decompressobj(-15)` wraps, streamed from the member's bytes: a stream `zlib` calls bad is "couldn't be unpacked",
  and one whose input runs out first ends there as `zipfile`'s does, the CRC deciding. (Not the Compression framework:
  its `COMPRESSION_ZLIB` consumes a corrupt stream whole and reports it as an error, a quiet nothing or a short end,
  which can't be told from a truncated stream, and a few streams `zlib` refuses it reads to their end; `roster.json`
  holds the shapes.) It is cut at the directory's size as `ZipExtFile` cuts it, read in the 1 MiB reads GamGUI's `_bounded` makes
  with the cap checked after each, and its CRC-32 checked when its end is reached. A file no reader uses is named and
  never inflated (`roster.json` has one whose CRC is wrong).
- **The CSV reader (`RosterLines`, `RosterCSV`) works on bytes, counting characters as Python does.** Lines end at "
",
  "
" or "
"; decoding is checked in `TextIOWrapper`'s 8192-byte chunks when a line first needs one, so the refusal
  that comes first is GamGUI's (a missing column before a bad byte two chunks on). As CPython's does, the check holds a
  chunk's cut-off last character, and a surrogate's first two bytes (ED A0..BF) at a chunk's end, for the next chunk
  to refuse (unicodeobject.c, "Truncated surrogate code"). The parser is CPython 3.14's
  `_csv.c` reader in strict mode, state for state, with the module's default field limit (131,072 characters). The repo's
  `CSVReader` (GamEngine) isn't reused: it reads GAM's output, lenient and whole, where this must be strict and streamed.
  A row is built from the used columns alone; an address is checked as given, then lowercased (U+212A); every other cell
  drops controls and Cf characters in Python's Unicode version. IDs are compared by their exact characters (`ExactKey`):
  a Swift `String` would take é and e + ◌́ as one ID.

## More than one SIS (C5.1 to C5.3, from GamGUI 07c505d)
- **Every reader goes through the same bounds.** `Roster.Layout` names an export's files and the ones never unpacked;
  every row is read by `Roster.rowValues` (`rows` is its keyed form), which builds a row from the `used` columns alone
  and stops when told (`preview` stops after three rows; nothing past them is read). That is what keeps passwords out:
  **Clever's `Username`, `Password`, `Contact_*` and its demographic columns, OneRoster 1.2's `userProfiles.csv` and any
  `password` column are never read into anything**; Clever's `staff.csv` and `administrators.csv` are named, never
  unpacked. The values come back in `used`'s order, so two column names Swift's `String` takes as one (é and e + ◌́) stay
  two, as Python keeps them.
- **Detection by name** is C5.1's (`detect`); **one picked CSV is always a spreadsheet to map, whatever its name** (a SIS
  report called `students.csv` is not a Clever export missing four files).
- **Clever** (`RosterClever`, SFTP CSV spec v2.2.0): headers matched ignoring case only (`foldCase`). People are
  `student:<id>` and `teacher:<id>` (separate ID spaces). A repeated ID keeps its first row; a repeat with a different
  address is a `conflict`. A section's `Teacher_id` is its primary teacher, `Teacher_2_id`..`Teacher_10_id` co-teachers
  (a repeat dropped); `enrollments.csv` is students only. Courses (`course:<Course_number>`) and terms
  (`term:<name>|<start>|<end>`, MM/DD/YYYY to ISO only when exactly that and a real date) are built from section columns.
  Title: `Name`, else `Course_name - Period <Period>`, else `Course_name`. Each file is taken out of the dictionary as
  it's read. The shared fixture is GamGUI's `tests/fixtures/roster/clever/`, copied by the generator and read by
  `theSharedCleverFixtureReadsAsGamGUIsTestReadsIt`.
- **A spreadsheet of any other shape** (`RosterMapped`, one flat file, a row per person in a class). `RosterColumnMap`
  maps six fields (class ID, class name, email and role needed; section and primary teacher optional) and the role words;
  `guess(header)` fills what the header's names suggest, each column for one field at most; `preview` reads three rows;
  `read` reads the rest (person ID = address; a class's name or section that differs on a later row is a `conflict`, the
  first kept; a role word in neither list is `unknown_role`; a primary flag counts for a teacher only, in GamGUI's truthy
  words; someone who teaches one class and studies in another counts as a teacher).
- **What GamGUI's adversarial run of C5 found, and the rule each keeps here:** an address is checked as given, then
  lowercased, in every reader (U+212A KELVIN SIGN lowercases to an ASCII `k`); the mapped reader cleans every field but
  the address by field, since one column may be mapped as the address and a class; `headerOf` (GamGUI's `header_of`)
  refuses a first line holding an address (a sheet without its header would save a student's address as a column name)
  and a column name past `RosterCaps.headerCell` (200).
- **Saved maps** (`RosterMapStore`): `roster-maps.json` beside the offboarding templates, GamGUI's format
  (`{"version": 1, "maps": {name: map}}`), column names and role words only. Read by descriptor and written atomically
  `0600` in a `0700` folder through `SignatureStore.load`/`writeFile`; a file it can't read is moved aside and said on the
  map step, never saved over. Names are GamGUI's rules: stripped, at most 60 characters, printable (Python's
  `isprintable`), at most 50 maps; a name kept already in another case is replaced; listed ignoring case.
- **Parity:** `roster_mapped.json` is recorded by running GamGUI's own `tests/test_roster_clever.py` and
  `test_roster_mapped.py` (each synchronous test without a fixture, once per parameter set) with `read_clever`,
  `read_upload`, `guess`, `preview`, `read_mapped`, `ColumnMap.problem` and `from_json` wrapped, plus the web tests' map
  step, `header_of`'s refusals, the form's role words and the name rules. The store tests GamGUI runs with `tmp_path` are
  ported as native tests.

## The kept roster (C2.5)
- **`RosterStore`**: one file per domain in `<Application Support>/SwiftGamGui/roster/`, named by a hash of the domain,
  `0600` in a `0700` folder refused if it's a link or someone else's; the folder opened once, every file reached from it
  (`openat`, `O_NOFOLLOW`). Written under `.saving-<pid>-<name>` and renamed in; **every `.saving-*` copy of that domain's
  file is swept** by the next save and by Purge (a folder by that name is left). A copy a quit or crash left before its
  rename has no snapshot to Purge, so **every look and the app's launch sweep each abandoned copy of any domain**
  (`sweepAbandoned`), whatever pid its name records. One save, read, purge or sweep at a time **across every running
  copy of the app**: the in-process lock plus `flock(LOCK_EX)` on the folder's descriptor, so while the store is held no
  save is in progress anywhere and every `.saving-*` file is abandoned. (An in-process lock alone let a second copy's
  save or Purge delete the first's temporary file mid-save; a pid/mtime guess kept a crash leftover whose pid was reused
  or whose mtime was ahead of the clock. GamGUI's `roster_store.py` had only an in-process `RLock`, and took this design in gamgui#120, found by this port.) The folder
  opened is checked by descriptor against the one checked by path, and again after the lock is taken: a folder moved
  or swapped meanwhile is refused, never written into. The listing's descriptor is close-on-exec, since it shares the
  locked description and a child that kept it would hold the store.
- **The format is this app's own** (GamGUI keeps SQLite; nothing else reads this): `SGGROST1`, the head's length, the head
  as JSON (metadata, issue counts, the issues kept), then the body (schools … enrolments). **The screen reads the head
  alone** (`meta`, `issues`), never the people; `load` reads the whole, for the compare to come.
- **Kept `keepDays` (14), and expiry fails closed**: an unreadable date, an import dated more than a day ahead, or a
  stored expiry past `imported + keepDays` deletes it on the next look. A head whose content can't be read deletes the
  file and says so; a read the disk failed (an I/O error, not the content) only says so, and never deletes a good
  roster. Reads and writes retry an interrupted call. No data-protection class is set on the file: FileVault protects it at rest, as SECURITY.md says.

## Plan an Import (C2.2, C2.4)
- **Classroom has two parts**, a segmented control above the screen (GamGUI's two tabs are links): Classes and Plan an
  Import. A class asked for from another screen opens Classes.
- **One `fileImporter`** takes a ZIP, a folder or CSV files (several at once). `RosterImport.readPicked` reads each by
  descriptor, never through a link (a link is refused); a picked folder gives its own files, its folders left. More than
  `members` files, or more than `upload` bytes by `fstat`, is refused before any byte is read; each file is then read at
  most one byte past what's left. Security-scoped access ends once the files are read. Reading, saving and the audit run
  off the main actor (`RosterKeeper`).
- **Beside the picker, what to export**: OneRoster, Clever, or one spreadsheet mapped by its columns. A refusal is said
  under the picker; the last good roster stays.
- **The map step** (C5.3, `RosterMapView`): one picked spreadsheet isn't read on pick. Its header is read (`headerOf`; a
  refusal is said under the picker) and it is **held in memory only** (`RosterKeeper.held`: name, bytes, header, the
  domain and tenant generation it was picked on; never on disk), and the kept roster's pane shows its columns: a picker per
  field (labelled, "needed" or "optional"), the role words (comma-separated), and **three rows read with the map**,
  again on every change, off the main actor, a field per line and a row per column so it fits the smallest window; a row
  whose role word is in neither list says "Neither: check the role words" with a warning symbol, never colour alone. On
  first sight the map is a saved one that fits the header, else a guess. **Use a saved map** loads one (only when that
  picker changes); **Delete “name”…** asks first and leaves the spreadsheet; **Save Map As** keeps the map under a name;
  **Read with This Map** (disabled while the map has a problem) saves it too when a name is typed, reads the whole
  sheet, and keeps it like an export, audited `roster_import` with `mapped_fields` (which fields were mapped, never the
  column names: they are the sheet's text); **Cancel** (Escape) drops it. A new pick (read or refused), Purge, a read,
  Cancel or a tenant switch drops what's held; one held for another domain or generation is never read, and a read that
  ends after the held sheet changed keeps nothing.
- **What's kept**: "Read:" or "Kept:" and the label (the file's name, or "N CSV files"), the format, when it was read and
  when it's deleted, the seven counts, the people in other roles, then **Problems to fix in your SIS**: each kind most
  frequent first, its whole count and cause, opening to its fix and its first `issuesShown` (20) rows; **Issues CSV…**
  saves every row kept (GamGUI's columns `kind,cause,fix,file,line,ID,detail,kind_total`) through `AuditExport`
  (formula-safe, `0600`, whole or not at all). **Purge It Now…** asks first.
- **Audited as local events** in the app's own log (`connector: local`): `roster_import` (source, label, the picked
  bytes' SHA-256, the counts, each kind of issue's count; never a row) and `roster_purge` (`deleted`). No GAM runs on
  this screen. A tenant switch made anywhere drops what's held at once (`SetupModel.onTenantChange`), not when the screen
  next appears; a read that ends on another domain keeps nothing and says so.
- **Snapshots**: `classroom-import` (`SWIFTGAMGUI_TAB=import`) with the demo package kept in a temporary store;
  `classroom-clever` (`clever`) with Clever's shared fixture kept; `classroom-map` and `narrow-classroom-map` (`map`)
  with `demo/schedule.csv` held for its map, opening on the demo's saved map. CI renders them (a hook blocks launching
  the app here).

## Compare with Classroom (C3, from GamGUI 07c505d)
- **`RosterPlan.plan(snapshot, classroom:, directory:, unread:)`** is GamGUI's `roster_plan.plan`, pure: a `ChangeList`
  (changes in run order, counts, flags, notes, `summary`). No GAM, nothing written. It is held to
  `Tests/Fixtures/roster_plan.json`: the generator wraps GamGUI's `plan` while every synchronous test in its
  `tests/test_roster_plan.py` runs, and records the web test's compare (its SIS files through `read_upload`, Classroom
  through `managed_from` from GamGUI's mock, plain and with the lowered `LIMITS` its flagged test uses), so each call's
  inputs and its whole ChangeList, plus `roster_handover`'s files for it, are a case `RosterPlanTests` must equal.
- **The app's classes carry its alias**, `d:gg-<sourcedId>` (`RosterPlan.alias(for:)`: the ID when it's `[A-Za-z0-9._-]`,
  1 to 80, else `h` and 24 hex of its UTF-8's SHA-256). Only those are compared, updated or archived; a hand-made class
  is counted as left alone. GAM may print an alias with or without `d:`; both are read.
- **Kinds and run order, risk and notes** are GamGUI's (its runbook's C3 section is the reference): `Change.swap` (a role
  swap's removal first), `Change.late` (an outgoing owner's student add after the teacher removals), `RosterPlan.limits`
  (count and share, both past) with each flag's sentence, the duplicate-create guard (a class matching an unaliased one by
  name and section is noted, never created), a directory that only limits who is added, an owner not read (no removals
  there), and the headline that never says "already matches" when the list is incomplete or has notes.
- **Text is compared by its code points** (`ExactKey`), as Python's `str`: a Swift `String` takes "é" and "e" + U+0301 for
  one address or title, and would sort, dedupe and match differently. Sorting is Python's (code point; a stable sort's
  ties by position). `f"{n:,}"`, `.1%` and `.0%` are `RosterPlan.grouped` and `%.1f`/`%.0f` of the share × 100.
- **The read** (`UserAccess.classroomState`, GamGUI's `classroom_state`): `print courses states active,provisioned,archived
  owneremail aliases fields … formatjson` then `print course-participants states … show all formatjson`, one after the
  other, the domain-wide timeout each, paired by `Classroom.state` (GamGUI's `managed_from`): each record as read (none
  merged), a later participants row for an ID replacing an earlier one, aliases read as objects (`[{"alias": …}]`; a bare
  string too; anything else makes the cell unread), no `JSON-aliases` cell read as no alias. A class whose aliases can't
  be read, whose row is missing, or whose roster is unreadable or hides an address is **unread**, and any unread class
  makes the list incomplete. `ClassroomStateTests` holds the pairing to every `managed_from` case the generator recorded,
  and the Swift mock's two reads to the classes GamGUI's mock gave its web test.
- **The directory** (`UserAccess.directoryAddresses`): `print users` with the cache's fields, read fresh each compare,
  primary addresses lowercased. Unread, the plan has no directory and says so (`RosterPlan.directoryUnread`, GamGUI's note).
- **The compare** (`RosterCompare`, in Directory so it's tested; the app's `RosterKeeper` holds it): one at a time, not
  stoppable (the screen going away doesn't cancel it), its change list held in memory only, for the tenant and generation
  and the kept roster's SHA-256 it was made from. A new upload or a purge drops it (`drop()`), and so does a tenant switch
  (`onTenantChange`). `drop()` drops a compare still reading too: its reads finish unseen and store nothing (no change
  list, no failure, no audit), and the next ask starts at once. Before, a switch or a new upload mid-read left the old
  compare holding the one slot, so Compare on the new tenant did nothing and said nothing, and a new roster showed the
  old one's spinner, failure or announcement. `compare()` returns what the ask came to (`Outcome`: compared, failed,
  busy, dropped) and the screen says that, never what it reads back later. Audited as `roster_compare` (when, the roster's
  hash, counts, flagged kinds, incomplete, unread and unmanaged counts; never a row).
- **The screen** (`RosterCompareView`, under the issues on Plan an Import): **Compare with Classroom**; while it reads,
  GamGUI's sentence; a failure as "Couldn't compare with Classroom." and the read's fixed words (the scope note, or GAM's
  scrubbed message), with Try Again; then "Change list · compared <when>" with **Compare Again**, the summary (focused for
  VoiceOver and announced), each flag (icon and "held back", not color alone), the notes, a chip per kind with its count
  (a wrapping row), and the list searched (class, alias or person) and paged by 50 (`RosterPlan.page`, GamGUI's
  `_changes_ctx`), off the main actor: the search waits a quarter second after typing (GamGUI's `delay:250ms`) and runs
  over `Held.haystack`, each change's search text lowered once per compare, never in the view body (a district's list is
  tens of thousands of rows). A held-back row has the chip's icon, not orange alone. The screen resets on `Held.id`,
  each compare's own (two in one minute share `when`). Compare, Compare Again and Try Again take ⌘R (the toolbar's
  Refresh is the Classes part's). The hand-over's split, CSV, ZIP and CRC run detached too (`RosterCompare.package`).
  The planner's "GamGUI" reads "GAM GUI" on the screen (`shown`); the files keep GamGUI's words.

## Hand it over (C4, from GamGUI 07c505d)
- **`RosterHandover.build`** is GamGUI's `roster_handover.build`, pure: `README.txt`, `review.csv` and a numbered CSV per
  kind (`steps`, GamGUI's `STEPS`), each with its `shlex.join`ed `gam csv <file> noescapechar true gam …` line. Nothing
  runs GAM. `Refusal.incomplete` / `.nothing` carry GamGUI's fixed words; `kept(_:including:)` is `kept_changes` (a flagged
  kind not ticked is left out, and what needs it).
- **Bytes are GamGUI's.** `Tests/Fixtures/handover/` is GamGUI's own `tests/fixtures/handover/`, written by the generator
  only when GamGUI still writes exactly that; `RosterHandoverTests` builds GamGUI's test list and equals each file byte for
  byte, and equals the files for a list of values Python's csv writer treats specially (CR, LF, quotes, a lead space, a
  one-empty-field row written `""`, formula leads, combining marks). The plain CSV is Python's `QUOTE_MINIMAL` (comma,
  quote, CR or LF quoted, quotes doubled, CRLF), scalar by scalar.
- **`review.csv` is formula-safe** with `RosterHandover.csvSafe`: GamGUI's `csv_safe`, the same rule as ChangeCore's
  `AuditExport.safe` (Stores doesn't depend on ChangeCore; `RosterCompareTests` holds the two to one rule). The GAM files
  keep values exact.
- **The grammar:** `eachCommandIsOneTheGrammarHas` is GamGUI's `test_each_command_is_one_the_grammar_has` over
  `Vendor/gam7/GamCommands.txt` (each word a choice, a `~field` in a `<slot>`, a keyword in its nonterminal's definition,
  the fields among the columns); `eachReadmeLineRunsAsWrittenInZsh` runs zsh's `print` over each line.
- **The ZIP** (`RosterHandover.zip`) is written here: stored, entries in name order, each dated with the compare's minute
  (DOS time) and `0600` (made on Unix), so one compare gives one set of bytes; a test reads it back with the C2 reader
  (`RosterZip`). It's named `classroom-changes-<domain>-<yyyymmddhhmm>.zip` (GamGUI's `_zip_name`).
- **Saved, never opened:** **Download the Hand-over…** is a save panel; `RosterCompare.handOver` writes through
  `AuditExport.writePrivately(bytes:to:)` (0600, created exclusively, never through a link, whole or not at all) and
  audits `roster_handover` (when compared, the kept changes' counts, the flagged kinds included; never a row). The
  statement comes before the button (C4.3): the files run outside GAM GUI's preview, confirmation and audit log, and
  Classroom support hasn't been checked on a real school domain. A flagged kind is a checkbox to include it; any other
  kind asked for is ignored.
- **Compare Again** (C4.4) reads Classroom again: what's left is what didn't happen.
- **Snapshots**: `classroom-compare` and `narrow-classroom-compare` (`SWIFTGAMGUI_TAB=compare`): the demo roster compared
  with the mock's Classroom before the picture (`Spikes`): a rename, adds, a create, the hand-over's statement. Not run
  locally (a hook blocks launching the app); CI renders them.

## Deviations from GamGUI (each tested)
- **The compare:** one read of the directory, fresh, every compare (GamGUI uses its user cache within its TTL); an empty
  directory is taken as unread, never as "nobody has an account". An unknown-owner exit 56 is accepted as the C1 reads
  accept it (`Classroom.records`; the owner reads as not read, so the plan notes it): GamGUI's `classroom_state` runs
  without that rule and fails the whole compare on one deleted owner. The compare is also audited (`roster_compare`);
  GamGUI lists it only in its jobs tray.
- **The hand-over is saved through a save panel**, not a browser download, and its ZIP is stored, not deflated: the ZIP's
  bytes differ from GamGUI's; every file inside is the same.
- **The screen says "GAM GUI"** where the planner's sentences say "GamGUI"; the hand-over's files keep "GamGUI" (they are
  the two apps' shared contract).
- **Flagged kinds are ticked, then one download** (GamGUI has a second link that includes every flagged kind).
- **The roster reader refuses what `zipfile` would read, where a roster export never needs it** (`roster.json` marks each
  `swift: refused`, or the Swift tests hold it): ZIP64 (said in its own sentence; a full 32-bit size or offset counts), a
  NUL in a member's name (`zipfile` cuts the name at it; here it isn't a plain file name), BZIP2 and LZMA members (only
  stored and deflate; GamGUI's "couldn't be unpacked" words), and two entries sharing one local header (`zipfile` only
  warns).
- **The map step** (C5.3): **Save Map As** saves without reading (GamGUI saves only with Read, which also saves here);
  the role words stay as typed while the map takes the words read from them (GamGUI redraws them joined); a column
  named twice in the header is offered once; a held spreadsheet is tied to the tenant generation as well as the domain.
  Its preview checks an address as the read does before lowercasing it, and says why the read would leave a row out (no
  class ID, no address, not one address, in the read's order, each once its field is mapped). GamGUI at 07c505d
  lowercased first, so a Kelvin sign U+212A showed as an ASCII k and "Teacher" for a row `read_mapped` refuses; it
  matched this in gamgui#123 (found by this port): drop this sentence when the fixtures move past it. Role words, saved map names and columns are compared and picked by
  exact text (Swift's `String ==` takes NFC and NFD spellings as one). Cancel has no Escape shortcut, and Cancel and a
  new pick wait while the map's read runs.
- **The saved maps file**, as this app's other stores: an unreadable one is moved aside to
  `roster-maps.json.unreadable-<UTC time>` (GamGUI: `-<epoch seconds>`), and one the system can't read (an I/O error,
  not its content) isn't moved: the store doesn't open and saving says why (GamGUI moves it aside). It is written by the
  app's JSON writer (GamGUI: `indent=2`); the keys and values are GamGUI's, and a version that isn't the integer 1 is
  refused.
- **The csv field limit is fixed at the module's default.** GamGUI never sets it, and another read in its process may
  raise it, so past 131,072 characters GamGUI says either the csv module's error or the field cap; here, always the
  module's (as the fixture records it).
- **The picker:** more files than `members` says so in its own sentence (GamGUI's form parser says "The upload couldn't
  be read"); the bytes are bounded by `fstat` before reading (GamGUI's server spools the upload first); a link is refused.
- **The kept roster's file** is this app's framed JSON, not SQLite; a head that can't be read is said in fixed words,
  without the error's own text.
- **An unknown-owner 56 with no table is a shortfall.** GamGUI at 07c505d raised the 56 (not-found), which its offboarding
  read took as "owns none"; here it's `Incomplete`, said, never none. GamGUI matched it in gamgui#119 (found by this port):
  drop this line when the fixtures move past that commit.
- **The owned list is the one in hand.** GamGUI's CSV route reads the classes again; here the list the plan shows is saved,
  so the file is exactly what was shown.
- **A stopped read is never kept.** Leaving the screen mid-read cancels it; the store keeps nothing, so the next look reads
  again, and a cancellation is said in fixed words, never Swift's own text.
- **A person with no address is said** ("Someone (no address shown)", "no address shown" under a name), never a blank row.

## Gotchas / mock-lies traps
- **A failed side of a roster can read as empty, and nothing here can tell.** GAM's `_getCourseAliasesMembers` swallows
  `notFound` and `serviceNotAvailable` on a class's teachers or students and prints `[]`, exit 0 (7.51.00).
- **Not modelled by the mock:** an address outside GAM's domain is GAM's `Teacher: x, Service not applicable`, exit 73
  (`entityUnknownWarning`), not the mock's "Does not exist", 56; and GAM checks the Classroom scope before the arguments.
  The app shows GAM's message for the first; neither changes what's read.
- **A shortfall never reads as complete.** No output at all is `Incomplete` (GAM prints its header even for none), a missing
  row or `JSON-` column or a cell that isn't a list is `unreadable`, and a class's missing record is "answered without it",
  never "no such class".
- **Setup lists no Classroom scopes.** Unlike GamGUI's delegation step, Setup here shows no optional admin-token scopes; a
  failed read says which to add (`scopeNote`), as the Chrome profiles read does. Reads the token's recorded scopes say it
  lacks are skipped (`classroomReadable`), so a domain without Classroom shows no failure on every person's page.
- The mock refuses what it doesn't model (`print courses` without `formatjson`, by ID and a filter at once,
  `aliasesincolumns`; `print course-participants` by teacher, by ID and states at once, or with neither), and takes `all`
  in a states list only on its own.
  `$GAM_MOCK_STATE/noclassroom` is a token without the scopes, `classroom_silent` GAM answering nothing.

## Testing / live-verification status
Offline only: `swift test --package-path Packages/GamKit --filter Classroom` and `--filter Roster`. The map step is not
seen here (the app isn't launched in these sessions); CI's `classroom-map` shots are its first look. The roster's, the
change list's and the hand-over's parity fixtures are regenerated with the others (`scripts/gen_fixtures.py` against a pinned GamGUI clone); never hand-edit it. **Never run live, and can't be here:** the
operator has no Education domain (plan E1).
