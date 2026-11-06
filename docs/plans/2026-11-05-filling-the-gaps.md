# Plan: filling the gaps

**Status (2026-11-05): not started.** Nothing here is built yet.

The app stays free and is built for the operator's own use, so this isn't a race. A slice earns its place by being used
or by preventing a loss; the rest is under "Not planned unless asked". What has run is in
[live-verification.md](../live-verification.md).

## Waiting on the operator

- **A name.** The operator expects to change "GAM GUI". Only the display name moves: `App/en.lproj/InfoPlist.strings`, the
  on-screen strings, the README, `NOTICE` and `SECURITY.md`. The bundle ID stays, because Keychain items bind to it. One PR
  once a name is picked.
- **An Apple Developer account** ("soon, but not today"). Slice R waits for it.

## Run what's built

No code and no test session: use the app, and record what ran when it comes up. The biggest unproven areas:

- **Onboard**, on the next hire: it has never run in this app.
- **Calendars' sharing**, on a calendar the operator owns.
- **Incident's other fixes**, the next time one is needed: filters, send-as addresses, drafts, scheduled emails, computers.
- **Groups' managers and owners**, and the **Builder's changes** (B4), on scratch objects the operator owns.

## Slices, in order

### 1. Named reports (reads only)

The Builder can already run these reads, but only someone who knows GAM would find them. Give each a name and a row in
Reports.

| Report | GAM's read |
|---|---|
| Licenses | `print licenses` |
| Shared drives | `print shareddrives` |
| Shared drive permissions | `print shareddriveacls` |
| Mobile devices | `print mobile` |
| Everyone's group memberships | `print group-members` |
| Data transfers | `print datatransfers` |
| Google's security alerts | `print alerts` (the Alert Center scope; a refusal says so) |

One table in code names each report and its catalog command. Each runs through `GamCommands.catalogRead` and shows in the
Builder's result table with its CSV export: no new parser and no new screen. A test holds that each name resolves to a
promoted command. Only a live run proves a read, so the first run of each gets checked by eye.

### 2. Everyone's mail settings (reads only)

Forwarding and delegates are how an attacker stays in, so this prevents a loss. Reads go across all users, on the path
`print tokens` already uses for connected apps.

| Report | GAM's read |
|---|---|
| Who forwards mail out | `all users print forward enabledonly` |
| Who has a delegate | `all users print delegates shownames` |

Each reader accounts for every user GAM lists, and an unknown line is unread, never absent (rule feedback 2026-10-19).

### 3. Close Out and the delete (Off3)

The last destructive flow only GamGUI has, and it finishes an offboarding: groups, org unit, suspend, aliases and archive
after the transfer ends, then the delete (`docs/domains/offboarding.md`). Its first run is on a real leaver. Re-check
Google's Workspace Updates first: a platform change already made one proven routine lose calendars (rule feedback
2026-10-13).

### 4. Many people at once

Built when the operator asks, each on its own. No new mechanism: many steps in one preview, as Groups' add and Phishing
already do, with the typed count, the jobs tray and a retry of what failed.

- Remove several members from a group.
- A department for many (GamGUI has it).
- A signature for many (S2) and hires from a CSV (O3), both already deferred until asked.

### 5. The Builder's remaining pieces

- Sequences, with Stop (GamGUI has them).
- An audit record for reads, so the 14 sensitive reads can run.
- Saved reads, a Builder read kept by name with its values, if the same ones keep coming up.
- The curated "List a shared drive's files" read.

### R. A signed download

Waits for the Apple Developer account. Developer ID signing and notarization, the bundled GAM included (the design doc's
risk 5), and a build on GitHub Releases. It also ends the free signing's 7-day expiry. A first run on a clean Mac comes
before anyone else is pointed at it.

## Small, any time

- Home's Recent failures card (parity audit 2026-10-28).
- The Suspended report with Google's reason, once GAM's source shows which field carries it.
- Refresh the parity fixtures from a pinned GamGUI clone once its catch-up to this app settles.

## Not planned unless asked

- Sheet export: dropped by decision (design doc §1), and `todrive` is a write.
- Scheduled runs, other languages and Classroom sync: nothing in the operator's use needs them.
- Removing limited Drive access: a write across many files, with a large blast radius.
- A plain-language command finder: parked with Siri. A model would only ever draft a preview (invariant 10).
- Calendars: find by name, share with a group, delete a calendar or an event (`docs/domains/calendars.md`).
- Auto-update: a signed download is enough for one person's use.
