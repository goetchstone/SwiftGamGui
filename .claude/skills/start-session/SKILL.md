---
name: start-session
description: Orient before feature or fix work in SwiftGamGui — check the tree and the GAM pin, get a green baseline, read the design doc's Status and the domain runbook for the area you'll touch. Use at the start of any task that will change code; skip for questions and trivial doc edits.
---

# Start-session — ORIENT

Scale it to the task: a question needs none of this; a change in `Packages/GamKit` needs all of it.

1. **Where is the tree?** `git log --oneline -8`, `git status`. The session-start hook's digest has the
   branch, last commit, dirty count and pin state.
2. **Is the toolchain sane?**
   - `swift test --package-path Packages/GamKit` — a green baseline before you change anything.
   - **GAM pin drift**: `Vendor/gam7/` is gitignored, so a pull can move `GamVersion.expected` without
     the binary. Re-vendor with `scripts/fetch_gam.sh` (fails closed on an unpinned asset).
   - `xcodebuild` failing to load a plug-in after an OS update means `sudo xcodebuild -runFirstLaunch`
     — the operator runs it (admin password).
3. **Read the plan's Status line** — `docs/plans/2026-10-08-native-gamgui.md`. Never re-apply an item
   it marks done.
4. **Load the domain, not the whole map** — the [docs/domains](../../../docs/domains/README.md) runbook
   for your area, and GamGUI's runbook of the same name while ours is a stub.
5. **Plan** the task as a short todo list. A real-tenant mutation needs the operator's per-action yes
   (`live-verify`).
