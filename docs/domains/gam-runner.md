# Domain: running `gam`

**One line:** `GamEngine.GamRunner` runs the vendored `gam` as a child process with an explicit argv,
an allowlisted environment, a timeout, and capped output capture.

**Owns invariant(s):** #1 (argv-only), #9 (bounded output). **Enforcement home:**
`Packages/GamKit/Tests/GamEngineTests/RunnerTests.swift`.

## Files
- `Packages/GamKit/Sources/GamEngine/GamRunner.swift`:
  - **`posix_spawn`, not Foundation's `Process`** (PR #2 review). `Process` passes arguments through
    the file-system representation, which decomposes "é" into "e" + U+0301 (171 golden-argv elements
    changed under it) and aborts the app on a NUL. Here arguments and environment go out as their
    exact UTF-8 bytes; a NUL throws `invalidArgument`.
  - The child inherits only stdin (`/dev/null`), stdout and stderr (`POSIX_SPAWN_CLOEXEC_DEFAULT`), with
    signal dispositions and mask reset.
  - A thread drains each pipe with `read(2)` into a `CappedBuffer` (8 MiB per stream). A thread
    `waitpid`s: an exit gives its code, a signal its number.
  - A timeout sends SIGTERM, then SIGKILL after 5 s, and throws `timedOut`.
  - `children` tracks every live `gam` for `stopAll()` at quit.
- `GamEnvironment.swift` — `allowlist` (GamGUI's `ENV_ALLOWLIST`, exact names) and `mockOnly` (debug
  builds only); `GAMCFGDIR` and `GAM_NO_UPDATE_CHECK=1` are set by the runner, never inherited.
- `GamBinary.swift` — the bundled `gam7/gam`; `SWIFTGAMGUI_GAM_BINARY` honoured in debug builds only.
- `GamVersion.swift` — the pin, rewritten by `scripts/bump_gam.py`.

## Failure history inherited from GamGUI
- The whole parent environment once reached GAM (`DYLD_*`, `PYTHON*`, `_PYI_*`) — GamGUI failure-log
  2026-09-23. Here both the parent and `extra` are filtered.
- A binary override honoured by the shipped app would hand the credentials to any binary — same entry.
- 120 s killed a domain-wide sweep: callers pass `domainWideTimeout` (1 h) for `all users` calls.

## Builders
`GamCommands.swift` ports GamGUI's builders, each held to every case of `Tests/Fixtures/argv.json` by
`GoldenArgvTests`: 58 of 59. `todrive_args` is not ported, because Sheet export is dropped (CSV only).
- **Closed sets are types** (`GamChoices.swift`: `GroupRole`, `CalendarRole`, `ForwardAction`,
  `TransferPrivacy`, `MessageDetail`), so a builder can't be handed a value GAM doesn't know.
  `init(validating:)` ports GamGUI's validator for free-form text: Python's `strip().lower()` scalar
  by scalar (Python's whitespace set, not Foundation's), then a **byte** match.
- **The fixture's boundary cases** (section 4 of `gen_fixtures.py`) feed each validator case,
  Unicode whitespace, a combining accent, a Kelvin sign, a Cyrillic look-alike and unknowns: 142 of
  its 1,293 cases are refusals.
- An empty optional value is left out, as GamGUI's `if value:` does; Swift takes `""`, not `nil`.

## Authenticated runs
`AuthenticatedRunner` (phase 1, slice 2) runs `gam` as a domain: credentials from the Vault into a
per-call `EphemeralConfig`, then this runner, then the wipe. Details in [secrets.md](secrets.md).

## Not built yet
Write serialization (ChangeCore, phase 2) and general stderr/exit-code classification (port of
GamGUI's `core/gam/errors.py`); `check serviceaccount`'s own exits are handled in `AccessCheck`.
