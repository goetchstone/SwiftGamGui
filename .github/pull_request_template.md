<!-- Title: a type, then the change in words, e.g. `feat: rename a user (roadmap 5.1)`. A `fix:` adds a
     docs/failure-log/ entry. The rest of the rules are in CONTRIBUTING.md. -->

## What and why

<!-- The change, and the problem it solves. Link the issue if there is one. -->

## How it was verified

- [ ] `swift test --package-path Packages/GamKit` passes
- [ ] The app builds (`xcodebuild -project SwiftGamGui.xcodeproj -scheme GamGUI build`)
- [ ] A screen changed: it works with VoiceOver and the keyboard, and has a screenshot spec CI renders

## If it builds or runs a `gam` command

- [ ] The argv is built in `GamCommands`; each operator-supplied value is exactly one element
- [ ] A builder GamGUI also has matches its argv (`Tests/Fixtures/argv.json`, regenerated, never hand-edited)
- [ ] A write goes through ChangeCore: preview → guard → audited run, and the confirm runs what the preview held
- [ ] Checked against the vendored grammar (`Vendor/gam7/GamCommands.txt`) and GAM's source; a mock change fails the way real GAM fails
- [ ] Live status stated below: a write that hasn't run against a real domain stays *Not run* in `docs/live-verification.md`

**Live status:** <!-- "Ran on a throwaway user in a real domain: …" or "Offline only." -->

## Nothing private

- [ ] No credentials, real domain names, real addresses, or captures from a real tenant (screenshots come from CI's demo domain)
