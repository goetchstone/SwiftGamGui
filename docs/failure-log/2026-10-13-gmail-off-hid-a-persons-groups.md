# 2026-10-13 — Gmail off hid a person's groups: the mock read delegates GAM refuses

- **Symptom:** found by reading GAM's source while building offboarding's read-only plan (Off1), not yet
  seen live.
  - For a person without Gmail (no license, or Gmail off for their unit), GAM 7.48.22's `print delegates`
    fails: Gmail answers "Mail service not enabled", GAM reads it as `serviceNotAvailable`
    (`gamlib/glgapi.py:311`) and reports "User: x, Gmail Service/App not enabled", exit 73
    (`printShowDelegates` → `userGmailServiceNotEnabledWarning`, `gam/__init__.py:77232-77313`, :2533,
    :2498-2502).
  - `UserAccess.load` failed the whole person when either `print groups member` or `print delegates`
    failed. So on that person's page every list said the read failed: their groups, their delegates, their
    auto-reply and their signature, though only Gmail was off.
  - GamGUI loads each panel on its own, so its users page shows the groups.
- **Cause:** `UserAccess.Lists.delegates` was a plain list, read together with the groups; only the
  auto-reply and the signature were their own results.
- **Why not caught:** the mock lied. Its `nogmail/<user>` marker refused `show vacation`, `show signature`
  and `signature`, but `print delegates` still listed the person's delegates. Two tests
  (`aFailedAutoReplyReadLeavesTheOtherLists`, `theCurrentSignatureIsReadWithThePersonsLists`) relied on
  that: they passed only because the mock answered a read GAM refuses.
- **Fix:** branch `offboard/off1`.
  - The mock's `print delegates` prints GAM's "Getting all Delegates for x" on stderr and, with the
    `nogmail` marker, fails as GAM does: the failure line, exit 73, the CSV header with no rows
    (`MockDelegatesTests`).
  - `UserAccess.Lists.delegates` is its own `Result`, like the auto-reply and the signature. A person
    without Gmail still shows their groups; their delegates say why they couldn't be read.
  - Offboarding's preview reads the same `print delegates` and warns when it fails (GamGUI failure-log
    2026-09-23: the swallowed read made the preview look clean).
- **Prevention:**
  - `aFailedAutoReplyReadLeavesTheOtherLists` now also expects the delegates to fail and the groups to
    show.
  - `MockDelegatesTests` holds the mock to GAM's words and exit code.
  - The `nogmail` marker's other refusals exit 1 where GAM's `userGmailServiceNotEnabledWarning` exits
    73; checked against the source for `print delegates` only. Not live-proven: a Gmail-off person on a
    real tenant (`live-verify`).
