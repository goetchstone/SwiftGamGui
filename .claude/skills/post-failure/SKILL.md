---
name: post-failure
description: Run after any regression, broken test, or bug caused by a change — especially "the mock passed but the live tenant broke". Document, reproduce, fix, and leave a tripwire so the same shape can't recur silently.
---

# Post-failure learning

1. **Root cause**: what broke (the exact symptom), what caused it (which line, which assumption), why it
   wasn't caught (a permissive mock, a missing test), what would have prevented it. For a live break,
   capture the exit code, stream and wording from the audit record — never by re-running the write.
2. **Reproduce before fixing**: a failing Swift test, or for a live-only break a mock case that fails the
   way real GAM failed (check `Vendor/gam7/GamCommands.txt`). It becomes the regression test.
3. **Fix**, then `swift test --package-path Packages/GamKit`.
4. **Leave a tripwire** in the right home (docs/FRAMEWORK.md §2): a coding pattern → `pre-commit`; a
   permissive mock → tighten `mock_gam.sh`; a cross-cutting invariant gap → one `docs/RULE-FEEDBACK.md`
   entry (do not edit CLAUDE.md now); a domain assumption → its runbook.
5. **Log it**: a new `docs/failure-log/YYYY-MM-DD-<slug>.md` with the five fields. This is what clears
   the hook's `fix:` block, so write it before committing the fix.
