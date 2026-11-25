# 2026-11-24 — Unbounded test waits hung the suite for days

- **Symptom:** five local `swift test` runs, in two worktrees, sat for one to two days in `DirectoryStoreTests`; their
  output never came. `sample` showed two tests spinning: `RosterCompareTests.anAskWhileOneReadsForThisTenantIsBusy` and
  `DirectoryStoreTests.everyStoreOnOneSetupStopsItsOldLoad`, each polling a flag in `while !x { await Task.yield() }`.
  CI passed the same tests.
- **Cause:** 26 tests waited for a model to show a state (`isLoading`, `isRunning`, `isReading`) with no bound. A run that
  ends before its first suspension, as one can on a Mac busy with other suites, sets and clears the flag between two looks,
  and the loop never ends.
- **Why not caught:** CI runs one suite at a time on an idle runner, where the state is always seen. A hang reports nothing,
  so the two "unrelated" failures seen beside it on the F5b branch were read as load flakes.
- **Fix:** `TestSupport.yieldWhile` yields while its condition holds, for at most 60 s on `SuspendingClock`, then records the
  issue at the caller and throws. Every such wait uses it.
- **Prevention:** a test that waits never waits unbounded; `yieldWhile` is the one way to wait for a state, and since
  2026-11-25 `TestWaitsTests` holds it (the sweep had missed eight loops that slept instead of yielding). A suite whose
  output doesn't come is a finding: `sample` the process before rerunning anything.
