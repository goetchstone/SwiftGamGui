# Domain: guard-audit (ChangeCore)

**One line:** every write goes Preview, then Guard, then Confirm, then an audited run. ChangeCore is
the only path to a write (design doc §6).

**Owns invariants:** #2 (a write runs only through ChangeCore) and the guard's confirmation rules.

**Enforcement home:** `Tests/ChangeCoreTests`. Later, a source-scan test proves no other path starts
a write.

## Built: the guard (phase 2, slice 1)
`Packages/GamKit/Sources/ChangeCore/Guard.swift` ports GamGUI's `core/guard.py`.
- **`evaluate`:** what a set of `Change`s needs.
  - destructive: a Confirm click;
  - bulk (10 or more) at any write risk: a Confirm click;
  - destructive and bulk: the word `confirm` typed;
  - more than a caller's `typedCountAbove` (25, opted in): the count typed;
  - an account delete (argv exactly `gam delete user <address>`): its address typed.
  - Over 200 targets it warns.
- **`refusal`:** why an `OperatorConfirmation` may not run them, in GamGUI's words, or nil.
  - Typed text is trimmed and lowercased as GamGUI's `.strip().lower()` (`PythonText`).
  - The typed count is compared as text, so `026` is not `26`.
- **`aliasDeletes`:** refuses deleting an address that resolves to another account's primary, since GAM
  would delete that account (GamGUI failure-log 2026-09-24).
- **Parity:** `GuardTests` holds all three to `Tests/Fixtures/guard.json`. That is GamGUI's own functions
  over 700 seeded change sets and confirmations (counts either side of 10, 25 and 200; every risk;
  deletes in and near GAM's shape; typed text with case, spaces and look-alikes) and 80 alias
  resolutions.
  - A third of the sets share one risk: with mixed risks, ten changes almost always included a
    destructive one, and a mutant that dropped the rule for an all-LOW bulk change survived.

## Built: the audit log (phase 2, slice 2)
`Packages/GamKit/Sources/ChangeCore/AuditLog.swift` ports GamGUI's `core/audit.py`, in its format.
- **Format:** one JSON object per line with `ts`, `connector`, `action`, `target`, the redacted `argv`,
  `exit_code`, `ok`, `actor` and an optional `extra`. It is written as Python's `json.dumps` writes it,
  so the Audit screen reads both apps' logs alike.
- **Redaction**, two layers:
  - the value after a sensitive keyword (`ArgvRedaction`);
  - then every occurrence of each secret the caller passes, anywhere in the record, longest first.

  The second exists because the first can be shifted: a hire surnamed "Password" (GamGUI failure-log
  2026-09-23).
- **The file:** 0600, never written through a link (`O_NOFOLLOW`). It rolls past 16 MiB, shifting
  generations oldest first and keeping ten.
- **Reading:** newest-first across generations, every one opened before any is read (a roll
  mid-read can't make a reader repeat or skip one). Blank and malformed lines are skipped.
- **Parity:** `AuditLogTests` holds the written lines byte for byte to `Tests/Fixtures/audit.json`,
  GamGUI's own `record` at fixed times (control characters, raw U+2028, overlapping secrets,
  microseconds left out when zero), and the reader to its `iter_records`. Eight mutants fail.

## Failure history (GamGUI) the guard carries
- Five routes ran a write on a bare POST because only their pages asked (2026-09-23): the executor,
  not a screen, calls `refusal`.
- The Builder deleted an account on one Confirm click (2026-09-23): the typed-address rule applies to
  every change set whose argv deletes an account.
- An alias delete removed the account it belonged to (2026-09-24): `aliasDeletes`.

## Built: typed commands and closed routes (before slice 3)
Builders return `GamRead` or `GamWrite`; the app can run only reads; the source scan
(`WriteRouteTests`) holds the routes the compiler can't. See [gam-runner.md](gam-runner.md).

## Built: the executor (phase 2, slice 3)
`Packages/GamKit/Sources/ChangeCore/ChangeCore.swift`, held to `Tests/ChangeCoreTests/ExecutorTests` (15
cases against the strict mock; each check proven to bite by removing it).
- **`WriteStep`**: one `GamWrite`, its target and summary, `requires` (earlier steps it needs), `about`
  (audit extra), typed `secrets`. Its risk never falls below `WriteAction.minimumRisk`, GamGUI's
  destructive writes (delete user, suspend, delete calendar or event, data transfer, offboarding's
  steps), so a caller can't understate a delete.
- **`HeldPreview`**: made only by `Executor.preview`: the steps, a SHA-256 digest of their argv, the
  domain and generation, the origin (form, Siri, model), the guard's decision, a `ContinuousClock`
  time. Eight kept; fifteen minutes runnable, time asleep counted.
- **`Executor.run`**, in order: take the preview (single use, refused or not); expiry; tenant and
  generation; `Guard.refusal`; no target already in flight; the precondition re-read (false: "preview
  again", never a silent re-plan); the write lock (writes serialized, as GamGUI's `_write_lock`); the
  tenant again (a switch during the re-read or the wait). Then each step: a begin record, the run
  through the runner's `package` write entry with a `WriteTicket`, an end record (exit code, ok, the
  masked error and its kind). A failed or skipped prerequisite skips its dependents; an account-wide
  failure stops the rest; a cancellation is recorded as interrupted.
- **Records** carry `preview`, `digest`, `origin`, `step`, `phase` in `extra`, GamGUI's line format.
  `Executor.unfinished(in:)` finds a begin with no end: Home shows it as "Outcome unknown — check".
- **Secrets** are masked by value in the audit, errors, output and `shownArgv`, beside the positional
  masks (the "surname Password" case is a test).
- **The ticket**: `WriteTicket`'s init is `package`; `WriteRouteTests` holds that only ChangeCore
  mints one. The app holds an `Executor` (AppServices) whose tenant is Setup's active domain.

## Not built yet
The confirm UI and the first curated writes (Users), the §8 voice ticket (today the executor takes only an
operator's confirmation), and GamGUI's tolerated-kinds sweep (`tolerate_kinds`) for best-effort bulk steps.
