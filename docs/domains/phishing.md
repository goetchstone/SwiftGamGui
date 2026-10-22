# Phishing

**One line:** take one email out of every mailbox that has it, by its Message-ID, for a phishing email sent from a
compromised account. When a taken-over account Bcc's a phishing email, the operator can sign the person out and
reset the password in this app, but trashing the email everywhere meant going to Terminal. Find lists who has a copy, using GAM's own dry run, which is a read,
and beside it who has one in Spam, which the dry run can't see (D11). Trash moves those copies
to each person's Trash, where they stay for 30 days. It runs one ChangeCore step per mailbox (and one more per mailbox
with copies in Spam) and keeps the sender's Sent copy as evidence. Who it was addressed to, outside the domain first, is read from the sender's own copy
(its Bcc only when it was written in Gmail).
This is native: GamGUI has no builder for it; the recipients read is GamGUI's `search_messages`.

**Owns invariants:**
- #1: the Message-ID is validated as one value inside the one `query` element.
- #2: each mailbox's trash goes through ChangeCore. ChangeCore's only change is `.trashMessage`'s destructive
  floor.
- #3: the dry run is the one reviewed read with a destructive verb, and no read may carry `doit`.
- The strict mock's fidelity for `trash messages` (by query and by ID) and the Spam read (`all users print messages`).

**Enforcement home:**
- `NativeArgvTests`: the four argvs, the Message-ID's rule, the cap of at least 1, and each ID one element.
- `CommandKindTests`: `reviewedDryRuns` and `noReadCarriesDoit`.
- `MockPhishingTests`: the mock prints GAM's lines and fails as GAM fails.
- `MessageCopiesTests`: the lines are read and a partial list is refused.
- `SpamCopiesTests`: the Spam read's lines and rows; a partial read refused, a copy not plainly this email in Spam left
  alone.
- `PhishingChangesTests`: end to end through the executor.
- `WriteRouteTests`: only `ChangePreviewSheet.swift` confirms.

## Files
- `Packages/GamKit/Sources/GamEngine/GamChoices.swift`: `GamCommands.MessageID`, which validates the Message-ID
  and builds the query.
