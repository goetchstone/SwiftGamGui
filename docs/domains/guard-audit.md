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

## Failure history (GamGUI) the guard carries
- Five routes ran a write on a bare POST because only their pages asked (2026-09-23): the executor,
  not a screen, calls `refusal`.
- The Builder deleted an account on one Confirm click (2026-09-23): the typed-address rule applies to
  every change set whose argv deletes an account.
- An alias delete removed the account it belonged to (2026-09-24): `aliasDeletes`.

## Not built yet
The held preview (exact argv, digest, tenant, generation, origin, expiry, single use), the executor
and its ticket, the begin/end audit log, multi-step plans, and the source-scan test.
