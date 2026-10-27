# Live verification

What this app has run against a real Google Workspace domain. Each write is listed here. **argv-identical** means it sends exactly the command a GamGUI write
already proven live sent; **confirmed** means this app has itself run it against a real tenant.

| Write | Status |
|---|---|
| Title and department (Users) | **confirmed** (2026-10-09) |
| Suspend and unsuspend (Users) | **confirmed** (2026-10-09) |
| Remove from a group (Users) | **confirmed** (2026-10-09) |
| Add to a group (Users) | **confirmed** (2026-10-13; the same command as Groups' add as member) |
| Add a mail delegate (Users) | **confirmed** (2026-10-09) |
| Remove a mail delegate (Users) | **confirmed** (2026-10-10) |
| Turn on or change an auto-reply (Users) | **confirmed** (2026-10-09) |
| Turn off an auto-reply (Users) | **confirmed** (2026-10-10) |
| Sign out of all sessions (Users) | **confirmed** (2026-10-09) |
| Set a temporary password, changed at next sign-in (Users) | not yet: new to both apps |
| Set the phone a signature shows (Users) | **confirmed** (2026-10-24; a shared office number, new to the person) |
| Change or remove the phone a signature shows (Users) | not yet: new to both apps |
| Set signature (Signatures) | **confirmed** (2026-10-13) |
| Add people to a group as members (Groups) | **confirmed** (2026-10-13) |
| Add people to a group as managers or owners (Groups) | not yet: never run live in either app |
| Remove a member (Groups) | **confirmed** (2026-10-13) |
| Share a calendar with a person (Calendars) | argv-identical |
| Put a shared calendar in their list (Calendars) | argv-identical |
| Share their own calendar (Users) | **confirmed** (2026-10-13) |
| Remove someone's access to their own calendar (Users) | **confirmed** (2026-10-13) |
| Remove someone's access to a calendar (Calendars) | GamGUI's command, which GamGUI never ran live either |
| Create an account (Onboard) | argv-identical |
| Task checklist: a task list and its tasks (Onboard) | argv-identical |
| Subscribe to a calendar (Onboard) | argv-identical |
| New-account wait: retrying what Google wasn't ready for (Onboard) | never run live (in GamGUI either) |
| Welcome email (Onboard) | GamGUI's command (sent live 2026-09-30), but the body keeps its line breaks: never run live |
| Offboarding: reset password, sign out, forwarding off, delegate, auto-reply, transfer, calendar sweep (Offboard) | **confirmed** (2026-10-16; GamGUI ran all eight live, 2026-10-07) |
| Offboarding: the manager's reminder with an invitee (Offboard) | **confirmed** (2026-10-16): the invitee got the email |
| Offboarding: clear recovery email & phone, hide from the directory (Offboard, added steps) | **confirmed** (2026-10-16) |
| Offboarding: hand over secondary calendars (Offboard, added step) | not yet: new to both apps |
| Offboarding: remove filters that forward (Offboard, added step) | not yet: new to both apps |
| Offboarding: turn off IMAP, turn off POP (Offboard, added steps) | **confirmed** (2026-10-16) |
| Compromised account: reset, sign out, forwarding off, IMAP and POP off, clear recovery (Compromised) | **confirmed** (2026-10-19): run from this screen, each step exit 0 in the audit log; the same commands' effect checked on Offboard (2026-10-16) |
| Compromised account: delete the ticked filters (Compromised) | not yet: Offboard's filter command, also not yet live |
| Compromised account: remove a delegate (Compromised) | not yet from this screen: Users' command, confirmed there (2026-10-10) |
| Compromised account: remove a send-as address (Compromised) | not yet: new to both apps |
| Compromised account: delete drafts, all or by subject (Compromised) | not yet: new to both apps |
| Compromised account: list and delete the emails scheduled to send (Compromised) | not yet: new to both apps; prove it on a test email you schedule to yourself |
| Compromised account: Check Account and Pull Incident Logs (Compromised; reads only) | **confirmed** (2026-10-19): Check Account before each of those runs, and Pull Incident Logs since |
| Pull Incident Logs: a log at the 1,000-activity cap read further back, up to 10 reads (reads only) | not yet: new to both apps |
| Search a mailbox (Users, Mail; reads only) | not yet from this screen: GamGUI's search |
| Chrome's log by profile, and a person's Chrome profiles (Compromised, Users' Security tab; reads only) | not yet: new to both apps |
| Read the logs: findings, drafted fixes, the on-device model's explanation (Incident; changes nothing) | not yet: new to both apps |
| Incident: turn off the auto-reply; any lock step alone (Incident) | not yet from this screen: Users' auto-reply off, confirmed there |
| Incident: the phones and tablets syncing an account (reads only) | not yet: new to both apps |
| Incident: the computers signed in with an account (reads only; needs the Cloud Identity devices scope) | not yet: new to both apps |
| Read the logs: a device registered at a sign-in from a suspect address | not yet: new to both apps |
| Incident: a person's Apps Script projects (reads only) | not yet: new to both apps |
| Incident: a person's connected apps and AI agents, and who acted on each log row (reads only) | not yet: new to both apps |
| Reports: every account's connected apps and AI agents, its summary, and the on-device model's wording (reads only) | not yet: new to both apps |
| Read the logs: where each account stands (the lock from the admin log), what a lock leaves in place (reads only) | partly: the lock's admin events seen in real exported logs (2026-10-22); the reader not yet run live |
| Read the logs: That was them (marks a flagged sign-in as the person's own; this Mac only) | not yet: new to both apps |
| Incident: a kept incident, made from an export, its saved logs read back after a relaunch (reads; this Mac only) | not yet: new to both apps |
| Incident: Show the Events and Pull Again on the to-do items (reads) | not yet: new to both apps |
| Incident: Who it reached: every recipient, received or bounced, the warning picked, Export CSV (Respond; reads only) | not yet: new to both apps (L3w in the compromised-account runbook) |
| Incident: Pull Incident Logs read whole, oldest first, with Read the Rest (reads) | not yet: new to both apps |
| Incident: Where it started: the vendor's email listed with its sender, picked, who else here received it (Investigate; reads only) | not yet: new to both apps (L3o in the compromised-account runbook) |
| Incident: Pull Every Account From the attacker's address, and a wide read's estimate (reads only) | not yet: new to both apps (L1n in the compromised-account runbook) |
| Read the logs: each account's timeline and Still to do (reads only) | partly: run over real exported logs (2026-10-22), not yet in the app live |
| Incident: block a computer, or take the account off it (Incident) | not yet: new to both apps |
| Read the logs: Do It Here on a to-do item (opens the plan with only that fix picked) | not yet: new to both apps |
| Trash an email from each mailbox that has it (Phishing) | ran live (2026-10-19 and 2026-10-23), each step exit 0 in the audit log; a copy in Trash not yet seen in Gmail |
| Find and trash the copies of an email in Spam (Phishing) | not yet: new to both apps |

The Groups rows are checked on a scratch group the operator owns, with throwaway members or the
operator's own account, never someone's real group without their yes.
