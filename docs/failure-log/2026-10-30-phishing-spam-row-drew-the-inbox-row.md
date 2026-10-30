# 2026-10-30 — Phishing drew alice's copy in Spam as her Inbox copy

- **Symptom** — Every CI picture of Phishing's results with copies in Spam (from 2026-10-24 on) listed alice twice under
  "2 mailboxes have a copy (4 copies in all, 1 in Spam)": both rows "1 copy" with the Inbox icon, none "1 copy in Spam".
  The screen never said whose copy was in Spam, and VoiceOver, which reads the row drawn, presumably heard alice's Inbox
  row twice (not measured). The headline, the CSV and Trash were right: Trash's rows have their own ids
  (`PhishingChanges.Trash.id`). Noticed while checking #141's pictures; `main`'s render had it too.
- **Cause** — `FoundSection` lists `withCopies` and `inSpam` as two `ForEach` in one Form section, both keyed by the
  address (`MessageCopies.Mailbox.id`, `SpamCopies.Mailbox.id`). Rows of two `ForEach` in one section with the same id
  came out as one: the Spam list's alice drew the copies list's (observed; why SwiftUI does it isn't known here). Two
  more lists there had the same shape (`copies.unusual`, a warning beside the same mailboxes, and `spamUnsearched`), and
  so did Incident's log pull: its progress rows (`id: \.self`, the application) share a section with the logs, whose id
  is the application (`IncidentLogs.Log.id`).
- **Why not caught** — Nothing reads what a picture shows (as on 2026-10-24), and the app has no view tests; the model's
  tests hold the CSV rows, not the rows drawn. The Spam rows were first rendered in a refresh of every picture at once,
  and each refresh since looked like the last.
- **Fix** — Each list beside `withCopies` keys its rows by what it lists as well as whose (`unusualRow`, `spamRow`,
  `spamUnreadRow`), and Incident's progress rows by `progressRow`. In the PR that adds this entry; its CI picture shows
  alice's row "1 copy in Spam" with the bin.
- **Prevention** — `pre-commit`'s screen items: every `ForEach` in one section keys its rows apart from the others'.
  No test reads a picture, so a screen that shows the wrong row still passes: nothing yet beyond the checklist and
  looking.
