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
| Signatures: saved templates, render, set for one person | [signatures.md](signatures.md) | phase 2: parity core, template store, screen and write built; live check next |
| Calendars: rooms, a person's calendars, who has access, sharing with one person | [calendars.md](calendars.md) | phase 2: reads and sharing with one person built (C1a, C1b, C2a); live checks (C1c, C2b) pending |
| Offboarding: the leaver routine, its checks and plan, and (later) the account delete | [offboarding.md](offboarding.md) | phase 3: Off1, the read-only plan, built; L1 live check next, then Off2 (run) and Off3 (delete) |
| Catalog and the Builder | [catalog-builder.md](catalog-builder.md) | stub (phase 4) |
| ChangeCore: preview, guard, audit | [guard-audit.md](guard-audit.md) | phase 2: guard and audit log built |
| The Audit and Reports screens: the log paged and exported, the directory reports, the usage report | [audit-reports.md](audit-reports.md) | built; the usage report's live read pending |

Template for a filled runbook: **One line** · **Owns invariant(s)** · **Enforcement home** · Files ·
How it works · Invariants & failure history · Gotchas / mock-lies traps · Testing / live-verification
status · To do common tasks here.
