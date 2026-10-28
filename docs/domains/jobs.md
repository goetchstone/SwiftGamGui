# The jobs tray

**One line:** every write run since launch, listed from any screen as it starts, as each step ends and as it finishes, with
Stop: GamGUI's jobs tray (plan U5). Plan §12 phase 3's Jobs, slice 1.

**Touches** invariant 2 (it adds no write path: Stop only asks the executor to stop after the step in flight) and 9 (bounded).

## Files
- `Packages/GamKit/Sources/Jobs/Jobs.swift`: `JobEvent` (what the executor reports), `Job` (one run: counts, the newest
  steps, the first failures, where it stands in words), `JobBoard` (the runs since launch, `@MainActor @Observable`, fed in
  order through an `AsyncStream`; `stop`; the tray's rows).
- `ChangeCore.swift`: `Executor(jobs:)` reports each `execute`: `started` (a fresh job ID, the preview's ID, its title, the
  steps it will decide), a `step` beside the existing `progress` yield (`Executor.jobStep`), `finished` on the way out.
  `HeldPreview.title`: the screen's (`Executor.preview(title:)`: Offboarding and Onboarding name theirs), else
  `Executor.title(of:)` from the steps (linear, for a run of thousands). One change to what the executor does: a stopped run,
  like a cancelled one, parks nothing for a retry, so a Stop also ends Onboarding's wait for Google (review 2026-10-28: the
  tray gave every run a Stop, and a stopped onboarding's waiting signature was still retried 20 seconds later).
- `App/JobsView.swift` (the toolbar button, the tray, a row, a step), `App/AppServices.swift` (the board made before the
  executor, which reports into `board.report`; `stopRun` set after), `App/GamGUIApp.swift` (the toolbar item, a spoken line
  when a run ends, the snapshot demo).
- Tests: `ChangeCoreTests/JobsTests.swift`.

## How it works
- **Every run is a job**, a one-step change too: the tray is "what ran since launch", and Audit stays the full record. A run
  refused before its first step (unconfirmed, expired, another tenant, a target in flight) is no job: nothing ran. A retry
  round (Onboarding's wait for Google) is a job of its own, of the steps still waiting, titled "(waiting for Google, try N)".
- **Bounded as GamGUI's registry** (`web/jobs.py`): the full counts, the newest 12 steps (`window`), the first 200 failures
  (`failedCap`, "and N more" past it), each reason cut to 300 characters (`detailCap`: GAM can echo a whole body), the newest 10
  finished runs (`finishedKept`, pruned as each ends; a running one never goes), 8 rows in the tray, running first.
- **Stop** asks first ("Stop After This Step"), then `Executor.stopAfterCurrentStep` for the job's preview: the step in flight
  finishes, with its end record, and the rest read "Not run: stopped." It's every job's (GamGUI asked first only for
  offboarding; here every Stop can leave a run part done, and the dialog says so). The row says "Stopping…" until it ends.
- **Retry stays on the screen that ran it** (a deliberate difference from GamGUI's per-kind retry from the job): Offboard's
  Preview the Rest and Onboarding's retry already make a new preview of what's left, with the checks their screen wraps around
  it (the precondition, the typed address). A generic retry from the tray would run steps without those. The tray says where.
- Ordered: the executor's events go through one stream to the main actor, never a Task each (which could land out of order).
- A run's end is spoken from the window in front ("Finished: …") by the toolbar button, watching the board's counters
  (`running`, `finishedCount`, `lastFinished`): a step redraws only the tray, never the window (review 2026-10-28).
- **Reaches no write** (`WriteRouteTests.theJobsTrayReachesNoWrite`): the Jobs module has no dependency, its screen imports only
  it and SwiftUI, and only `AppServices` sets `stopRun`.

## Not built yet
- The bulk runs GamGUI has (onboarding from a CSV, a department for many, a signature for a scope): each will run through the
  executor and so appear here, with its own retry of what failed. Build each only when the operator asks.
- A job's page of its own: the tray's row opens to its steps; the screen that ran it has the whole panel.

## Testing
`swift test --package-path Packages/GamKit --filter JobsTests`: a run's events in order against the strict mock, a refused run
no job, Stop from the board after the step in flight, the bounds and the tray's order. The tray's look: the `jobs` snapshot.
