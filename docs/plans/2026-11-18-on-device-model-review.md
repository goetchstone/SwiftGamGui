# Plan: the on-device model and security, reviewed (and what to do next)

**Status (2026-11-19): S1 done (#169); S4 in review (#173); R1 done (this PR). Next: A1.** Asked for: check the repo, its security, its usefulness and its use of
Apple's on-device model; say where the model is used wrongly and where else it could be used; write it so a smaller model
can carry out each task. Read against the macOS 27 SDK on this Mac (Xcode 27.2, `FoundationModels.swiftinterface`), not
from memory. Nothing here was run against the real model: where a finding is read from code and not reproduced, it says so.

## How to use this plan

- One task, one branch off `main`, one PR (no stacked PRs). Order: **S1, S4, R1, A1, A2, A3, A4, S3, S2**. Nothing
  waits on the operator but the checks each task names. The A tasks lean on each other in that order; the S tasks stand alone.
- Before a task: the `start-session` skill, then `docs/domains/compromised-account.md` ("Log reader" and "The model").
  Before its commit: the `pre-commit` skill. A `fix:` commit needs its failure-log entry (the local hook blocks it without).
- A task is done when `swift test --package-path Packages/GamKit` is green and its "Done when" holds. The real model is
  only reached by hand: `SWIFTGAMGUI_MODEL=1 swift test --package-path Packages/GamKit --filter OnDevice`. It uses test
  fixtures, never tenant data.
- The SDK is the oracle for every FoundationModels name here, not memory: `xcrun --show-sdk-path`, then
  `System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/*.swiftinterface`
  (grep it; don't read it whole).
- Stop and ask the operator instead of deciding when: a test that guards an invariant has to change; the SDK doesn't
  have a symbol this plan names; the real model's output contradicts a "Why" below.
- **Model tier:** tasks marked *small* are mechanical (Haiku-class is enough). Tasks marked *medium* touch wording the
  operator reads in an incident or a guard's logic: use a Sonnet-class model, and have `gam-command-reviewer` or one
  review agent read the diff. Nothing here needs the largest model.

## What was found

### The model's use today (three places, all in `Packages/GamKit/Sources/Assist`)

| Where | What the model does | File |
|---|---|---|
| Incident → Read the logs → **Explain** | words the reading: what happened, what's done, what's urgent | `LogExplainer.explain` |
| Incident report → **Draft** | the same, as the report's summary paragraphs | `LogExplainer.summary` |
| Reports → Connected apps → **Explain** | rewords the counts | `AppsExplainer.explain` |

**Sound, keep as is:** code finds and the model only words; the prompt holds no text an attacker wrote (a moment's
`plain` words, accounts held to an address's shape by `isAccount`); guided generation (`@Generable`) shapes the answer;
a new session per question, so no transcript grows; `Assist` imports only Foundation and FoundationModels and
`WriteRouteTests.theLogReaderCanRunNothing` holds that; availability is said in words; the screens label the text as the
model's; a stale answer is never shown for a newer reading; with no attacker the model isn't asked (PR #166).

**Not sound** (each is a task below):

1. **"On-device only" is a sentence in a doc, held by no test.** macOS 27 added `PrivateCloudComputeLanguageModel`, which
   conforms to the same `LanguageModel` protocol, and `LanguageModelSession.init(model: some LanguageModel, …)`. Both
   explainers write `LanguageModelSession(model: .default, …)`. One changed word would send tenant accounts and
   addresses off the Mac, and every test would stay green. → **A1**
2. **The answer's guides still presuppose an attack that got in and a lock.** `Answer.overview` asks "when and how the
   attacker got in, to which accounts, and when each was locked"; `Answer.done` asks "whether the locks are holding".
   `untold` only stops the model when there is *no* status. A reading whose only status is a failed try, or a password
   typed on a phishing site, or an account not yet locked, still reaches the model under those words. This is the cause
   of the 2026-11-17 failure at a smaller size, and that entry's last line already says it isn't proven. *Read from the
   code; not reproduced on the model.* → **A2** reproduces it, **A3** fixes it
3. **Explain shows two paragraphs no guard checks.** `summary` drops a sentence holding a number the facts don't;
   `explain` (the Explain button) shows `overview` and `done` unchecked. Neither path checks that an account the model
   names is one it was given. → **A3**
4. **The log explainer has no answer cap and its own sampling.** `AppsExplainer` got `maximumResponseTokens: 400` and
   `.greedy` after "it once wrote until its context was full"; `LogExplainer` still runs `temperature: 0.2` with no cap.
   → **A3**
5. **A long reading fails with the wrong words.** The prompt can hold 20 accounts' moments plus 30 + 30 tasks of up to 10
   accounts each: by rough count several thousand tokens on a bad day (a phishing wave), against a context the model
   reports itself (`SystemLanguageModel.default.contextSize`; 4096 before macOS 27). The screen then says "its answer ran
   longer than the model allows. Try again.", which is wrong, and trying again can't help. *Estimated, not measured.* → **A4**
6. **Three errors the macOS 27 SDK can throw have no words:** `SystemLanguageModel.Error.assetsUnavailable` (the model
   was removed or is downloading), `GeneratedContent.ParsingError` (the answer was cut; its `rawContent` should not be
   what the screen shows), and `CancellationError`. → **A4**
7. **Every real-model test is a takeover** (the 11-17 lesson, half applied: the stub now covers quiet logs, the real
   model still sees one shape). → **A2**

Small, folded into the tasks: an address (`event.ip`) reaches the prompt unshaped, where an account is shape-checked
(Google writes it, so low risk; one shape check closes it, **A3**); the design doc's Status says GAM 7.51.00 and the pin
is 7.52.01 (**A1**, one line).

### Usefulness

The app is in daily use and its plan is honest about what's unproven ("Run what's built"). Two things limit what it
gives today, neither a model's job to fix:

- **The Builder is hard to search.** 1,052 catalog commands, none with a description (`command_catalog.json`'s
  `description` is empty for all), searched by substring of the name or grammar line. Typing what you want ("who
  forwards mail") finds nothing unless GAM's grammar uses that word.
- **`AppsExplainer` adds little.** Its prompt *is* the summary in plain sentences, written by code; the model rewords
  them, and a sentence it gets wrong is dropped. The screen could show code's sentences and lose nothing. It costs
  128 lines and a guard to keep. The operator chose to retire it (**R1**).

### Where else the model could be used

Held to the repo's own bar ("a slice earns its place by being used or by preventing a loss") and to invariant 10. The
honest answer is: **nowhere new, today.** The on-device model is small; it is good at wording facts it is given and at
filling a fixed shape from a person's own sentence, and poor at knowing GAM. The model is already where wording helps
most (an incident, read by someone under pressure, and by an owner who isn't technical). Each other candidate, and why not:

| # | Use | Verdict |
|---|---|---|
| U1 | **Users: "show me…" in plain words** → a `UserFilter` | **Not now.** `UserFilter` is three scopes and one substring: a click and a word already say all it can. Worth a second look only if Users gains filters that Reports doesn't already answer (last sign-in, 2-Step) |
| U2 | **Reports or curated commands picked by meaning** | **Not now.** The reports fit on one screen with their descriptions. The 1,052-command catalog is where a finder would pay, and it has no descriptions to find by; the gaps plan already parks "a plain-language command finder" |
| U3 | A plain-words digest of the audit log ("what changed this week") | **No.** Same shape as `AppsExplainer`: code counts, and code's own sentences say it |
| U4 | Onboard: fill the form from a pasted note | **No.** Four fields; typing them is faster than checking a model's reading of them |
| U5 | Explaining a failed `gam` run | **No.** The model doesn't know GAM; the exit-code table and GAM's own words are the truth |
| U6 | Reading an app's name, an email, a subject, a URL (to tag "looks like AI", to triage a phish) | **No, by rule.** "The model never reads what an attacker wrote" |
| U7 | `PrivateCloudComputeLanguageModel` for longer or better answers | **No, by rule.** Tenant data never leaves the Mac; A1 makes that a test |
| U8 | Tool calling (the model asks code for more) | **No.** A tool is a second route from model text to code; invariant 10's point is that there is one, a preview |

Platform features worth knowing, none needed now: `ContextOptions(reasoningLevel:)`, `SystemLanguageModel.variant`
(`core3`, `coreAdvanced3`: which one this Mac has decides how much A4 matters), `Response.usage`, `prewarm()`
(shaves the first answer's wait; add only if the wait is felt), `SystemLanguageModel(guardrails:
.permissiveContentTransformations)` (try only if A2 shows refusals on incident wording, and read Apple's page first:
whether it applies to guided generation is not something this plan verified).

---

## Tasks

### A1 — "On-device only" becomes a test · *small* · branch `test/on-device-only`

**Why:** finding 1.

1. `Packages/GamKit/Sources/Assist/LogExplainer.swift`, in `OnDevice.answer` (after R1 it is the only session made):
   change `LanguageModelSession(model: .default, instructions: instructions)` to
   `LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)`.
2. `Packages/GamKit/Tests/GamEngineTests/WriteRouteTests.swift`, next to `theLogReaderCanRunNothing`, add
   `@Test func theModelIsOnThisMacOnly()` using the file's existing helpers (`Self.swiftFiles(in:)`, `.lines`):
   - no line of any Swift file under `App` or `Packages/GamKit/Sources` contains `PrivateCloudCompute`;
   - every line containing `LanguageModelSession(` is in `Packages/GamKit/Sources/Assist` and also contains
     `SystemLanguageModel.default`;
   - no Swift file under `Packages/GamKit/Sources/Assist` contains `URLSession` (it is in Foundation, so the import
     check doesn't catch it).
3. `docs/plans/2026-10-08-native-gamgui.md`: in the Status line, "GAM 7.51.00 is pinned" → the version in
   `Vendor/gam7/VERSION` (read it; don't type it from this plan).
4. `docs/domains/compromised-account.md`, "The model" entry: one sentence naming the new test.

**Done when:** the suite is green; temporarily writing `PrivateCloudComputeLanguageModel()` in `LogExplainer` makes the
new test fail (try it, then undo).
**Don't:** touch invariant text in `CLAUDE.md`.

### A2 — The real model sees every shape of reading · *medium* · branch `test/model-shapes`

**Why:** findings 2 and 7. This task changes no shipping code. It finds out whether finding 2 is real before A3 fixes it.

1. In `Packages/GamKit/Tests/AssistTests/LogReadingTests.swift`, beside `static let incident`, add four small event
   fixtures built the way `incident` is (same event names and parameters, which already cite Google's reference; add no
   new field or value without a citation, per "the mock lies"):
   - `triedOnly`: failed sign-ins from a suspect address, none succeeding, no admin action;
   - `notLocked`: the attacker signed in; no sign-out, no reset;
   - `halfLocked`: the attacker signed in; a password reset, no sign-out;
   - `wave`: 12 accounts signed in to from one suspect address, each locked (for A4's size).
   For each, a plain unit test that `LogReading.read` gives the statuses the name says (state, `attackerGotIn`,
   `lockedAt`), so the fixture is proven to be that shape.
2. In `OnDeviceModelTests` (the `SWIFTGAMGUI_MODEL=1` suite, same file), replace the single test with one parameterised
   over `incident`, `triedOnly`, `notLocked`, `halfLocked`, `wave`. For each: call `LogExplainer.explain`, print the
   prompt (`LogExplainer.prompt(reading)`) and every field of the answer, and print
   `try await SystemLanguageModel.default.tokenCount(for: LogExplainer.prompt(reading))` beside
   `SystemLanguageModel.default.contextSize`. Expect only what holds today: no throw except for `wave` (record what it
   throws), and every cite is a real to-do ID.
3. `App/ModelSpike.swift`: also print `model.contextSize` and `model.variant.displayName`.
4. Run the by-hand suite on this Mac. Paste the printed answers for `triedOnly`, `notLocked` and `halfLocked`, the token
   counts, the context size and the variant into a new section "2026-11-18: what the real model says for each shape" at
   the end of `docs/failure-log/2026-11-17-the-model-told-an-incident-the-logs-didnt-show.md`. Mark, sentence by
   sentence, anything the facts don't hold (an entry that didn't happen, a lock that isn't there, a date not given).

**Done when:** the fixtures' unit tests are green in CI; the failure-log section holds the real output and the counts.
**Hand back to the operator:** whether finding 2 reproduced. If the model wrote nothing false for all three, A3 keeps
its checks (steps 3 to 6) and drops steps 1 and 2.

### A3 — The model is asked only what the facts hold, and every sentence is checked · *medium* · branch `fix/model-asked-only-what-holds`

**Why:** findings 2, 3, 4. A `fix:` with A2's failure-log section as its entry. All in
`Packages/GamKit/Sources/Assist/LogExplainer.swift` unless said.

1. **Guides that presuppose nothing.** Reword `Answer.overview`'s guide to: "Up to three plain sentences telling what
   the lines under 'What happened' say, in time order. Say only what those lines say. Use the dates given." Reword
   `Answer.done`'s to: "Up to two plain sentences on what the lines after 'Done:' and under 'Already done' say was
   done." In `instructions`, replace "a short rundown of a security incident" with "a short rundown of what security
   logs show", and add: "If the facts don't say an account was signed in to, or locked, don't say it was."
2. **Code says "nothing done".** Add `static func nothingDone(_ reading:) -> Bool`: true when no status has `lockedAt`,
   no status's timeline holds a moment whose kind is in `doneKinds`, and `reading.done` is empty. In
   `explain(_:facts:using:)`, when it is true, set `done` to the constant
   `"Nothing has been done to secure these accounts yet."` whatever the model wrote.
3. **One check for both paths.** Move `summary`'s `checked` into `explain(_:facts:using:)` so it runs on `overview`,
   `done` and each point's text. A sentence stands only if (a) every run of digits in it is among the facts' (as now),
   and (b) every token holding `@` is, once its trailing punctuation is trimmed and it is lowercased, a substring of the
   lowercased facts. Give `Explanation` a `public let dropped: Int`. `summary` then joins the already-checked parts and
   returns `explanation.dropped`.
4. **The screen says what was left out.** `App/LogReaderView.swift`, in `explanation(_:)`'s `.done` case: when
   `explanation.dropped > 0`, add the sentence the report sheet already uses (`IncidentReportView.ask`), reworded for
   both checks: "N of its sentences held a number or an account the logs don't, so were left out." If `overview` is
   empty after the check, show "The model's sentences didn't match the logs, so none is shown."
5. **Same sampling, and a cap.** `OnDevice.answer`: `GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 700)`.
6. **An address has an address's shape.** In `LogReading.swift`, add `static func isAddress(_:) -> Bool` (non-empty, at
   most 45 characters, only hex digits, `.` and `:`). Apply it once, where the set of suspect addresses is built (find
   it from `.suspectAddress` and the `acting` set passed to `timeline`), so a value without an address's shape is never
   a suspect address and so never reaches a moment's words; the address the operator pulled by is held to it too.
   Unit-test both sides (an IPv4, an IPv6, a sentence), and that a reading whose flagged "address" is a sentence has no
   suspect address.

**Tests** (stubs; `LogReadingTests`' `Stub`): a made-up date in `overview` is dropped by `explain` and counted; a
made-up account in `done` is dropped; `notLocked` with a stub that answers "The locks are holding." shows the constant
instead; the existing summary tests pass unchanged in meaning. Then the by-hand suite again: paste the three shapes'
new answers under A2's section as "after".

**Done when:** suite green; the by-hand output for `triedOnly`, `notLocked`, `halfLocked` holds no sentence the facts
don't; the runbook's model entry says the guides presuppose nothing and names the checks.
**Don't:** give the model findings, subjects, app names or any new field. Don't loosen `untold`.

### A4 — A long reading fits, and failures say the right thing · *medium* · branch `fix/model-long-reading`

**Why:** findings 5 and 6. Start from A2's numbers: if `wave`'s token count plus 700 is well under `contextSize`, do
only steps 3 and 4 and write that down.

1. `LogExplainer.Asking` gains `func fits(instructions: String, prompt: String) async -> Bool`, with a protocol
   extension answering `true` (so stubs don't change). `OnDevice` implements it:
   `tokenCount(for: Instructions(instructions)) + tokenCount(for: prompt) + tokenCount(for: Answer.generationSchema)
   + 700 <= contextSize`, on `SystemLanguageModel.default`, answering `true` if counting throws.
2. `prompt(_:when:)` gains `short: Bool = false`. Short keeps 8 statuses, 12 story moves, 12 to-do and 12 done items,
   3 accounts per item, and ends each cut list with a line code writes ("and 9 more accounts", "and 18 more tasks").
   `explain(_:when:using:)` builds the full prompt, asks `fits`, and uses the short one if not. `Explanation` gains
   `public let shortened: Bool`; `LogReaderView` adds "The model was given the first accounts and tasks only; the lists
   above are complete." when true. `summary` checks numbers against the facts actually sent.
3. `OnDeviceModel.failure`: `.contextSizeExceeded` → "there is more here than the model can read at once. The lists
   above are complete without it." (no "Try again"). Add, before the `LanguageModelError` guard:
   `SystemLanguageModel.Error` → "the on-device model is still being set up (downloading). Try again in a while.";
   `GeneratedContent.ParsingError` → "the model's answer didn't come out whole. Try again." (never its `rawContent`);
   `CancellationError` → "it was stopped."
4. Tests: `OnDeviceModelWordsTests` (its own file since R1) gets a case per new line (each error has a public init in the SDK; if one doesn't,
   leave its test out and say so in the PR). A stub whose `fits` answers false gets the short prompt, proven by the
   stub recording the prompt it was given; the short prompt's "and N more" numbers are right.

**Done when:** suite green; by hand, `wave` answers instead of throwing, or A2 showed it never threw and steps 1 and 2
were skipped on purpose.

### R1 — Retire the connected-apps explainer · *small* · branch `chore/retire-apps-explainer`

**Decided (operator, 2026-11-18: "Yes, retire it").** Do it before A1, so the A tasks touch one explainer.

**Why:** the panel already shows code's own sentences (`ConnectedApps.Summary.sentences`, drawn at
`App/ConnectedAppsView.swift:68`); the Explain button below them had the model reword the same counts. Removing it
loses nothing the screen says and takes a model call, a guard and a by-hand suite with it. Nothing moves: it is a deletion.

1. Delete `Packages/GamKit/Sources/Assist/AppsExplainer.swift`.
2. `App/ConnectedAppsView.swift`: delete `import Assist`, the `explained` state, the `Explaining` enum, the
   `explanation(_:)` view and its call on the line after the sentences, `explain(_:)` and `facts(_:)`. In the type's
   doc comment, drop the sentence about the on-device model and the "(invariant 10, `WriteRouteTests`)" clause: the
   file no longer talks to a model. `summary.sentences` stays exactly as it is.
3. `Packages/GamKit/Tests/AssistTests/AppsExplainerTests.swift`: move `OnDeviceModelWordsTests` (it tests
   `OnDeviceModel.failure`, which the log explainer still uses) into a new file `OnDeviceModelWordsTests.swift` in the
   same folder, unchanged; then delete `AppsExplainerTests.swift` (its other suites, the by-hand `OnDeviceAppsModelTests`
   included, test what's gone).
4. `Packages/GamKit/Tests/GamEngineTests/WriteRouteTests.swift`: replace `theAppsExplainerCanRunNothing` with
   `theConnectedAppsPanelTalksToNoModel`: `Self.files(in: "App", matching: ["AppIntent", "FoundationModels",
   "LanguageModel", "Assist"])` does **not** contain `App/ConnectedAppsView.swift`, and
   `Self.files(in: "App", matching: ["AppsExplainer"])` is empty. Leave the other tests' lists alone: they are computed.
5. `swift test --package-path Packages/GamKit`, then build the app (`xcodebuild … -scheme GamGUI build`): a leftover
   reference fails one or the other. `ConnectedAppsTests` (the summary's sentences) must pass untouched.
6. Docs: `docs/domains/audit-reports.md`: remove the **Explain** entry (line ~107), the by-hand model line (~159) and
   the two test names on line ~19; add one line under the apps entry: "The summary is code's own sentences; a model
   reworded them until 2026-11 and was retired: it added nothing they didn't say." `README.md` needs no change (its
   two model mentions are about the incident summary).
7. The `reports-apps` and `narrow-reports-apps` screenshots lose a line: refresh them from the PR's CI run, the usual way.

**Done when:** suite and app build green; `grep -rn AppsExplainer App Packages` finds nothing; the panel in the CI
screenshot shows the sentences and no model line.
**Don't:** touch `OnDeviceModel.swift`, `LogExplainer`, or `ConnectedApps.Summary`.

## Security (outside the model)

From one read-only sweep of the source (nothing run, no credential touched), then each finding below re-read in the
code before it was written here. **No high-severity defect.** The invariants hold where they were checked: one launch
site (`posix_spawn`, no shell, NUL bytes refused), an allowlisted environment with `GAMCFGDIR` set, `WriteTicket` minted
in one place, the three-way read-only promotion, Siri drafting only ("Just do it" isn't built), the data-protection
Keychain with user presence, `mkdtemp` 0700 and `O_EXCL` 0600 with a wipe on every path, descriptor reads, masked argv
and stderr, 0600 stores, a fail-closed fetch, SHA-pinned actions with `contents: read`, empty app entitlements, no
`URLSession`, and caps on every stream.

What is left is mostly about **the build the operator runs every day**, which is a Debug build:

| # | Finding (verified) | Where | Task |
|---|---|---|---|
| 1 | In a Debug build, `SWIFTGAMGUI_GAM_BINARY` replaces the bundled binary on the **real-Keychain** path with any file at all. Demo and the spikes already insist on the mock (`mockGam()`); `make()` doesn't. A leftover scheme variable, or a same-user `launchctl setenv`, gets both credentials materialised for a program of its choosing | `GamBinary.swift:19-23`, `AppServices.swift:86` | **S1** |
| 2 | `get-task-allow` is stripped for Release only, so the daily build is debuggable by any same-user process, which can read credentials from its memory during the 10-minute Vault session. `check_app.sh` fails on any app entitlement, so it can't check a team-signed build at all | `Config/Base.xcconfig:16`, `scripts/check_app.sh:34` | **S4** |
| 3 | The Vault's 10-minute session is never ended by screen lock or sleep; expiry is checked on the next read | `Vault.swift:10, 36-38`; no `lock()` caller in `App/` | **S2** |
| 4 | After SIGTERM, if the child exits within the grace, the cancelled sleep is swallowed by `try?` and `kill(pid, SIGKILL)` still runs on a pid already reaped | `GamRunner.swift:204-208` | **S3** |
| 5 | `fetch_gam.sh` ends by asking the vendored binary for its version with the caller's environment and no `GAMCFGDIR` (so against the home config folder, which the rules of engagement forbid), and parses the release with `python3 -` without `-I` | `scripts/fetch_gam.sh:57, 141` | **S3** |
| 6 | `SECURITY.md` still says no write is wired and the app reads only | `SECURITY.md:~62` | **S3** |

### S1 — The binary override never meets real credentials · *medium* · branch `fix/gam-override-mock-only`

A credentials change: one adversarial review of the diff (`gam-command-reviewer`) before the PR. A `fix:`, so a
failure-log entry: "a debug switch reached the real Vault".

1. `Packages/GamKit/Sources/GamEngine/GamBinary.swift`: delete the `#if DEBUG … #endif` block in `locate`. Keep
   `overrideVariable` (`AppServices.mockGam` and the spikes read it). `locate` then returns the bundled binary or nil.
2. Confirm by grep that `GamBinary.locate` has one caller (`AppServices.make`) and that every other reader of
   `overrideVariable` goes through `AppServices.mockGam`.
3. Test (GamEngineTests): with `environment: [overrideVariable: "/bin/echo"]`, `locate` doesn't return `/bin/echo`.
   Add a `WriteRouteTests` source scan: `overrideVariable` is read only in `GamBinary.swift` and `AppServices.mockGam`.
4. `CLAUDE.md`'s Commands block already pairs the variable with `SWIFTGAMGUI_DEMO=1`; change nothing there.

**Done when:** suite green; the app built Debug with the variable set and no `SWIFTGAMGUI_DEMO` uses the bundled binary.

### S2 — The Vault locks when the screen does · *medium* · branch `feat/vault-locks-with-the-screen`

1. `App/AppDelegate.swift`: observe `NSWorkspace.screensDidSleepNotification`, `NSWorkspace.sessionDidResignActiveNotification`
   and the distributed `com.apple.screenIsLocked`; each calls the Vault's `lock()` (make it reachable from the app if it
   isn't: read `Vault.swift` first and keep `package` access where the write path depends on it).
2. A run in flight keeps what it already holds (a lock mid-job must not strand a half-done sequence): `lock()` only ends
   the session, so the next read asks for presence again. Prove that with a Vault test on the memory store.
3. Runbook `docs/domains/secrets.md`: one line.

**Done when:** suite green; by hand, lock the screen, unlock, start a read: Touch ID is asked for again.

### S3 — Three small ones · *small* · branch `fix/small-hardening`

1. `GamRunner.swift:204-208`: replace `try? await Task.sleep(for: terminationGrace)` with a `do/catch` that returns
   without calling `kill` when the sleep was cancelled. The existing timeout tests must stay green; add none that
   depend on timing (three failure-log entries are about timing tests on a busy runner).
2. `scripts/fetch_gam.sh:57`: `python3 -I -`. Line 141: make the version check the way `check_app.sh:51-53` does
   (a `mktemp -d` folder as `GAMCFGDIR`, `GAM_NO_UPDATE_CHECK=1`), then remove the folder.
3. `SECURITY.md`: replace the "no write is wired yet / reads only" sentence with what's true (changes run through one
   path: preview, typed confirmation, audit). Keep it to two lines; no other edits.

### S4 — The daily app is a build nothing can attach to · *medium* · branch `feat/daily-scheme`

**Decided (operator, 2026-11-18: "Yes, plan it").** Today the daily app is Xcode's Run on the autocreated `GamGUI`
scheme, a Debug build, so finding 2 is standing: it is the only finding here that leaves credentials readable. After
this task the operator picks **GamGUI Daily** in Xcode's scheme menu and presses Run as before.

What is already true, so don't redo it: both configurations share one bundle ID (`io.github.goetchstone.swiftgamgui`)
and one team (`Config/Local.xcconfig`, gitignored), so the Keychain items are reachable from either;
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS[config=Release] = NO` already keeps `get-task-allow` out of Release; the project has
no scheme file (Xcode autocreates `GamGUI`), and CI builds `-scheme GamGUI` in both configurations.

A credentials-adjacent change: one review of the diff before the PR. Do it after S1.

1. **Two shared schemes** in `SwiftGamGui.xcodeproj/xcshareddata/xcschemes/` (new folder; check `.gitignore` doesn't
   hide it). Both build the one target (`BlueprintIdentifier = "5A6D00000000000000000040"`, `BuildableName =
   "GamGUI.app"`, `BlueprintName = "GamGUI"`, `ReferencedContainer = "container:SwiftGamGui.xcodeproj"`).
   - `GamGUI.xcscheme`: what Xcode autocreates (Run, Test and Analyze on Debug; Profile and Archive on Release). It is
     written down because a project with one shared scheme may stop autocreating the other, and CI names `GamGUI`.
   - `GamGUI Daily.xcscheme`: the same, but its `LaunchAction` has `buildConfiguration = "Release"`,
     `selectedDebuggerIdentifier = ""` and `selectedLauncherIdentifier = "Xcode.IDEFoundation.Launcher.PosixSpawn"`
     (Xcode's "Debug executable" unticked: with no `get-task-allow`, a Run that tries to attach fails), and no
     environment variables and no arguments.
   The attribute names above are from memory of Xcode's scheme format, not read from a file on this Mac. Prove them:
   `xcodebuild -project SwiftGamGui.xcodeproj -list` shows both schemes, and both
   `xcodebuild -project SwiftGamGui.xcodeproj -scheme GamGUI -configuration Debug -derivedDataPath build/DerivedData.noindex build`
   and the same with `-scheme "GamGUI Daily"` (no `-configuration`) succeed. If Xcode rejects or rewrites the files,
   stop and ask the operator to make the scheme in Xcode (Product → Scheme → Manage Schemes → duplicate `GamGUI`,
   tick Shared; Edit Scheme → Run → Release, untick "Debug executable"), then commit what Xcode wrote.
2. **`scripts/check_app.sh` can check a team build.** A second, optional argument `--team`. Without it nothing changes
   (CI's ad-hoc build still must carry no entitlement). With it, the app's entitlement keys must be exactly the set a
   team-signed Release build carries, and in both modes `com.apple.security.get-task-allow` fails by name with its own
   message. Find the exact set by reading it off the Daily build from step 1 with the script's own `keys` function
   (expected: `keychain-access-groups` from `Config/GamGUI-Team.entitlements`, plus the application and team
   identifiers the provisioning adds); write the set into the script as the embedded binary's set is written
   (`GAM_ENTITLEMENTS`). If the build carries anything beyond those three, stop and ask. Update the header comment's
   last sentence. Run `scripts/check_app.sh build/DerivedData.noindex/Build/Products/Release/GamGUI.app --team`: it
   must pass on the Daily build and fail on the Debug product.
3. **The app says when it is debuggable.** The scheme is a habit; this is the tripwire that keeps it.
   - `App/` (platform code stays in the app): a small `enum BuildSafety` with
     `static let debuggable: Bool`, read once from the running process's own signature
     (`SecTaskCreateFromSelf`, `SecTaskCopyValueForEntitlement` for `com.apple.security.get-task-allow`). It asks what
     the signature says, not `#if DEBUG`: the entitlement is the risk, whichever configuration carries it.
   - `App/HomeView.swift`: when `debuggable` is true **and** the services are the real ones (not `SWIFTGAMGUI_DEMO`,
     so no CI screenshot changes), one line at the top: a warning symbol and "This is a debug build: another app on
     this Mac could read its credentials. For daily use, run the GamGUI Daily scheme." Text and symbol, not colour
     alone; a VoiceOver label; no button, no dismissal, nothing blocked (in an incident, a debug build that works
     beats a daily build that doesn't).
   - Test: the view's condition as a pure function of `(debuggable, demo)`, four cases.
4. **Docs.** `docs/domains/secrets.md`: a short "Which build holds credentials" entry (Daily is Release, team-signed,
   not debuggable; `check_app.sh --team` checks it; Home says so when it isn't). `SECURITY.md`: one sentence beside
   the Keychain boundary saying the daily build carries no `get-task-allow`. `README.md`: if it says how to run the
   app, name the Daily scheme there. Don't edit `CLAUDE.md`.

**Done when:** suite and CI green (CI still builds `-scheme GamGUI` in both configurations); `check_app.sh --team`
passes on the Daily build; the banner test passes.
**Then the operator, once** (this is the live check; no session starts the real app): pick GamGUI Daily, Run, see
Touch ID asked and the domain load, and see no banner on Home. Record it in `docs/live-verification.md`.
**Tell the operator:** breakpoints and the debug console need the `GamGUI` scheme; the snapshot, demo and spike
switches don't exist in the Daily build; the 7-day re-sign is unchanged (it is the free team's limit); Xcode's
DerivedData now holds a Release copy beside the Debug one, which is one more copy Siri could pick by name while Siri
stays parked. The session's saved note that the operator runs Debug builds is out of date once they switch: update it,
and from then on speed work is measured in Release first.
**Don't:** change the bundle ID, the team, the access group or `Config/Local.xcconfig`; make a Debug build refuse the
real Vault (a stronger rule, and the operator's to ask for).

### Looked at, not planned

- **A digest of the unpacked `Vendor/gam7` tree, checked at embed.** A process that can rewrite that folder can rewrite
  `embed_gam.sh` beside it; the pin protects the download, which is what it is for.
- **A hash chain on the audit log.** Same reason: it guards against a same-user process, which could rewrite the chain.
- **The signature preview loading remote HTTPS images** (a signature could tell its author's server the admin looked).
  A design decision (D1), no script runs, and seeing the signature as Gmail draws it is the point.
- **Suspected, not verified:** a catalog read refuses only `todrive` and `doit` as values
  (`CommandCatalog.swift:128`). Whether any other single word typed as a value makes a GAM read change something needs
  GAM's source read per command. Do it the next time the Builder's reads are touched, not as its own slice.
- **Suspected, not verified:** after a crash, a running child is orphaned and the launch sweep removes its folder. GAM
  then fails closed, which is the right way to fail; nothing to do unless it is seen.

## Not planned

U1 to U8 above, each for the reason given. A model-written description for each of the 1,052 catalog commands (it would
have to be checked against GAM's source line by line to be worth showing; the gaps plan parks the finder it would feed).
