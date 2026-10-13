# Offboarding options: more steps for templates

**Status (2026-10-13): DECIDED. Slices 0 and 1 built** (typed confirm; templates v2 with clear recovery info and hide from the directory; the secondary-calendars and Vault-hold warnings). Next: slice 2, the secondary calendars handed over. The operator asked for more optional steps in offboarding templates and
approved four (remove from groups, hide from the directory, move to a former-staff OU, POP/IMAP and 2SV off at
sign-out), then asked what else would be useful. This plan is the researched answer: GAM 7.48.26's grammar and
source, GamGUI (frozen, read only), Google's documentation, and this app's code, synthesized and then checked by
two adversarial reviewers (an argv check against the grammar and source; a safety and completeness review). Their
corrections are folded in below. Decisions for the operator are at the end.

Placeholders: L the leaver, M the manager, R a transfer recipient. Grammar lines are `Vendor/gam7/GamCommands.txt`.

## What the research found that changes the picture
- **Secondary calendars are deleted with the account now.** Google, 2026-03 Workspace Updates: from
  **October 5, 2026**, a Workspace user's secondary calendars are "permanently deleted upon the deletion of the
  owner's account"; the Calendar data transfer doesn't include them ("Secondary calendars and their events don't
  transfer"). Today's routine plus a delete loses every team or project calendar the leaver owns. This is the one
  gap that destroys data, so it comes first.
- **The grammar file can be wrong.** Line 1685 gives `gam calendars <CalendarEntity> transfer <UserItem>`; GAM
  7.48.26's own code (read by disassembly through `scripts/gam_oracle.py`, and 7.48.22's source) accepts only
  `calendars <id> transfer ownership <user>` (GamUpdate 7.46.04). The source is the authority; the mock follows it.
- **`forward off` doesn't stop filters that forward.** Gmail filters with a forward action are separate from
  automatic forwarding and keep sending mail out after the routine.
- **The transfer runs in the background for 10 to 25 minutes.** Steps that can switch off the leaver's Drive,
  Calendar or licence (groups, org unit, suspend) must not run in the same minute as the transfer: row order
  doesn't make them wait.
- **Turning off 2SV inside the revoke weakens the lock.** GAM's `deprovision` turns 2SV off before signing out and
  catches only one error there; Google refuses the turn-off when 2SV is enforced, when the user isn't enrolled, or
  under Advanced Protection, and then the sign-out is skipped. Recommended against (see decisions).
- **A long routine trips the guard after Run.** A destructive plan of 10 or more steps needs the typed word
  `confirm` (Guard), but the offboarding confirm sheet doesn't ask for it, so the run is refused only after Run is
  clicked (`ChangePreviewSheet.swift` OffboardConfirmSheet, `Guard.swift`). Every option below can pass 10 rows.

## The steps

Each is a template switch, off unless said; one ChangeCore step per row; reads at plan time, before the reset;
held to the strict mock and an exact-argv table (native steps have no GamGUI builder to be parity-tested against).

### Now: the hand-over routine (runs with today's eight)

