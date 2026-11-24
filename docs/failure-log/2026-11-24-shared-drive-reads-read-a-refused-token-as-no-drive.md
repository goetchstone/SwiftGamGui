# 2026-11-24 — A shared drive read read a token Google refused as "no shared drive"

- **Symptom:** none live; ported from GamGUI's entry of 2026-11-21 (same title, found in review of its #176). The F3 port
  carried the same reading: when Google refuses the service-account token with one of `REFRESH_PERM_ERRORS`, Shared drive
  permissions would have said the domain has no shared drive and every listed drive's members were read, and a scheduled run
  (F7a) would have shown every member as gone.
- **Cause:** `printShowSharedDrives` and `printShowSharedDriveACLs` (the 7.52.04 tag) call `buildGAPIServiceObject`, whose
  `handleOAuthTokenError(softErrors)` returns None without a word for those errors; the loop `continue`s before its
  `NO_ENTITIES_FOUND_RC` check, so GAM writes the titles alone and exits 0. `AuditRuns.drives` and `driveACLs` took exits 0 and
  60 as whole answers, and no row at either as "none". GAM's own none is 60 only.
- **Why not caught:** the strict mock (GamGUI's, copied) modelled "no drive" (60) and a refused `drives.list` (50), never the
  silent token skip, nor every drive's permissions refused, which GAM answers with 60 as for none. Parity held the port to
  GamGUI's reading, which was wrong the same way.
- **Fix:** `AuditRuns.Step.emptyCodes` (GamGUI's `empty_rcs`): the drives and drive-members steps take no row as an answer only
  at 60; at 0, `AuditRuns.answer` is `Incomplete` ("GAM wrote no row and exited 0, …") and the step says
  `AuditRunner.noRowUnsaid`. The mock's `drive_token_silent` writes the titles alone, exit 0, and every drive dropped exits 60.
  Both drive tables are partial whenever a drive's members weren't read. Fixtures regenerated from GamGUI `73498c4`.
- **Prevention:** `AuditRunnerTests.titlesAloneAtExit0AreATokenGoogleRefusedSilentlyNeverNoDrive`,
  `everyDriveDroppedIsGams60AndEveryDriveIsNamedUnread`, `MockAuditRunTests.sharedDrivesAndTheirMembers`, and
  `audit_runs.json`'s read cases with `empty_rcs`. A read whose "none" GAM says with its own code takes no row as an answer only
  at that code. Mock-proven only: not run on a real domain.
