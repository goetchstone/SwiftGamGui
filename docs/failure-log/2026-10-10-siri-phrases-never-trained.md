# 2026-10-10 — Siri never matched the title intent's phrases by voice

- **Symptom:** "Open GAM GUI" worked by voice, but "Change a title in GAM GUI" got "couldn't find an app
  to do that"; Xcode's App Shortcuts Preview said "No flexible match". The same action ran fine from
  Shortcuts (PR #32's live check).
- **Cause:** the project has no App Shortcuts string catalog. Without one, Xcode runs
  `appintentsmetadataprocessor --no-app-shortcuts-localization` and ships no `AppShortcuts.strings`,
  so Siri has nothing to train its phrase matching on: the phrases exist in the metadata
  (`extract.actionsdata`) but are never matched by voice. Xcode's app template adds the catalog; this
  project was assembled by hand. The renames (#34, #36, #37) chased the app's name instead.
- **Why not caught:** `check_app.sh` checked the intent's metadata (foreground mode, every phrase names
  the app), which was right; nothing checked that the phrases were localized for matching, and voice
  can't be tested on CI.
- **Fix:** PR #38: `App/AppShortcuts.xcstrings` holds the three phrases; the build ships
  `en.lproj/AppShortcuts.strings` and the metadata processor no longer runs without phrase
  localization. The intent's description and reply say GAM GUI.
- **Prevention:** `check_app.sh` fails without the catalog in the built app or without the title
  phrase in it. `SiriIntents.swift` says to change the phrases in both places. The lesson for every
  future intent: a phrase needs the catalog entry, and App Shortcuts Preview is the check before a voice
  test.
