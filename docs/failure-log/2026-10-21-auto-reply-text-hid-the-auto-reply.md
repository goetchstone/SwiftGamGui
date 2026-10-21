# 2026-10-21 — An auto-reply's own text could hide it from the check

- **Symptom:** found in the security review of the Incident screen, before it was committed: an attacker's auto-reply
  whose text holds the line `Enabled: False` read as off. The check said nothing, offered no switch, and the plan
  refused to turn it off, so the phishing reply would keep going out after the lock.
- **Cause:** `Vacation(showText:)` (GamGUI's `Vacation.from_show_text`, ported for parity) ended the message at any line
  that looked like a setting and read it. GAM's `_showVacation` prints the settings, then `Message:` last, so such a line
  can only be the reply's own text. GamGUI's parity fixture (`Tests/Fixtures/vacation.json`) pins that reading.
- **Why not caught:** the reader only filled in the Users page until the Incident check made a lock decision on it;
  parity with GamGUI's output passed, and GamGUI shares the flaw.
- **Fix:** settings are read only above `Message:`; GAM's config banner still ends the message text. The parity test keeps
  every other GamGUI reading and records this one as the difference (`HTMLTextTests.showVacationIsReadAsGamGUIReadsIt`),
  and `CompromisedChangesTests.anAutoReplyIsReadSaidAndTurnedOff` holds a reply saying `Enabled: False`.
- **Prevention:** the tests above. GamGUI (frozen) still has it: reported to the operator. RULE-FEEDBACK 2026-10-21,
  "A parity fixture pinned a reader's flaw a security decision came to rest on".
