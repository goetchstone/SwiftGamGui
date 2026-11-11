# Domain: Google Classroom (read only)

**One line:** Reads Google Classroom for school domains (classes, who teaches and who is in each). Per the two-app
[Classroom plan](https://github.com/goetchstone/gamgui/blob/main/docs/plans/2026-11-11-classroom-and-rostering.md) it will
also plan roster changes from a student information system, handed over as files. **The app never writes to Classroom.**

**Owns invariant(s):** none of its own. It leans on #1 (course IDs and addresses validated, one argv element each), #9
(the index, teachers and cards kept bounded) and #11 (both builders held to GamGUI's argv), and on #2 by having no write.
**Enforcement home:** `GoldenArgvTests` (`print_courses`, `print_course_participants`), `ClassroomTests` (builders, the
mock, the reader), `ClassroomReadsTests` (the screen's reads).

GamGUI's runbook of the same name (`docs/domains/classroom.md` in its repo) is the reference: this app ports each piece from
GamGUI's merge commit, GamGUI first. Status by item is the plan's table, in GamGUI's repo.

## Files
- `GamEngine/GamCommands.swift`: `printCourses`, `printCourseParticipants`, `CourseState`, `courseFields`, `isCourseID`.
- `GamEngine/Classroom.swift`: `Course`, `Participant`, `Roster`; `courses`, `roster`, `records` (a shortfall is never
  complete), `matching` (the index search), `scopes`, `scopesMissing`, `scopeNote`, `classLink`.
- `Directory/UserAccess.swift`: `courses`, `course`, `roster`, each failure in words.
- `Directory/ClassroomReads.swift`: the screen's store: the index, a teacher's classes, a class's card.
- `App/ClassroomView.swift`: the screen.
- `Tests/Fixtures/mock_gam.sh` (`print courses`, `print course-participants`), `mock_gam/courses.json`,
  `mock_gam/course_participants.tsv`: GamGUI's handlers and data at 3c8d909, unchanged.

## How GAM reads Classroom (read from the 7.51.00 build by GamGUI, not seen live)
- **With the admin token**, not the service account (`buildGAPIObject(CLASSROOM)`): the scopes are GAM's "Classroom API -
  Courses", "- Rosters" and "- Profile Emails" (read-only will do), picked when the admin token is made. Without them GAM
  exits 15 with "There are no scopes authorized for the API(s): Classroom API", read as `scopeMissing` for any API.
- **Output.** `print courses … formatjson` is `id,JSON`. `print course-participants … formatjson` is one row per class:
  `courseId,courseName,JSON-teachers,JSON-students`, each `JSON-` cell a list of people.
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

## Deviations from GamGUI (each tested)
- **An owner GAM can't look up keeps the read.** With `owneremail`, a deleted or unreachable owner is GAM's warning
  `Course: <id>, Owner ID: <id>, Does not exist (i/n)`, exit 56, after it printed every class with that owner as "Unknown
  user" (7.51.00, `_convertCourseUserIdToEmailName` → `entityDoesNotHaveItemWarning`). GamGUI at 3c8d909 fails the read
  and says Classroom doesn't know the teacher or class. Here `Classroom.ownersUnknownOnly` reads the table when every line
  is such a warning, and "Unknown user" is never kept as an address (the owner is named from the directory by ID). The
  mock models it: `$GAM_MOCK_STATE/ownergone/<owner id>`. Told to GamGUI's session (2026-11-11).
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
  failed read says which to add (`scopeNote`), as the Chrome profiles read does. Skipping reads the token's recorded scopes
  say it lacks comes with C1.4 (a person's classes), where a domain without Classroom would otherwise show a failure on every
  person's page.
- The mock refuses what it doesn't model (`print courses` without `formatjson`, by ID and a filter at once;
  `print course-participants` by teacher or for every class), and takes `all` in a states list only on its own.
  `$GAM_MOCK_STATE/noclassroom` is a token without the scopes, `classroom_silent` GAM answering nothing.

## Testing / live-verification status
Offline only: `swift test --package-path Packages/GamKit --filter Classroom`. **Never run live, and can't be here:** the
operator has no Education domain (plan E1).
