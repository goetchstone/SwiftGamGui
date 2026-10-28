# 2026-10-28 — Still to do kept asking for what was done

- **Symptom:** on a run through Respond on the real incident, a week in, about 14 items stayed to do that the operator had
  done or already answered. One was to unblock a sender, done with the person. Five were to warn people, one for each of the
  attacker's emails, where Report keeps one list. Three were to confirm phone sign-ins from IPv6 addresses the operator had
  already identified, and one her home address. Four more the operator thought the logs already showed; which items those
  were is still to confirm (they rank after the address questions, so they aren't Pull Again items).
- **Cause:** three rules, each sound alone, and a fourth found while looking:
  1. A step no log can show (a sender unblocked, contacts warned by phone) had no way to leave. The plan's hand tick was never
     built ("a note for now").
  2. Each email's Who it reached made its own warn and pull-again items, worded per email, so one person to warn was asked
     about once per email they got. The count also used Who it reached's over-warning rule (bounces count), not Report's
     "if it bounced, they did not get it".
  3. "Ask … whether this address is theirs" never read the operator's "That was them" marks, and had no button to give one.
     Marks matched the exact address, but a phone's IPv6 address changes within its /64 (and a phone on mobile data changes
     network as it moves), so each new sign-in was a new question.
  4. (Found in passing, not one of the items asked about.) Pull Again listed anyone with no Gmail event after the email. The merged evidence couldn't tell "their log wasn't read"
     from "it was read, and they got nothing since", because putting saved reads together kept the rows and forgot whose
     mailboxes each read held.
- **Why not caught:** every test incident was a few minutes of one attack, read once. None ran a week of real use: a
  person's phone moving between networks, every account's Gmail read whole, several emails reaching the same people, a
  step done by talking to someone.
- **Fix:** each rule fixed in place (the PR for the report's Markdown and the hand tick):
  1. Mark Done… on any item no log can show done, kept with the incident (who, when, how), undoable, and matched by what the
     item stands on as well as its words, so new evidence brings it back. It is never offered on a lock, recovery details
     cleared, a computer or a read, which Google's logs or this app show done.
  2. One warn item and one pull-again item across every email, counted as Report counts (`IncidentReport.gotIt`). An email
     is done once everyone it got to is warned.
  3. The address question honors marks, by network as the reader's other per-address rules do, and has its own That Was
     Them. A mark stays exact for whether a sign-in is a suspect, and never covers a network a suspect address shares.
  4. Each log read keeps whose events it holds whole and between when (`IncidentLogs.Log.whole`, from its rows and where a
     capped read stopped, never a claimed window). Pull Again leaves out a mailbox a read holds past the email.
- **Prevention:** `StillToDoTests`, a suite named for the class: each rule above on the made-up incident, including a phone's
  later IPv6 address and a quiet mailbox read whole. An adversarial review before merge found the first version's mark could
  clear an attacker sharing a relay's /64 and a tick could outlive new evidence; both are tested (`aMarkAnswersForItsNetwork
  ButNeverTheAttackers`, `aTickComesBackWhenTheEvidenceGrows`). The runbook's Next asks for one live check after any change to Still to
  do: a run through Respond on a real incident a week in, each item read against what was actually done.
