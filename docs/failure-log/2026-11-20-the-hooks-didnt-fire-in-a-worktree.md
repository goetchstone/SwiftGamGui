# 2026-11-20 — The hooks didn't fire in a worktree

- **Symptom:** none caught in the act; found while checking the claims of the standard's first page ("prove the rules
  load"). A command naming a credential file's path was blocked from the main checkout and ran unchecked from
  `.claude/worktrees/standard`. Sessions here work in worktrees by default, so for those sessions the credential guard
  (no `gam` from a shell, no Keychain read, no credential path) and the pre-commit checklist were off, with no sign.
- **Cause:** the local `.claude/settings.json` ran each hook by a relative path (`./.claude/hooks/…`). Hooks run in the
  session's working directory, and `.claude/hooks/` is gitignored, so a worktree has no copy: the command wasn't found
  and the tool call went on. The git `pre-commit` hook already found the main checkout through `git-common-dir`; the
  Claude hooks never had the same fix. The checklist hook, once found, also listed the main checkout's changes, not the
  worktree's.
- **Why not caught:** nothing checked that a hook fires, only that it exists; a missing hook fails open and says
  nothing. The cross-project lesson ("a relative hook path exits 127 after a `cd`") was written about another repo.
- **Fix:** each hook command is rooted at `"$CLAUDE_PROJECT_DIR"`; the checklist reads the changed files from the
  session's own checkout. Both are local files (`.claude/` wiring stays out of the repo, FRAMEWORK.md §2). Probed again
  from the worktree: blocked.
- **Prevention:** the session-start digest says every session whether any hook command is relative (a "HOOKS:" line),
  proved by running it once against the old wiring. The standard's rule 0 (STANDARD.md): a rule counts only once its
  enforcement is seen to fire, from where the work happens.
