# 2026-11-27 — The one-call signature write was an argv GAM refuses

- **Symptom:** PR #218's review (before merge, never run live) read GAM 7.52.05's `openCSVFileReader`: the port of GamGUI's
  `set_signatures_csv` sent `csv - columndelimiter , quotechar " noescapechar true gam …`. GAM checks `columndelimiter`,
  `noescapechar`, `quotechar` in that order, each once, so `noescapechar` is left for the required `gam` and it exits 2
  before any row. Every fast run would read and keep everyone, then set nobody. GamGUI #193 has the same argv.
- **Cause:** the argv was ported as GamGUI wrote it, and GamGUI's mock loop (`mock_gam_loops.py`) matched that exact list,
  so the mock accepted the one shape it knew rather than parsing as GAM does. The grammar (`GamCommands.txt`'s `gam csv`
  line) lists the same order; nobody read it for order.
- **Why not caught:** the mock lies (CLAUDE.md): parity held to GamGUI's fixture, and the mock held to the argv, never to
  GAM's parse.
- **Fix:** GAM's order, as a listed deviation (`GoldenArgvTests.deviations`, invariant 11) until GamGUI's fixture changes;
  the mock parses `csv -` options in GAM's order and exits 2 on one left over (`MockSignatureTests`).
- **Prevention:** a mock loop parses options as GAM's function does, read to the end, never by matching one argv. GamGUI
  was told the same day.
