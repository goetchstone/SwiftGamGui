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

## 2026-11-20: what the real model says for each shape (plan 2026-11-18, A2)

Run by hand twice on this Mac (`SWIFTGAMGUI_MODEL=1 swift test --package-path Packages/GamKit --filter OnDeviceModelTests`),
on test fixtures only (`LogReadingTests.triedOnly`, `notLocked`, `halfLocked`, `wave`, `incident`). Model: AFM 3 Core
Advanced, context 8,192 tokens. Prompt tokens: `notLocked` 143, `halfLocked` 205, `triedOnly` 209, `incident` 469, `wave`
1,803. Nothing threw, the wave included, and every cite was a real to-do ID in both runs. ✗ marks a sentence the facts don't
hold; the rest hold.

**Finding 2 reproduced, in `done`, not in `overview`.** Asked what was done when nothing was, the model says the accounts
were secured: `notLocked` in 2 of 2 runs, `triedOnly` 1 of 2, `incident` 1 of 2; `halfLocked` never. Its guide is "what has
been done to secure the accounts, and whether the locks are holding". The overview, asked "when each was locked", invented no
lock in 10 answers. A3 keeps its steps 1 and 2.

**`triedOnly`** (erin@'s and frank@'s passwords tried, nobody got in, nothing done)
- Run 1, overview: "On 2026-10-19 at 09:04:20Z, the attacker tried the password for erin@example.com and failed. At
  09:05:20Z, the same attacker tried the password for frank@example.com and failed. Neither account was locked since the
  attack."
- Run 1, done: ✗ "The accounts for erin@example.com and frank@example.com have been secured by preventing further access
  after the failed attempts." Nothing was done.
- Run 1, left: "The account for erin@example.com remains unsecured since the attack, requiring immediate action." (T1) "The
  account for frank@example.com also remains unsecured since the attack, needing similar protection." (T2) "Logs from the
  attacker's address must be reviewed to determine other affected accounts." (T3)
- Run 2: the same overview. Done: ✗ "The accounts have been checked for lock status, and no locks were applied yet." (no
  check was done; its second half holds) "The systems show no automatic locking for either account since the failed
  attempts."

**`notLocked`** (carol@ signed in to by the attacker, nothing done)
- Run 1, overview: "On 2026-10-19T09:04:20Z, the attacker signed in from 198.51.100.23 using carol@example.com. The attack
  affected carol@example.com, which has not been locked since the incident." "No other accounts were directly reached by
  the attacker at this time." (not in the facts, which list carol@ only; true of these logs)
- Run 1, done: ✗ "We have secured the account for carol@example.com, but the lock has not been applied since the attack."
  Nothing was done; the sentence contradicts itself.
- Run 1, left: "The account for carol@example.com remains unsecured as no lock has been enforced since the attack." (T1) "We
  must review all logs from the attacker's address to determine other impacted accounts." (T2)
- Run 2, done: ✗ "We have secured carol@example.com by ensuring its status after the incident." "The locks on the accounts
  are not active."

**`halfLocked`** (carol@ signed in to, her password reset, no sign-out): nothing false in either run.
- Run 1, overview: "On 2026-10-19T09:04:20Z, the attacker signed in from 198.51.100.23 using carol@example.com. A password
  reset was issued on 2026-10-19T09:53:20Z for carol@example.com, but no sign-out was observed. The account was partly
  locked after the reset, with no full lock applied yet."
- Run 1, done: "One password reset was performed by an admin for carol@example.com. The account status remains partially
  affected, with no sign-out recorded."
- Run 1, left: "The lock status for carol@example.com must be finalized, as only a reset or a sign-out was executed." (T1:
  vague, the to-do's own "or"; the facts say which) "Logs from the attacker's address must be reviewed across all accounts
  to determine additional reach." (T2)
- Run 2, done: "A password reset was issued by an admin for carol@example.com to secure the account."

**Not asked for, recorded:**
- `incident`, run 1, done: ✗ "The accounts for carol@example.com, dana@example.com, and erin@example.com have been secured
  by ensuring no further access was granted, though the locks remain active." None was locked. Run 2's held.
- `wave`: overview and done held in both runs; its points about what's left didn't. Run 1 said two of the open sweeps were
  done: ✗ "…have had their logs reviewed…", ✗ "The full scope of access … has been analyzed across all accounts,
  confirming widespread compromise". Run 2 made T1, T2 and T3 "the first batch", "the next set" and "the final phase" of one
  review, and left out T4 to T12. The cause is code's: twelve suspect addresses make twelve `sweep` items whose meanings are
  word for word the same and don't name the address, so the model can't tell them apart.
- Size: the wave's 12 accounts used 1,803 of 8,192 tokens. A4 should size from this measure, not the plan's estimate.
