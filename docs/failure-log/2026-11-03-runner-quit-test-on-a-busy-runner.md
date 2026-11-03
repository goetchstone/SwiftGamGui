# 2026-11-03 — The runner's quit test looked for its child too briefly on a busy CI runner

- **Symptom:** `RunnerTests.quittingStopsARunningChild` failed `pids.count == 1` on PR #145's CI (run 41631457918),
  then waited out the child's 30 s sleep and got exit 0 instead of `CancellationError`. The PR only bumps GAM; nothing
  in the runner changed.
- **Cause:** the test looked for its child for 5 s of wall time. The child started about 15 s after the test began,
  while other suites' mock runs were taking 15 s each, just as the look gave up; the 30 s sleep then ran out with
  nothing stopping it.
- **Why not caught:** the 2026-10-20 entry's rule, a wall-time bound on a process sits far from both ends, was applied
  to the timeout test beside this one and not swept across the file.
- **Fix:** look for 60 s, sleep 600 s, and `#require` the child, cancelling the run when it's never found, so a real
  failure fails at once instead of waiting out the sleep (PR #145).
- **Prevention:** swept the package's tests for the same shape: none left (the other short bounds time a file
  operation, thread CPU time, or a wait with no process). Nothing new beyond the 2026-10-20 rule.
