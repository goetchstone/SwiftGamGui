# 2026-11-14 — A mid-call test guessed when the call had begun

- **Symptom:** PR #164's third CI run failed `AuthenticatedRunnerTests.aDomainRemovedMidCallStaysRemoved` with
  `.missing(example.com, [oauth2Service])`. Nothing it tests had changed; it passes locally.
- **Cause:** the test starts a slow fake `gam` through `AuthenticatedRunner`, sleeps 250 ms and then removes the domain,
  taking for granted that the call had loaded its credentials by then. On a busy runner it hadn't: the removal came
  first, and the runner rightly refused a domain with no credentials. `aDomainReImportedMidCallKeepsItsNewToken` had
  the same guess. Same class as 2026-11-13's stop-timing tests: a sleep standing in for an event.
- **Why not caught:** a quiet Mac starts the call well within 250 ms.
- **Fix:** both tests use `HeldGam`, a fake `gam` that writes a `started` file once running (its credentials loaded)
  and refreshes its token only when the test writes `go` (bounded at 30 s, so a broken test fails rather than hangs).
  The test changes the vault between the two. The other `Task.sleep`s in the suite were read: one only waits to show
  nothing happened (a busy runner can't fail it), two are cancelled at once.
- **Prevention:** a test of "X happens during a call" waits for the call to say it has begun, never for a time.
