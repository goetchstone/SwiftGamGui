# 2026-10-13 — GAM's command echo read as the failure

- **Symptom:** found while writing the mock's transfer failures from GAM's source (Off2a), not seen live.
  When GAM ends a command because an address isn't a user (`entityDoesNotExistExit`, gam/__init__.py:800-805
  at 7.48.22), it first echoes the command with the bad argument marked, then the error:
  `Command: gam create datatransfer >>>nobody@example.com<<< drive,calendar alice@example.com all`, a blank
  line, `ERROR: User: nobody@example.com, Does not exist`, exit 56. `GamError` read the echo as an unknown
  error line. Unknown outranks not-found, so the failure was "unknown" and its message was the command
  itself: the operator would have read "GAM failed (unknown, exit=56): Command: gam create datatransfer …"
  with the unknown remediation, instead of who doesn't exist.
- **Cause:** `GamError` is held to frozen GamGUI's reader (`_error_lines`), which skips progress and the
  service-account instructions but not the echo, which GAM writes before every usage error and
  does-not-exist exit.
- **Why not caught:** the fixture's usage errors carry the echo too, but there every line is unknown, so the
  echo changed nothing visible; no case paired the echo with a line of another kind. The mock's
  `does_not_exist` printed the entity line without the echo GAM writes before it.
- **Fix:** branch `fix/command-echo`. `GamError.isCommandEcho` skips a line starting "Command: ";
  `gen_fixtures.py`'s `gam_command_echo` widens GamGUI's `_INSTRUCTION_LINE` in memory to match, and
  `gam_errors.json` gains GAM's does-not-exist exit with its echo, keeping frozen GamGUI's reading as
  `gamgui`. `GamErrorTests` holds the deviations to progress and echo lines. `ExecutorTests`'s secret test
  now checks the echo never becomes the message, and still masks a password an error line repeats.
- **Prevention:** the deviation test names each kind of line GamGUI misreads. The echo's format was read
  from the 7.48.26 build (glclargs `CommandLineWithBadArgumentMarked`), not from GamGUI's test helper. The
  mock's own `does_not_exist` still prints the entity line alone (approximate; the transfer handler prints
  the echo).
