---
name: end-of-session
description: The wrap-up routine at the end of a SwiftGamGui session — capture what was learned where the next session will find it. Deliberately does NOT edit CLAUDE.md.
---

# End-of-session — capture

1. **Incident this session?** → a failure-log entry via `post-failure`.
2. **An invariant strained?** → one `docs/RULE-FEEDBACK.md` entry. Don't edit CLAUDE.md; `improve-rules`
   decides later.
3. **A domain behaved differently than its runbook says?** → update the runbook.
4. **Plan progress** → the design doc's Status line and phase table, in the same change.
5. **Deferred work** → a task chip or the design doc's open items; "later" in chat is not tracking.
6. **A defect GamGUI shares?** → tell the GamGUI session (or leave a task chip for it); never edit GamGUI from here. A
   port's review reads both apps: the Classroom port (2026-11-13) found nine GamGUI defects this way.
7. **A parity port finished?** → the Swift column of GamGUI's plan is marked by PR number, by the GamGUI session.

Commit documentation as its own atomic commit, when the operator asks.
