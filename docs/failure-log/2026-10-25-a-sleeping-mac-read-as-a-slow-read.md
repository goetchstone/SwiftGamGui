# 2026-10-25 — A Mac asleep mid-test read as a slow log read

- **Symptom:** `LogReadingTests.aWholePullIsReadInSeconds` failed `took < .seconds(60)` twice in one local session
  (872 s once), while swift-testing timed the same test at 3.8 s. The Mac was on battery and went into maintenance sleep
  during the runs.
- **Cause:** the test measured `ContinuousClock`, which keeps counting while the Mac sleeps. A 4 s read that straddled a
  sleep counted the sleep too.
- **Why not caught:** the 2026-10-16 entry's rule (a test bounding pure code measures its thread's CPU time) was applied
  to `SignatureTests` only, and its helper was private there; this test, written later, chose a wide wall-time bound for a
  busy runner instead, which a sleep crosses however wide it is.
- **Fix:** `threadCPUTime` moved to TestSupport, and this test measures with it (the bound unchanged: reading every event
  per account still takes about 110 s of CPU and fails it). The PR for the Who it reached list.
- **Prevention:** the helper's own comment names the rule, with its exception: a bound on blocking or waiting (a FIFO
  open, a wipe, a load being stopped, a process's timeout) stays wall time, since a thread that's stuck spends no CPU, and
  every such bound now reads `SuspendingClock`, which stops while the Mac sleeps (the final review found eight still on
  `ContinuousClock`). The clocks tests move, standing in for the app's own `ContinuousClock`, stay on it. Who it reached's
  own cost is held the same way (`whoItReachedIsReadInSeconds`, against summing every email).
