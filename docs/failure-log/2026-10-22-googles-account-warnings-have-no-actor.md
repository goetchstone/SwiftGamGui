# 2026-10-22 — Google's account warnings have no actor, and the mock gave them one

- **Symptom** — Reading a real tenant's exported incident logs (read-only, the operator's export) against the reader
  merged in #98: Google's `account_disabled_hijacked` for the taken-over account, and its three `suspicious_login`
  warnings, had an empty actor. The reader's per-account statuses look for an account's events by `who`, so Google's own
  disabling of the account would never have counted as a lock, and its warnings named no account. The same export showed
  two false flags the reader would act on: the operator's own passkey re-sign-in through a relay's address, and a person
  re-proving themselves at the office, both marked `is_suspicious`.
- **Cause** — `Tests/Fixtures/mock_gam/report_login.csv` put the victim in `actor.email` on `suspicious_login`, as if it
  were their own sign-in; Google writes these as account warnings with the account in `affected_email_address`. And
  `LogReading.marksAttacker` took any `is_suspicious` as the attacker's address, though Google also marks re-sign-ins that
  re-prove a session before a sensitive change.
- **Why not caught** — The mock was written from the API's field list, not from a real row: nothing showed an account
  warning's shape. The rule's tests used events built in code with the same assumption.
- **Fix** — `ActivityLogs.Row.who` takes `affected_email_address` for a sign-in log row with no actor; `marksAttacker`
  doesn't count a sign-in proved with a passkey or security key, or a re-sign-in from an address the account signs in
  from unmarked; the mock's `suspicious_login` has no actor, and a named account's read leaves it out (the strict guess).
  Same PR: a person's own password change counts as a reset, a blocked sender and contacts printed during the attack are
  found, and "That was them" marks a false flag.
- **Prevention** — `ActivityLogsTests.googlesOwnWarningIsTheAccountsItsAbout`,
  `LogReadingTests.aPasskeyOrAnOrdinaryReSignInIsntTheAttacker`. Only a greener mock proves the per-account case: whether
  Google returns an account warning to a read of that one account is the live check L1l, not yet run. Lesson: read one
  real export of a log before modelling it.
