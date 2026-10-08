# Domain: secrets

**One line:** GAM's three credentials live in the data-protection Keychain, this device only, behind
user presence, and are materialized into a `0700`/`0600` dir for one `gam` call (invariant 4).

## Spike results (2026-10-08, macOS 27.0.1, Xcode 27.0)
- **Ad-hoc signing ("Sign to Run Locally") can't use the data-protection Keychain**: `SecItemAdd`,
  with or without a user-presence ACL, and `SecItemDelete` all return `errSecMissingEntitlement`
  (-34018). Nothing is written and no prompt appears. Source builds need a signing team (a free
  Personal Team is the next check; this Mac has no signing identity yet, so an Apple ID goes into
  Xcode → Settings → Accounts first, then `Config/Local.xcconfig` sets the team).
- **Reading a legacy login-Keychain item another program created works**: a throwaway
  `swiftgamgui-spike-legacy` item made by `security add-generic-password` was read by a separately
  signed binary, status 0, after macOS showed an Allow dialog the operator accepted.
  This is the path for copying GamGUI's `gamgui:<domain>` items once at setup.

## Not built yet
`Vault` itself (phase 1 slice 2), after the Personal Team spike.
