# Offboarding options: more steps for templates

**Status (2026-10-14): slices 0-2 built (#66; slice 2, the secondary calendars handed over); trimmed to KISS.** The operator asked for optional steps in
offboarding templates, approved four (remove from groups, hide from the directory, a former-staff org unit, POP/IMAP
and 2SV off), then asked what else would be useful. The research's answer grew to fifteen steps and a per-item row
model; on 2026-10-14 the operator asked for KISS from micro to macro, so this plan keeps what was asked for or
prevents a real loss, and lists the rest as not planned unless asked. Next: slice 3.

Placeholders: L the leaver, M the manager. Grammar lines are `Vendor/gam7/GamCommands.txt` (GAM 7.48.26).

## The rule
**One added step is one GAM command**, over the list the preview read where GAM takes a list (calendars, filters,
groups). GAM works through the list and reports each item; a failure leaves the rest done. "Preview the Rest" reads
again, so it plans only what's left. No per-item rows, no new model.

## What the research found
- **Secondary calendars are deleted with the account** (Google, from 2026-10-05), and the Calendar transfer doesn't
  include them. The one gap that loses data.
- **The grammar file can be wrong:** line 1685 reads `calendars <CalendarEntity> transfer <UserItem>`; GAM's source
  accepts only `calendars <list> transfer ownership <user>`. The source is the authority.
- **`forward off` doesn't stop filters that forward.**
- **The transfer runs 10 to 25 minutes after its command.** Groups, org unit and suspend can switch off what it
  needs, so they wait for Close Out.
- **2SV off inside the revoke can skip the sign-out** when Google refuses it. Not built.

## Built (#66)
Clear recovery email & phone; hide from the directory; the owned-secondary-calendars and Vault-hold warnings; the
typed `confirm` a ten-step routine needs; templates file version 2. The runbook (`docs/domains/offboarding.md`) has
the detail.

## Next, in the hand-over routine
| Slice | Step | Command | Read first |
|---|---|---|---|
| 2 | **Hand secondary calendars to the manager** | `calendars <ids> transfer ownership M` | the owned read #66 already makes |
| 3 | **Remove mail filters that forward** (all of them, operator) | `user L delete filters <ids>` (7957) | `user L print filters formatjson` (7961) |
| 4 | **Turn off IMAP**, **Turn off POP** (two steps) | `user L imap off`, `user L pop off` (8372, 8378) | none |

Each: off unless added; needs only the reset; a strict mock handler that fails as GAM's source does; an exact argv in
`NativeArgvTests`; the README row "not yet" until it runs live with the operator's yes. An added step with nothing to
act on (no calendars, no forwarding filters) isn't planned.

## Close Out (with Off3, the delete)
After the transfer finishes: remove from groups (`user L delete groups <groups read>`, to check against the source),
a former-staff org unit (when the operator has one), suspend or archive, L's aliases to M, then the delete, refused
while a transfer runs, a secondary calendar is still owned, or a Vault hold covers L.

## Not planned unless asked
Forward new mail to the manager (the delegate covers it), remove other delegates, remove admin roles (the preview
warns; the Admin console does it), transfer extras (release rooms, Looker Studio, another recipient), a warning for
sign-in through another provider, wiping phones, removing the licence.

## Decisions (operator, 2026-10-13)
1. **2SV off: not built.** "That's what the delegate is for."
2. **Close Out:** groups, org unit, suspend run later, with the delete.
3. **Filters:** all that forward are removed; the preview lists each and where it goes.
4. **Vault: used.** The preview warns of a hold; Close Out refuses the delete under one.
