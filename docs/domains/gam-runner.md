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
  by scalar (Python's whitespace set, not Foundation's), then a **byte** match. An empty transfer
  privacy is `nil` (none), and `MessageDetail(label:)` falls back to headers, as GamGUI does: the
  rules live in the types, so production callers get what the parity test proves.
- **What the golden test also holds:** each builder's defaults (the fixture's `defaults`, called
  with only the required arguments), that the adapter reads every argument of a case, and that a
  refusal is the builder's own `Invalid`.
- **The fixture's boundary cases** (section 4 of `gen_fixtures.py`) feed each validator case,
  Unicode whitespace, a combining accent, a Kelvin sign, a Cyrillic look-alike and unknowns: 142 of
  its 1,293 cases are refusals.
- An empty optional value is left out, as GamGUI's `if value:` does; Swift takes `""`, not `nil`.

## Authenticated runs
`AuthenticatedRunner` (phase 1, slice 2) runs `gam` as a domain: credentials from the Vault into a
per-call `EphemeralConfig`, then this runner, then the wipe. Details in [secrets.md](secrets.md).

## Failed runs
`GamError.swift` ports GamGUI's `core/gam/errors.py`: a failed run's kind (which drives the remediation
and whether a bulk loop stops), its kinds per line, the message, and GAM's output and argv with echoed
secrets masked. `GamErrorTests` holds it to `Tests/Fixtures/gam_errors.json`: GamGUI's own
`GAMError.from_run` over 1,773 stderrs.
- **The fixture's sources:**
  - GAM's known lines in case, indent and counter variants, and every pair of them
  - progress chatter and GAM's instructions
  - timeouts and missing-scope lines
  - echoed passwords in GAM's usage-error shapes
  - Unicode and boundary edges
  - 400 seeded random stderrs
- **No regex engine.** Python's `re.IGNORECASE` matches only four non-ASCII characters to ASCII
  letters (dotted and dotless I, the long s, the Kelvin sign), so each line is folded scalar for scalar
  and GamGUI's ASCII patterns are matched as plain predicates. `\w`, `\s`, `\d` and `splitlines` are
  Python's (`PythonText`), held to Python's tables over every code point it assigns.
- Each pattern's place in the order comes from a GamGUI failure-log entry, cited beside it: per-line
  classification (2026-09-23), per-user `invalid_grant` before the expired sign-in (2026-09-23), the
  credentials file before not-found (2026-09-23), 403 before not-found and the entity counter
  (2026-09-24), the service-account instructions (2026-10-01).
- `stdout` is kept for a caller that reads it (`check serviceaccount`'s table) and is never in the
  message, the description or a dump.
- **Not wired in yet:** nothing throws it until the first screen runs GAM for data.

## Not built yet
Write serialization (ChangeCore, phase 2). `check serviceaccount`'s own exits are handled in
`AccessCheck`.
