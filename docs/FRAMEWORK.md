# How this repo teaches itself

Carried over from GamGUI's `docs/FRAMEWORK.md`, where it was built after weeks of incidents. A
solo-operator project has no second pair of eyes, and the credentials this app touches make a silent
mistake expensive, so the structure has to make the model's review enforceable.

One sentence if you read nothing else: **rules earn their place by surviving incidents; each rule lives
in the layer that can actually enforce it; and the mock is guilty until proven faithful.**

## 1. Three layers of written context

| Layer | Where | Purpose | Loaded |
|---|---|---|---|
| **Constitution** | [`CLAUDE.md`](../CLAUDE.md) | Numbered invariants, each with the incident behind it | Every session |
| **Domain runbooks** | [`docs/domains/*.md`](domains/README.md) | Per-area files, flow, failure history, mock-lies traps, common tasks | On demand, by area |
| **Skills** | [`.claude/skills/*/SKILL.md`](../.claude/skills) | Procedures for a moment: pre-commit, post-failure, start/end-session, improve-rules, live-verify | When the moment arrives |

When CLAUDE.md wants to grow, push the detail into a runbook and keep the invariant one line.

## 2. Three enforcement homes

| Home | What it is | Strength | Example here |
|---|---|---|---|
| **Skill** | A checklist the model reads when activated | Persuasive | `pre-commit`: "route the mutation through ChangeCore" |
| **Hook** | Code on a tool event; can hard-block | Hard gate | `.claude/hooks/pre-commit-check.sh` (private terms, `fix:` without a failure-log entry); `credential-guard.sh` |
| **Tripwire test** | A test that fails if a guard is missing or the mock lies | Backstop | `FixtureTests` (pin consistency, golden argv coverage), the Runner's env-allowlist and argv tests |

**A hook only counts if its output reaches the model.** A SessionStart hook's stdout becomes context; a
non-blocking PreToolUse hook prints `{"hookSpecificOutput": {"hookEventName": "PreToolUse",
"additionalContext": "…"}}`; stderr reaches the model only on a blocking exit 2. GamGUI's hooks once
printed to stderr at exit 0 for weeks and nobody saw a line.

**Local vs shared.** `.claude/*` is gitignored except `skills/` and `agents/`: the knowledge is
committed; the enforcement wiring (`.claude/hooks/`, `.claude/settings.json`, `.claude/private-terms`)
stays local to the operator.

**Review skills are a probe, not a home.** `/code-review`, `/security-review` and the
`gam-command-reviewer` agent find breaks; a real finding goes in RULE-FEEDBACK, and the rule it implies
still needs one of the three homes.

## 3. The learning loop

```
Something breaks (a test late, a live tenant, a regression)
        ↓  post-failure skill
docs/failure-log/ entry: symptom / cause / why-not-caught / fix / prevention
        ↓
Recurring shape? ── yes ─→ a tripwire test that asserts it can't recur silently
        ↓ no
docs/RULE-FEEDBACK.md — which invariant strained, and how
        ↓  (sessions do NOT edit CLAUDE.md)
improve-rules — later, with distance — proposes ONE focused CLAUDE.md edit as a PR
```

GamGUI's failure log stays the history this repo's rules came from; cite its entries by date
("GamGUI failure-log 2026-09-23"). New incidents here get entries here.

## 4. The defining failure class: the mock lies

`Tests/Fixtures/mock_gam.sh` must **fail the way real GAM fails**, checked against the vendored grammar
`Vendor/gam7/GamCommands.txt`. A mock more permissive than GAM converts a live break into a green test.
Passing the offline suite does not mean a GAM write works; a mutation is unproven until it has run
against a real tenant, by the `live-verify` skill.
