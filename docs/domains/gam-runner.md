# Domain: running `gam`

**One line:** `GamEngine.GamRunner` runs the vendored `gam` as a child process with an explicit argv,
an allowlisted environment, a timeout, and capped output capture.

**Owns invariant(s):** #1 (argv-only), #9 (bounded output). **Enforcement home:**
`Packages/GamKit/Tests/GamEngineTests/RunnerTests.swift`.

## Files
- `Packages/GamKit/Sources/GamEngine/GamRunner.swift` — `Process` + `Pipe`s; a dedicated thread drains
  each pipe into a `CappedBuffer` (8 MiB per stream); `ExitSignal` hands the exit status to one waiter;
  a timeout sends SIGTERM, then SIGKILL after 5 s, and throws `timedOut`.
- `GamEnvironment.swift` — `allowlist` (GamGUI's `ENV_ALLOWLIST`, exact names) and `mockOnly` (debug
  builds only); `GAMCFGDIR` and `GAM_NO_UPDATE_CHECK=1` are set by the runner, never inherited.
- `GamBinary.swift` — the bundled `gam7/gam`; `SWIFTGAMGUI_GAM_BINARY` honoured in debug builds only.
- `GamVersion.swift` — the pin, rewritten by `scripts/bump_gam.py`.

## Failure history inherited from GamGUI
- The whole parent environment once reached GAM (`DYLD_*`, `PYTHON*`, `_PYI_*`) — GamGUI failure-log
  2026-09-23. Here both the parent and `extra` are filtered.
- A binary override honoured by the shipped app would hand the credentials to any binary — same entry.
- 120 s killed a domain-wide sweep: callers pass `domainWideTimeout` (1 h) for `all users` calls.

## Not built yet
Credential materialization (`0700` dir, `0600` files, wipe, launch sweep), write serialization and
exit-code classification against `Tests/Fixtures/exit_codes.json` — phase 1 slice 2.
