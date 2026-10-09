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

## Not built yet
The held preview (exact argv, digest, tenant, generation, origin, expiry, single use), the executor
and its ticket (which writes the begin and end records, and is the only caller of a `package` write
entry point that takes a `GamWrite`), multi-step plans, and the executor's behavioural cases from
`test_write_routes_guarded.py` (a bare confirm, an edited form, a replay).
