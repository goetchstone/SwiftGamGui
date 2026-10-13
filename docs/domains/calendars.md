# Calendars

**One line:** find a calendar (a room, or one in a person's calendar list), see who has access, and
share it with one person or take their access away; and on a person's page, who can see their primary
calendar. Built in slices from the calendars plan (2026-10-12): C1a, the parity core and the strict
mock's reads. Next: C1b (the screen and the person tab, read-only), C2a (sharing with one person and
unsharing, through ChangeCore). Deferred until asked: find by name (C3a, the domain-wide index), delete a
secondary calendar (C3b, a ChangeCore addition), share with a group (C4, a background job), events.
GamGUI's `web/routes/calendars.py` and `users.py:560-604` are the reference.

**Owns invariants:** #1 and #11 (every read and write is a GamGUI builder already held to `argv.json`;
no argv key is new), the mock's fidelity for the calendar reads and writes, #9 for the reads kept.

**Enforcement home:** `Tests/GamEngineTests/CalendarTests.swift` (the models, held to
`gam_models.json`'s `calendar_acls`, `user_calendars` and `resources`; the sharing rules),
`Tests/GamEngineTests/MockCalendarsTests.swift` (the mock prints GAM's bytes, fails as GAM fails, and its
calendars agree with one another).

## Files
- `Packages/GamKit/Sources/GamEngine/Calendar.swift`: `CalendarACL`, `UserCalendar`, `ResourceCalendar`
  (GamGUI's models), `ResourceCalendar.search` (GamGUI's room filter), `CalendarSharing` (who GAM acts
  as, the share target check, the picker's four roles) and `GettingLines`.
- `Tests/Fixtures/mock_gam.sh`'s calendar section, and its data: `mock_gam/user_calendars/<person>.json`,
  `mock_gam/calendar_acls/<calendar>.json`, `mock_gam/resources.json`.
- `scripts/gen_fixtures.py`: `GAM_PRINTED` (each read's header and key columns, so the generator checks
  the mock's bytes), and `models_fixture`'s calendar sections.

## What GAM 7.48.22 prints and does (read from the vendored build, not a tenant)
- **F1, sorted keys.** Every calendar read's JSON cell has its keys sorted: `cleanJSON` rebuilds each
  dict sorted (gam/__init__.py:9317) and drops `kind` and `etag`, even where the dump says
  `sort_keys=False` (the ACL reads, :41879). So the mock's data-file rule (one `json.dumps(…,
  ensure_ascii=False, sort_keys=True)` line per record) holds for all of them.
- **F2, the headers.** A person's calendars: `primaryEmail,calendarId,JSON` (:55696, :55805-55818);
  `fields summary` also asks for `summaryOverride`, and `primary` is present only on the primary
  calendar. A person's primary calendar's rules: `primaryEmail,calendarId,JSON`, `primary` read as the
  person (:55338-55339). A calendar's rules by ID: `calendarId,JSON` (:41941). A rule holds only `id`,
  `role` and `scope` (:41839); the role is the API's (`editor` is stored as `writer`, `freebusy` as
  `freeBusyReader`: `CALENDAR_ACL_ROLES_MAP`, :41596-41605); a `default` scope has no value; a secondary
  calendar lists itself as an owner (why `noselfowner` exists, :41859). Rooms:
  `resourceId,resourceName,JSON` (:41482-41486, :41543-41545), `buildingId` as `id:<id>` beside a
  looked-up `buildingName`, which is the raw ID for a building GAM can't name (:41515-41517,
  :40799-40802).
- **F3, no rules exits 60.** A calendar with no rules prints the header alone and exits
  NO_ENTITIES_FOUND_RC (:41847-41848). GamGUI's runner raises on any non-zero exit.
- **F4, who GAM acts as.** `validateCalendar` (:41574-41589): an ID ending `.calendar.google.com`
  (secondary, room, holiday) is read and changed with the admin's own sign-in; any other ID as that
  address (and, if that isn't a user, the admin again). A calendar GAM can't get fails "Calendar: <id>,
  Print Failed: Not Found", exit 50. Google refuses a change to the acting account's own access
  ("Cannot change your own access level", :41693, :41704-41708).
- **F5, the share target is a list.** The ACL writes read `<CalendarACLScopeEntity>` with
  `getEntityList` (:41637-41641, :7338-7342): a comma or whitespace splits it into several rules, a
  selector word (`file`, `csvfile`…) reads a local file, a bare name gets `@<domain>` (`normalizeRuleId`,
  :40654-40664), `domain` becomes `domain:<domain>`. GamGUI passes the typed text straight through; only
  its browser field (`type="email"`) stopped the rest.
- **F6, the writes' lines** (C2a): an added rule prints `Calendar: <c>, Calendar ACL: (Scope: <id>, Role:
  <r>), Added` (:40649-40652, :41697); a refused one (own access, an invalid scope value, a default
  scope's illegal role, forbidden) "…, <Act> Failed: <msg>", exit 50; deleting a rule that isn't there,
  "Failed: Not Found", exit 50 (:41698-41703). A subscribe prints `User: <u>, Calendar: <c>, Added`, fails
  `duplicate` and `notFound` with exit 50, and a person with Calendar off with "Calendar Service/App not
  enabled", exit 73 (:55465-55478, :2498-2511).
- **F7, GamGUI mislabels the writer role** "Make changes & manage sharing" (`models.py:226-227`); its own
  picker says "Make changes", and Google's writer can't change sharing. This app says "Make changes to
  events"; `CalendarTests` lists the one difference.
- **F8, one person without Calendar fails the whole index build** (C3a): `all users print calendars`
  exits 73 for them.
- **The "Getting" line.** Before a per-entity print GAM writes "Getting Calendars for <person>" or
  "Getting Calendar ACLs for <calendar>" to stderr (`printGettingEntityItemForWhom`, :2718-2722;
  `show_gettings` is on by default). GamError, held to GamGUI's classification, knows only "Getting all
  …" as progress, so this line reads as an unknown failure and outranks the real one (a person with
  Calendar off read as "GAM reported an error"). The calendar reads drop it before classifying
  (`GettingLines`); GamError itself is unchanged.

## Gotchas / mock-lies traps
- **The mock lied about every calendar read** (found planning C1): it refused all four (and before that
  printed NDJSON GAM never prints for them), and failed an unknown calendar as "Does not exist", exit 56,
  where GAM says "Not Found", exit 50. Now each read is modelled strictly: only the fields and words the
  app sends (a field GAM doesn't know is GAM's invalid choice, exit 2; another of GAM's options is
  refused as not modelled), the per-user reads answer for that person and fail a non-user as GAM fails
  (exit 50), Calendar off (`GAM_MOCK_STATE/nocalendar/<person>`) exits 73, and a calendar with no rules
  exits 60 with the header. The generator checks each read's bytes against the data files.
- **One data set:** alice (her primary, owner of Team Calendar, reader of the US holidays with a
  `summaryOverride`, Aspen's free/busy, writer of `Rota "B" C:\Shifts, Zoë`), bob (reader of Team
  Calendar), carol (owner of Operations and the Rota, writer of Team Calendar), dana (her primary); Team
  Calendar's rules cover a self-owner, every role, a group (`sales@`) and the domain; three rooms (Aspen
  in HQ; `Birch Huddle, 2nd floor` in a building GAM can't name, a type with a quote and a backslash; a
  projector with no building). `theCalendarsAgreeWithOneAnother` holds the lists and the rules together.
  GamGUI's reader drops the Rota and Birch rows (GAM's CSV escapes, failure-log 2026-10-10);
  `gam_output.json` keeps its records beside each.
- **Approximate:** the "Not Found" and "Getting" wording (from the build's code, not a tenant); whether
  the admin can read a secondary calendar it isn't on (plan Q2: the mock answers for every calendar it
  holds); the holiday calendar's rules (not in the mock: reading them fails as an unknown calendar).

## Testing / live-verification status
- Mock-tested. No calendar read or write has run on a tenant from this app. GamGUI's live record: share,
  subscribe and delete a secondary calendar confirmed; share with a group, unshare and delete an event
  never confirmed (GamGUI `README.md:179-184`).
- **C1c (the operator, read-only):** rooms; their own calendars; the rules of their primary and of a
  secondary calendar they own; the rules of a secondary calendar the admin is not on (Q2). Compare with
  the mock: the headers and their order, the primary's `summary`, role casing, the `id:` building
  prefix, the self-owner rule, the "Getting" line. Fix the mock first wherever they differ.
