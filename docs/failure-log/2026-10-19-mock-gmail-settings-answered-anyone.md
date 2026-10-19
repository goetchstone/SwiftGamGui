# 2026-10-19 — The mock's forwarding addresses answered for anyone, and any delegate removal passed

- **Symptom:** found while building the compromised-account check, before anything shipped on it: `user <u> print
  forwardingaddresses` answered `fwd@example.com,accepted` for every address, a non-user and a person with Gmail off
  included; `user <u> delete delegate <d>` succeeded for a delegate the person didn't have.
- **Cause:** both handlers were written for argv shape only (GamGUI's builders), before any screen read or removed
  these for real. GAM acts as the person (a token, then Gmail): printShowForwardingAddresses fails at the token for a
  non-user and reports Gmail off (exit 73); processDelegates reports Gmail's notFound for a delegate the person doesn't
  have (exit 50).
- **Why not caught:** nothing read forwarding addresses, and the only removal test removed a delegate the person had.
- **Fix:** the compromised-account PR: `print forwardingaddresses` now acts as the person (`gmail_read`: the token,
  "Getting Forwarding Addresses for <u>", Gmail off) with each person's own list; `delete delegate` of one they don't
  have fails "Delete Failed: Not Found", exit 50. The new reads (`print forward`, `print sendas verifyonly`, `print
  admins user`) and `delete sendas` were written to fail the same way from the start.
- **Prevention:** `MockCompromisedTests` (`eachGmailReadFailsAsGamDoes`, `removingADelegateTheyDontHaveFails`). Only
  a greener mock: the live L1 and L2 in docs/domains/compromised-account.md are the proof.
