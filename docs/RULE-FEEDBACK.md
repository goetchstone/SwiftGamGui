# Rule feedback ledger

Low-friction notes on how [CLAUDE.md](../CLAUDE.md)'s invariants performed in practice. **Sessions
append here; they do not edit CLAUDE.md.** The `improve-rules` observer pass reads this pile later,
with distance, and proposes at most one focused constitutional edit as a PR. See
[FRAMEWORK.md](FRAMEWORK.md) §3.

When to add an entry: an invariant almost let something through, was in the wrong enforcement layer,
was worded loosely enough to permit a bad reading, or a failure hit a shape no invariant covers.

**Format**, newest first:

```
## <date> — <one-line title>
- **What happened:** <the incident / near-miss; link commit/PR/failure-log entry>
- **Invariant in force:** <#N and its name, or "none — new shape">
- **Why it didn't hold:** <wrong layer / weak wording / not covered / not a rules problem>
- **Would a rule have caught it?** <no / only if enforced differently / yes but unworded>
- **Enforcement home if changed:** <skill (soft) / hook (hard) / tripwire test (backstop)>
```

The most valuable answer is *"only if enforced differently"*: the invariant exists and lives in the
wrong layer, and moving it (skill → hook → tripwire) needs no text change.

<!-- No entries yet. -->
