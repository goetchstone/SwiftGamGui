# 2026-10-13 — Offboarding's own-admin check failed open, and its review found three more holes

- **Symptom:** found by Off2's adversarial review after #59 merged, before any live run. With example.com
  connected as carol@, a Check access of another domain that failed (a `partialdwd` admin) left example.com
  active but its admin unknown, and offboarding carol@ then planned and ran all eight steps: the password reset
  and the sign-out of the account the app signs in as. The review also found:
  - a Stop asked before the first step began (the run still checking: the write lock, the precondition's
    reads) was dropped, and every step ran;
  - "Preview the Rest" couldn't finish a run whose reminder was all that was left: the address to type was
    the leaver's, and no remaining step acted on the leaver;
  - the sweep's tolerance ignored a truncated stderr (past 8 MiB a real failure may be among the lines
    dropped), and a `gam` stopped at quit read as an ordinary exit-15 failure, so a quit mid-sweep left no
    "outcome unknown — check".
- **Cause:** `SetupModel.connectedAdmin` read the last Check access, of any domain, and a failed check
  doesn't change the active domain; offboarding treated an unknown admin as "skip the check" (`?? ""`), as
  GamGUI's pure `check_addresses` does for an empty one, and captured the admin at plan time. The executor
  only took a stop once its loop had started; the typed address assumed every routine acts on the leaver;
  the tolerance read the lines it had, never whether it had them all.
- **Why not caught:** the own-admin test connected once; no test checked another domain between. The
  run-time re-check, Stop, the typed address and the tolerance were each tested at the executor, not
  through the routine's own paths (eight mutants survived the suites: the review's list).
- **Fix:** branch `fix/off2-review`. The active domain keeps the admin its activating check passed for until
  it's forgotten; offboarding refuses to plan without one and reads it again at the run. A run is stoppable
  from the moment it's taken; a Stop before the first step runs none. The address to type is the leaver's
  only while a step acts on the leaver. A truncated stderr is never tolerated. A `gam` stopped at quit
  throws as a cancelled run does, and an interrupted end record stays "outcome unknown" until marked
  checked. A failed re-read says why (`PreconditionFailure`). The run panel stays, with Stop, if the domain
  changes mid-run. The mock's suspended-user deprovision exits 51 only with backup codes, as GAM does. Each
  has a test; the review's surviving mutants were run again against them.
- **Prevention:** the tests above, and `SetupModelTests.theConnectedAdminStaysTheConnectedDomainsOwn`.
  The plan's rule held: the adversarial review ran before the first live run (L2), which is still to come.
