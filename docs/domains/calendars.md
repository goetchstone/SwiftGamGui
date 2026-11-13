# Calendars

**One line:** find a calendar (a room, or one in a person's calendar list), see who has access, and
share it with one person or take their access away; and on a person's page, who can see their primary
calendar. Built in slices from the calendars plan (2026-10-12): C1a, the parity core and the strict
mock's reads; C1b, the store, the Calendars screen and the person page's Calendar tab; C2a, sharing with
one person and taking access away, through ChangeCore; then (2026-11-13) sharing with a group, deleting a secondary
calendar, and finding and deleting an event (C3b, C4 and events, below). Next: the operator's live checks (C1c, C2b, and
those below). Deferred until asked: find by name (C3a, the domain-wide index).
GamGUI's `web/routes/calendars.py` and `users.py:560-604` are the reference.

**Owns invariants:** #1 and #11 (every write is a GamGUI builder held to `argv.json`; every read is too but one,
`printCalendarSettings`, the delete's data owner, an app-only read held by `NativeArgvTests` and `CommandKindTests.appOnlyReads`;
the event search's days depart from GamGUI's at the screen, not in the builder), #2 (every share and removal through ChangeCore; nothing new in ChangeCore), the
mock's fidelity for the calendar reads and writes, #9 for the reads kept.

**Enforcement home:** `Tests/GamEngineTests/CalendarTests.swift` (the models, held to
`gam_models.json`'s `calendar_acls`, `user_calendars` and `resources`; the sharing rules),
`Tests/GamEngineTests/MockCalendarsTests.swift` (the mock prints GAM's bytes, fails as GAM fails, and its
calendars agree with one another), `Tests/DirectoryStoreTests/CalendarReadsTests.swift` (the store against
the strict mock with its argv log), `CalendarChangesTests.swift` and `UserChangesTests`' calendar tests (the
writes end to end), `WriteRouteTests` (the one confirm screen).

## Files
- `Packages/GamKit/Sources/GamEngine/Calendar.swift`: `CalendarACL`, `UserCalendar`, `ResourceCalendar`
  (GamGUI's models), `ResourceCalendar.search` (GamGUI's room filter), `CalendarSharing` (who GAM acts
  as, the share target check, the picker's four roles).
- `Packages/GamKit/Sources/Directory/CalendarReads.swift`: the four reads (C1b).
- `Packages/GamKit/Sources/Directory/CalendarChanges.swift`: the screen's share and removal (C2a), a group's share, a
  calendar's and an event's delete; `CalendarEvents.swift`, the event search; `GamEngine/Calendar.swift`'s `CalendarEvent`
  and `CalendarDeletion` (GamGUI's model and delete rules);
  `UserChanges.previewShareCalendar` and `previewUnshareCalendar`, the person page's; `CalendarPreviewSheet`
  in `App/ChangePreviewSheet.swift`.
- `App/CalendarsView.swift`: the screen, its calendar page, and the person page's `PersonCalendarSection`;
  `App/UsersView.swift` (the Calendar tab), `App/GamGUIApp.swift` (the sidebar's Calendars),
  `App/AppServices.swift`, `App/Spikes.swift` (the demo fill), `scripts/screenshots.sh`.
- `Tests/Fixtures/mock_gam.sh`'s calendar and event sections, and their data: `mock_gam/user_calendars/<person>.json`,
  `mock_gam/calendar_acls/<calendar>.json`, `mock_gam/calendar_events/<calendar>.json`, `mock_gam/resources.json`.
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
  Calendar off read as "GAM reported an error"). GamError now reads every "Getting …" line as progress
  (failure-log 2026-10-13); this branch's own filter for the calendar reads was removed then.

## The reads (C1b): `Directory/CalendarReads.swift`
- **GroupMembers' reviewed shape:** each read (`.rooms`, `.calendars(of:)`, `.access(calendar:)`,
  `.primaryAccess(of:)`) is kept for the domain and generation it was read under, keyed as `Guard`
  compares addresses; `ReadsInFlight` counts reads per key, so one window leaving a page never ends
  another's read, and an older, slower read never replaces a newer one; only the last sixteen are kept
  (invariant 9); output the runner cut at its cap is refused. Each is GamGUI's builder with the default
  timeout, as GamGUI runs it.
- **Exit 60 is none, for rules only** (Q4): a calendar's rules with exit 60 and no records read as an
  empty list ("No access rules returned." on the screen, GamGUI's "Only the owner has access." on the
  tab); a list never exits 60, so there it is a failure.
- **Failures** are GamError's remediation with GAM's line beneath.

## The screen and the tab
- **Calendars** (sidebar, after Groups): Rooms | Person. Rooms are read when Rooms is first shown for a
  tenant, searched by GamGUI's filter (name, address or ID); a person is chosen from the directory
  (address order, a suspended one said so; nobody at first, as GamGUI's field starts) and their
  calendars read then. Each row is the name above the ID, each truncating on its own (GamGUI
  failure-log 2026-09-15), then GamGUI's details (`primary · owner`, a room's type), read by VoiceOver as
  one sentence. A calendar's page: the name as the heading (header trait), the ID (selectable), and who
  has access in GAM's order with the role in words, read each time the page opens (a quarter second
  late, so arrowing down the list reads nothing). ⌘R reads the list again; the outcome is spoken from
  the window in front.