| Step | Writes (argv after `gam`) | Reads first | Default | Undo |
|---|---|---|---|---|
| **Clear recovery email and phone** | `update user L recoveryemail '' recoveryphone ''` (5842-5843, 5942) | none | on, after live proof | none kept on purpose (personal data); the person supplies new values |
| **POP and IMAP off** | `user L imap off`, `user L pop off` (8372, 8378): two rows after the revoke; the revoke keeps GamGUI's `deprovision signout` | none | off | `imap on`, `pop on` |
| **Remove mail filters that forward** | `user L delete filters <id>` per filter (7957) | `user L print filters formatjson` (7961) | on, after live proof | re-create from the recorded criteria (7955) |
| **Hand secondary calendars to the manager** | `calendars <id> transfer ownership M` per calendar (source; see above) | `user L print calendars ownedsecondary showhidden fields id,summary formatjson` (6287-6288) | on, after live proof | `transfer ownership L` while L exists |
| **Remove other delegates** | `user L delete delegate X` per delegate but M (7919, GamGUI's builder) | the delegates read the preview already makes | off | `user L add delegate X` |
| **Forward new mail to the manager** | `user L add forwardingaddress M`, `user L forward on keep M` (GamGUI's builders) | `user L print forwardingaddresses` (7997) | off | `forward off`, delete the address |
| **Remove admin roles** | `delete admin <assignmentId>` per assignment (1574) | `print admins user L` (1579), only when the directory says L is an admin | off | `create admin L <role> <scope>` (1572) from the record |
| **Hide from the directory** | `update user L gal off` (5831; always the explicit `off`: a bare `gal` means on) | none | on, after live proof | `gal on` |
| **Transfer switches** | on the existing transfer row: `release_resources` (3599, only with calendar), `lookerstudio` in the one services element (3591, offered only when `print transferapps` lists it), or a recipient R other than M | `print datatransfers olduser L` (3603): warn while one is running | off (default argv stays GamGUI's) | none for a transfer |

Placement, in run order: reset → **clear recovery** → revoke → **POP/IMAP** → forwarding off → **forward to manager**
→ **filters** → **admin roles** → **other delegates** → delegate → auto-reply → transfer → **secondary calendars**
→ sweep → reminder → **hide from directory**. Each added row requires the reset only; the secondary calendars require
what the transfer requires. Gmail settings writes come before anything that could turn Gmail off.

### Later: the close-out pass (after the transfer finishes, with the delete)
These can switch off the leaver's services or licence, so they wait until `print datatransfers olduser L` shows the
transfer completed (a failed transfer blocks with words). Proposed as one later screen, "Close out", which is also
where Off3's delete lives:

| Step | Writes | Reads first | Notes |
|---|---|---|---|
| **Remove from groups** | `update group G remove L` per group (GamGUI's, live-proven) | `user L print groups` (8403; role per group) | security-labelled and admin-created groups left unticked by default; a group L owns alone is warned |
| **Move to a former-staff OU** | `update user L org <path>` (5837) | `info org <path> nousers` (4589) | the template holds the path; the preview says what the OU must keep on |
| **Suspend** | `update user L suspended on` (GamGUI's) | none | for lock-only exits; requires the reset only |
| **Move aliases to the manager** | `delete alias A`, `create alias A user M` | L's aliases | just before the delete, so alias mail keeps L's auto-reply until then |
| **Archive instead of delete** | `update user L archived on` (5824) | the edition | the keep-the-data alternative to Off3's delete |
| **After the delete: L's address on M** | `create alias L user M` (1610) | — | mail to L keeps reaching someone |

Close-out's read-only checks before a delete: no transfer running or failed, no secondary calendar still owned, no
Vault hold (`user L print vaultholds`, 5704), no shared drive whose only manager is L.

### Warnings the preview adds (read only)
- Single sign-on through another identity provider (`print inboundssoassignments`, 4479): the reset doesn't lock L
  out; disable L there.
- A Vault hold: the data won't transfer, and the account can't be deleted.
- Each ticked step's access proven before the reset (role management, calendar admin access), as the delegates read
  already is: a missing scope found after the reset strands the routine.
- Security keys and passkeys can only be removed in the Admin console: the run's "next" text says so.

## Not offered
- **2SV off**: see above; if the operator needs to sign in as a leaver, that's a separate action that keeps 2SV.
- **Wiping phones**: per device and irreversible; on a company-owned phone an "account wipe" is a factory reset.
- **Removing the licence**: Gmail, Drive and Calendar stop, which breaks the hand-over; archive (close-out) is the
  keep-the-data path, and the delete frees the licence.
- **Vault holds as a step**: a hold blocks the transfer and the delete; it's a legal decision, so only the warning.
- **Shared drives**: nothing to do while the account lives; close-out checks for drives left without a manager.
- **Emailing the manager, contacts delegation**: little gain for a new write path or a new scope.

## Build slices
0. **Typed confirm for long routines**: OffboardConfirmSheet asks for `confirm` when the guard requires it; each
   row's target named so the sheet doesn't call a 30-row routine "30 accounts".
1. **Templates v2 + clear recovery + hide from directory + the secondary-calendars read**: `Step` gains native keys
   beside GamGUI's eight, whose parity tests run unchanged; the template file gains `add` (v1 migrated, never moved
   aside); the preview lists L's secondary calendars and warns before any delete. Starters change only after proof.
2. **Secondary calendars transferred** (one row per calendar; the `ownership` form; admin visibility warned).
3. **One row per item read at plan time**, then **forwarding filters** (multi-action filters re-created without the
   forward, or their other actions shown).
4. **POP/IMAP off.** 5. **Other delegates** (and the mock's lenient `delete delegate`, below). 6. **Forward to
   manager** (and the mock's `add forwardingaddress`). 7. **Admin roles** (delete only assignments whose assignee is
   L as a user). 8. **Transfer switches.**
9. **Close-out**: the transfer-finished gate, then groups, OU, suspend, aliases, archive, with Off3's delete.

Every slice: grammar and source cited; a strict mock handler that fails as GAM's source does; an exact-argv table;
VoiceOver words; a screenshot; this runbook updated; the README row "not yet" until the operator's per-action yes
on a real leaver (reversible ones, like hide/show and IMAP off/on, can be proven on the operator's own account).

## Mock lies found (fix in the slice that touches them)
- `delete delegate` succeeds for a delegate not on the list (GAM: exit 50).
- `add forwardingaddress` succeeds for an address already registered (GAM: exit 50); `forward on` succeeds with no
  accepted address.
- `update user … org` accepts any value (GAM: usage error for empty, exit 50 for a missing OU).
- `releaseresources` requires a Boolean (GAM accepts it bare) and isn't refused without calendar (GAM refuses).
- `lookerstudio` is always accepted (GAM refuses an app the customer's list doesn't resolve).

## Decisions (operator, 2026-10-13)
1. **2SV off: not built.** "That's what the delegate is for": the manager reads the mailbox as a delegate.
2. **Close Out: yes.** Groups, org unit, suspend, aliases and archive run in a later Close Out step after the
   transfer finishes, with Off3's delete.
3. **Filters: all that forward** are removed; the preview lists each one and where it goes.
4. **Vault: used.** The Vault-hold read (`user L print vaultholds`, 5704) is built with slice 1 as a preview
   warning (a hold stops the transfer, and Google says "their events don't transfer"), and Close Out refuses the
   delete under a hold, offering archive. A refused read (no Vault access) warns in words; it never passes silently.
   No third-party single sign-on and no group-based licensing: those warnings stay generic, for other tenants.
