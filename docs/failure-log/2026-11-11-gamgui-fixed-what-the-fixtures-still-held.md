# 2026-11-11 — GamGUI fixed readers that the parity fixtures still held at its old commit

- **Symptom:** nothing seen live. Regenerating the parity fixtures from GamGUI `487be35` (they were pinned at `2f35285`, before its
  back-port) failed three Swift readers. A usage error's message was GAM's `Help: Syntax in file …` line, so the operator was told
  where GAM's grammar file is instead of what was wrong. And the signature, auto-reply and usage-report readers split GAM's text on
  every Unicode line break, so a value holding U+2028, U+2029, U+0085, a form feed or a file separator ended there: a signature cut
  short, an auto-reply subject read with half its message, a usage row split in two.
- **Cause:** both were GamGUI's readings when the fixtures were cut, and GamGUI fixed both during its back-port: the help lines in its
  failure log of 2026-10-31 (`_FRAMING_LINE`), the splits in its #83 (`split("\n")`, not `splitlines()`). Swift took the command echo
  from the same incident (2026-10-13) but GAM's two help lines weren't in its mock, so nothing showed them.
- **Why not caught:** the fixtures named a GamGUI commit three weeks and 200 commits old, and the gaps plan had "refresh the fixtures"
  under "Small, any time". The strict mock printed no help lines after a usage error, so it was kinder than GAM, and no mock output or
  test value held a line separator inside a value.
- **Fix:** PR for this branch. `GamError.isFraming` skips GAM's echo and both help lines (words read from the 7.51.00 build's
  `gamlib.glmsgs`; "Command can not be nested." is still an error). `PythonText.splitLF` splits on LF alone, for the three readers.
  The mock's `usage_error` prints GAM's help lines, as `usageErrorExit` does. The fixtures are GamGUI's own reading again:
  `gen_fixtures.py` drops its three in-memory patches of GamGUI's readers and refuses a pin that still misreads GAM.
- **Prevention:** `gam_errors.json` and the readers' fixtures now hold GamGUI's fixes, and `GamErrorTests.gamsFramingIsNeverTheFailure`
  holds the build's words. The 31 builders this app wrote first are held to GamGUI's argv too (`GoldenArgvTests`). Regenerating at
  GamGUI's merge is now part of each two-app item (finish-the-roadmap, "How a two-app item runs"), so the pin stops lagging. **Not
  proven live:** a usage error and a value holding a line separator are fixture and mock readings.
