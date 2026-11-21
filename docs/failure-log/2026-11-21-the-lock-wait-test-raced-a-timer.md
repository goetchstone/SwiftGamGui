# 2026-11-21 — The lock-wait test raced a timer

- **Symptom:** `SignatureBackupStoreTests.aLockHeldAMomentIsWaitedFor` (from #185) failed twice in full-suite runs on a
  clean `main`, and passed every time on its own.
- **Cause:** the test took its holder's lock with a single `flock` try and released it from a 40 ms `asyncAfter` timer. In
  the full suite, processes started beside it can hold a reference to the run's file for a moment (the store's own pruning
  waits up to 200 ms for exactly that), so the single try could be refused; and a timer on a busy machine fires late.
- **Why not caught:** the suite runs pass alone, and #185's review and CI runs didn't hit it. The same shape (a test leaning
  on a process's timing) is in this log four times (2026-10-16, 10-20, 11-03, 11-13).
- **Fix:** the holder takes its lock through `lockedNow`, as pruning does; the release happens after the first refused try,
  through a test-only `afterRefused` hook, so nothing races a timer, and the test checks the lock was held when the wait
  began.
- **Prevention:** a test that needs something to happen "a moment later" does it at a known point in the code under test
  (a hook), never on a timer. Noted in the pre-commit checklist's time-bound line.