- `Packages/GamKit/Sources/GamEngine/GamCommands.swift`: `findMessageCopies` (the dry run, a `GamRead`),
  `trashMessage` (one mailbox, a `GamWrite`, `.trashMessage`), `findSpamCopies` (the Spam read) and `trashMessages`
  (one mailbox's copies in Spam by ID, `.trashMessage` too).
- `Packages/GamKit/Sources/GamEngine/MessageCopies.swift`: reads the dry run's lines into mailboxes.
- `Packages/GamKit/Sources/GamEngine/SpamCopies.swift`: reads the Spam read's lines and rows into mailboxes and IDs.
- `Packages/GamKit/Sources/GamEngine/MessageRecipients.swift`: the sender's copy's To, Cc and Bcc
  (`MessageRecipients`), and the tenant's domains and aliases (`TenantDomains`) for inside and outside.
- `Packages/GamKit/Sources/Directory/PhishingChanges.swift`: the model (find, preview, run, stop).
- `App/PhishingView.swift`: the screen.
- `App/ChangePreviewSheet.swift`: `PhishingConfirmSheet`.
- Wiring: `App/GamGUIApp.swift` (the sidebar's Phishing, and the quit guard) and `App/AppServices.swift`.
- `Tests/Fixtures/mock_gam.sh`'s "One email out of every mailbox" handler, its trash by ID, its Spam read (`all users
  print messages`), its recipients read (the `rfc822msgid:` branch of `print messages`), `mock_gam/messages.csv` and
  `mock_gam/message_headers/<id>`.
- `scripts/screenshots.sh`: the `phishing*` specs.

## What GAM 7.48.30 does
This is read from its source (`_processMessagesThreads`, its printers and `glmsgs`), not a tenant.
- **P1, without `doit` nothing changes.** GAM checks the arguments first. Then, for each user, it gets a token
  and lists matches (`messages.list`). It prints a count and `continue`s before any trash call. The max check
  comes before the `doit` check, so the dry run also reports a mailbox over the cap.
- **P2, a domain's exit code is the last user's.** `setSysExitRC` overwrites rather than keeps the worst. Each
  user sets one:
  - 60, no match (`NO_ENTITIES_FOUND_RC`);
  - 51, a count without `doit`, or over the cap;
  - 73, Gmail off;
  - 50, a failure.

  So an `all users` run is never 0 in a real domain, whatever happened. The dry run is read from its lines, and
  the trash runs one mailbox at a time, where 0 means trashed.
- **P3, `quick` caps the listing.** `quick` is the default, and with it `maxItems = max_to_trash`: Gmail is
  asked for at most that many. "Count N exceeds maximum" then can't happen, and a mailbox holding two copies
  under `max_to_trash 1` would quietly lose one and keep one. Only `notquick` counts every match.
- **P4, `max_to_trash 0` is no limit.** The default is 1.
- **P5, who `all users` is.** `isSuspended=False isGuest=False`, in address order. Suspended users aren't
  searched; archived users are.
- **P6, Spam and Trash aren't searched.** `includeSpamTrash` is set only for delete, modify and untrash, so a copy
  Gmail filed to Spam is neither counted nor trashed by query: `trash` has no `includespamtrash`. Until 2026-10-21 the
  app said so and left those copies; D11 reaches them.
- **P7, Gmail off.** GAM prints "User: x, Gmail Service/App not enabled", because Gmail's "Mail service not
  enabled" maps to `serviceNotAvailable`. A service account without the Gmail scope says the same for every
  user (`handleOAuthTokenError` → `userServiceNotEnabledWarning`).
- **P8, the words.** All of these go to stderr, with ` (i/n)` added when there is more than one user:
  - `User: x, Message: 1, Not Trashed: Use the "doit" argument to perform action` (the quotes are GAM's);
  - `Messages: 0, Not Trashed: No Messages matched`;
  - `Messages: 2, Not Trashed: Count 2 exceeds maximum to Trash 1`.

  With `doit`, stdout gets `User: x, Trash 1 Message`, then `  User: x, Message: <id>, Trashed`. A token
  refused for a non-user prints `User: x, User:, Trash Failed: invalid_grant: Invalid email or User ID`
  (live wording, GamGUI failure-log 2026-09-23).
- **P9, how GAM reads arguments.** Keywords are lowercased with `_` dropped (`getArgument`). The query is
  wrapped as `(Q)`. `max_to_trash` takes an integer ≥ 0.

- **P10, the sender's copy (`print messages … headers all showlabels showdate`).** This is
  `printShowMessagesThreads` / `_printMessage`. The CSV columns are `User,threadId,id`, GAM's default headers, and
  `LabelsCount,Labels`, then every other header name sorted (`SortTitles`). Each header is under its own name as
  the message has it ("Cc" or "CC"), a repeat as "To 1", decoded (`_decodeHeader`). `showdate` overwrites `Date`
  with the message's own time. `includespamtrash` finds a copy in Spam or Trash. No match sets exit 60, and the
  header line is printed anyway (also after a token or Gmail-off failure). With `showlabels` the labels are
  fetched first, so Gmail off fails there (73) before any list. Only the sender's copy can hold a Bcc header,
  and only when the message was written in Gmail: a mail client or a script sending over SMTP leaves Bcc off what
  it submits. `showdate` is in GAM's timezone, UTC on the app's fresh config.

- **P11, the Spam read (`all users print messages query "rfc822msgid:<id> in:spam" includespamtrash headers
  message-id showlabels`).** `printShowMessagesThreads`. Per user, in order: with `showlabels` the labels are read
  first, so Gmail off is `User: x, Gmail Service/App not enabled (i/n)` before that user's `Getting all Messages that
  match query ((Q)) for x (i/n)` (`show_gettings`, on in the app's fresh config); then the list, Spam and Trash
  included, and a get per message. A message's failure is `User: x, Message: <id>, … (j/n)`, numbered by message.
  The CSV is printed once every user is read: `User,threadId,id`, the asked header under its `SMTP_HEADERS_MAP` name
  (`Message-ID`), `LabelsCount,Labels` (names; a system label's is its ID, `SPAM`, `TRASH`). No `max_to_print` is no
  limit. Exit codes as P2 (60 for none, 73, 50).
- **P12, a trash by ID (`user x trash messages ids <a,b>`).** With `ids` nothing is listed, so Spam is no bar, and
  no `doit` or count applies. After `getProfile` (Gmail off: 73) GAM prints `User: x, Trash N Messages` and runs
  Gmail's `messages.trash` on each ID in a batch: `  User: x, Message: <id>, Trashed (j/N)`, or on stderr `  User: x,
  Message: <id>, Trash Failed: Does not exist (j/N)` for a missing one (Gmail's `notFound` through
  `_GMAIL_ERROR_REASON_TO_MESSAGE_MAP`), exit 50, the rest trashed.

## How it works (decided 2026-10-19)
- **D1, a Message-ID only.** Paste it bare, as `<id>`, as the `Message-ID:` header line, or as `rfc822msgid:id`.
  It is checked as RFC 5322 `id-left@id-right`, each side `dot-atom-text`. That form has no space, quote,
  parenthesis, colon, comma or backslash, so it can't end the Gmail term or start another operator. Gmail's
  `{ }` OR syntax is refused as well, and so are bracketed literals, non-ASCII and anything over 998
  characters. A free-form Gmail query is a broader tool and isn't built (see the end of this runbook).
- **D2, the query is `rfc822msgid:<id> -in:sent`.** The compromised sender's Sent copy (also an Inbox copy
  if they Bcc'd themselves, since it's one message) is left as evidence. Replies and forwards have their own
  Message-IDs and aren't touched.
- **D3, the dry run is a reviewed `GamRead`, not a held write.**
  - It changes nothing (P1).
  - Its per-user lines are the result, and ChangeCore reduces a non-zero step to one message (P2).
  - A held write would need a confirm just to look, and would audit a look as a change.
  - `CommandKindTests.reviewedDryRuns` holds it: the verb is destructive and the argv has no `doit` element.
    `noReadCarriesDoit` holds every read.
- **D4, the run is one ChangeCore step per mailbox Find showed copies in, not `all users … doit`.** The brief
  asked for the domain-wide command. It would always report "failed" (P2) and lose the per-user lines. Its
  held preview would name "all users" instead of the mailboxes, and it would search again at run time. Per
  mailbox:
  - the preview lists exactly who is trashed;
  - the audit has one begin and one end record per mailbox;
  - Stop works between mailboxes;
  - an account-wide failure stops the rest;
  - ChangeCore needs no new path.

  The cost is one `gam` per mailbox, about a second or two each.
- **D5, `notquick max_to_trash <copies found>`.** Without `notquick`, P3 applies. The cap is that mailbox's
  count from Find, so a run never trashes more than its preview showed: a mailbox holding more by then fails
  with GAM's "exceeds maximum". `trashMessage` refuses a count below 1 (P4).
- **D6, the confirm.**
  - The number of steps is typed (`typedCountAbove: 0`): the mailboxes, plus one for each with copies in Spam
    as well (D11).
  - From ten mailboxes, the guard's destructive-bulk rule asks for the word `confirm` too.
  - Over 200, the guard's hard-cap warning shows.

  The executor checks all of these, not only the sheet.
- **D7, trash, not delete.** Each copy is recoverable from the person's Trash for 30 days. Nothing in the app
  untrashes yet (see "To undo").
- **D8, after a run the search is dropped.** Its counts are from before the run. Find Again shows what's left.
- **D10, the lists as CSV (operator, 2026-10-19).** "Export CSV…" saves who has a copy (mailbox, found, copies,
  in Spam, and once a trash has run, each step's outcome) and who it was sent to (address, outside or inside, its header;
  unreadable pieces as they are). The rows are built in the model from what the screen shows
  (`PhishingChanges.copiesRows`, `recipientsRows`), and tests hold them to it. They are written as the Audit
  export writes: a save panel with a dated name, Python's `excel` dialect, `csv_safe`'s quote before a formula
  lead, and a hidden 0600 file beside the destination renamed over it once whole: the one private writer,
  `AuditExport.csv` and `writePrivately`, which the Audit export and the incident logs use too.
- **D9, who it was sent to.** This is added from real use: the operator needed the outside recipients to
  warn them.
  - It reads the sender's copy (GamGUI's `search_messages`, detail Headers, `max_to_print 50`) with
    `rfc822msgid:<id>`, Sent included, and then `print domains` to sort the addresses.
  - The tenant's domains and their aliases count as inside; the rest is outside. Outside comes first, with a
    Copy button.
  - Every To, Cc and Bcc address is read as RFC 5322 `address-list`. A display name, a comment and a group's name
    are never taken for the address, and a piece with an `@` but no address is shown under "check by hand",
    never dropped.
  - A copy the sender received rather than sent (no SENT label) is said to be one: it has no Bcc.
  - It never claims to be everyone. A sent copy without a Bcc header says that a mail client or a script leaves Bcc
    off. Mailboxes Find saw a copy in that the headers don't name are listed: they prove the list is incomplete
    (a Bcc not kept, or a group). Google's own record (Admin console › Reporting › Email Log Search) is always
    named, and no check mark is ever shown for "nobody outside".
  - No copy left is said in words, with the same pointer to Google's record.
  - Both are reads.

- **D11, copies in Spam (2026-10-21).** A pull by query leaves the copies Gmail filed to Spam in people's mailboxes,
  where they can still be opened (P6). Find now also runs the Spam read (P11) at the same time as the dry run, and
  Trash adds, for each mailbox with copies there, `trashMessages` naming exactly those IDs (P12).
  - The dry run and its query trash are unchanged: the Spam read is added beside them, never in their place.
  - `SpamCopies` keeps a copy only when its labels say `SPAM` and not `TRASH`, its `Message-ID` header is exactly
    `<id>`, and its ID is one element GAM can be handed back. Anything else leaves that mailbox unsearched in Spam,
    with why, never clear. A copy in Trash is skipped.
  - It refuses a read that isn't whole, as `MessageCopies` does: every user GAM listed accounted for by a "Getting"
    line or a failure line, ` (i/n)` covering 1…n once, no row for a user it didn't report, no output past the cap.
  - A failed Spam read is said beside the rest and never blocks the trash of the copies outside Spam.
  - By ID, a run trashes exactly what its preview showed: a copy that arrived in Spam since is left, and one gone
    since fails that step in GAM's words.
  - A mailbox with copies in both places has two steps; the screen says "mailboxes" and the sheet says "steps" when
    the two counts differ.

## Gotchas / mock-lies traps
- The mock models only the query the app sends, matching the ID exactly. Whether Gmail's `rfc822msgid:`
  matches case-insensitively or by part isn't modelled. The live check must show it finds the one email
  (D5's cap limits what a broader match could trash).
- The mock's "Got N Users" progress line is approximate. A reader skips every progress line anyway.
- A suspended user as a run target isn't modelled: Google's wording is unknown. Find never lists one (P5).
- The mock's recipients read answers only the screen's exact search (Headers detail and an `rfc822msgid:` query)
  and only for messages whose headers it has (alice's, carol's). Any other shape is "not modelled", and other
  `print messages` reads keep the older canned answer.
- `MessageCopies` refuses a list that isn't whole: an exit code no per-user line sets, an account-wide failure
  line, output past the 8 MiB cap, or a ` (i/n)` count that doesn't cover 1…n once each. An unknown line is
  shown under "GAM also said", never guessed at.
- **Not seen live, for the Spam read and the trash by ID:** whether `in:spam` with `includeSpamTrash` lists only Spam
  (the reader checks the `SPAM` label anyway); whether `messages.trash` drops a copy's `SPAM` label (the mock keeps it
  beside `TRASH`, so the reader must skip a copy in Trash either way); whether trashing a copy already in Trash
  succeeds (the mock says yes); and Gmail's exact words for an ID that's gone (the mock's are GAM's map, "Does not
  exist").

## Review (2026-10-19, gam-command-reviewer, before merge)
No injection, chokepoint, credential or cap break was found. Fixed before merge:
- **F1, Find failed open.** A per-user line in words the parser didn't know was set aside, so an empty list read
  as "no copies". Now an unknown user's line is that mailbox `.failed` (unsearched), never clear. The reader
  checks GAM's own count of users (`Got N Users...`), refuses a search that reports nobody, and the headline
  says how many mailboxes couldn't be searched (F6).
- **F2, the token refusal's wording.** GAM 7.48.30 prints `User: x, User Trash Failed: …` (`formatKeyValueList`
  with a `None` value; the live onboarding capture agrees), not the shared helper's `User:, Trash Failed`. Both
  readers take both forms; this screen's mock branches print GAM's (`token_refused`). The shared helper is a
  follow-up.
- **F3, one user's `invalid_grant` read as the admin's expired sign-in.** Account-wide is now judged only from
  lines that aren't a user's. The admin's expired sign-in fails the listing of users itself.
- **F5, nothing showed what the ID matched.** Find now reads one copy (From, Subject, Date) and shows it, and the
  confirm sheet repeats it. A mailbox with more than two copies is flagged. `*` is refused in an ID.
- **F8, the review is tied to a version.** `CommandKindTests.reviewedDryRuns` names the GAM version, so a bump
  fails until GAM's source is read again.
- **F9, a race.** A held trash that finishes after a newer Find began is discarded.

Second pass, on the fixes and the recipients read (all fixed before merge):
- **R1, the list claimed to be complete.** A message sent over SMTP (an app password, a script) keeps no Bcc
  header in its Sent copy, so "everyone it went to is listed here" and a check mark for "nobody outside" could hide
  every outside recipient. Now nothing claims completeness (D9).
- **R2, the address reader dropped addresses.** A piece naming two addresses (`a@x b@y`, `<a@x> <b@y>`) kept only
  the last. A semicolon now ends an address too, and a piece naming more than one distinct address is kept whole
  as unreadable.
- **R3, an all-clear despite unreadable addresses.** Withheld.
- **R4, unverified domains counted as inside.** Only verified domains and aliases count.
- **R5, one heading.** Every distinct From and Subject among the copies is kept, and more than one is flagged.
- **R6:** exit 0 with no row isn't "no copy" (only GAM's 60 is). The fixtures' times are UTC, as GAM prints them
  on a fresh config.

Third pass, on the copies in Spam (2026-10-21, four lenses and a skeptic each; all fixed before merge):
- **S1, a user label with a space hid a copy.** GAM joins label names with a space, so a Spam copy carrying a label like
  "Old TRASH" read as already in Trash and its mailbox as clear. Labels are now told apart only when their words are as
  many as GAM's `LabelsCount`; otherwise that mailbox is unsearched.
- **S2, the sender's Sent copy.** The Spam read had no `-in:sent`: a Sent copy Gmail filed to Spam would have been
  trashed. A copy labelled `SENT` is now kept, as D2 keeps it.
- **S3, no sample when every copy is in Spam.** Find now reads the sample from a Spam copy when there's none elsewhere.
- **S4, Stop said "mailbox".** It stops between steps, and a mailbox's Spam step runs after every mailbox's other step:
  the run, the quit alert and the confirm sheet now say so.
- **S5, "No copy" where Spam wasn't checked.** Those mailboxes are listed apart, as "no copy outside Spam".
- **S6, the confirm's wording.** The count cap is said only for the copies outside Spam, and the over-200 warning counts
  mailboxes, not steps.
- **S7, the mock.** A trash by ID as a suspended user isn't modelled (as by query), and a word GAM takes after `ids` is
  "not modelled", never GAM's invalid argument.

Left as follow-ups: the shared mock helpers' older wording (`not_a_user`, `invalid_arg`, the sweep's "Got N Users:
a - b"), which other suites and GamGUI's `gam_errors.json` rely on.

## Testing / live-verification status
**Not yet** (README). The live check, each write with the operator's own yes for that action
(`live-verify`):
1. The operator sends a test email from one of their own test accounts to two others.
2. Find, by its Message-ID, and List Recipients for the sender. Both are reads, run once the operator says go.
   Also Find with the ID one character short: it must find nothing, which shows `rfc822msgid:` matches exactly.
   Before Find, mark one test copy as spam in Gmail: Find must list it under Spam, by itself.
3. Trash, from those test mailboxes only.
4. Find Again: no copy is left, in Spam either, and the sender's Sent copy stays.
5. Put one copy back from Trash in Gmail.

Never a real person's mailbox without their yes.

## To undo
In Gmail: Trash › Move to Inbox. With GAM: `gam user <email> untrash messages query "rfc822msgid:<id>" doit`
(untrash searches Trash, P6). An Untrash for the same mailboxes is a natural next slice if the operator wants it.

## To do common tasks here
- **Several Message-IDs at once, or by sender and day** (operator). One phishing run can span many
  Message-IDs: several mass sends, colleagues' forwards and replies carrying the same link, and the outside
  email that started it. One Find over a list of IDs (each validated, then one `query` per ID or one OR'd query),
  or over `from:<sender>` and a day, would replace the pastes. A sender-and-day search widens what can be trashed,
  so it needs Find's sample to show every distinct email it matched.
- **A Gmail search instead of a Message-ID** (`from:`, `subject:`), for an attack that sent many different
  emails: that needs its own validated type, and a mock that models those operators' meaning. Keep each
  mailbox's cap at what Find showed.
