# 2026-11-13 — A wrong typed count spent the group change's preview

- **Symptom:** found in review, not in use. On the Groups sheet, a change of more than 25 people asks for the count typed.
  The confirm button (the default, so Return presses it) turned on as soon as the field held any text. Typing "12" for 13
  and pressing Return closed the sheet with "preview again": no write ran, but the preview was gone and the operator had
  to build it again.
- **Cause:** `GroupChanges.confirm` went straight to `Executor.run`, which takes the held preview out before
  `Guard.refusal` checks the count. The sheet checked "not empty", not the count. The same shape was found in the
  calendar and signature sheets of PR #161, by its second review; an adversarial verifier then found it here on `main`.
- **Why not caught:** the test previewed again before each wrong count, so it never asked whether the preview survived
  one. Nothing held the sheet's button to the guard's own check.
- **Fix:** `Guard.Decision.typedCountMatches(_:)`, the guard's strip-and-exact check (the same function #161 adds), now
  runs in `GroupChanges.confirm` before the executor: a mismatch sets `typedProblem`, counts `typedRefusals` and keeps the
  preview. The sheet keeps its button off until the count matches, shows the problem and announces each refusal to
  VoiceOver. The phishing sheet's button already waited for the count, but trimmed with Foundation's whitespace set
  rather than Python's; it now uses the same check. Held by `GroupChangesTests.moreThan25PeopleNeedTheirCountTyped`
  (four wrong counts on one preview, then the right one runs it) and `theExecutorRefusesAnotherCount`.
- **Prevention:** a typed confirm is checked with the guard's own function before the executor, never with a second
  copy of its rule. A test of a refusal confirms the *same* preview again afterwards.
