# 2026-10-12 — The mock's duplicate create was a 409 GAM never prints

- **Symptom:** found by reading GAM's source while planning onboarding, not seen live. The strict mock
  answered a `create user` for an address already taken with `ERROR: 409: Entity already exists -
  duplicate: <e>` and exit 1. GAM 7.48.22 never prints that. Its `doCreateUser` catches `GAPI.duplicate`
  and calls `duplicateAliasGroupUserWarning`, which looks the address up and names what holds it:
  `User: <e>, Create Failed: Duplicate, User: <e>` (or `User Alias: <e>, User: <primary>`, or
  `Group: <e>`), with exit 57, `ENTITY_DUPLICATE_RC` (`gam/__init__.py:2583-2612, 47315-47322, 356`).
  The same reading found four more gaps on onboarding's writes:
  - an org unit that doesn't exist created the account, where GAM fails the whole command with `ERROR:
    User: <e>, Create Failed: Invalid Organizational Unit`, exit 50 (47325-47326);
  - an address already in the directory, or made earlier in the same mock state, was created again;
  - one fixed task-list id (`MockTasklist_abc123`) was printed for everyone and accepted for anyone's
    tasks, so a task on another user's list passed;
  - a task list, a task or a calendar subscribe for an address that isn't a user succeeded, where GAM's
    token request for that user fails (`invalid_grant`, exit 50); a missing calendar succeeded too.
  - A first or last name over 60 characters was accepted. GAM reads it with `getString(maxLen=60)`, and
    the usage error echoes the whole command line, temporary password included.
- **Cause:** the mock's failure triggers were written from GAM7's conventions in general ("409 on
  create", "404 if the tasklist id doesn't exist"), not from `doCreateUser` and `processTasks` in
  particular, and the per-user token rule had only been applied to the reads and to signatures.
- **Why not caught:** no test asserted GAM's wording or exit code for these writes, and nothing used them
  yet: SwiftGamGui had no onboarding. Every test that met the duplicate (`aFailedStepSkipsOnlyWhatRequiresIt`)
  only needed *a* failure. The onboarding model's "says why" for a duplicate would have matched the
  mock's 409 and missed GAM's real line.
- **Fix:** onboarding slice O1 (branch `onboard/o1`), the mock fixes M1, M2, M4-M7 of the onboarding plan:
  - `create user`: GAM's duplicate line and exit 57 for a directory user, a user's alias, a group, an
    account made earlier in the state, or `*exists*`; GAM's org-unit failure for a `*missing*` org; GAM's
    60-character name limit as a usage error that echoes the command;
  - `create tasklist` mints an id per call under `GAM_MOCK_STATE` (one per user without it), and
    `create task` takes only a list made for the same user, failing as `processTasks` reports;
  - task lists, tasks and calendar subscribes for a non-user fail on the token; a `*missing*` calendar
    fails as `_processCalendarList` reports; `create task` meets the new-account lag like the other
    per-user calls.
  - The onboarding model words GAM's two create refusals (design D7) from GAM's lines, not the mock's.
- **Prevention:**
  - `MockOnboardingTests` holds each line and exit code above, as read from GAM's source.
  - `ExecutorTests.aSecretNeverReachesTheAuditOrTheScreen` runs GamGUI's echoing gam against sensitive
    surnames, so an echoed password is masked by value.
  - Not live-proven: Google's own "Not Found" texts for a missing task list and calendar are assumed, and
    so is the task list's "not ready" wording. The duplicate and org-unit lines are GAM's own, but no
    tenant has shown them to us. The onboarding runbook's stage C (the next real hire) is the first live run.
