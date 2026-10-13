# 2026-10-13 — Two branches wrote two mocks of one calendar subscribe, each wrong in its own way

- **Symptom:** rebasing onboarding (O1) onto main after Calendars (C2a) merged, both branches had
  rewritten the mock's `gam user <u> add calendars <c>`, and neither matched GAM 7.48.22:
  - Calendars' printed each calendar's line unindented: `User: <u>, Calendar: <c>, Added` and `… Add
    Failed: <why>`. GAM's `addCalendars` steps in one level (`Ind.Increment()`) before
    `_processCalendarList` prints, and `gamlib/glindent.py` indents two spaces a level (read from the pinned
    binary's `INDENT_SPACES_PER_LEVEL`), so GAM prints `  User: <u>, Calendar: <c>, Added`
    (`gam/__init__.py:55465-55499`). Only the "Calendar Service/App not enabled" line, from
    `validateCalendar` before the step in, is unindented.
  - Onboarding's subscribed anyone to any calendar not named `*missing*` and printed `User <u> subscribed to
    calendar <c>`, a line GAM never prints. Its tests subscribed hires to `team@group.calendar.google.com`,
    a calendar the mock's data doesn't have: GAM would answer `Add Failed: Not Found`, exit 50.
  Once merged on Calendars' stricter data, three onboarding tests failed.
- **Cause:** each slice made the mock fit its own tests: Calendars wrote the line from the shape of the
  other calendar lines, onboarding from its plan's wording. Neither read the indent, and onboarding's
  calendar ids were invented rather than taken from the mock's data.
- **Why not caught:** the two branches were built in parallel against the same base; each passed alone.
  No test held the subscribe line to GAM's indent, and nothing tied onboarding's calendar ids to the
  calendars the mock has.
- **Fix:** the merged mock keeps Calendars' data-backed checks (a calendar the data has, a duplicate, the
  state) with GAM's two-space indent. `MockCalendarsTests.subscribeAsANonUserFails` now holds the exact
  success and duplicate lines. The mock gains a calendar no one lists yet, `c_allhands@` (All Hands), which
  onboarding's tests and demo role subscribe to. `CalendarChanges` reads the `.waiting` result onboarding
  added to ChangeCore.
- **Prevention:** the indent rule is in the mock's comment, with its source; `theCalendarsAgreeWithOneAnother`
  counts the mock's calendars, so a new one has to be added on purpose. Branches that touch the same mock
  command are rebased one at a time, and the second runs its tests against the first's data. Still a mock:
  Google's own "Not Found" and "Duplicate" texts are assumed, not captured live.
