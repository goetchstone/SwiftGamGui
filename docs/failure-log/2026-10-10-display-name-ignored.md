# 2026-10-10 — The app's new name didn't show: macOS read it as a rename

- **Symptom:** after PR #36 renamed the app to "GAM GUI", the operator's rebuilt app still showed
  "GamGUI" in the Dock, and Spotlight (which Siri searches) still listed it as GamGUI.
- **Cause:** PR #36 set the Info.plist's own `CFBundleDisplayName` to "GAM GUI" as well as the localized
  one in `App/en.lproj/InfoPlist.strings`. macOS uses an app's localized name only while its unlocalized
  display name equals the bundle's file name; anything else reads as the user renaming the app, and the
  file name ("GamGUI") is shown.
- **Why not caught:** `check_app.sh` checked that both names said "GAM GUI", which is the broken state;
  nothing asked macOS what it would show. A debug build can't be launched here to look at the Dock.
- **Fix:** PR #37: the build setting's display name is the bundle's name again (GamGUI), the localized
  name stays "GAM GUI". Checked by asking LaunchServices (`FileManager.displayName(atPath:)`,
  `localizedName`) for both builds: #36's shows GamGUI, #37's shows GAM GUI.
- **Prevention:** `check_app.sh` now fails unless the Info.plist display name is the bundle's file name,
  and still checks the localized name. The runbook's Siri bullet states the rule.
