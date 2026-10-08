# Domain: setup and credentials import

**One line:** getting GAM's three credentials into the Vault, from a GAM config folder or from the
Python GamGUI's Keychain items, and checking that delegation actually works ("Check access").

**Owns invariant(s):** #5 (credential files read by descriptor). Touches #4 (secrets) and #11
(`check_svcacct` argv parity). **Enforcement home:** `Tests/VaultTests/ImportTests.swift`,
`Tests/GamEngineTests/AccessCheckTests.swift` and `GoldenArgvTests.swift`.

## Files (phase 1, slice 2b-core)
- `Vault/CredentialFolder.swift`: reads `oauth2service.json`, `oauth2.txt` (required) and
  `client_secrets.json` (optional) from a picked folder, returned as `Secret`s.
  - The folder is opened once; each file is opened relative to it with `O_NOFOLLOW | O_NONBLOCK`.
  - Each must be a regular file of at most 64 KiB, read with `read(2)` (a failed read is an error, not
    a crash), containing a UTF-8 JSON object.
  - `oauth2service.json` must name its `client_email`.
  - A problem with the optional file only leaves it out, as in GamGUI.
  - The operator's files are never modified or removed.
- `Vault/GamGUIKeychain.swift`: reads GamGUI's legacy-keychain items for the one-time copy.
  - Index: service `gamgui`, account `_domains` (a JSON list of spellings).
  - Items: service `gamgui:<spelling>`, accounts `oauth2service` / `oauth2` / `client_secrets`.
  - Case twins (`Example.com`, `example.com`) are listed with their own spellings and share one
    canonical domain.
  - Read only, never written or deleted. macOS asks the operator to Allow each read (seen live in the
    phase 1 spike).
- `Vault/CredentialFacts.swift`: the non-secret facts Setup shows — the admin's email (from
  `oauth2.txt`'s `decoded_id_token`/`id_token`, never decoding a JWT), the token's granted scopes, and
  the service account's client ID. Also `VaultError.guidance`: an action for the operator instead of a
  status code ("Your Mac is locked. Unlock it and try again.").
- `GamEngine/GamCommands.swift`: `version`, `checkServiceAccount` — the first ported builders,
  byte-identical to GamGUI's on every fixture case.
- `GamEngine/AccessCheck.swift`:
  - `DelegationScopes` — GamGUI's `DWD_SCOPES`, plus the pre-filled Admin-console link.
  - `GamExitCode` — 10 and 16, held to the build's table.
  - `AccessCheck.interpret` — GamGUI's `_check_result` / `_parse_check` / `_extract_auth_url`.
  - `AuthenticatedRunner.checkAccess(admin:as:)`.

## Failure history this area inherits (GamGUI failure log), each now a Swift test
- 2026-09-23, a FIFO named like a credential hung the import:
  `aFIFONamedLikeACredentialIsRefusedWithoutBlocking`.
- 2026-09-25, verify checked GAM's default scopes, not ours: argv parity, and
  `theScopesAreGamGUIsDelegationScopes`.
- 2026-09-25, verify hid which scopes failed: `missingDelegationNamesTheCountAndCarriesTheDirectLink`.
- 2026-09-25, verify blamed delegation for a rejected key: `aRejectedKeyIsNamedNotBlamedOnDelegation`.
- 2026-10-01, the exit codes were guessed: `theExitCodesAreTheBuilds`.
- 2026-10-02, a capitalized domain became a second tenant: `Domain` canonicalization, and
  `gamguisDomainsAreReadWithTheirSpellingsAndCaseTwinsShareOneDomain`.

## PR #2 review (2026-10-08)
One adversarial reviewer proved five issues, all fixed with tests:
- **argv bytes** differed from GamGUI's under Foundation's `Process`; the golden test compared Strings,
  which Swift compares canonically, so it couldn't see it — now `posix_spawn`, and the test compares
  bytes
- Check access showed GAM's instructions instead of its `ERROR:` line
- a failed read crashed the import
- imported credentials were plain `Data`
- smaller drifts from GamGUI: Unicode word boundaries, control characters in the email, an index with
  one odd entry, the optional file failing the import, UTF-16 accepted

## Mock-lies traps
- The mock answers `check serviceaccount` the way the vendored build prints it (PASS/FAIL table,
  exits 10 and 16, the links), for three tenant types: authorized, `*partialdwd*` and `*badkey*`.
  GAM's real output for a failing scope and a rejected key has **not** been captured live yet; the
  mock's shapes are read from the build.

## Not built yet (slice 2b-ui)
The Setup screen: the pick-a-folder or copy-from-GamGUI choice, the domain field (pre-filled from the
admin email), Check access with the delegation link, the tenant list, switching (a generation bump
that drops previews and caches, GamGUI failure-log 2026-09-25) and removal.
