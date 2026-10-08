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

## 2026-10-08 — The port of the credential code missed lessons GamGUI had already paid for
- **What happened:** PR #1's adversarial review proved nine defects in the new Vault/EphemeralConfig
  code before merge. Two repeated GamGUI incidents the port should have carried:
  - quitting leaves `gam` running (GamGUI failure-log 2026-09-23)
  - "only absence is a no-op" applied to writes as well as deletes (2026-10-01)

  Others were new shapes no GamGUI rule covered: hard links, a folder swapped by path, ACLs,
  composed characters in a name check.
- **Invariant in force:** #4 (secrets), #2 in spirit (the GAM child is part of the write).
- **Why it didn't hold:** the GamGUI history lived in runbooks and the failure log, and the port read
  the code but not every incident behind it. Nothing tied a GamGUI incident to a Swift test.
- **Would a rule have caught it?** only if enforced differently: porting an area should start from
  that area's failure-log entries, turning each into a Swift test before writing code.
- **Enforcement home if changed:** skill (`add-builder-command`-style "port an area" checklist). The
  tests added in PR #1 are the backstop for these nine.

## 2026-10-08 — The first publish would have gone out under the wrong GitHub account
- **What happened:** before creating this repo, `gh auth status` showed the active account was not the
  repo owner. `gh repo create` would have made the repo there. Caught by reading the status by hand;
  pushed with the owner's token for that one command instead of switching the global account.
- **Invariant in force:** none here; GamGUI's failure-log 2026-09-23 ("two handoff plans published
  the operator's second GitHub account") taught the related rule, and it lived only in prose.
- **Why it didn't hold:** not covered — no hook looks at which account a `gh` write or `git push` uses.
- **Would a rule have caught it?** only if enforced differently: a PreToolUse check that refuses
  `gh repo create` / `git push` unless the account in use owns the target.
- **Enforcement home if changed:** hook (hard). CLAUDE.md's rules of engagement now say it in words.
