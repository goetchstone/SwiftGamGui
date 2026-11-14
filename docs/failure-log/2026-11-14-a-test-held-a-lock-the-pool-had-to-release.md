# 2026-11-14 — A test held a lock that only the test pool could release

- **Symptom:** PR #164's first CI run (the Classroom roster port's first push) stopped printing a second into the package
  tests and was cancelled at the job's 45 minutes; `ci-ok` failed. Locally the whole suite passed in about 30 seconds.
  The same run failed `RosterHandoverTests.eachCommandIsOneTheGrammarHas`: `Vendor/gam7/GamCommands.txt` was missing.
  A first fix (`8aed7ed`) hung again, now stopped by the step's new 20-minute limit, 30 ms after the store tests started.
- **Cause:** `RosterStoreTests.anotherAppsSaveInProgressIsWaitedFor` plays another running copy of the app: it holds the
  store folder's `flock` and lets the store's save, purge or sweep wait for it. As written, the store's call blocked a
  cooperative-pool thread in `flock` and the release came after an `await`, which needed the same pool; its three cases
  ran at once, each queuing behind the store's process-wide lock. `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (a one-thread
  pool) hangs on that test alone and on nothing else. The first fix moved the release to GCD's global queue but still
  ran the three cases at once, each blocking a pool thread; whether GCD could run beside a full pool on a 3-core runner
  is not proven, and the second hang left no stacks to say. The grammar failure was separate: the test read
  `Vendor/gam7`, which isn't in the repo, and the package tests run before CI fetches GAM. The repo's rule (CalendarTests,
  `GRAMMAR_CALENDAR_ACL_ROLES`) is that the generator writes what a test needs of the grammar; the first fix moved
  CI's vendor step instead, against it.
- **Why not caught:** a developer Mac's pool is wide enough that blocked threads never starve it, the branch had never
  been pushed, and nothing ran the tests with a narrow pool. A hung CI step printed nothing about where it hung.
- **Fix:** the other app releases from a plain `Thread`, in no pool, and the cases run `.serialized`; the whole suite
  passes with a one-thread pool. `scripts/gen_fixtures.py` writes the grammar the hand-over test reads into
  `roster_handover.json` (its commands' `gam` lines, their definitions and its words; a word removed from the extract
  fails the test), and CI's vendor step is back after the tests. The package-test step has its own 20-minute limit, and
  past 15 minutes CI prints the test process's stacks (`sample`), so a hang names its frame.
- **Prevention:** a test that holds something a blocking call waits on releases it from a plain thread, never after an
  `await` or from a pool. A suite that may block threads gets one run with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`
  before its first push. A test never reads `Vendor/gam7`: the generator writes what it needs.
