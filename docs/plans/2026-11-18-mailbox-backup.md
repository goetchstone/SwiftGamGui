# Plan: back up a mailbox (Vault where there is Vault, GYB where there isn't)

**Status (2026-11-18): plan only, nothing built.** Neither this app nor GamGUI backs up mail today: offboarding keeps
the leaver's mailbox live (delegate, auto-reply) and the account delete, a separate step, is where mail is lost.

**Decision (operator, 2026-11-18):** Google Vault is the proper way and is used when the tenant has it. Without Vault,
the app uses Got Your Back (GYB, the GAM team's Gmail backup tool). Both end in a local copy of one person's mail.

Read for this plan, not run: GAM's grammar at 7.52.03 (`Vendor/gam7/GamCommands.txt`), and GYB's source at
`GAM-team/got-your-back` `1f562ba` (`gyb.py`, `build.yml`, `gyb.spec`). GYB's latest release is v1.97 (2026-09-29),
with a `gyb-1.97-macos-aarch64.tar.xz` asset. Where a fact below is read from source and not proven live, it says so.

## Which route

One read decides, per domain, before anything is offered: `gam print vaultmatters` (grammar 5562).

- It answers → **Vault**.
- It fails with GAM's words for "no Vault on this tenant / this admin has no Vault rights" → **GYB**.
- Anything else → say it couldn't tell, and offer neither until a re-read. Never guess a route.

The failure's words and exit code come from GAM's source at the pin (read to the end of the function), and the
mock answers them; they are not known yet. A tenant with Vault but an admin without Vault privileges is a different
answer ("ask for Vault rights"), not a reason to fall back to GYB.

## Route V — Vault export (GAM only, no new binary)

A tenant write sequence through ChangeCore (invariant 2), never on the "Just do it" list:

1. `gam create vaultmatter name "Mail backup: <user> <date>"` (grammar 5540).
2. `gam create vaultexport matter <id> name … corpus mail accounts <user> format mbox` (grammar 5594). `mbox` because
   any mail client reads it; `pst` only if the operator asks.
3. Wait: `gam info vaultexport <export> matter <id>` until its status is done or failed, bounded (invariant 9), with
   Stop. A read.
4. `gam download vaultexport <export> matter <id> targetfolder <private folder>` (grammar 5617). A read of the export.
5. The matter is left open and named, so the export stays findable in Vault. Google expires exports on its own
   schedule; check the current retention in Google's reference when building, don't quote it from memory.

Verify before building: the status field and its values in `info vaultexport` output, and what `download` writes
(zip, extracted, checksum files) and exits with, from GAM's source at the pin.

## Route G — GYB backup (a second vendored binary)

Backup only. GYB's other actions are out: `restore*` (a mailbox write, and a failed message is recorded as restored
so a resume skips it, `gyb.py` 2418–2426), `purge` (with no `--search` it deletes every non-chat message),
`purge-labels`, `create-project` (can change org IAM), `check-service-account` (its fix link can overwrite the
delegated scopes and goes through a third-party shortener), and GYB's own sign-in (interactive, loose file modes,
sends the address to the shortener).

**G1 — Vendor and pin it (invariant 7).** `scripts/fetch_gyb.sh` + `scripts/gyb_checksums.txt`, failing closed like
`fetch_gam.sh`; a bump that writes a pin only after `gh attestation verify <asset> --repo GAM-team/got-your-back`
with the signer workflow pinned (GYB attests its archives, `build.yml` 384–391; GYB publishes no checksums, so the
attestation is the only proof). **First step, and a gate:** verify v1.97's macOS asset by hand; if it doesn't
verify, stop and ask. An embed phase into `Resources/gyb/` with GYB's own entitlements read from its signed release,
`check_app.sh` widened for that one location, a version constant and an agreement test. GYB's build is looser than
GAM's (unpinned PyInstaller, `actions/checkout@master`, notarization not stapled): say so in the runbook.

**G2 — Run it through the one runner.** `GamRunner(binary:)` already takes any binary; no second process start
(`WriteRouteTests.onlyGamRunnerStartsAProcess` stays as is). A GYB command type minted in one builder file, its own
source scan, and the runner's environment builder taught that GYB takes its folder from argv, not `GAMCFGDIR`. Per run:

- Materialise **only** `oauth2service.json` (the domain's existing one; GYB reads the same key format, `gyb.py`
  1440–1455) into the usual `0700` folder, plus `lastcheck.txt` holding a far-future time: GYB checks GitHub on every
  run and sleeps 15 s when there's a newer release, with no switch to turn it off (`gyb.py` 615–663).
- argv: `--email <user> --action backup --service-account --config-folder <that folder> --local-folder <absolute>`.
  Both folders always absolute: GYB's default config folder is beside its executable. Never `--debug` (it can print
  auth headers).
- Not the runner's 1-hour `domainWideTimeout`: a mailbox can take hours. Stop, and a progress line parsed from GYB's `\r` output, bounded.
- Exit codes from `gyb.py` at the pin, including `sys.exit(http_status)` truncated mod 256 (403 → 147). A strict
  mock that fails and answers as GYB's source does ("the mock lies").
- A backup reads the tenant (invariant 3 in spirit); it still gets an audit record, since it copies a mailbox.

**G3 — Scope check.** GYB's Gmail calls need `https://mail.google.com/` on the service account's delegation. Before
the first backup, `gam check svcacct <admin> scopes https://mail.google.com/` (grammar 1491) answers it; if missing,
the app says which scope to add in the Admin console, and never runs `update svcacct` itself. Confirm from GAM's
source that `check svcacct` changes nothing.

## Where the copy lives (both routes)

`~/Library/Application Support/SwiftGamGui/mail-backups/<domain>/<user>/<date>/`, created `0700` and checked like
`RuntimeDirectory` (owner, mode, no ACL) before the run. GYB writes plaintext `.eml` files and a SQLite index with no
modes of its own; the folder's mode is what protects them. A small record per backup (who, when, route, message count
or export size) so offboarding can see one exists. The operator deletes a backup from the app; nothing expires it.

## Where it shows in the app

- **Offboarding:** "Back up mail" as an addable step (not one of GamGUI's eight, which are fixture-held), and a warning
  in the account-delete preview when no backup is recorded for the leaver. The delete's existing Vault-hold refusal
  stays as it is.
- **A person's page:** "Back up mail" for anyone, the same flow.
- No voice or model starts either route (invariant 10).

## Order

V-route detection read → Route V → G1 → G2 → G3 → offboarding and person-page wiring → back-port to GamGUI from a
GamGUI-rooted session. Each its own PR off `main`.

## Live checks (read-only, on the operator's go)

- `print vaultmatters` on the operator's tenant: which route it gets.
- `check svcacct` for `https://mail.google.com/`.
- Every write in route V (matter, export) needs the operator's per-action yes in chat, on a throwaway test account.

## Not planned

Restore from either route; purge; GYB's own sign-in; backing up Drive, Calendar or Chat (Vault can, later, if asked).
