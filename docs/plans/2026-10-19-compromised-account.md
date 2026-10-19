# Compromised account: lock it, see what changed, undo it

**Status (2026-10-19): slice 1 built (the check, the lock and the picks); slice 2 (reports) next.** On 2026-10-19 a user's account was taken over and sent a phishing email
from Gmail (SPF, DKIM and DMARC passed: it came from her account). The operator signed her out and reset her
password, then found the rest needed the Admin console or GAM in Terminal, and asked for all of it in GAM GUI, now.
This is that response, for a person who **stays employed**: no manager, no hand-over. Defaults were chosen without
asking (the operator: "get it done asap"); each is below, for the operator to change.

Placeholders: P the person. Grammar lines are `Vendor/gam7/GamCommands.txt` (GAM 7.48.30); GAM's source is
`src/gam/__init__.py` at tag v7.48.30.

## Why a sibling screen, not a mode of Offboard
Offboarding is a leaver **and a manager** in every part: the address check, the run-time re-check, the delegate,
the auto-reply, the transfer, the reminder, the templates and their file. A compromised-account mode would put a
branch in most of its functions and its fixture-held words. So **Compromised Account** is its own small screen and
model that reuse offboarding's pieces rather than copy them: the lock's builders and words (`Offboarding.Step`
names), `UserAccess`'s reads, ChangeCore's held preview, typed address and Stop, and the screen's step and status
rows. Nothing in offboarding changes.

## The flow
0. **From anyone's page** (asked 2026-10-19, after a second account needed it): Users → Actions → **Secure Account…**
   opens this screen for that person and checks them. "Password already reset" stays for the operator to tick.
1. **Check Account** (read-only, nothing runs): P's account (`info user`), every Gmail filter with what it does,
   auto-forwarding and the forwarding addresses, mail delegates, send-as addresses, and admin role assignments. Each
   read that fails is said in GAM's words, never taken as "none".
2. **Pick what to undo**: a box beside each filter (delete), each delegate (remove) and each send-as address but the
   primary (remove). None is ticked to start: the operator says what the attacker made.
3. **Preview Steps**: the lock and the picks as one held ChangeCore preview, each step's exact `gam` line.
4. **Run**: P's address typed; Stop between steps; then **Check Again** re-reads everything, so anything made before
   the sign-out shows.

## The steps (run order)
| Step | Command | Default | Why |
|---|---|---|---|
| Reset password | `update user P password random changepassword off` | runs; one switch says "already reset" | usually done first in the Admin console |
| Clear recovery email & phone | `update user P recoveryemail '' recoveryphone ''` | **off** | an attacker's recovery phone can take the account back, but P's own are a loss: the panel shows both to decide |
| Revoke access & sign out | `user P deprovision signout` | always | ends every session, deletes app passwords and backup codes, revokes every connected app (P re-grants what they use) |
| Turn off forwarding | `user P forward off` | always | |
| Delete the picked filters | `user P delete filters <ids>` | when picked | one command, as offboarding's |
| Remove a picked delegate | `user P delete delegate D` (7919) | when picked | one step each (GamGUI's builder) |
| Remove a picked send-as address | `user P delete sendas S` (8293) | when picked | one step each; native builder |
| Turn off IMAP / POP | `user P imap off`, `user P pop off` | **on** | the lock as asked; P can turn either back on in Gmail settings |

- **What stops what:** offboarding's rule, kept: when the reset runs, everything needs it ("nothing after it runs");
  ticked as already done, nothing stops anything else. And as offboarding, only `requires` stops a step
  (`stopsAtAccountWideFailure: false`): the sign-out uses the admin token's scope, forwarding and the Gmail steps the
  service account's, so a refused sign-out mustn't stop the rest of the lock. `WriteRouteTests` allows this model that
  and nothing else (no tolerated failures).
- **Not built:** 2-Step Verification off (it weakens the account), suspend (P stays employed), deleting forwarding
  addresses (forwarding off stops the forwarding; the list only lets P turn it back on without a new verification),
  message pull (its own session), a signature check (the Signatures screen shows it).
- **Checked at the run:** P read fresh (`info user`): the same primary address, suspension and admin roles, and not
  the admin this app is connected as (the sign-out would delete the app's own token). A filter made after the check
  isn't seen until Check Again.

## The reads
| What | Command | Grammar |
|---|---|---|
| Account, recovery, 2SV, admin flags | `info user P fields primaryEmail,name,suspended,isAdmin,isDelegatedAdmin,isEnrolledIn2Sv,isEnforcedIn2Sv,recoveryEmail,recoveryPhone formatjson` | 5945ff; field names from `USER_FIELDS_CHOICE_MAP` |
| Filters | `user P print filters labelidsonly formatjson` (offboarding's read) | 7961 |
| Forwarding | `user P print forward` | 8003 |
| Forwarding addresses | `user P print forwardingaddresses` (GamGUI's builder) | 7997 |
| Delegates | `user P print delegates` (GamGUI's builder) | 7922 |
| Send-as | `user P print sendas verifyonly` (signatures as yes/no, not their HTML) | 8297 |
| Admin roles | `print admins user P` | 1579 |

User labels show as their IDs (`labelidsonly`, offboarding's read): system labels (Inbox, Trash, Spam, Unread) are
what an attacker's filter uses, and those are named.

## Slice 2: sign-ins and app grants
`report login user P start -Nd` and `report token user P start -Nd events authorize` (4730), as tables: time, event,
IP address, and for tokens the app and its scopes. N is 7, 30 or 180 days (30 by default); `maxactivities` bounds
each (invariant 9). Needs the admin token's Reports scope.

## Done means
Each new builder in `NativeArgvTests` with a strict mock handler that fails as GAM's source does; the screen
accessible (VoiceOver labels, words not colour, keyboard, Dynamic Type); CI screenshots; the runbook
`docs/domains/compromised-account.md`; README live rows "not yet" until each runs live with the operator's yes.
