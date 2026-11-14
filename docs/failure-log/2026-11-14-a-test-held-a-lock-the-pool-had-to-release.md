# 2026-11-14 — A test held a lock that only the test pool could release

- **Symptom:** PR #164's first CI run (the Classroom roster port's first push) stopped printing a second into the package
  tests and was cancelled at the job's 45 minutes; `ci-ok` failed. Locally the whole suite passed in about 30 seconds.
  The same run also failed `RosterHandoverTests.eachCommandIsOneTheGrammarHas`: `Vendor/gam7/GamCommands.txt` was missing.
- **Cause:** `RosterStoreTests.anotherAppsSaveInProgressIsWaitedFor` plays another running copy of the app: it holds the
  store folder's `flock`, starts the store's save, purge or sweep in a `Task.detached`, then `await`s a 300 ms sleep
  before releasing. The store's call blocks its thread in `flock` while it waits, and the other roster tests block on
  the store's process-wide lock behind it. On a runner with few cores every cooperative-pool thread was blocked, so the
  sleep's continuation, the one thing that would release the lock, never got a thread. The grammar failure was separate:
  CI vendored GAM only after the package tests, and the grammar file is gitignored.
- **Why not caught:** a developer Mac's pool is wide enough that a blocked thread or two never starves it, and the branch
  had never been pushed, so this was its first CI run. Nothing ran the tests with a narrow pool.
- **Fix:** the test's other app now finishes on a GCD thread, as another process would, and the store call runs on the
  test's own thread; `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (a one-thread pool) reproduced the hang before the change
  and passes the whole suite after it. CI vendors GAM before the package tests, and the package-test step has its own
  20-minute limit, so a hung test fails there by name.
- **Prevention:** a test that holds something a blocking call waits on releases it from a thread outside the cooperative
  pool, never after an `await`. A suite that may block threads gets one run with
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` before its first push.
