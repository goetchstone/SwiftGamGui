# Failure log

Institutional memory of what broke and why, so the same shape can't recur silently. Read the recent
entries before working in a domain that has prior ones. Every incident that reaches a user (a broken
test caught late, a live tenant break, a regression) gets an entry via the `post-failure` skill.

**One file per incident**: `YYYY-MM-DD-<slug>.md`, opening `# YYYY-MM-DD — <title>`. Newest first:
`ls -r docs/failure-log/`. Cite an entry by its date and title.

**Format**, five fields:

- **Symptom** — what was actually observed.
- **Cause** — the line or assumption that did it.
- **Why not caught** — the test, validation or gate gap.
- **Fix** — what shipped (link the commit or PR).
- **Prevention** — the tripwire test, hook, skill or CLAUDE.md rule it fed ("nothing yet" is a valid,
  and telling, answer).

This repo inherits GamGUI's defining failure class, **"the mock passed, the live tenant broke"**, and
its history: GamGUI's `docs/failure-log/` (90 entries by 2026-10-08) is where most invariants here came
from. A fix whose only proof is a greener mock is not proven; say so in the Prevention field.

<!-- No entries yet. -->
