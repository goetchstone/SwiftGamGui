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

- A guard can't prove that a GAM command does what you expect against *your* domain. Check the
  README's live-verification table, and rehearse anything unproven on a throwaway user first.
- GamGUI is provided **as-is under the MIT License, with no warranty**. You are responsible for what
  you run against your own tenant.
