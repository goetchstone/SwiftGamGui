# Domain: Google Classroom (read only)

**One line:** Reads Google Classroom for school domains (classes, who teaches and who is in each). Per the two-app
[Classroom plan](https://github.com/goetchstone/gamgui/blob/main/docs/plans/2026-11-11-classroom-and-rostering.md) it will
also plan roster changes from a student information system, handed over as files. **The app never writes to Classroom.**

**Owns invariant(s):** none of its own. It leans on #1 (course IDs and addresses validated, one argv element each), #9
(the index, teachers and cards kept bounded) and #11 (both builders held to GamGUI's argv), and on #2 by having no write.
**Enforcement home:** `GoldenArgvTests` (`print_courses`, `print_course_participants`, `print_all_course_participants`),
`ClassroomTests` (builders, the mock, the reader), `ClassroomReadsTests` (the screen's reads, a person's classes, who can
create classes, the classes someone owns), `OffboardChangesTests` (the leaver's classes), `GamErrorTests` and
`GuidedSetupTests` (`only_unknown_owners` and `classroom_readable`, held to `gam_errors.json` and `setup.json`).

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

## Deviations from GamGUI (each tested)
- **An unknown-owner 56 with no table is a shortfall.** GamGUI raises the 56 (not-found), which its offboarding read would
  take as "owns none"; here it's `Incomplete`, said, never none. GAM prints its header whenever it prints the table.
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
Offline only: `swift test --package-path Packages/GamKit --filter Classroom`. **Never run live, and can't be here:** the
operator has no Education domain (plan E1).
