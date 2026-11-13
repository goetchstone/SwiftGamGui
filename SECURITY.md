# Security Policy

## Reporting a vulnerability

Please report it **privately**, not in a public issue: a public report on a tool that holds
domain-wide admin credentials is itself a risk to everyone running it.

Use GitHub's private reporting on this repository: **Security → Report a vulnerability**
([direct link](https://github.com/goetchstone/SwiftGamGui/security/advisories/new)). If that page isn't
available to you, open a public issue with **no details** that asks for a private channel, and the
maintainer will follow up.

Say what you did, what happened, and what you expected. A proof of concept helps a lot. This is a
small volunteer project: expect a reply in days, not hours.

## What GamGUI is, for threat modelling

GamGUI (this repository, SwiftGamGui) is a **local, single-operator macOS app**. It has no server, no
listener, no hosted service and no remote users. It runs the bundled `gam` as a child process, and
nothing leaves the Mac except `gam`'s own calls to Google.

The stakes are high because of what the app can reach:

> `oauth2service.json` can impersonate **any user in the domain**, and `oauth2.txt` is effectively an
> administrator password. Anything that exposes those, or makes `gam` run a command the operator
> didn't intend, is serious.

**In scope:**

- another **local process** running as the same user, reading credentials at rest (within the limits
  under *Known limitations*);
- **hostile or malformed data from Google** (names, signatures, calendar and group text, GAM's output
  and errors) reaching a `gam` argument list, a parser or a log;
- **a model or Siri** causing a change the operator didn't confirm;
- **supply chain:** a tampered `gam` binary or a compromised GitHub Action.

**Out of scope:** rate limiting, multi-user authorization (there is one operator), and anything that
needs an attacker who already has root or can modify the app bundle.

## Properties the code is expected to hold

Each is an invariant in [CLAUDE.md](CLAUDE.md); a change that breaks one is a bug, and tests guard them.

- **Credentials live in the Keychain**: the data-protection keychain, this device only, behind a
  user-presence check (Touch ID or the password). For one `gam` call they are written into a `0700`
  directory (`0600` files) and wiped after it; a launch-time sweep removes any a crash left behind,
  and quitting stops a `gam` still running.
- **The guided setup's folder doesn't keep credentials.** GAM's own setup commands write them into a
  private `0700` folder; once the Vault holds the whole set, exactly the files read are overwritten and
  removed, recognised by inode, not by name, so a swapped folder or file is left alone.
- **Code outside the app's core library can't read a secret or run a write.** Its public API runs
  only typed read commands; raw secret bytes, the raw runner and the per-call config directory are
  internal to the package (`WriteRouteTests` scans for anything the compiler can't check).
- **`gam` never runs through a shell.** Every call is an explicit argv; each operator value is one
  element, byte-identical to the live-proven builders of the Python GamGUI (a golden test, and
  coverage-guided fuzzing of the builders, the output parsers and the error masking).
- **The environment can't steer `gam`.** It gets an allowlisted set of variables only, and the app and
  the bundled `gam` are signed with the hardened runtime.
- **Only read-only commands become runnable automatically**; every write is curated, and every write
  will run through one guarded, audited path with a preview it can't diverge from. (No write is
  wired yet: the app reads only.)
- **A model or Siri only drafts a preview**, except the operator's optional, off-by-default "Just do
  it" list of simple single-target actions, which never includes deletes, offboarding, passwords,
  sign-outs, delegation, forwarding, transfers, sharing or bulk changes.
- **A student roster upload is read as hostile, and kept briefly.** On a school domain the operator can pick a SIS's
  OneRoster export (a ZIP, a folder or its CSV files) on Classroom's Plan an Import. `Stores/Roster/` reads it in
  memory and never extracts it: its own ZIP reader (`RosterZip`) checks the archive's end record and refuses a central
  directory past its cap before walking it, inflates with zlib (as Python's `zlib`, refusing a corrupt stream) while counting every byte, never
  trusting a header's size, and checks each CRC; a member is matched by its base name against OneRoster's own, and a
  link, an encrypted member, `..`, an absolute name, a backslash, a NUL, nested folders, ZIP64 or an unknown file refuse
  the package. Picked files are read by descriptor, never through a link, bounded in number and bytes before any is
  read. Only the columns a roster needs are read from a row, and the files no reader uses are never unpacked. What it
  read (names and addresses of teachers and students, and who is in which class) is kept by `RosterStore` as one file
  per domain, `0600` in a `0700` folder under Application Support (refused if it's a link), for 14 days, and deleted on
  **Purge**; a half-written copy is swept, and one a quit or crash left is swept at the next launch. Deleting a file on an SSD doesn't overwrite it; FileVault is what protects it
  at rest. GAM GUI never sends it anywhere and never writes to Classroom; the import and the purge are audited as local
  events, never with a row.
- **The Classroom hand-over runs outside GAM GUI, and the screen says so before the button.** Compare with Classroom only
  reads; the change list is held in memory for that tenant and roster. Download the Hand-over saves a ZIP (README, a
  formula-safe review sheet, and a numbered CSV per kind with the `gam csv` line that runs it) as a `0600` file, never
  opened, and audits what was handed over (counts and the held-back kinds included), never a row. Whoever runs those
  files with GAM does so outside GAM GUI's preview, guard and audit log, and the commands haven't been run on a real
  school domain. The ZIP lists students' addresses: keep it as you would the roster export.
- **The vendored `gam` is checksum-pinned and fails closed.** `scripts/bump_gam.py` writes a pin only
  after GitHub's build attestation shows GAM-team's release workflow built it.
- **Every GitHub Action is pinned by commit SHA**, and the fuzzing container by digest.

## Known limitations

- **During a `gam` call, the credentials are readable by your other processes.** The `0700` directory
  keeps other users out, not other processes running as you. The wipe keeps that window short; it
  doesn't close it. The boundary against same-user code is the Keychain item's access control.
- **There are no released builds.** Build it yourself; a build is signed for your own Mac (a Personal
  Team), not notarized.

## Using it safely

- A guard can't prove that a GAM command does what you expect against *your* domain. Check
  [docs/live-verification.md](docs/live-verification.md), and rehearse anything unproven on a throwaway user first.
- GAM GUI is provided **as-is under the Apache License 2.0, with no warranty**. You are responsible for what
  you run against your own tenant.
