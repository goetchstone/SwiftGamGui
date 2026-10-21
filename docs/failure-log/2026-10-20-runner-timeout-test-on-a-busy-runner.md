# 2026-10-20 — The runner's timeout test read a busy CI runner as a missed timeout

- **Symptom:** `RunnerTests.aRunPastItsTimeoutIsStopped` failed `clock.now - started < .seconds(10)` on PR #86's CI
  (run 39434480519, 12.5 s). Nothing in the runner had changed; it was red on main once before (38434660241).
- **Cause:** the test bounds wall time, as it must for a process, but 10 s sat too close to what a loaded runner takes
  to start and stop a process while other suites spawn the mock. The 30 s sleep left little room above it either.
- **Why not caught:** the 2026-10-16 entry named this test and kept it, since a process's time can't be thread CPU time.
- **Fix:** sleep 600 s and bound at 60 s. A timeout that doesn't stop the process still fails (10 minutes), and the
  `timedOut` error stays the main check; a busy runner no longer crosses the bound.
- **Prevention:** a wall-time bound on a process sits far from both the expected time and the failure it detects.
