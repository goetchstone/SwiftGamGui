# Plan: an incident you can open, watch and report

**Status (2026-10-22): slice 1 built (#98: lock status from the logs; runbook: docs/domains/compromised-account.md,
"Where each account stands"). Then, from a real tenant's export: the reader's rules corrected (failure log 2026-10-22),
and "That was them" moved up from slice 3 at the operator's ask and built (runbook "That was them"). Then the rundown,
at the operator's ask after running a real incident through it: every account touched with its status and timeline, and
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
Then, from the real incident, the checklist's first piece: an email Phishing trashed from every mailbox shows done on
Respond, with when and by whom, from this app's audit log, and one Phishing's Find showed nobody here has, kept on this
Mac (runbook "Done from the audit log"; phishing.md D13, D14).
Next, in this order: the incoming phish, a pull anchored on the attack, and who to warn (and whether they were); the
checklist (done from the logs where they show it, else ticked by hand) and the report (slice 4); then slices 5 and 6.** Asked for: scan the logs, flag behaviour, recommend actions, use the
on-device model and the logs' own logic, open an incident from what the logs flag, watch it with log pulls that add
to it, and a report "sufficient documentation we can take to anyone". Required: **an incident already in progress is
picked up as it stands, without redoing a step.** Built on the Incident screen
([docs/domains/compromised-account.md](../domains/compromised-account.md)) and the log reader
([2026-10-19-on-device-log-reader.md](2026-10-19-on-device-log-reader.md)), on main once PR #97 (a person's Apps
Script projects) merges, as #96 (a person's computers) has: no stacked PRs.

## Why
After a real takeover the logs were read by hand several times and still couldn't answer "are they still in?" with
confidence. Google's alert came late. Nothing on the screen remembered what was done or said where the incident
stood, and there was no document to hand anyone. The operator's incident response standard follows the SANS six
steps (preparation, identification, containment, eradication, recovery, lessons learned) and lists what an incident's
record must hold. The screen should walk those steps well enough that a backup admin or a hired MSP can run it.

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
   Live, read-only (L1): on a real incident, which events GAM's reset and sign-out leave, and whether
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

Each slice: tests against the strict mock, screenshots from CI, a runbook section, the README's live rows.

## Not built unless asked
Watching with the app closed (nothing may unlock the Keychain without a person), sending a report anywhere, a cloud
model, IP lookups over the network, Admin console CSV import, several tenants at once, approvals inside the app, the
standard's contact list and escalation matrix (they belong in the written standard), totals across incidents, the
model setting a severity or a status.
