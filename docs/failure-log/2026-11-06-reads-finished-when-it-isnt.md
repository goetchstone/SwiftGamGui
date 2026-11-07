# 2026-11-06 — The incident screens could read finished when they weren't

- **Symptom:** nothing seen live. Porting the incident screens to GamGUI, review against GAM's source found the same harm
  in this app: something reads finished, whole or proven when it isn't. A read for one person made every account's log read
  whole. An email stayed "nobody has it" after a later Find showed a copy or the log showed a later delivery. A computer block GAM
  never did, or Google hadn't finished, read as done; computers, send-as addresses, drafts and scheduled sends read as none, and
  the auto-reply as off, when GAM skipped a refused token. A report rested on capped or unread logs without saying so, called
  2-Step Verification "on" for anyone not on the list of those without it, counted failures and notes as steps taken, and could
  lose the lock past the timeline's cap. A line break in a subject could forge a heading in its text export. Do It Here could pick a
  computer for a phone's item, or an old computer by a sync time Google moves. Read the Rest on Gmail could skip a stretch and read
  whole. A shared phone listed only its first owner.
- **Cause:** each read and rule was written for what it says when it works. `merged` cleared a cap on any uncapped read; a mock
  with no silent exit 0 could not show GAM's `sys.exit(SYSEXITRC)` after a refused token (buildGAPICIDeviceServiceObject,
  handleOAuthTokenError) or its exit 0 while an operation runs (_performCIDeviceUserAction).
- **Why not caught:** the tests asked whether the right answer came back, not what the screen says when a read fails, stops short,
  or answers for less than it seems to. The mock was kinder than GAM here.
- **Fix:** PR for this branch. A log stays short until a read holds what it left out (`IncidentLogs.stoppedShort`, stricter than
  GamGUI's: over less of the window doesn't count either). `GamWrite.notDone` makes GAM's silent exit the step's failure in the
  executor, on the device writes, a short `delete messages` and every per-person Gmail write (found by review, 2026-11-07), and a mailbox
  read's silence is "not read" (`MessageCopies.unanswered`). The report says what it rests on. Checked against GAM
  7.50.00's source.
- **Prevention:** the mock now fails these ways (`quiet/<user>`, `quiet/devices`, `queued/deviceusers`, `unavailable/<user>`, `print mobile`
  cutting lists without `listlimit 0`), and each has a test. **Not proven live:** every one of these is a mock and source reading until
  it comes up in use. Noted in RULE-FEEDBACK: a read's tests should cover its failure and partial cases on the screen.
