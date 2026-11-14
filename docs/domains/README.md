# Domain runbooks

Read the runbook for an area **before** working in it. Each carries the area's files, flow, failure
history and mock-lies traps. GamGUI's runbook of the same name (in its `docs/domains/`) is the history
the Swift design inherits; read it too when this one is still a stub.

| Area | Runbook | Status |
|---|---|---|
| Running `gam` (argv, environment, timeouts, output) | [gam-runner.md](gam-runner.md) | phase 1: Runner built |
| Credentials in the Keychain, materialization and wipe | [secrets.md](secrets.md) | phase 1: Vault + EphemeralConfig built |
| Importing credentials, verifying access, tenants | [setup-credentials.md](setup-credentials.md) | phase 1: built; first live run pending |
| The directory cache and Home | [directory-home.md](directory-home.md) | phase 1: built; first live load pending |
| The Groups screen: the group list, a group's members, adding and removing them | [groups.md](groups.md) | phase 2: reads built and read live; writes built, live check pending |
| Signatures: saved templates, render, set for one person, a group's members, an org unit or the company | [signatures.md](signatures.md) | phase 2: parity core, template store, screen and write built (one person live); a scope as a job (S2) built, live check pending |
| Calendars: rooms, a person's calendars, who has access, sharing with a person or a group, deleting a calendar or an event | [calendars.md](calendars.md) | phase 2: reads, sharing (C1a, C1b, C2a, C4), the calendar and event deletes (C3b, events) built; live checks pending |
| Google Classroom, read only: classes by name or teacher, who is in each | [classroom.md](classroom.md) | C1.1 to C1.3 built from GamGUI 3c8d909; offline only (no Education domain) |
| Offboarding: the leaver routine, its checks and plan, and (later) the account delete | [offboarding.md](offboarding.md) | phase 3: Off1 (the plan), templates and Off2 (the run) built; Off2's review, then L1 and L2 live; Off3 (delete) next |
| Incident (compromised account): the logs and their reader, the check, every lock step a switch, the picks, one preview | [compromised-account.md](compromised-account.md) | slices 1-4 merged; Chrome (5), the log reader and the Incident screen (6) built 2026-10-21; live L1 and L2 pending |
| Onboarding: one hire through one preview, the sign-in card, the wait for Google, the roles | [onboarding.md](onboarding.md) | O1 and O2 (the roles) built; W (welcome email) and live stages B and C next |
| Phishing: one email out of every mailbox, by its Message-ID (GAM's dry run, then a trash per mailbox) | [phishing.md](phishing.md) | built; live check not yet |
| Catalog and the Builder | [catalog-builder.md](catalog-builder.md) | built: reads and curated commands; sequences to come |
| ChangeCore: preview, guard, audit | [guard-audit.md](guard-audit.md) | phase 2: guard and audit log built |
| The jobs tray: every write run, from any screen, with Stop | [jobs.md](jobs.md) | phase 3: the tray built (2026-10-28); bulk runs on it later |
| The Audit and Reports screens: the log paged and exported, the directory reports, the usage report | [audit-reports.md](audit-reports.md) | built; the usage report's live read pending |

Template for a filled runbook: **One line** · **Owns invariant(s)** · **Enforcement home** · Files ·
How it works · Invariants & failure history · Gotchas / mock-lies traps · Testing / live-verification
status · To do common tasks here.

A runbook's live checks say how to check something. [live-verification.md](../live-verification.md) says what has run, and
it wins where they disagree.