- **States, in words:** not connected; connecting; reading; a problem (the remediation, GAM's line
  selectable, Try Again), Calendar off or a missing scope among them; "No rooms or resources."; "No
  calendar matches"; "Choose a person to see their calendars."; on the page, "No access rules
  returned.", a problem in place of the list (GamGUI's error partial), or "Not read." with Read Again.
- **The person page's Calendar tab:** who can see their primary calendar, read by GamGUI's user form
  when the tab is shown; "Show Their Calendars…" opens Calendars for them (as the Mail tab opens
  Signatures). A fifth tab: the page's content clips rather than widen the inspector, and the
  `narrow-person-calendar` run checks it fits.

## The writes (C2a)
Nothing new in ChangeCore: every step is LOW (each action's floor), at most two targets, so no bulk or typed
confirm; the sheet asks for the click.
- **Share (Calendars):** two steps held together, `expecting` the tenant the screen read on: the rule
  (`calendars <id> add calendaracls <role> <address>`, target the calendar, `about.scope`), then the
  subscribe as the person (`user <address> add calendars <id> selected true`, target the person,
  `about.calendar`), which needs the first. GamGUI's messages: "Shared with X — it will now appear in
  their Google Calendar.", or, when the subscribe failed, "Shared with X, but couldn't auto-add it…" (said,
  not only amber), or "Couldn't share the calendar with X." with the remediation and GAM's line.
- **Share (the person page):** their primary calendar by the user form (`user <person> add calendaracls
  primary <role> <address>`), one step and no subscribe (`users.py:588`), in UserChanges' sheet.
