# Domain: secrets

**One line:** GAM's three credentials live in the data-protection Keychain, this device only, behind
user presence, and are materialized into a `0700`/`0600` dir for one `gam` call (invariant 4).

## Spike results (2026-10-08, macOS 27.0.1, Xcode 27.0)
- **Ad-hoc signing ("Sign to Run Locally") can't use the data-protection Keychain**: `SecItemAdd`,
  with or without a user-presence ACL, and `SecItemDelete` all return `errSecMissingEntitlement`
  (-34018). Nothing is written and no prompt appears.
- **A team signature alone isn't enough** (Personal Team, Apple Development certificate, still -34018):
  with no capability claimed, Xcode embeds no provisioning profile, so the app has no
  `application-identifier`. Claiming a keychain access group (`Config/GamGUI-Team.entitlements`,
  `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`) makes Xcode provision it — after **one build
  inside Xcode** (`xcodebuild -allowProvisioningUpdates` reported "No Accounts").
- **With the Personal Team, provisioned: everything works.** Add (no ACL and user presence), read
  after authenticating (macOS asked for **Touch ID**), a second read in the same `LAContext` reuse
  window, delete: all `errSecSuccess`.
- **Reading a legacy login-Keychain item another program created works**: a throwaway
  `swiftgamgui-spike-legacy` item made by `security add-generic-password` was read by a separately
  signed binary, status 0, after macOS showed an Allow dialog the operator accepted.
  This is the path for copying GamGUI's `gamgui:<domain>` items once at setup.

## Files (phase 1, slice 2)
- `Packages/GamKit/Sources/Vault/Credential.swift`: `Credential` (the three names, their GAM file
  names, `required`, `removalOrder` with the impersonate-anyone key first); `Domain`, the one canonical
  spelling, lowercased and validated; and `Secret`, bytes that never print, log or `dump`.
- `SecretStore.swift`: the protocol. `read` returns nil **only** for "no such item", and every other
  `OSStatus` throws `VaultError.keychain`. Also `MemoryStore` for tests and the demo tenant, which
  queues a failure with a real status.
- `KeychainStore.swift`: data-protection Keychain, service `swiftgamgui`, account `<domain>/<name>`,
  `WhenUnlockedThisDeviceOnly`, a user-presence ACL on every item. One shared `LAContext`, used under
  a lock, until `endSession()`. `domains()` reads attributes only.
- `Vault.swift`: an actor over a store. **No in-memory copy of any secret**, unlike GamGUI's 300 s
  cache: the store's authentication session gives one prompt per burst. Store calls run on a GCD
  thread, because a Touch ID prompt blocks. `remove` stops at the first refusal.
- `Packages/GamKit/Sources/GamEngine/EphemeralConfig.swift`: the per-call `GAMCFGDIR`. Port of
  GamGUI's `ephemeral.py`:
  - `0700` directory, `0600` files created `O_EXCL | O_NOFOLLOW`, an owner-PID marker
  - registered as live before anything is written
  - `wipe()` zeroes regular files (64 KiB chunks, capped at 1 MiB), removes subfolders GAM creates
    (`gamcache/`, `Downloads/`) to a bounded depth, and unlinks anything else without opening it
  - `wipeAllLive()` runs at quit (`App/AppDelegate.swift`)
  - `sweepStale(in:)` runs at launch: a dead owner goes at once, a live one is trusted for at most a
    day, and an unmarked folder goes after 10 minutes
- `RuntimeDirectory`: `~/Library/Application Support/SwiftGamGui/run` (never GamGUI's folder). It
  must be a real `0700` directory owned by this user, or nothing is materialized.
- `AuthenticatedRunner.swift`: Vault, then `EphemeralConfig`, then `GamRunner`, then write back a
  refreshed `oauth2.txt`, then wipe — on every path, including failure, timeout and cancellation.

## Gotchas
- **A locked Mac refuses every Keychain write and read** of these `WhenUnlocked` items with
  `errSecInteractionNotAllowed` (-25308). Even an item with no access control can't be added. Seen
  live 2026-10-08 when the screen locked mid-spike. Setup must say "Unlock your Mac", not show the
  status. `errSecAuthFailed` (-25293) is a failed or abandoned authentication.
- `--spike vault` (debug builds) runs this whole path on throwaway items (service
  `swiftgamgui-spike`, domain `spike.example.com`) against the real Keychain. It needs an unlocked Mac
  and one Touch ID.

## Tests
- `Tests/VaultTests`: the canonical domain, a secret that never prints, a missing required credential
  named, a refused read (`errSecUserCanceled`) that is an error and not absence, removal order and
  stopping at a refusal, lock ending the session.
- `Tests/GamEngineTests/EphemeralConfigTests` (GamGUI's `test_ephemeral.py` cases):
  - modes and the owner-PID marker; path-like file names refused; an unsafe runtime directory refused
    (a symlink, or group-readable)
  - nested GAM subfolders wiped; a symlink never followed (an outside file left intact); a FIFO that
    can't hang the wipe; a 256 MiB sparse file gone in under 5 s
  - the termination backstop
  - the sweep: a dead owner removed; a living one and an in-use folder kept; one older than a day
    removed; unmarked by age; a PID of 0 not trusted; a symlinked `gamcfg-*` never followed
- `AuthenticatedRunnerTests` (mock `gam`): credentials reach GAM and are wiped; a refreshed token is
  written back; missing credentials stop the call before anything is written; failed and timed-out
  calls are still wiped.
