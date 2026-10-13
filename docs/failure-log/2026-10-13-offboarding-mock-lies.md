# 2026-10-13 — The mock ran offboarding's writes more loosely than GAM

- **Symptom:** found by reading GAM's source while planning Off2, not seen live. Five of offboarding's
  writes passed in the strict mock where GAM 7.48.22 would refuse or answer otherwise:
  - **M1:** a transfer to the same account (alice@ to her alias a.anders@ included) was accepted. GAM
    compares the two owners as user IDs and refuses: "New owner must differ from old owner", a usage
    error (`doCreateDataTransfer`, gam/__init__.py:17886-17888).
  - **M2:** an owner that isn't a user was refused only for a `*missing*` address. GAM resolves each
    owner as it reads it (`convertEmailAddressToUID`, :5997-6013) and ends the command there: the command
    line, then "User: x, Does not exist", exit 56, before any transfer.
  - **M3:** success printed "Requested transfer of …", a line GAM never prints. GAM prints "Transfer
    Request Performed", then the transfer's ID, services, From and To (:17907-17912). A second transfer
    for the same leaver 409d only for a `CONFLICT409` address; with state it never did.
  - **M5:** deprovisioning a suspended user exited 0. GAM leaves a suspended user's backup codes alone,
    says why ("User is suspended. You must unsuspend to process backupcodes", read from the build's
    glmsgs), still runs the other parts, and exits 51 (`deprovisionUser`, :74188, :74222-74229).
  - **M8:** the default sweep printed one "Deleted" line and the leaver's own calendar. GAM walks every
    active user with progress lines, a header per user and a "Delete Failed: Not Found" where the user
    never shared with the leaver (:55925-55935, :41681-41708).
- **Cause:** the transfer and deprovision handlers came from GamGUI's mock, written from GAM's
  conventions, not from these functions; nothing in GamGUI or here ran them with a non-user, an alias, a
  suspended leaver or a second transfer. The sweep's default modeled the one live run's last line.
- **Why not caught:** Off1 only shows these commands; no test ran them, and GamGUI's tests never asserted
  GAM's wording or exit codes here. A tolerance test over the old default sweep would have tolerated a
  single line, never the per-user "Not Found" that real sweeps are made of.
- **Fix:** Off2a (branch `offboard/off2`). The mock resolves each transfer owner as GAM does (aliases to
  their owner; `CONFLICT409` stays a trigger, as a pseudo-user), prints GAM's success, keeps a transfer in
  progress under `GAM_MOCK_STATE` and answers a second with Google's 409 (HTTP_ERROR_RC 9), exits 51 for a
  suspended user's deprovision, and walks the active directory for the default sweep from the calendar
  data. `MockOffboardingTests` holds each. `MockProgressTests` had relied on M5's lie (bob@, suspended,
  exit 0) and now deprovisions an active user.
- **Prevention:** each handler's comment cites GAM's function and lines, and the tests assert GAM's exit
  codes and words. Found on the way, not fixed here: for GAM's "does not exist" exit, `GamError` (as
  GamGUI's reader) takes its message from the echoed `Command: gam …` line, which outranks the not-found
  line, so the operator would read the command rather than "User: x, Does not exist". That is a reader
  deviation of its own, for its own change. Still a mock: Google's "Not Found" text and the transfer's
  service names are assumed, not captured.
