---
name: add-builder-command
description: Add a curated GAM operation to SwiftGamGui (a typed builder that runs through ChangeCore, and a Builder catalog entry). Use when asked to add a command, expose a GAM operation, or extend the curated catalog.
---

# Add a curated command

1. **Verify syntax** in the pinned grammar — never guess: `grep -niE "<words>" Vendor/gam7/GamCommands.txt`.
   Note the entity prefix and required/optional arguments; mind `remove` vs `delete`.
2. **If GamGUI has the builder**, the Swift one must emit the identical argv for every case in
   `Tests/Fixtures/argv.json`. If it's new (GamGUI is frozen), add Swift tests with exact argv and a
   strict `mock_gam.sh` handler that accepts only the grammar shape and fails like GAM.
3. **Every operator value is one argv element (#1)**. A closed set is a Swift enum in
   `GamChoices.swift`, so the builder can't be handed a value GAM doesn't know; free-form text reaches
   it through `init(validating:)`, which throws as GamGUI's `ValueError` builders do and matches
   bytes, not `String ==`.
4. **Pick the builder's type.** A read returns `GamRead`, and `CommandKindTests` must agree it is
   read-only by GamGUI's verb rule. A write returns `GamWrite` with its own `WriteAction` case, and runs
   only through ChangeCore (#2) with its authoritative risk level. Never make a write runnable by
   promotion (#3).
5. **Catalog entry** with typed slots; `swift test` green; record the new command as **not yet** in the
   README live table until `live-verify` proves it.
