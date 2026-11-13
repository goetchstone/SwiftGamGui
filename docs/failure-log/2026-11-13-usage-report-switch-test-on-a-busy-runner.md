# 2026-11-13 — The usage report's tenant-switch test read a busy CI runner as a load left running

- **Symptom:** `UsageReportTests.aTenantSwitchStopsTheOldLoad` failed `clock.now - started < .seconds(1.5)` on PR #161's
  CI (run 43474873656, 3.0 s). Nothing in the usage report or the runner had changed in that PR.
- **Cause:** the slow mock slept 2 s and the bound was 1.5 s: a bound between the expected time and the failure it
  detects, with half a second of room on a runner where other suites spawn the mock at once.
- **Why not caught:** the 2026-10-20 entry fixed the runner's timeout test the same way but nothing swept for other
  wall-time bounds on a process.
- **Fix:** sleep 600 s and bound at 60 s, as on 2026-10-20. A switch that doesn't stop the old gam still fails (10
  minutes); `isLoading` and the empty report stay the main checks. Its siblings had the same 2 s against 1.5 s
  (`DirectoryStoreTests` twice, `GroupStoreTests` once): there only the first slow call sleeps 600 s, since each test
  loads again after the switch and a test that waits a read out keeps two seconds. A stopped mock's trap now kills its
  sleep too, so no ten-minute `sleep` outlives the suite.
- **Prevention:** a wall-time bound on a process sits far from both the expected time and the failure it detects; when
  one flakes, look for its siblings (`grep -rn "seconds(" Packages/GamKit/Tests`).
