# 2026-10-23 — Each pull re-read every saved pull, and the screen sat still while it read

- **Symptom** — On the pinwheel fix's build, the operator's 10-day pull for every account, with an incident open, looked
  frozen. Sampled by hand and then for 20 minutes, the main thread never blocked: the work was in the background. During
  the pull nothing moved for minutes (a log's "read through" line moved only once a whole day was read, and every-account
  Gmail takes a dozen or more reads a day). After it, the app ran at full CPU for about 15 minutes with the only sign
  "Reading the saved logs…" at the top of the screen, out of view.
- **Cause** — The pull's progress was told once a day, not once a read. And with an incident open, a pull that ended was
  saved to it, then `IncidentRecordView.showEvidence` read every export ever saved back from disk, parsed each CSV
  (`IncidentLogs.evidence` → `pull(of:)`), put them all together and showed that, so the log reader read the pull twice
  (alone, then with the evidence). Pull Again saved the whole merged evidence again as a new export. Each saved pull made
  the next one slower.
- **Why not caught** — The kept incident's runbook said it ("fine at a few, slow at many large ones"), left to a later
  slice. The tests' pulls are the mock's few dozen events, and nothing showed the work after a pull where the operator was
  looking.
- **Fix** — A pull is saved to the open incident before it ends (`IncidentLogs.keep`, `Incidents.add`), only what was
  read from Google, and added to the evidence shown in memory from the text just written (`IncidentLogs.adding`, the very
  step reading the exports back takes), so it ends once, as the evidence, and nothing saved is read again. It's read back
  whole only when a read-back could differ (`IncidentStore.readsBackLast`). Each log's progress is told after every GAM
  read (waiting, reading with its events and reads so far, done), and each step after the pull is said under the logs.
- **Prevention** — `CompromisedChangesTests.aPullAddedToAnIncidentIsWhatReadingItBackGives` (what Export All wrote is what
  the store reads back, and the evidence with it added in memory is the read-back's, row for row),
  `.aPullIsKeptBeforeItEnds`, `IncidentStoreTests.aNewExportReadsBackLastOnlyWhenItWould`, and
  `aLogIsReadWholeOldestFirst` (progress heard after every read). Lesson, with
  [2026-10-23-the-log-reader-stopped-the-app](2026-10-23-the-log-reader-stopped-the-app.md): "slow at many" written in a
  runbook is a failure waiting for a real incident's size; and work the operator waits on is said where they're looking.
