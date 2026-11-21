# 2026-11-21 — The directory read never asked for `id`, and the mock gave it anyway

- **Symptom:** nothing seen here live (no Education tenant). Ported from GamGUI's failure log of 2026-11-19 (its #156, found in
  review there). On a real tenant the Classroom screen's owners would all be blank: `ClassroomReads.owners` names each class's
  owner from the cached directory by Google account ID, and the cached directory held no ID. The Users stale-page check in
  `UserChanges` (another account ID than the one the page shows) could never fire for the same reason; only its name check did.
- **Cause:** `GamCommands.cacheFields` didn't name `id`. GAM's `doPrintUsers` asks the Directory API for `users(<fields>)`, the
  fields named and nothing more (7.52.04 :49533), and adds no `id` of its own, so `GamUser.accountID` was nil for every cached user.
- **Why not caught:** the strict mock's `print users` returned every record of `mock_gam/print_users.json` whole, whatever
  `fields` named, so the account ID was always there. `ClassroomReadsTests.ownersAreNamedFromTheDirectoryByAccountID` built its
  users from the data file, not through the read the screen uses, so it passed on an `id` real GAM never sends.
- **Fix:** this branch. `cacheFields` is GamGUI's `CACHE_FIELDS` again, ending `creationTime`, `id`. The mock's `print users`
  drops `id` unless `fields` names it (read as GAM's `_getFieldsList` reads names: lowercased, `_` dropped) and refuses a read
  without fields, which GAM answers with `primaryEmail` alone. `gen_fixtures.py` expects the mock's bytes without `id` for a read
  that doesn't name it (`GAM_SHOWN`), so the parity check holds the mock to it.
- **Prevention:** the stricter mock is the tripwire: a match on `id` from a read that didn't ask for it now fails offline.
  `MockCSVTests.aUsersReadGetsTheAccountIDOnlyWhenItsFieldsNameIt`, and the owners test now loads through `DirectoryStore`'s own
  read and checks every user has an account ID. `GoldenArgvTests` holds `cacheFields` to GamGUI's `CACHE_FIELDS` in order. Only
  `id` is filtered: other fields not asked for still come back, and modelling GAM's whole field map in the mock isn't done.
  **Not proven live:** the owners column and the stale-page check by ID are mock readings.
