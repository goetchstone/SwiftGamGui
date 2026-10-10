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
| The Groups screen: the group list and a group's members | [groups.md](groups.md) | phase 2: reads built; first live read pending |
| Catalog and the Builder | [catalog-builder.md](catalog-builder.md) | stub (phase 4) |
| ChangeCore: preview, guard, audit | [guard-audit.md](guard-audit.md) | phase 2: guard and audit log built |

Template for a filled runbook: **One line** · **Owns invariant(s)** · **Enforcement home** · Files ·
How it works · Invariants & failure history · Gotchas / mock-lies traps · Testing / live-verification
status · To do common tasks here.
