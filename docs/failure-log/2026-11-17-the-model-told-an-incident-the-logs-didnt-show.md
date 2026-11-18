# 2026-11-17 — The on-device model told of an incident the logs didn't show

- **Symptom:** the operator: "The on board AI seems to state there is an incident even when there isn't one." Reproduced on
  this Mac's real on-device model. Logs with three office sign-ins and one Chrome breach warning, with no suspect address and
  no account touched, drew this overview: "The attacker accessed the system on 2023-10-05 by exploiting a vulnerability in
  Chrome… The compromised account was locked on 2023-10-06." It also wrote that the locks were holding. The sign-ins alone,
  as a report's summary draft, drew "The breach began on 2023-10-05…".
- **Cause:** `LogExplainer` was written for logs with an attacker in them. Its instructions say "a short rundown of a security
  incident", and its overview field asks "when and how the attacker got in… and when each was locked". Explain was offered
  for any finding, including Chrome's warnings and a shared address set aside, which leave no account status. The report's
  Draft was offered for any incident. So the model got empty "What happened" and "Where each account stands" sections
  under a frame that said there was an attack, and it filled them in. Findings are never given to it, so nothing in the
  prompt said "nothing found".
- **Why not caught:** every model test used the takeover fixture. The stub answers whatever it's given, and the real-model
  suite (by hand, `SWIFTGAMGUI_MODEL=1`) also ran only on a takeover. Nothing asked what the model says when the reading
  finds nothing. The guards checked citations and numbers, not whether the story has a basis.
- **Fix:** code decides whether there is a story. The model is asked only when an account was touched from a suspect address
  (a status). Otherwise `LogExplainer.untold` gives the app's own sentence, which `explain` and `summary` return and the log
  reader shows where Explain was: no sign of an attacker, or a suspect address with no account touched. Review caught that
  second case, a pull by the attacker's address that read only Gmail, which a status-only check would have called "no
  attacker". The report's Draft sheet says the same sentence. The reader's own "no account the attacker touched" now reads
  "no account was touched from a suspect address".
- **Prevention:** `LogReadingTests.logsShowingNoAttackerAreNeverToldAsAnIncident` has a stub answer the way the real model
  did, for a quiet reading that has a finding, a Gmail-only pull by the attacker's address, and a quiet
  report summary. Neither reaches the screen. The runbook's
  model entry says the model is asked only when code found an attacker. **Not proven against the model's wording for logs
  with an attacker:** there it may still add dates or steps the facts don't hold, and only the number check and the
  "check it against the timelines" label stand in the way.
