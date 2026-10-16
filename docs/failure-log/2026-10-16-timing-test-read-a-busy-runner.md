# 2026-10-16 — A timing test read a busy CI runner as a slow scan

- **Symptom:** `renderAndQuoteScanAreLinear()` (`SignatureTests.swift`) failed `elapsed < .seconds(1)` on
  CI three times (main's runs 38431763432 and 38780682992, then PR #71's 38898462793, 9.03 s). Nothing in
  the signature code had changed; locally it takes about 0.1 s.
- **Cause:** the test measured wall-clock time (`ContinuousClock`) while the runner ran the other suites in
  parallel, several spawning the mock. Wall time counts every other process's turn on the CPU, so a linear
  scan looked quadratic.
- **Why not caught:** the bound was set on an idle Mac; a red main run was read as noise and left.
- **Fix:** the test measures the CPU time of its own thread (`CLOCK_THREAD_CPUTIME_ID`), which other work
  doesn't inflate; the bound is unchanged, so a rescan that takes minutes still fails it (PR #71).
- **Prevention:** a test that bounds how long pure code takes measures thread CPU time, never wall time.
  `RunnerTests.aRunPastItsTimeoutIsStopped` (red on main's 38434660241) bounds a process's wall time,
  which it must, and is not changed here.
