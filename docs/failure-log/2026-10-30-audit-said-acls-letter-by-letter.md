# 2026-10-30 — Audit said "Remove all calendar a c ls"

- **Symptom** — After a live offboarding, Audit named its calendar sweep "Remove all calendar a c ls", and "Imap off" and
  "Pop off" beside it. VoiceOver reads a word as it's written, so "a c ls" came out letter by letter. The same name is the
  jobs tray's step line and a one-kind preview's title. The run itself was right: the audit record holds the action as
  written (`removeAllCalendarACLs`).
- **Cause** — `WriteAction.displayName` started a new lowercase word at every capital, so the run `ACLs` split into `a`, `c`,
  `ls`; `imapOff` and `popOff` write their acronyms small.
- **Why not caught** — No test read the names: tests held one (`Suspend user`), and no CI picture shows an ACL write.
- **Fix** — A run of capitals stays one word as written, and `imap` and `pop` are said as acronyms; a test reads every
  `WriteAction` (`AuditScreenTests.everyActionIsSaidInWords`). In the PR that adds this entry.
- **Prevention** — That test: a new action whose name says a letter alone, or a capital mid-name that isn't an acronym,
  fails it.
