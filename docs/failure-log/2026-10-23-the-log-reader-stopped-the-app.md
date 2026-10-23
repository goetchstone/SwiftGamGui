# 2026-10-23 — The log reader stopped the app for minutes after a whole pull

- **Symptom** — During a real incident, the operator added the Gemini log to a pull (Pull Again) and the app showed the
  spinning wheel for minutes, with no `gam` running. `sample` of the running app (a Debug build) put almost every
  main-thread sample in `LogReaderView.body` → `LogReading.read` → each account's `status`; it ended by itself, after
  about 4½ minutes of CPU.
- **Cause** — Three things together. The reader ran in the view's `body`, on the main thread (cached once per pull,
  but the first reading blocked the window for as long as it took). It scaled as accounts × events: every account the
  attacker touched had its status worked out from every event of every log, several passes each, twice (the `held`
  pass), plus a pass each for its "Show the Events" addresses and its printed contacts. And #107 ("read whole, oldest
  first") made a pull of 10 to 30 days for every account hold hundreds of thousands of events where it used to hold a
  capped few thousand. The pull's own work ran on the main thread too: each read's CSV parse (`UserAccess` is
  `@MainActor`), its paging, repeats dropped and sorts (`IncidentLogs`' statics were main-actor isolated), Pull Again's
  merge, and the CSVs saved to an open incident.
- **Why not caught** — The tests read a few dozen events, where accounts × events is nothing. Nothing measured the
  reader at a whole pull's size, and #107's change to the pull's size never looked at what reads the pull after.
- **Fix** — `LogReading.Accounts` indexes each account's events once (its own, and the admin's done to it); `status`,
  its timeline, a device's latest word, the printed contacts and a recovery detail removed read only those, and the
  suspect addresses' and the device rule's sign-ins are grouped once. Every per-account rule already filtered on the
  account or the admin's `USER_EMAIL`, so the results are identical: held byte for byte against the old reader's output
  for about 1,200 generated incidents × 3 contexts, and for a 200,000-event pull (old 22.7 s, new 2.2 s, Debug, 40
  accounts). The reading runs in a background task, once per pull, shared by Investigate and Respond, with "Reading the
  logs (N events)…" meanwhile. Each read's parse, the paging and sorting (`IncidentLogs.read` is `@concurrent`), Pull
  Again's merge, saving a pull to the open incident, and Export CSV and Export All run off the main actor. The Read the
  logs snapshot waits for the reading (`Spikes.snapshotWork`) and scrolls to the findings once they're drawn: its scroll
  had stopped landing, issued in the update that first drew them.
- **Prevention** — `LogReadingTests.anAccountsStatusReadsOnlyItsOwnEvents` (a rule that reads more about an account
  than `Accounts` holds fails it) and `aWholePullIsReadInSeconds` (80 accounts among 200,000 events within 20 seconds,
  where reading every event per account would take about 45). Lesson: a change that makes the data bigger (#107) checks
  what reads it next, at the new size; and nothing proportional to a pull runs in a view's body or on the main actor.
