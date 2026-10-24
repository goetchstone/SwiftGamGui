# Compromised account: lock it, see what changed, undo it

**Status (2026-10-21): slice 1 merged (#79: the check, the lock and the picks, and Secure Account… on a person's page); slice 2 merged (#82: Pull Incident Logs); slice 3 (search a mailbox) merged (#83); slice 4 (leftover drafts) merged (#85); slice 5 (Chrome: its log by profile, a person's Chrome profiles) built; slice 6 (the Incident screen) built; slice 7 (apps and AI agents, every log) built; slice 8 (computers, and a device joined at a sign-in) built; slice 9 (Apps Script projects) built.** When an account is taken over and sends phishing from Gmail, signing the person
out and resetting the password are in this app, but the rest needed the Admin console or GAM in Terminal; the
operator asked for all of it in GAM GUI.
This is that response, for a person who **stays employed**: no manager, no hand-over. Each default is below, for the
operator to change.

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
0. **From anyone's page** (the operator: "a button to do that for anyone"): Users → Actions → **Secure Account…**
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
| Remove a picked delegate | `user P delete delegate D` (7927) | when picked | one step each (GamGUI's builder) |
| Remove a picked send-as address | `user P delete sendas S` (8301) | when picked | one step each; native builder |
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

## Slice 2: Pull Incident Logs
Why: when an account is taken over, its logs read together (sign-ins, OAuth, Gmail, Access, Chat) find every other
account the attacker reached. The sign-in log matters most (success, failure, the challenge, "is suspicious", Google's
warnings), and filtering every log by the attacker's IP is the most useful view: failed sign-ins from it show who typed
their password into the fake page. Without this, those logs are exported from the Admin console one at a time.

- **One read per log:** `report <application> (user <u>|user all|select users <list>) start -<hours>h end now [ip X]
  maxactivities 1000` (4735-4749), for login, token, gmail, accessevaluation, chat, useraccounts, drive, takeout, admin
  and mobile. The logs an incident needs first are on by default (see the runbook's list). The Admin console's
  "Access" log is the Reports API's `access_evaluation` (cookie validation and access-token requests; Google's appendix).
- **The window:** a day, 3 days (the default), a week, a month or six months. `end now` is named so the Gmail log's
  30-day rule (doReport) doesn't move it. **The accounts:** empty for every account, else up to 20 (the field starts
  with the checked person). **The IP:** typed, or picked from the last pull's sign-in addresses, flagged ones first.
- **One row shape** for every log (`ActivityLogs.Row`: when, who, the event, the IP, the parameters by name, Gmail's
  nested ones by their chain), which the on-device log reader (docs/plans/2026-10-19-on-device-log-reader.md) reads too.
  Each log is a table, at most 300 rows drawn, with "Only what Google flagged" and **Export CSV…** in that shape (cells
  made safe for a spreadsheet as the audit export's are; the file 0600).
- **Gmail** reads at most its 30 days (the API's limit) and says so; the **admin** log is read for what the accounts did
  (`userisactor`). A read past the runner's 8 MiB cap fails in words rather than pass its newest rows as all.
- **An edition without a log:** GAM's words are shown for that log (an API refusal is GAM's systemErrorExit), the
  others still read. Which editions lack which log isn't known offline; the live check tells.

## Slice 3: search a mailbox
From the operator's list (2026-10-19): Users → a person → Mail → **Search this mailbox**, GamGUI's search (read-only, at
most 50 messages, Spam and Trash included), each message with its To, Cc and Bcc read by the Phishing screen's header
rules, starting at `in:sent newer_than:3d` to find other phishing waves the account sent.

## Slice 4: leftover drafts
A taken-over account can be left with phishing drafts anyone signed in can send: they're removed, all or by subject, alone if need be.
The check lists the drafts (newest 5,000); all of them, or those whose subject matches, are deleted in one held step, as
Gmail's Discard does (a trashed draft may still be sendable: review 2026-10-19). Scheduled sends, left out at first, were added on 2026-10-23: listed with their recipients and deleted in one held step, beside the drafts. Runbook: docs/domains/compromised-account.md, "Leftover drafts".

## Slice 5: Chrome
Why: after a takeover, whether the person uses Chrome signed in with their work account matters, since what that Chrome
saved was within the attacker's reach. Chrome's log in Pull Incident
Logs, read by the account signed in to the profile (GAM's own match for a named user is the computer's login name), and a
person's Chrome profiles on their Security tab. Reads only; saved passwords are never readable. Runbook:
docs/domains/compromised-account.md, "Chrome".

## Slice 6: the Incident screen
Asked for (2026-10-21): the remediation as one procedure, each step also runnable on its own, and every log an
incident should look at. One screen in working order (find who's affected, secure an account, pull the email, afterwards), every
lock step a switch so any one runs alone, the auto-reply (read and turned off) and the devices (read) in the check, and
SAML, Takeout and Devices among the logs pulled by default, with Calendar, Groups, Rules, Context-aware access and Vault to
tick. Runbook: docs/domains/compromised-account.md.

## Slice 7: apps and AI agents
Asked for (2026-10-21): who has apps and agents connected and what they might be doing, and every log an incident might
need. Each log row says when an AI agent or an app acted; GAM's whole list of activity logs is offered; Incident read every
account's connected apps (moved to Reports on 2026-10-22: a check of the whole tenant), and Check Account the person's. Runbook: docs/domains/compromised-account.md, "Apps and AI agents".

## Slice 8: computers, and a device joined at a sign-in
Found in a review: an attacker's sign-in can register their own computer to the account, which the phones list can't show
and the log reader didn't call out. Check Account lists the person's computers (Google's endpoint management), and Read
the logs says a device registered at the moment of a sign-in from a suspect address. Reads only. Runbook:
docs/domains/compromised-account.md, "Computers, and a device joined at a sign-in".

## Slice 9: Apps Script projects
Asked for (2026-10-22): whether Apps Script is checked. A script someone authorized keeps acting for them on its triggers.
Check Account lists the person's own Apps Script projects, the latest changed first, and calls out one made or changed in
the last two weeks. Reads only. Runbook: docs/domains/compromised-account.md, "Apps Script projects".

## Done means
Each new builder in `NativeArgvTests` with a strict mock handler that fails as GAM's source does; the screen
accessible (VoiceOver labels, words not colour, keyboard, Dynamic Type); CI screenshots; the runbook
`docs/domains/compromised-account.md`; README live rows "not yet" until each runs live with the operator's yes.