- **Remove:** one step by the rule's token (`delete calendaracls <token>`: an address, `group:…`,
  `domain:…`, `default`), only from its confirm step (GamGUI's in-page confirm), never on an owner's
  rule. "Removed access for X." Either way the calendar's access is read again after the run.
- **Checked before a preview (D5-D8), none changing the argv for a valid one:**
  - the target is one address (`CalendarSharing.shareTargetProblem`): `Address.looksLikeEmail` and no
    colon. The plan said `looksLikeEmail` refuses `group:`; it doesn't (a colon is allowed in its local
    part), so the colon check is this app's. An empty target says GamGUI's words ("Enter a person or
    group to share with." on Calendars, "Enter an email to share with." on the tab);
  - the role is one of the grammar's (`CalendarRole(validating:)`, GamGUI's message); the picker offers
    GamGUI's four;
  - not the account GAM acts as (`CalendarSharing.actingAccount`, F4): "That's the account GAM acts as
    for this calendar; Google doesn't let it change its own access." Skipped when the admin isn't known;
    Google's own refusal (`.ownACL`) is then said in the same words, not GamError's offboarding remediation;
  - a person, not a group (D6, GamGUI's `_subscribers_for`): an active directory user is a person; one of
    the tenant's groups (if the list is loaded) is a group; otherwise `print group-members group <t>
    formatjson`: an answer, even an empty group, is a group; "Does not exist" a person (exit 56 in the
    domain; an outside address is "Service not applicable/Does not exist", exit 73, GAM's
    entityUnknownWarning, and a person too, whose subscribe may then fail); any other failure is a problem. GamGUI guessed "person" there and
    took an empty group for a person. A group is shared with its members (C4, below);
  - warnings on the sheet: a target who already has a rule ("already has access (X): sharing changes it to
    Y", and "This takes away their ownership." from an owner), and an owner grant ("Owners can change
    sharing and delete the calendar.").
- **The confirm runs what the preview held,** once, only while it's the one the sheet shows (GamGUI
  failure-log 2026-09-23): an edited target or role, a replay, a bare confirm of a removal, or a switch of
  tenant runs nothing.

## Sharing with a group, deleting a calendar, events (2026-11-13, from GamGUI 3c8d909's `calendars.py`)
Ported from GamGUI's `/share` (its group half), `/share/group`, `_grant_and_subscribe`, `_run_subscribe`, `_subscribers_for`,
`/delete/preview`, `/delete`, `_resolve_delete_owner`, `/events`, `/event/preview` and `/event/delete`, with their
templates' words. No builder is new (each is GamGUI's, held to `argv.json`); nothing is new in ChangeCore.

### What GAM 7.51.00 does (read from its source; the calendar and event code is unchanged at 7.52.01)
- **F9, events.** `calendars <c> print events [query <q>] [after <day>] [before <day>] | eventid <id>` (getCalendarEventEntity,
  :42159-42214; _printShowCalendarEvents, :43257-43302): "Getting Events for <c>" on stderr, then `calendarId,id,JSON`, keys
  sorted (cleanJSON). `after`/`before` are Google's `timeMin`/`timeMax` (getTimeOrDeltaFromNow,
  :2091-2116, via LIST_EVENTS_SELECT_PROPERTIES' TYPE_DATETIME, :42085-42086, :42141-42142): a bare `yyyy-mm-dd` is midnight
  in GAM's `timezone` setting (UTC unless set; the app sets none); anything `arrow.get` parses, a full time with its offset
  included, is passed on as it is. Google keeps an event whose end is after `timeMin` and whose start is before `timeMax`
  (Events: list, both exclusive). None found is the titles alone and exit 60 (NO_ENTITIES_FOUND_RC). `eventid` is `events.get`: one Google
  lacks is "Calendar: <c>, Event: <id>, Print Failed: Not Found" (or 410's "Resource has been deleted"), exit 50. Without a
  query, days or an ID GAM lists every event: the app never asks (GamGUI's rule), and the mock refuses it.
- **F10, an event's delete.** `calendars <c> delete events eventid <id> doit sendupdates none` (:42936-43016). Without `doit`
  GAM only says what it would delete (exit 51). With it: "Calendar: <c>, Delete 1 Event", then one level in "…, Event: <id>,
  Deleted", or "Delete Failed: <why>", exit 50. `sendupdates none` is GAM's default too; GamGUI sends it anyway.
- **F11, a calendar's delete.** `user <owner> remove calendars <c>` is `calendars.delete` as that owner (removeCalendars,
  _modifyRemoveCalendars, :55658-55685); `delete calendars` would only take it off their list. "User: <u>, Remove 1
  Calendar", then "  User: <u>, Calendar: <c>, Removed", or "Remove Failed: <why>", exit 50.
- **F12, a bare group address is a person's rule.** `normalizeRuleId` (:40654-40664) makes `x@` into `user:x@`; only
  `group:x@` is a group's rule.
- **F13, a calendar's data owner.** Google gives a secondary calendar one `dataOwner` (Calendars resource: "The email of the
  owner of the calendar. Set only for secondary calendars."). The cheapest read of it is `calendars <c> print settings fields
  id,dataowner formatjson` (doCalendarsPrintShowSettings, :43687-43730): one `calendars.get` as the admin (validateCalendar),
  `calendarId,JSON`; `dataowner` is in CALENDAR_SETTINGS_FIELDS_CHOICE_MAP (:43669-43678) though the grammar's
  `<CalendarSettingsField>` leaves it out; `_showCalendarSettings` and `_showCalendar` print it as `Owner`, and `print
  calendars ownedsecondary` keeps the rows whose `dataOwner` is the person (:55830, :55858). A calendar GAM can't get is
  "Calendar: <c>, Print Failed: Not Found", exit 50. An `owner` ACL rule is not the data owner: a co-owner can't delete it.
- **F14, a deleted event.** Google's events.get always returns a deleted event, `status` "cancelled" (Events reference,
  `status`), so `print events eventid <id>` prints it, exit 0; events.list leaves it out. A second `delete events` is 410.

### Sharing with a group (C4)
- The target is a group when D6 says so; its members are then read (`print group-members`, a known group's too) and held in
  the preview: the confirm runs exactly those. Steps: the rule (`calendars <c> add calendaracls <role> group:<g>`), then a
  subscribe per member, each needing the rule. The job tray names it as GamGUI did ("Calendar to g's N members"), with Stop.
- **Who gets a step:** members of type `USER` whose status is `ACTIVE`, once each, in GAM's order. GamGUI took every member
  with an address: a group inside it or a suspended account would only fail. The sheet counts the ones left out and says
  they have access through the group. GAM doesn't expand a group inside it without `recursive` (no builder asks).
- **The confirm:** always the sheet's click (`confirmStep`); GamGUI's count and its first ten members, "… and N more"; at
  the guard's bulk threshold (ten members, so eleven changes) the number of changes typed (`typedCountAbove:
  Guard.bulkThreshold`). GamGUI asked only a click there; the typed count is this app's group rule (Groups, Signatures).
  Share stays off until the count typed is the guard's (`Guard.Decision.typedCountMatches`: stripped, exact), so Return (it is
  the default button) can't run a mismatch; `CalendarChanges.confirm` refuses one too, "Type N, the number of changes, to
  confirm." on the sheet, which stays with its preview unspent (the executor spends a preview it refuses). Each refusal is
  announced to VoiceOver (`typedRefusals`), a repeat too, and editing the field clears it (`typingChanged`), as for DELETE.
- **The run:** the sheet closes; the page's banner counts each member as it ends ("Adding to calendars… 3 of 12 · 3
  added"), with Stop (the member in flight finishes). Then GamGUI's words: "It now appears in A of T members' Google
  Calendars.", "Couldn't add it for F — they can add it manually." with the first ten in a bounded scroll box (two hundred
  kept, invariant 9). A member whose subscribe never began is not attempted, never a failure (GamGUI's `stop_requested`,
  `stop_reason`): "Stopped by you — K not attempted." or "Stopped: <remediation> The remaining K were not attempted."
  (an account-wide failure, a tenant switch, a cancel), then "Added to A of T members' calendars before stopping." The live
  count never counts them as failed. An empty group: "Shared with g, but that group has no members to add it for."
- **`group:<address>`** (GAM's `<CalendarACLScope>`, GamGUI's `_subscribers_for`) is a group, never looked up as a person;
  a bare address is resolved. The jobs tray names the run "Share <calendar> with <group> and add it to N members' calendars".
- **A preview outdated while it reads** (a group's members): the page's calendar, the target or the role changed, or a newer
  preview began. Its held preview is discarded and nothing is shown (`CalendarChanges.edited`, a preview serial).
- One person still shares with the rule and the subscribe, as before (GamGUI's single-person auto-subscribe).

### Deleting a calendar (C3b)
- The page's last section, only on a secondary calendar (`CalendarDeletion.isSecondary`, GamGUI's `_is_secondary`): GamGUI's
  danger-zone words and Delete This Calendar…, or why it can't be (no owner but itself; owners suspended or gone), or "Load
  the directory…" before the directory is in hand (GamGUI read it on demand).
- **The preview** reads the access again now (the sheet's rule count) and the data owner (F13, `printCalendarSettings`),
  and acts as the data owner while the directory has them active: never from the screen, never a co-owner instead. No data
  owner is GamGUI's "Couldn't find an owner account to act as…"; a suspended or deleted one is "X, the calendar's owner, is
  suspended or no longer exists — transfer ownership to an active user, then delete." The page's note before the preview
  still reads the owner rules (GamGUI's `delete_note`): the data owner holds an owner rule, so a calendar the note says can't
  be deleted can't be. The step is destructive (`removeCalendar`'s floor). The sheet: GamGUI's "Permanently delete this
  calendar?", the access rule count, "Runs as owner X.", a field for DELETE.
- **The confirm:** DELETE, stripped, exact case, and the click. The word is held with the preview (`typedExactWord`) and the
  executor refuses a run without it ("Type DELETE (exactly) to run this."), as it does an offboarding's typed address;
  `CalendarChanges.confirm` says a mistyped word on the sheet first, so the preview isn't spent. The run reads the data owner
  again first (a precondition): another owner since is refused ("X is no longer this calendar's owner — preview the delete
  again."), and so is one suspended or deleted since (`info user`, read now: GamGUI's `_active_emails` at the delete). A read
  that fails says so in fixed words, never an error's type name: a calendar gone since, "That calendar no longer exists —
  nothing was deleted."; GAM refusing the read, "Couldn't check who owns the calendar before deleting it." with its
  remediation (inside the executor's "couldn't be checked again … — preview again"). After: "Calendar deleted: “name”.", the calendar dropped from every person's list read and its access read
  (`CalendarReads.forget`, GamGUI's `idx.remove`), its page closed, the result above the list.

### Events
- **Find an event** (the page's next section): a title, and optional days (each its own switch: GamGUI's date fields could
  be left empty). Each day is sent as the instant it begins in the operator's zone, with its offset
  (`CalendarEventSearch.instant`: `2026-07-14T00:00:00-04:00`), not the bare day GAM would read as midnight UTC (F9). Nothing to search by: "Enter a title to search for, or a date range." and no `gam`. The first 200 kept
  (`EVENT_CAP`), "Showing the first N matches — narrow your search to see the rest." Exit 60 is "No matching events."
  (GamGUI's runner raised on it, so its own "No matching events." never showed live). Each row: the title, "(recurring)" in
  words, when and the organizer; Delete… named for the event.
- **Delete:** the event read again (`get_event`); gone (Not Found, 410, or `cancelled`) is GamGUI's "That event no longer
  exists."; else a destructive confirm with GamGUI's words and its warning for a series ("deleting removes the entire
  series"); an instance (Google's `recurringEventId` set) says it deletes only that occurrence. Delete Event is never the
  default button. The run reads the event again first: gone (cancelled) is "That event no longer exists."; one that became a
  series, or stopped being one, since the preview (its `recurrence` or `recurringEventId` differs) is refused, "That event has
  changed since the preview…", since the sheet's warning said what the delete removes; a failed re-read is "Couldn't re-read
  the event before deleting it." with the remediation. After: "Event deleted.", and it leaves the results.

### Deliberate differences from GamGUI (each tested)
- A resolved group's rule is `group:<address>` (F12); GamGUI sent the address as typed.
- Only active people in a group get a subscribe step; the rest are counted on the sheet.
- The group confirm asks the number typed at ten members.
- Exit 60 from an event search is none, not a failure; an event read that fails "Not Found" is "no longer exists", not
  GamGUI's error partial.
- The delete's owner check is repeated just before the run (GamGUI repeated it at the POST, the same moment for a web form);
  an owner no longer active is refused there, where GamGUI would act as another active owner.
- The delete acts as the calendar's data owner (F13), never another owner: GamGUI's `_owner_candidates` and `_pick_owner`
  took the first active `owner` rule in GAM's order, a co-owner Google refuses (or, with a suspended data owner, a co-owner
  instead). `theDeleteActsAsTheDataOwnerNotACoOwner`, `aCalendarWithoutAnActiveOwnerIsRefused`, `CalendarTests.deletionIsGamGUIs`.
- The event search sends each day as the operator's midnight with its offset; GamGUI sent the bare day, which GAM reads as
  midnight UTC, so a day began hours away from the operator's. The builder (`printEvents`) is GamGUI's and unchanged (its
  `argv.json` cases pass); the screen passes it the instant. `eventDaysAreTheOperatorsOwn`, `aDayIsTheInstantItBegins`.
- An event's delete is refused when it became a series, or stopped being one, since the preview; GamGUI checked only that it
  still existed. `anEventThatChangedSinceThePreviewIsRefused`.
- A `group:` target GAM says is no group is refused ("x isn't a group here."); GamGUI shared it and subscribed nobody.
- An event instance (`recurringEventId` set: Google's Events reference, "the id of the recurring event to which this
  instance belongs") warns that only that occurrence goes: deleting an instance's own ID cancels that one occurrence.
  GamGUI's `_event_delete.html` warned of the whole series for it too (`is_recurring` counts an instance). GamGUI is wrong
  here as well.

### The mock (Tests/Fixtures/mock_gam.sh)
- New data: `mock_gam/calendar_events/<calendar>.json`, Team Calendar's four events (a weekly series, an all-day event, one
  whose title has a quote, a comma, a backslash and an accent, one with no title), ids in Google's base32hex (a-v, 0-9),
  times with the calendar's zone as Google returns them.
- `print events` (F9) answers only the app's fields and selectors, and compares instants as Google does (an event ending
  after `after` and starting before `before`; a bare day is midnight UTC, GAM's); `eventid` prints a deleted event cancelled,
  exit 0 (F14), and fails Not Found only for an ID the calendar never had. `delete events` (F10) needs `doit` and keeps state
  (`$GAM_MOCK_STATE/events_deleted/<c>`); `remove calendars` (F11) acts as the data owner only, refuses anyone else, a
  co-owner too ("Forbidden"), and a primary, and keeps state (`calendars_removed/<c>`: the calendar is then unknown to every
  read and leaves each list). `print settings` (F13) answers `dataOwner` from the mock's one ownership model
  (`user_owned_calendars/<u>.json`, or a handover in `calendar_owner/<c>`): alice owns Team Calendar, carol Operations and
  Old projects; All Hands has none.
- `user <u> add calendars <c>` (subscribe) needs access, as Google's calendarList.insert does (404 Not Found otherwise):
  a rule naming them, a group they are in (nested groups and the CUSTOMER row count, `in_group`), their domain, or
  `default`; a `none` rule gives none. It once answered "Added" for any existing calendar, so a group shared under the
  wrong scope (a bare address is a person's rule, F12) still passed a fan-out test. GamGUI's mock has the same hole.
- **Approximate:** Google's `q` searches more than the title (here: a substring of the summary); an all-day event's date
  is midnight UTC (Google reads it in the calendar's zone) and a series is compared by its first occurrence (Google keeps one
  with any occurrence in range); the 410 and 403 wordings and "Delete not Performed". It once compared days as strings,
  which dropped a 2-3pm meeting from a search on its own day. The old handlers lied: `remove calendars`
  removed anything but a `*missing*` name, and `delete events` deleted any event, kept nothing, and used GAM's wrong words.
- `scripts/gen_fixtures.py` now runs the event reads (`GAM_PRINTED`, `GAM_SELECTED`) and builds `gam_models.json`'s
  `calendar_events` from GamGUI's `CalendarEvent`; GamGUI's test reads its own event id (`evt-allhands`), so the generator
  reads this data's All Hands id instead.

### Tests
`CalendarChangesTests` (a group's active members, the typed count, an empty group, Stop, an account-wide failure, the
failure sample's cap, `group:`, a preview outdated while reading; a delete as the active owner after
DELETE, the executor refusing it without the word, only a secondary calendar, no active owner, the owner checked again and
still active; an event search's filter and results, an event read then deleted, one deleted since refused, a series' and an
instance's warnings), `MockCalendarsTests` (F9-F11 against the mock), `CalendarTests` (the
event model held to `gam_models.json`, the delete rules, the event argv), `MockCSVTests` (every event is refused).

### Live checks still to do (the operator; a yes in chat for each write)
On scratch calendars and a small test group the operator owns: share a calendar with the group and check it appears in
each member's Google Calendar; delete a scratch secondary calendar; find and delete a scratch event, and one occurrence of
a scratch series' search result. Compare each GAM line with F9-F11 and fix the mock first where they differ.

## Gotchas / mock-lies traps
- **The mock lied about every calendar read** (found planning C1): it refused all four (and before that
  printed NDJSON GAM never prints for them), and failed an unknown calendar as "Does not exist", exit 56,
  where GAM says "Not Found", exit 50. Now each read is modelled strictly: only the fields and words the
  app sends (a field GAM doesn't know is GAM's invalid choice, exit 2; another of GAM's options is
  refused as not modelled), the per-user reads answer for that person and fail a non-user as GAM fails
  (exit 50), Calendar off (`GAM_MOCK_STATE/nocalendar/<person>`) exits 73, and a calendar with no rules
  exits 60 with the header. The generator checks each read's bytes against the data files.
- **The mock lied about the writes too** (C2a): it took any calendar ID ("Does not exist", exit 56,
  only for a `*missing*` one), kept no rules, printed a subscribe line GAM never prints ("User x subscribed
  to calendar y"), and refused nothing Google refuses. Now the rule writes keep state
  (`$GAM_MOCK_STATE/acls/<calendar>`, seeded from the data file, read by every print), normalize each scope
  as `normalizeRuleId` and each role as `CALENDAR_ACL_ROLES_MAP`, replace a scope's rule on a second add,
  read a comma list as several rules, want a file for a selector word, fail an unknown calendar "Not
  Found" (exit 50), a missing rule's delete "Delete Failed: Not Found" (exit 50), and the acting
  account's own change "Cannot change your own access level." (exit 50; the admin read from the
  materialized `oauth2.txt`, as the demo writes it). The user form models `primary` only. The subscribe
  acts as the person (a non-user exit 50, Calendar off or a new account exit 73), fails an unknown calendar
  and one already in their list (Google's `duplicate`, exit 50, plan Q7), and prints GAM's line. A
  subscribed calendar isn't added to the person's printed list (approximate).
- **One data set:** alice (her primary, owner of Team Calendar, reader of the US holidays with a
  `summaryOverride`, Aspen's free/busy, writer of `Rota "B" C:\Shifts, Zoë`), bob (reader of Team
  Calendar), carol (owner of Operations and the Rota, writer of Team Calendar), dana (her primary); Team
  Calendar's rules cover a self-owner, every role, a group (`sales@`) and the domain; three rooms (Aspen
  in HQ; `Birch Huddle, 2nd floor` in a building GAM can't name, a type with a quote and a backslash; a
  projector with no building). `theCalendarsAgreeWithOneAnother` holds the lists and the rules together.
  GamGUI's reader drops the Rota and Birch rows (GAM's CSV escapes, failure-log 2026-10-10);
  `gam_output.json` keeps its records beside each.
- **The mock printed half of GAM's outside-domain answer** (2026-11-13): "Service not applicable", where GAM's
  `Msg.SERVICE_NOT_APPLICABLE` is "Service not applicable/Does not exist" (glmsgs.py:508), so an outside address
  read as an unplaceable answer, not as no account, and the group lookup answered exit 56 for every domain.
  Both now print GAM's words; `aGroupLookupOfANonGroupFailsAsGamDoes` holds them byte for byte.
- **Approximate:** the "Not Found" and "Getting" wording (from the build's code, not a tenant); whether
  the admin can read a secondary calendar it isn't on (plan Q2: the mock answers for every calendar it
  holds); the holiday calendar's rules (not in the mock: reading them fails as an unknown calendar).

## Testing / live-verification status
- Mock-tested. No calendar read or write has run on a tenant from this app. CI renders `calendars`,
  `calendars-alice` (Team Calendar's page), `narrow-calendars-alice`, `person-calendar` and
  `narrow-person-calendar`. GamGUI's live record: share,
  subscribe and delete a secondary calendar confirmed; share with a group, unshare and delete an event
  never confirmed (GamGUI `README.md:179-184`).
- **C2b (the operator; a yes in chat for each write):** on a scratch secondary calendar the operator
  creates and owns: share it as reader with a colleague who agrees (Q6) and check it appears in their
  list; remove that access; on their own Users Calendar tab, share their primary with the same person as
  free/busy, then remove it; try sharing with themselves (refused before GAM, no write); check each effect,
  and Google's names for the roles (F7), in Google's sharing settings. Q7: what a subscribe of someone who
  already has the calendar does.
- **C1c (the operator, read-only):** rooms; their own calendars; the rules of their primary and of a
  secondary calendar they own; the rules of a secondary calendar the admin is not on (Q2). Compare with
  the mock: the headers and their order, the primary's `summary`, role casing, the `id:` building
  prefix, the self-owner rule, the "Getting" line. Fix the mock first wherever they differ.
