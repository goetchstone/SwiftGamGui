# Plan: an incident you can open, watch and report

**Status (2026-10-22): slice 1 built (#98: lock status from the logs; runbook: docs/domains/compromised-account.md,
"Where each account stands"). Then, from real logs: the reader's rules corrected (failure log 2026-10-22),
and "That was them" moved up from slice 3 at the operator's ask and built (runbook "That was them"). Then the rundown,
at the operator's ask after running real logs through it: every account touched with its status and timeline, and
Still to do worked out by code, the model only wording it (runbook "The rundown"; this pulls forward slice 2's findings
first and slice 4's actions taken and next steps). Then undo from the app: block or take the account off the attacker's
computers as planned steps, and Do It Here on a to-do item (runbook "Undo from the app"). Then a capped log read further
back over the same window, in pages, so a pull for every account is whole (runbook "Past the cap"). Then (2026-10-23, at
the operator's ask: it must work after the fact, as the app is rebuilt often) slice 3's record and evidence first: an
incident kept on this Mac, made by hand or from an export, its saved pulls read back as the logs (runbook "A kept
incident"). Then the screen as tabs (Investigate, Respond, Report), Show the Events and Pull Again on the to-do items,
and Select All for the logs (runbook "Tabs, and a button on every to-do item"). Then every pull read whole, oldest first, a
day at a time, bounded, with Read the Rest, and windows of 1, 3, 10, 15 and 30 days (runbook "Read whole, oldest first").
Then the fix for a whole pull stopping the app: the reader linear in the events and off the main thread, with the pull's
parse, sorting, merge and saving (failure log 2026-10-23; runbook "Nothing a pull's size runs on the main thread"); then
progress after every read, each step after a pull said under the logs, and a pull saved to the open incident added to its
evidence in memory, never by reading every saved pull back (failure log 2026-10-23, "each pull re-read every saved pull").
Then the checklist's first piece: an email Phishing trashed from every mailbox shows done on
Respond, with when and by whom, from this app's audit log, and one Phishing's Find showed nobody here has, kept on this
Mac (runbook "Done from the audit log"; phishing.md D13, D14). Then (2026-10-24) an incident opens faster: saved logs
read four at once and merged once (PR #117; runbook "Opening fast").
Next, in this order: slice 7 (narrow pulls first, and how far a wide pull gets, planned 2026-10-24 at the operator's ask);
the incoming phish, a pull anchored on the attack, and who to warn (and whether they were); the
checklist (done from the logs where they show it, else ticked by hand) and the report (slice 4); then slices 5 and 6.** Asked for: scan the logs, flag behaviour, recommend actions, use the
on-device model and the logs' own logic, open an incident from what the logs flag, watch it with log pulls that add
to it, and a report "sufficient documentation we can take to anyone". Required: **an incident already in progress is
picked up as it stands, without redoing a step.** Built on the Incident screen
([docs/domains/compromised-account.md](../domains/compromised-account.md)) and the log reader
([2026-10-19-on-device-log-reader.md](2026-10-19-on-device-log-reader.md)), on main once PR #97 (a person's Apps
Script projects) merges, as #96 (a person's computers) has: no stacked PRs.

## Why
After a takeover, logs read by hand, several times over, still can't answer "are they still in?" with confidence,
and Google's alert can come late. Nothing on the screen remembered what was done or said where the incident
stood, and there was no document to hand anyone. Incident response standards such as SANS's six steps
(preparation, identification, containment, eradication, recovery, lessons learned) list what an incident's record
must hold. The screen should walk those steps well enough that a backup admin or a hired MSP can run it.

## The rules
- **Reading never changes the tenant.** Opening, watching and reporting are reads (invariant 3). A fix is still a
  hand-off to its own screen's preview and typed confirmation (invariants 2 and 10). The incident model holds no
  executor (`WriteRouteTests`).
- **Code finds, code recommends, the model words.** As in the log reader. The model drafts the report's summary from
  the findings (never text an attacker wrote), shown as the model's and edited by the operator. With no model, the
  operator writes it. The log reader's Explain becomes this draft: the model has one job.
- **Status comes from the logs in time order**, never a switch the operator flips. Whoever acted (this app, the Admin
  console, Google), the logs say it.
- **Nothing is redone.** Opening an incident reads what already happened: Google's logs and this app's audit log. A
  step already done shows done, with its time and who did it. Steps taken outside both are notes with their own time.
- **The Keychain session stays as it is** (invariant 4: user presence, 10 minutes). A due check runs inside a live
  session, else it says it's due and runs on Touch ID. Watching runs only while the app is open.
- **Bounded** (invariant 9): at most 500 check entries per incident; evidence is saved when a check finds something,
  not on every check.
- **On this Mac only.** The record holds tenant data, so it is `0600` in a `0700` folder under Application Support,
  as the audit log is. Never in the repo; examples here use the mock's carol@example.com and 198.51.100.23.

## The incident record
One folder per incident, `~/Library/Application Support/SwiftGamGui/incidents/<id>/`: `incident.json` (the stores'
atomic `0600` write) and the evidence CSVs. The record holds only what a person says or the logs can't keep:
- opened: when, by whom (a name as typed); how it was reported (an alert, a person, a check) and when;
- type (the standard's categories, e.g. unauthorized access, investigation) and severity (high, medium, low), each
  defaulted from the findings and the operator's to change;
- the people affected and the suspect addresses (seeded from the findings, editable), and the window's start;
- notes, each with its own time, which can be earlier than now ("called the bank", "added an alert rule");
- "That was them": a person and address the operator says are the person's own, with a note. Shown in the report,
  never hidden, and undoable;
- check entries: when, automatic or by hand, and what was new, in a line;
- closed: when, by whom, and the sign-off note.

Everything else is computed when shown or reported, never copied: actions taken (this app's audit log, and the Admin
log for what was done in the Admin console), each person's status (the timeline), findings and recommendations (the
rules).

## What the logs say (new rules, in `LogReading`)
- **The lock, per person:** the Admin log's events done *to* the person (`CHANGE_PASSWORD`, `RESET_SIGNIN_COOKIES`,
  `REVOKE_3LO_TOKEN`, `REVOKE_ASP`, `DELETE_2SV_SCRATCH_CODES`, `SUSPEND_USER`) and Google's own
  (`account_disabled_hijacked`, `account_disabled_password_leak`, `user_signed_out_due_to_suspicious_session_cookie`).
  This app's audited lock counts at once, before Google's log shows it (the logs lag): slice 3, which reads the audit
  log for what's done. **Not a lock:** a password change from a suspect address, which is the attacker locking the
  owner out.
- **After the lock:** from a suspect address, a failed sign-in means the lock is holding and a successful one means
  they're still in. A sign-in from an address the person hadn't used before the first suspect event is said, to be
  recognised or marked "that was them": attackers change addresses.
- **Status:** each person is *affected, no lock seen in this window* / *locked at T, by whom* / *locked, and the
  attacker tried again and failed* / *signed in after the lock*. The incident is *identifying* → *contained* (every
  person locked) → *watching* (no sign-in after a lock) → *closed*.
- **What a lock leaves in place**, from a suspect address: a passkey enrolled (`passkey_enrolled`), a 2-Step
  Verification method added, a recovery email or phone changed. Each is a finding that says how to remove it.
- **Sessions a lock doesn't end:** a sign-in to another app through Google (SAML) from a suspect address recommends
  signing the person out of that app.
- **A read to add:** the Admin log for what was done to a person (today it's read with `userisactor`, what a person
  did as an admin). The mock gets an Admin log fixture from Google's event list.

## Slices
1. **Lock status from the logs.** The Admin log read, the rules above, each person's status in Read the logs.
   Live, read-only (L1): on an incident, which events GAM's reset and sign-out leave, and whether
   `report admin user P` reads what was done to P.
2. **Findings first.** The findings and statuses at the top; the raw logs folded under Evidence, drawn only when
   opened, in a lazy `Table`; the reading computed once per pull (today every redraw re-runs the rules).
3. **Open an incident.** Open Incident from Read the logs (seeded from the findings: people, addresses, a window from
   just before the first suspect event) and New Incident by hand (a person or an alert). The incident's header on
   the Incident screen: its status, each person's status, and what's done. ("That was them…" is built already: the
   record lists the marks.) The pull's
   CSVs saved as evidence at opening (the Gmail log reaches back 30 days only). **This picks up an incident in
   progress:** New Incident with its people and a start before the attack, and the logs and the audit log fill in
   the rest.
4. **The report.** Export Report: a PDF drawn from plain text (nothing an attacker wrote is read as markup) and the
   evidence CSVs, in a new `0700` folder. Its sections are the standard's list: when reported and how, type and
   severity, summary, status, every action taken (when and by whom), the people involved, the evidence (files
   listed), notes, next steps (open recommendations, checklist items not done) and a timeline. Its metrics: time to
   detect (first suspect event to opened), time to contain (to every person locked), accounts affected, emails pulled.
5. **Watch and close.** While open: Check Now, and a check every 4 hours, each reading the incident's people and
   addresses since the last check. Each adds an entry ("nothing new", or what's new); anything after a lock posts a
   notification. Close Incident takes a name and a note, which is the standard's sign-off. Watching stops.
6. **Look for trouble.** Identification with no incident: one button, every account's sign-ins over the last 3 days,
   findings only, and Open Incident from any of them.
7. **Narrow first, and how far a wide pull gets** (asked 2026-10-24: "Investigate leads with the narrow pulls (the
   reported account, then the attacker's addresses across everyone), and an every-account pull says up front how far it
   will get"). **Why:** a pull's cost should grow with the attack, not with the organisation. Every account's every event
   is hundreds of thousands a day in a large organisation's Gmail. The bound (200,000 events a log, 100,000 a day) then
   stops it after about a day, after up to 200 GAM calls. Each call writes the credentials to disk once (invariant 4),
   and every 200,000 events hold 350 to 430 MB and take 2 s (Release) to 11 s (Debug) to read back (PR #117). Narrow
   pulls stay small at any size, so they are also the safer reads.
   - **The order on Investigate**, said in its order of work:
     - (a) **The reported accounts** (up to 20; the form already starts with the person checked): every log, the
       window.
     - (b) **Each attacker address the reader found, across every account**: one pull per address, every account,
       the logs and window shown. Google applies `ip` before it counts, so this stays small at any size. It's a to-do
       item with a button, as Pull Again is (`LogReading.Task.pullsAgain`): code finds the addresses, the model only
       words them. The addresses are the reader's suspect addresses (`.suspectAddress`). An address set aside as likely
       shared (`.sharedAddress`: an office or a VPN) gets no button, because sweeping it is every account's events again.
       An address the operator marked as the person's own ("That was them") gets none either. An address is done when a
       saved pull of the open incident read every account from it. That is known from each saved pull's `about.txt`,
       never from the merged query, which keeps only the first address (`IncidentLogs.merged`). So an address is never
       swept twice.
     - (c) **Every account, every event**: last, and only when nothing narrower answers.
   - **How far it will get, said up front.** Before any read, the form says the bound in words when every account and no
     address are chosen. After each log's first read, the log says how far it will get. That first read is the one
     `IncidentLogs.complete` already makes of the whole window, so this costs no extra GAM call. A first read short of
     `ActivityLogs.cap` is whole, so there's nothing to say. At the cap:
     - The span of its events gives events an hour, and the read's own time gives the time each read takes.
     - Past `cap × readsPerDay` events a day, the log can't read even its first day whole, and it says so.
     - Otherwise it says how much of the window it will read whole (about `cap × readsPerLog` events' worth, oldest
       first), in about how many reads and minutes: "Gmail, every account: about 9,000 events an hour. It would read the
       oldest 22 hours of the 30 days in about 200 reads (about 25 minutes), then stop."
     - A log that can't be read whole waits, with **Read the Oldest 22 Hours** and **Narrow Instead**. The logs that fit
       go on. A log narrowed instead is said as not read, never as an empty log (as Export All says it).
     - The rate comes from the newest events and swings with the time of day, so the estimate is worked out again after
       each day is read whole (`Progress` already has the events and "whole through").
   - Tests with a stand-in read that keeps the window as Google does, as `aLogIsReadWholeOldestFirst` does: the mock's
     few fixed-date events never reach the cap. Live check (read-only): every account's Gmail for 30 days says an
     estimate, and where it then read through is near it.
   - Not in this slice: GAM's `gmaileventtypes` (GAM 7.30.05: it limits the event types "displayed", so it may filter
     after reading, not before). It needs a live check before a pull relies on it to be small.

Each slice: tests against the strict mock, screenshots from CI, a runbook section, the README's live rows.

## Not built unless asked
Watching with the app closed (nothing may unlock the Keychain without a person), sending a report anywhere, a cloud
model, IP lookups over the network, Admin console CSV import, several tenants at once, approvals inside the app, the
standard's contact list and escalation matrix (they belong in the written standard), totals across incidents, the
model setting a severity or a status.
