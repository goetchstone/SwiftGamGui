# 2026-11-18 — A debug switch reached the real Vault

- **Symptom:** none observed; found by reading (the on-device model and security review, PR #168, finding 1). In a Debug
  build, the build the operator runs every day, `SWIFTGAMGUI_GAM_BINARY` set without `SWIFTGAMGUI_DEMO` made the
  real-Keychain path run whatever file it named. A leftover scheme variable, or a same-user `launchctl setenv`, would
  have had both credentials materialised for a program of its choosing on the next read.
- **Cause:** `GamBinary.locate` honoured the override under `#if DEBUG`, a guard carried over from GamGUI that assumed
  debug builds are for development. Demo and the spikes had since moved to `AppServices.mockGam`, which insists on the
  mock script; `AppServices.make`, the real path, still asked `locate`.
- **Why not caught:** no test said which code may read the override, and the debug/release split read as the defence
  while the daily app was itself a Debug build.
- **Fix:** `locate` no longer takes or reads an environment; it returns the bundled binary or nothing (PR for branch
  `fix/gam-override-mock-only`).
- **Prevention:** `GamBinaryTests` sets the variable in the process and expects the bundled binary; `WriteRouteTests.
  onlyTheMockCheckReadsTheBinaryOverride` allows one reader, inside the debug-only `mockGam`, runs the mock only from the
  demo and the spike, and holds `make` to `GamBinary.locate()`. Both fail against the old code. The wider lesson: "debug only" isn't a boundary while the operator runs Debug daily (S4 in PR #168's plan).
