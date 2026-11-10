# What has run live

What this app has really done on the operator's domain. Passing tests don't count, because the mock lies.

- **Changes** come from the app's audit log, read on 2026-11-05: 158 runs from 2026-10-09 to 2026-11-03, none failed. A
  change not under "Ran" has no record of this app running it.
- **Reads** aren't logged, so they rest on the operator's word.

To update this: read the audit log or ask the operator, then move the line and change its date (the `live-verify` skill).
Dates are 2026, and the last time the command ran from any screen.

## Changes

### Users
- **Ran:** title and department (10-24), suspend and unsuspend (10-09), sign out (10-19), add to a group (10-17), remove
  from a group (10-13), add a delegate (11-03), remove a delegate (10-19), auto-reply on (11-03), auto-reply off (10-10),
  share their own calendar and remove that access (10-13), set or change the phone a signature shows (10-29).
- **Not run:** a temporary password changed at next sign-in, removing a phone, deleting an account (new 2026-11-07; its first run is
  on a real leaver).

### Groups
- **Ran:** add people as members (10-17), remove a member (10-13).
- **Not run:** add people as managers or owners.

### Calendars
- **Not run:** anything from this screen: share a calendar with a person, put it in their list, remove someone's access.
  Sharing a person's own calendar ran from Users.

### Signatures
- **Ran:** set a signature (10-29).

### Onboard
- **Not run:** anything in this app: create an account, the task checklist, subscribe to a calendar, the wait for a new
  account, the welcome email. GamGUI has run the same create, checklist and subscribe commands, and the welcome email
  (here its body keeps its line breaks, which is new). The wait hasn't run in either app.

### Offboard
- **Ran:** the whole 12-step routine, three times (last 11-03): reset the password, clear recovery, sign out, forwarding
  off, IMAP off, POP off, a delegate, an auto-reply, the Drive and Calendar transfer, the calendar sweep, the manager's
  reminder, hide from the directory. Each step's effect was checked in Google on 10-16. The sweep ends in exit 50 each
  time and the run tolerates it: a calendar's owner can't be removed from their own calendar.
- **Not run:** hand over secondary calendars, remove filters that forward.

### Incident
- **Ran:** the lock (10-19): reset the password, sign out, forwarding off, IMAP and POP off, clear recovery.
- **Not run:** delete filters, remove a delegate from this screen (Users' command, which ran), remove a send-as address,
  delete drafts, delete emails scheduled to send, block a computer or take the account off it, turn off an auto-reply
  from this screen. No change has come from Do It Here yet.

### Phishing
- **Ran:** trash an email from each mailbox that has it (10-23). A copy in Trash hasn't been looked at in Gmail yet.
- **Not run:** copies in Spam, several emails in one preview (Pull All).

### Builder
- **Not run:** any change from this screen (the log marks a Builder run, and has none).
  - **B3:** the changes that ran from other screens: add or remove a delegate, auto-reply on and off, add or remove a group
    member, title and department, sign out, suspend, reset password, forwarding off, the Drive and Calendar transfer.
  - **B4:** the changes that haven't run in either app: add a forwarding address, forward on, create or remove an alias,
    create a group, undelete an account. Prove each on a scratch object the operator owns.

## Reads

### Ran, by the operator's word
- Connect, Check access and load the directory (10-09); connected on GAM 7.49.02 (10-28).
- The group list and a group's members (10-10).
- Check Account, Pull Incident Logs and the log export (10-21); a 30-day pull (10-27).
- Read the logs: findings, each account's timeline, Still to do, and Respond's to-do list (10-28).
- A kept incident reopened after a rebuild (10-27).
- Phishing's Find (10-23; the trashes above came from it).

### Probably ran
On 2026-11-05 the operator said most of what's built has run, without listing it. Move one up when you know.

- A person's page: mailbox search, Chrome profiles, phones and tablets, computers (needs the Cloud Identity devices scope),
  Apps Script projects, connected apps and agents.
- Incident: a capped log read further back, Pull Every Account from the attacker's address, Who it reached and its export,
  Where it started, Show the Events and Pull Again, That was them, the report and its export, the on-device model's
  wording.
- Reports: the directory reports, storage and mail usage, every account's connected apps and agents.
- Calendars: the rooms, a person's calendars and who has access.
- Builder: **B1**, a catalog command that only reads (`print users`, `print groups`, `info user`, `print domains`, `show`
  of one person); **B2**, the curated reads (list delegates, list forwarding addresses, search a mailbox, find users,
  Chromebooks or a person's Drive files).
- Setup: **C1**, the admin's account ID confirmed; any Check access or launch reads it.
- The jobs tray, listing a run from the click (fixed after the operator's 10-30 run didn't show).

### Not run
- A person's phones and computers on their Security tab (new 2026-11-07; Incident's check runs the same two reads).
- ChangeCore: **C2**, the refusal of a change that would cut off the connected admin (Suspend on its own page; the
  Builder's suspend of an alias of it). Nothing is written either way.
