# 2026-11-28 — A cut-off gam left its worker processes running, credentials loaded, and the run waited them out

- **Symptom:** found by GamGUI reading GAM's source for its scale work (`MultiprocessGAMCommands`, `doAutoBatch`; GamGUI
  #197); never seen live here. A cut-off (a timeout, a cancel, `stopAll` at quit) signalled gam's own pid only. GAM's
  parallel loops fork a pool of workers that each load the credentials: `csv` (roadmap 5.4's fast signature write),
  `batch` and auto-batch. Those workers ran on with their tokens in memory while `EphemeralConfig` wiped the directory, and
  could keep making calls. They also hold gam's stdout and stderr, so the drains waited for them: a "timed out" run went on
  to its end. The stand-in tests hung for their worker's whole 600 s.
- **Cause:** `GamRunner` was written for one gam process per call; `kill(pid, …)` reaches that one process, and nothing put
  gam in a process group of its own, so its workers couldn't be signalled together.
- **Why not caught:** the mock is one shell process per call, and its `csv -` loop (`mock_gam_loops.py`) runs each row in
  turn, not a pool. No test cut off a gam that had children.
- **Fix:** gam is spawned as the leader of its own process group (`POSIX_SPAWN_SETPGROUP`); every cut-off signal goes to the
  group (`signalGroup`, `killpg`). And when gam exits, before it's reaped (`waitid … WNOWAIT`, so its pid, the group's id,
  can't be anyone else's), whatever is left in its group is killed: stronger than GamGUI, which kills the group only on a
  cut-off, so a worker gam leaves behind can't outlive its run either.
- **Prevention:** `RunnerTests`' `aTimeoutStopsGamsWorkersToo`, `aCancelStopsGamsWorkersToo` and
  `whatGamLeavesRunningWhenItExitsIsStopped` run a stand-in gam that forks a 600 s worker: each run must return within 60 s
  and the worker must be gone. Without the fix each hangs on the worker. Not proven on real GAM's pool, which the mock
  doesn't fork; GAM's workers are its own children in its group, as the stand-in's are.
