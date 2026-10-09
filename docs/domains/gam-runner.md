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
- **Each builder returns a `GamRead` or a `GamWrite`** (`GamCommand.swift`; design:
  `docs/plans/2026-10-09-write-path-options.md`, option A). 24 reads, 34 writes. Only GamKit can make
  one (the inits are GamEngine-internal), and a `GamWrite` carries its `WriteAction`, fixed by the
  builder, which is what a per-action rule (preview, confirm, "Just do it") will key on. Suspend and
  unsuspend are one builder but two actions; `CommandKindTests` holds every builder's action exactly.
  - `CommandKindTests` holds every `GamRead` to GamGUI's catalog verb rule (the first known verb in
    the first six tokens is a read verb), called with placeholder values so an operator value can't
    pass for a verb. `check serviceaccount` is the one reviewed exception: the rule has no verb for it.
  - A new builder picks its side; a new write adds its `WriteAction` case. `CommandKindTests` counts
    the builders in the source, so one the golden test doesn't cover fails.
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

## Fuzzing
`Fuzz/GamFuzz.swift` is a libFuzzer target over GamEngine's platform-free files (the output parsers,
`GamError` and its masking, the builders' argv-only rule, the closed-set validators), built by
`scripts/fuzz.sh` on Linux and run by CI's `fuzz` job in the digest-pinned Swift image. On a Mac, run it
through Docker (the command is in the script). `Fuzz/gam.dict` gives it GAM's keywords: without it,
300,000 runs never produced the word `signature`, and a redaction bug that skipped it went unfound.
- A new platform-free file the parsers need goes on the script's source list; one that imports Vault
  or Darwin can't.

## Authenticated runs
`AuthenticatedRunner` (phase 1, slice 2) runs `gam` as a domain: credentials from the Vault into a
per-call `EphemeralConfig`, then this runner, then the wipe. Details in [secrets.md](secrets.md).
- **Its public `run` takes only a `GamRead`.** Beneath it, `GamRunner.runRaw`, `EphemeralConfig.materialize`,
  `Vault.credentials(for:)`, `Vault.refresh`, `GamGUIKeychain.credentials(for:)` and `legacyRead`, the
  `SecretStore` protocol, `KeychainStore`'s methods and `Secret.bytes` are `package` (a `Secret` the app
  holds is opaque), so the app target can read the tenant but has
  no route to a write or to a secret: it picks a store and hands it to `Vault`. Writes arrive with ChangeCore's
  executor and ticket (slice 3).
- A credentialed read takes only the mock's variables as extra environment (debug builds pass them).
- `WriteRouteTests` scans the source for what access levels can't stop: only `GamRunner.swift` starts
  a process (any use of the `Process` type counts), only `GamCommands.swift` makes a command, only the
  two runners call `runRaw` or make a config directory (without one GAM falls back to `~/.gam`), the
  app never reinterprets memory (`unsafeBitCast` would forge a `GamRead`), and
  the app never imports GamKit `@testable`.
- The app's vault spike reads the Keychain through `Vault.spikeRead`/`spikeOAuth2`, compiled only in
  debug builds; they say which credentials were found, never their values.

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
- **Fixed in PR #5's review:**
  - **Unicode version.** Swift has Unicode 17 and GamGUI's Python has 16, so a character added in 17
    is unassigned to Python. Read as a letter, it let an echoed password past the scrub.
    `PythonText.unicodeVersion` gates `\w` and `\d`, and the test now covers every code point.
  - **Speed.**
    - Masking was quadratic: 26 s for 4.5 MB, now 1.4 s.
    - The message is built once.
    - The credential-file rule is linear.
    - A 15 MB sweep classifies in 3.2 s (release); GAM's output is capped at 8 MiB.
    - Callers classify off the main actor.
  - **Coverage.** Fourteen pattern branches were reached only through lines an earlier rule caught;
    each now has a line of its own. Twenty-seven mutants all fail the suite.
- **Not wired in yet:** nothing throws it until the first screen runs GAM for data.

## Reading output
`GamOutput.swift` ports GamGUI's `core/gam/parser.py`: GAM's stdout as records, whether it printed one
JSON value, newline-delimited JSON, a `formatjson` CSV (a `JSON` column with key columns beside it)
or plain CSV. `GamOutputTests` holds it to `Tests/Fixtures/gam_output.json`: GamGUI's `parse_records`
over 600 inputs.
- **The fixture's sources:**
  - the strict mock's output for every read the app makes
  - GamGUI's property-test strategies (JSON shapes, plain and `formatjson` CSV, noise), drawn
    deterministically
  - the inputs its failure log names (a cell past the csv module's limit, a bare CR, deep nesting,
    raw U+2028 in NDJSON, an empty header)
  - JSON's and CSV's own edges
- **`JSONValue`** reads as `json.loads`:
  - `NaN` and `Infinity` are accepted;
  - integers keep their digits;
  - the last duplicate key wins;
  - raw control characters are refused.

  JSON `null` is "not JSON" to GamGUI's `_try_json`, and so here. Integers past 4,300 digits are
  refused (Python's `int` limit), floats aren't.
  - **Objects are `JSONObject`:** keys distinct by exact text, as a Python dict's are. A Swift
    `Dictionary` merged "é" with "e" + U+0301 and dropped one (PR #7's review).
  - **Two deliberate differences:**
    - nesting past 128 is refused (Python's limit is its C stack; a debug build overflowed a 512 KiB
      thread at about 470);
    - a lone surrogate escape becomes U+FFFD.
- **`CSVReader`** is `_csv.c`'s state machine in the default dialect over `newline=""` lines, with
  `DictReader`'s `restval` and its handling of duplicated headers.
  - Each distinct column holds its last position's cell. That is computed once per column, not per
    header cell per row: an 80 KB CSV with a wide header of repeated names took 13 GB (now 43 MB).

## Users, groups, members
`Directory.swift` ports GamGUI's `GAMUser`, `GAMGroup` and `GroupMember` (`core/gam/models.py`). They
read GAM's varying keys (`primaryEmail` / `email` / `User`, `name.givenName` / `First Name`), flags given
as booleans, words or numbers, counts given as numbers or text (Python's `int()`: any script's digits,
underscores, a float truncated), and a Directory list's primary entry. `DirectoryTests` holds them to
`Tests/Fixtures/gam_models.json`: GamGUI's models over the mock's records and 250 seeded variants,
as JSON text read through `JSONValue`.
- **Text fields:** a scalar reads as Python's `str()` of it (`1.50` is "1.5", `1E2` "100.0", `null`
  "None"); a list or object where text belongs reads as empty.
- **`int()`:** strips `isspace()` characters except U+001C to U+001F.
- **Case:** `PythonText.upper` and `lower` keep Python's Unicode 16 mappings (Swift's 17 gives U+A7D3 an
  uppercase), checked over every code point.
- **Not `Equatable`, no record in a dump:** the models skip comparing or printing the whole record.
- **`id`:** a record without an address gets a one-off one.

The fixture generator keeps its Hypothesis draws stable in two ways:
- **An explicit `@seed`.** `derandomize` seeds from the function's digest, which moves with any edit to
  the generator.
- **No local constants.** Hypothesis also draws string constants it finds in local source, the
  generator's own included, so adding an unrelated string literal changed the cases.

## Not built yet
Write serialization (ChangeCore, phase 2). `check serviceaccount`'s own exits are handled in
`AccessCheck`.
