# Screenshots

Rendered by CI from a demo domain and the test mock of GAM (`scripts/screenshots.sh`), so every name is made up.
`scripts/refresh_screenshots.sh <run-id>` replaces them all from one CI run.

| Home | Users | Setup |
|---|---|---|
| ![Home: the connected domain, GAM's version and the directory's counts](screenshots/home.png) | ![Users: the directory as a table](screenshots/users.png) | ![Setup: the domains on this Mac and a failed check of delegation](screenshots/setup.png) |

A person's page, opened from Users: an Actions menu for what changes the account, and tabs.

| Profile | Groups | Mail |
|---|---|---|
| ![A person's profile: title, department and details](screenshots/person-profile.png) | ![A person's groups, each with Remove, and a field to add one](screenshots/person-groups.png) | ![A person's auto-reply, with Change and Turn Off, and their mail delegates](screenshots/person-mail.png) |

| Calendar | Security |
|---|---|
| ![A person's Calendar tab: who can see their calendar, each with Remove…, an access level and a field to share it](screenshots/person-calendar.png) | ![A person's security: admin role, 2-step verification and recovery email, and their Chrome profiles checked: each computer, system, Chrome and when it was last used](screenshots/person-chrome.png) |

Groups: the domain's groups, and a group's members, owners first, with Add Members… and a Remove… for
each member.

| Groups | A group's page |
|---|---|
| ![Groups: the domain's groups by name and address](screenshots/groups.png) | ![A group's page: its description, Add Members…, and its members, owners first, each with Remove… and a nested group with Show Group](screenshots/group-sales.png) |

Calendars: the rooms, and a person's calendars with who has access to each; a calendar is shared with a
person, or their access taken away, from its page. Signatures: one person at a time, their current signature
beside the new one, each rendered or as HTML.

| Calendars | A person's calendars | Signatures |
|---|---|---|
| ![Calendars: the rooms, by name, address and kind](screenshots/calendars.png) | ![A person's calendars, and Team Calendar's page: a field to share it, the access level, and who has access, each with Remove…](screenshots/calendars-alice.png) | ![Signatures: the current signature and the new one from a saved template, each Rendered or HTML](screenshots/signatures-alice.png) |

Onboard: one new hire from a role, and the one-time sign-in card. Offboard: a leaver's offboarding from a
saved template (Hand-over by default), and every step's exact command before it runs.

| Onboard | The sign-in card | Offboard | Its plan |
|---|---|---|---|
| ![Onboard: the new hire, their role, its checklist, org unit, signature and groups](screenshots/onboard.png) | ![The sign-in card after the account is made, made-up password, and each step's result](screenshots/onboard-result.png) | ![Offboard: the template, the leaver and manager, and the steps, the lock's three marked Always runs](screenshots/offboard.png) | ![The plan: each step, what it does and its exact gam command](screenshots/offboard-plan.png) |

Reports: the people behind each of the directory's counts, the storage and mail usage, and every account's connected
apps and AI agents. Audit: this app's audit log, searched, paged and exported to CSV.

The jobs tray, in every window's toolbar: each change run since launch, running first, with where it stands, its newest
steps and failures in words, and Stop.

| Jobs |
|---|
| ![The jobs tray: an offboarding running with its progress and Stop, and a pull from every mailbox ended with two failed](screenshots/jobs.png) |

| Reports | Usage | Audit |
|---|---|---|
| ![Reports: each directory report with its count, and the people without 2-step verification](screenshots/reports.png) | ![The storage and mail usage: the top people by storage, with the day the counts are for](screenshots/reports-usage.png) | ![Audit: the log's records, each with its outcome in words, and a page at a time](screenshots/audit.png) |

Incident: an account taken over, in the order it's worked. Pull Incident Logs reads the logs by account or by the
attacker's address; Read the logs says what they show and drafts each fix; Secure an account runs the lock, every step
a switch, with what you tick undone, once you've typed the person's address.

| Incident | Read the logs |
|---|---|
| ![Incident: its Investigate, Respond and Report tabs, the incident kept on this Mac, and the logs to pull](screenshots/compromised.png) | ![Read the logs: each finding in words, with its fix as a button: secure the person, or pull the email from every mailbox](screenshots/compromised-reading.png) |

| Securing an account | Still to do, and done |
|---|---|
| ![Respond: what the check found worth looking at first, scheduled emails first](screenshots/compromised-plan.png) | ![Respond: where each account stands, what's left to do, and the emails already pulled](screenshots/compromised-todo.png) |

Who it reached: for each email the attacker sent, every recipient the Gmail log names, whether it was received, bounced
or only sent, whether a warning you pick reached them, and Export CSV… for the list. It reads only.

| Who it reached |
|---|
| ![Everyone the attacker's emails got to, once each, with Copy Addresses and Export for Import, above Who it reached](screenshots/compromised-reached.png) |

Where it started: what the first account taken over received from outside before the attack, the vendor's email marked as the
phish, and who else here received it.

| Where it started |
|---|
| ![Where it started: the vendor's email marked as the phish, and who else received it](screenshots/compromised-origin.png) |

The incident report, on Report: the numbers, each opening the list behind it; what was done, each step with the record
that shows it; the attacker's emails; and the review with the meeting's agenda. Export Report… saves it as a PDF with its
lists and a fingerprinted copy of the evidence.

| The incident report |
|---|
| ![The incident report: its numbers, what was done, and the review](screenshots/compromised-report.png) |

Phishing: one email out of every mailbox. Find Copies lists who has it, by its Message-ID, and changes nothing;
List Recipients reads who the sender sent it to, outside the domain first; Trash shows each mailbox it will move
a copy from, its Spam included, and runs with their number typed.

| Phishing | Who it was sent to | Its confirm |
|---|---|---|
| ![Phishing: the Message-ID, and the mailboxes that have a copy, each with its count, and those with one in Spam](screenshots/phishing-found.png) | ![Who it was sent to: the addresses outside the domain, with Copy, and those inside](screenshots/phishing-recipients.png) | ![The confirm sheet: each step, a mailbox or its Spam, the commands, and their number to type](screenshots/phishing-confirm.png) |
