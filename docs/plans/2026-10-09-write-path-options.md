# Write path: options for closing every route to a credentialed `gam` call (2026-10-09)

**Status: DECIDED 2026-10-09 — option A, with C's narrowing (the recommendation).** The operator's
rule: "there is almost always a correct way to do something … we always do it the correct way."
The refactor is built (typed builders, `package` routes, `WriteRouteTests`); ChangeCore slice 3 builds
on it (see "Decision" at the end).

## The problem

Invariant 2 says a write runs only through ChangeCore, and §6 says the run function takes a ticket
only ChangeCore can create. Today nothing stops a caller outside ChangeCore from starting a write. A
credentialed `gam` call can begin from five places:

| Route | Access today | Called from |
|---|---|---|
| `AuthenticatedRunner.run(argv, as:)` | public | DirectoryStore, `checkAccess` (AccessCheck), the vault spike (App) |
| `GamRunner.run(argv, configDirectory:)` | public | AuthenticatedRunner, `GamVersion.running` |
| `EphemeralConfig.materialize(files:in:)` | public | AuthenticatedRunner, `GamVersion.running` |
| `Vault.credentials(for:)` | public | AuthenticatedRunner, SetupModel (reads the admin), the vault spike (App) |
| `Process` / `posix_spawn` from the app target | Foundation | nothing yet |

Any of the first four lets the app target (views, App Intents, a model's tool) run an arbitrary argv
with the tenant's credentials. The fifth can't be closed by access levels at all, only by a source
scan.

Whatever is chosen must also carry §8's **voice-confirm ticket**: "Just do it" runs only an
allowlisted action class, and the class must come from code, never from Siri or a model.

## What every option shares

- **Access levels close routes 2 to 4:** `GamRunner.run`, `EphemeralConfig.materialize` and
  `Vault.credentials(for:)` become `package`. Their callers (AuthenticatedRunner, GamVersion,
  SetupModel) are all inside GamKit already. The app target's vault spike is the one outside caller:
  it times two `Vault.credentials` reads (the Touch ID check). Those reads move behind a small
  debug-only entry point in Vault; its authenticated run is a read, so it stays as it is.
- **A source-scan test closes route 5,** porting GamGUI's `test_write_routes_guarded.py`: no
  `Process`, `posix_spawn`, `NSTask` or `Vault` in `App/`, and no call of the write entry point
  outside ChangeCore.
- **The ticket** is a `package` struct ChangeCore mints from a held preview. It carries the preview's
  digest, and its authority is either `.operator` (a Confirm in the app) or `.voice(ActionClass)`.
  The executor accepts `.voice` only when the preview's class is enabled in the allowlist and is not
  in §8's never-list.

The options differ only in how a **read** stays easy while a **write** is locked down.

## Option A: typed commands (the handoff's suggestion)

The builders return `GamRead` or `GamWrite` instead of `[String]`. Both wrap the argv, which only
GamEngine's builders can construct. A `GamWrite` also carries its `ActionClass` (so voice can't
choose it) and its target.

- `AuthenticatedRunner.run(_: GamRead, as:)` stays public. Any caller can read.
- `run(_: GamWrite, as:, ticket:)` is `package`, and only the executor can reach it.
- **Read-only proof:** a test runs every `GamRead` builder over the golden inputs and asserts the
  catalog calls each argv confidently `READ_ONLY` (invariant 3's rule). A builder mistyped as a read
  fails CI.
- **Cost:** 58 builders change their return type. The golden test's adapter maps `.argv` (the fixture
  doesn't change). Callers change: AccessCheck, DirectoryStore, `Guard.deletedAccount` (it reads a
  `Change`'s argv). Mechanical, roughly one PR.
- **For:** a write can't even be expressed where it can't run; the compiler checks it. The action class
  sits next to the argv that defines it. Builder's arbitrary catalog reads (phase 4) become a
  `GamRead` that only Catalog's promotion rule mints.
- **Against:** the largest diff. Every future builder must pick a side, and the read-only test is
  what keeps that choice honest.

## Option B: untyped argv, classified at run time

Builders keep returning `[String]`. The public `run` refuses any argv the catalog doesn't call
confidently `READ_ONLY`, and writes go through a `package` `run(ticket:)`.

- **Cost:** small. No builder changes, and each caller is untouched.
- **Against:**
  - A second source of truth at run time: the read/write decision is re-derived from argv text on
    every call instead of being fixed by the builder.
  - A misclassification fails at run time, in front of the operator, not in CI.
  - The action class for voice still has to come from somewhere; with untyped argv it would be parsed
    back out of the argv, which is the kind of inference §8 forbids for a model.

## Option C: no general runner in the app at all

The app never holds an `AuthenticatedRunner`. GamKit exposes only named, purpose-built reads
(`DirectoryStore.load`, `checkAccess`, Home's counts, a Catalog read) and ChangeCore's executor. The
runner, with routes 1 to 4, is all `package`.

- **Cost:** moderate. The builders don't change. AppServices hands out the stores and the executor
  instead of a runner, and every new screen adds its reads as GamKit functions.
- **For:** the smallest public surface; the app can't name an argv at all.
- **Against:** it doesn't by itself say which builders are writes, so the executor still needs
  something like A's typing, or B's classification, to know an action class. In practice it is
  A or B with a narrower public API.

## Recommendation

**A, with C's narrowing where it's free:** typed `GamRead`/`GamWrite`, routes 2 to 4 made `package`,
the source-scan test, and the app reaching reads through stores (as it already does) rather than
holding a raw runner. The action class lives on `GamWrite`, so the voice ticket's allowlist is
checked against code, not text. The cost is one mechanical PR before slice 3, held to the existing
golden fixture.

## Decision (operator, 2026-10-09)

1. **Option A with C's narrowing.**
2. The vault spike keeps its timed Keychain reads through a debug-only entry point in Vault (`#if
   DEBUG`), so the Touch ID check still runs on a real Mac. Its authenticated run is a read and
   stays.
3. **Its own PR first:** a refactor with no behaviour change. The golden fixture must not move, the
   `gam-command-reviewer` agent reviews it, and ChangeCore slice 3 builds on it.
