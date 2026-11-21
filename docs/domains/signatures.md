# Signatures

**One line:** saved HTML signature templates with `{variables}` and `[[optional]]` blocks, rendered for
one person, a group's members, everyone in an org unit or the whole company, and set as each one's Gmail
signature through ChangeCore. Built: the parity core (S1a: the render, the reader of `show signature`,
GAM's stored form, the strict mock), the template store (S1b), the screen and the write for one person
(S1c, 2026-10-10, live 10-29), a scope as a job with Stop and a retry of what failed (S2, 2026-11-13,
asked for by the operator: "signature across a group or whole ou"), following the plan for signatures
(design doc D1–D5), and kept signatures with Put Back (GamGUI's #163 and #164, ported 2026-11-21: "signature
backups first", the operator): every run keeps each signature it replaces on this Mac first. The scope's live check,
and the kept signatures', are next. GamGUI's runbook
of the same name is the history this inherits: its render rules, its 2026-09-23 apply incidents and its
mock traps all carry over.

**Owns invariants:** #11 for the render, the reader, the seeds and the store's name rules, order and
messages; the store's own rules below (no template is ever lost to a failed save or an unreadable file).

**Enforcement home:** `Packages/GamKit/Tests/GamEngineTests/SignatureTests.swift` and
`MockSignatureTests.swift`, `Packages/GamKit/Tests/StoresTests/SignatureStoreTests.swift`, all held to
`Tests/Fixtures/signatures.json` (`scripts/gen_fixtures.py`'s `signature_fixture`); the write in
`Packages/GamKit/Tests/DirectoryStoreTests/SignatureChangesTests.swift` and ChangeCore's
`ExecutorTests`; the one confirm screen in `WriteRouteTests`. Kept signatures: `SignatureExactTests` (the read),
`SignatureKeepTests` (ChangeCore), `SignatureBackupStoreTests` (the store), the Put Back cases in
`SignatureChangesTests` and `SignatureScopeTests`, and `WriteRouteTests.onlyTheExecutorKeepsSignatures` and
`everySignatureAScreenReplacesIsKeptFirst`.

## Files
- `Packages/GamKit/Sources/GamEngine/Signature.swift`: the variables, the seeds, `render`,
  `smartQuoteWarning`, `parseShown`, `stored`, `readAsKeyword`, and the preview's `previewDocument`
  (the CSP shell) and `contentRules` (the WKContentRuleList).
- `Packages/GamKit/Sources/Stores/SignatureStore.swift`: the store.
- Kept signatures: `Signature.exact` and `GamCommands.printSignature` (GamEngine), `WriteStep.KeepFirst` and the
  executor's `keepFirst` (`ChangeCore/ChangeCore.swift`), `SignatureKeeper` (`ChangeCore/SignatureKeeping.swift`),
  `SignatureBackupStore` (`Stores/SignatureBackupStore.swift`), and `SignatureChanges.previewPutBack`, `putBackPlan`,
  `loadKept`.
- `Packages/GamKit/Sources/Directory/SignatureChanges.swift`: the write, for one person and for a scope;
  `SignatureScope.swift` whom a scope matches; `UserAccess.swift` reads the current signature.
- `App/SignaturesView.swift` (the screen), `App/SignatureWebView.swift` (the Rendered view and the
  Rendered | HTML pane), `App/SignatureEditor.swift`, `App/SignatureTemplates.swift` (the store for the
  screen), `SignaturePreviewSheet` and `SignatureScopePreviewSheet` in `App/ChangePreviewSheet.swift`, and
  the Mail tab's "Gmail signature" card in `App/UsersView.swift`.
- `Packages/GamKit/Sources/GamEngine/JSONValue.swift`: `JSONValue.parse` and `dumps`, Python's
  `json.loads` and `json.dumps`, which the store reads and writes with (shared with the audit log).

## What GAM does with a signature (7.48.22, read from the vendored build)
- **The write** is GamGUI's argv, `gam user <email> signature <body> html` (`argv.json`'s `set_signature`).
- **GAM changes the body before Gmail stores it** (`_processSignature`, gam/__init__.py:78601-78608):
  every CR is removed and each backslash followed by `n` becomes `<br/>`. Real line breaks stay, since
  `html` is always passed. A preview of the argv alone would show the operator something else, so the
  screen shows `Signature.stored` and says when it differs. GamGUI's preview hid this.
- **Some bodies are read as a file keyword, not as the signature** (getStringOrFile :1896-1899): the
  body stripped, lowercased and with `_` removed (checkArgumentPresent :892), when it's `file`,
  `htmlfile`, `textfile`, `gdoc`, `ghtml`, `gcsdoc` or `gcshtml`, makes GAM read the next argument
  (`html`) as that file or document. `textfile` is missing from the grammar file. `readAsKeyword`
  finds them; the screen refuses them before a preview. An empty body is accepted and clears the
  signature.
- **`show signature` prints one block, for the address given** (printShowSignature :78862-78865, without
  `primary` or `default`): `SendAs Address: [Name ]<addr>`, its fields, `Signature:`, then the body with
  each line indented (Ind.MultiLineText: only `\n` starts a new indented line; `None` when empty).
  GamGUI's reader, ported exactly, strips each line, so leading whitespace inside the body is lost, and
  a body line break other than `\n` (U+2028, a form feed) ends the read early, as in GamGUI. The plan
  once read this as one block per send-as address and planned a reader choosing among them; the build
  says otherwise, and the port stays GamGUI's.
- **The oracle is GAM itself:** the fixture runs `_processSignature` and `checkArgumentPresent` from the
  vendored build over the bodies, and reads SORF_FILE_ARGUMENTS from it, so a GAM bump that changes
  either fails the generator's run or the tests.

## The write (S1c): `Directory/SignatureChanges.swift`
One person at a time, through ChangeCore (invariant 2); the operator sets signatures per person.
- **Who:** `activePeople` (active users, code-point order by address, GamGUI's `scope_options`);
  `defaultPerson` is the connected admin when they're an active user, else nobody, never whoever sorts
  first (GamGUI review F18).
- **Preview:** `preview(person:template:current:)` renders the template (`Signature.render`), refuses a
  render GAM would read as a file keyword before any preview, and holds one
  `user <email> signature <render> html` with its confirm step and the typed count above 25 (D5), and
  `expecting:` the tenant the screen's reads belong to. Warnings, none changing the argv: GamGUI's
  curly-quote text, an empty render ("confirming clears their Gmail signature"), and the stored form
  differing ("GAM will store this with … changed").
- **The held body:** `Pending.body` is the held argv element (`WriteStep.signatureBody`), so the sheet
  shows the bytes the run sends; the audit and `shownArgv` keep it masked.
- **Confirm** runs the pending it's given only while it's the one shown, exactly as held: an edited
  template, another person, a directory change since, a replay or a bare confirm writes nothing.
- **Failure:** "Couldn't set the signature." plus the kind's remediation, GAM's error as `detail`. A
  never-signed-in account refused "Requested client not authorized" is told to wait for Google
  (live 2026-09-30); for anyone else those words stay GAM's unexplained error.
- **Put Back Previous (retired 2026-11-21):** was the signature as `show signature` displayed it before the change,
  held in memory, and none when that read failed. A one-person replace is now a kept run like any other ("Kept
  signatures" below), and its banner's Put Back… previews that run. What follows is the old rule, for the history:
  the signature as read before the change (`current`, from `UserAccess`, stamped
  with its tenant), previewed again as GAM showed it; refused on another tenant or when it's a keyword.
- **Reading the current signature:** `UserAccess` reads `show signature` with the person's other lists,
  on its own (Gmail off fails only it), parsed by `Signature.parseShown`; tenant-stamped and bounded
  like the rest.

## Many people (S2): `Directory/SignatureScope.swift`, `SignatureChanges.previewScope`
Ports GamGUI's `routes/signatures.py` (`preview`, `retry`, `apply`, `_matched`, `_run_apply`) and
`match_scope` at 487be35. One preview of N writes, one per person, through the executor; nothing new in
ChangeCore.
- **Who (`SignatureScope`):** one person (the S1c flow), a group's members, an
  org unit, the whole company. Active accounts only. Only `company` means everyone: a scope with no value
  matches nobody. An org unit is its path or any path under it (Python's `rstrip("/") + "/"`; `/` is
  everyone); a person matches in any case; the org units offered are every user's unit, suspended ones'
  too (`scope_options`). A group's members are read live with `print group-members group <g> formatjson`
  (`printGroupMembers`) when the preview is made; its active users are in scope, in the directory's
  order (a group inside it, the customer, a suspended account are not). The screen opens on one person.
  GamGUI's department and location scopes aren't built (not asked for).
- **Preview:** each person's render held as `user <email> signature <render> html`, confirm step always,
  the count typed above 25 (`typedCountAbove`, `Guard.countConfirmAbove`). Replace stays off until the count typed is the
  guard's (`Guard.Decision.typedCountMatches`, stripped and exact; GamGUI's `data-unlocks`), and `SignatureChanges.confirm`
  refuses a mismatch itself, "Type N, the number of people, to confirm." on the sheet, which stays with its preview unspent
  (the executor spends a preview it refuses); each refusal is announced to VoiceOver, a repeat too (`typedRefusals`), and
  editing the count clears it (`typingChanged`). `SignatureScopeTests.overTheThresholdTheCountIsTyped`,
  `theExecutorRefusesAnotherCount`. The sheet shows "Applies to N
  users · previewing as <first>", the first one's render exactly as held (`Pending.body`), ten addresses
  and "and N more" with the full list behind a disclosure, the warnings (GamGUI's curly quote; "renders
  empty for N of them"; GAM's stored form of the first), the guard's own warnings (over 200), and the
  commands masked. The job is titled as GamGUI's ("Signature for <who> — N users", "Signature retry — N
  users").
- **The run** is the executor's: each write audited (begin and end), in the jobs tray as it starts, the
  screen's banner counting set and failed with who is being set, and Stop (asked first) after the write
  in flight. A failure every later write would share (an expired sign-in, a missing scope) stops the
  rest, as GamGUI's `stop_reason`. The sheet closes once confirmed (as Calendars' group share). Its confirm is
  not the default button: Return alone never overwrites many signatures at once. The sheet's
  title names the scope ("Set the signature for N people in /Staff").
- **A preview outdated while it reads** (a group's members): the scope, person or template changed, or a
  newer preview began. Its held preview is discarded and nothing is shown (a preview serial, `edited()`).
- **The result** in GamGUI's words: "Applied to X of N users.", or "Stopped by you — K not attempted." /
  "Stopped: <remediation> The remaining K were not attempted." then "Applied to X of N before stopping.";
  each failure as "<address> — <remediation>" (the first 200, then "and N more"), in a bounded box that
  scrolls, so the template stays in reach in the smallest window.
- **Retry the N That Failed** (`previewRetry`): a new preview, never a write, of the failed addresses
  still active (lowercased, once each), with the run's template, bound to the run's tenant; "N of those
  that failed is no longer an active user and is left out". Its confirm is the same sheet. Not attempted
  isn't failed: a stopped run's rest isn't in the retry, as in GamGUI.
- **Exactly what was previewed:** the confirm runs the held people and template; any edit of who it's
  for, the person or the template drops the preview (`edited()`), and a later preview replaces it; a
  replay, a bare confirm or another count runs nothing (GamGUI's single-use token and form key).
- **Deviations from GamGUI, each tested:**
  - a group whose members can't be read says so (GAM's words, "isn't a group here" for Does not exist);
    GamGUI's `_matched` took any failure for an empty group ("No active users match");
  - a person whose render GAM would read as a file keyword (F2) is left out and named on the sheet, never
    sent; GamGUI would have sent it;
  - a retry covers every failure, not only GamGUI's kept sample of 200: the run's outcome has every step,
    so nothing is a sample of a larger set (GamGUI refused a retry past its cap);
  - group membership compares addresses in any case (GamGUI exactly; Google prints both lowercased);
  - an empty scope is a problem banner, not a preview with no Apply.

## The screen (S1c): Signatures, and the Users Mail tab's card
- **Signatures** (sidebar, SF Symbol `signature`): Person (a menu of active people; type to jump),
  Preview (Current and New, 260 pt tall, side by side while each has 380 pt and one above the other in a
  narrower window; then Review and Replace), the Template editor (240 to 320 pt) with the variables and
  the `[[ ]]` rule, and Saved templates. What will change comes first (the operator, 2026-10-12: the view
  was a little small, and the editor had pushed the preview below the window). The New view is the render for the chosen person, drawn a moment after typing stops
  and not held; "Review and Replace…" holds it. Why the button is off is said beside it: no domain, the
  directory loading or failed, nobody chosen, a blank template, a keyword body (refused in words before
  any preview), their current signature still being read (the sheet shows it beside the new one; what's kept is read
  again, exactly, by the run).
- **The panes:** each has Rendered | HTML and Copy HTML. The New pane's Rendered draws
  `Signature.stored(render)` (what Gmail will hold); its HTML is the render, the argv element. The
  sheet's HTML is the held element itself (`Pending.body`). Current is the body as GAM showed it, or
  "No signature set.", "Reading their signature…", or the read's error (Gmail off: GAM's words and the
  remediation). The same Current pane is the Mail tab's "Gmail signature" card, with "Change
  Signature…" opening Signatures for that person (off for a suspended person, said in words).
- **The Rendered view (D1)** is a `WKWebView`: no script, a non-persistent store, the rule list compiled
  once a launch and added before the first load, every navigation but its own `loadHTMLString(_,
  baseURL: nil)` cancelled (links, forms, a meta refresh, subframes, a dropped file), no new windows, no
  context menu, link preview, magnification or swipe back. Without the rule list nothing is drawn; a
  page that fails to load says so and shows its HTML.
- **The editor** is an `NSTextView` with quote and dash substitution, text replacement, spelling and
  grammar correction, completion and link and data detection off: the system's smart quotes would make
  the curly-quote-in-a-tag trap themselves. The template and the person are kept per window while the
  app runs (`@SceneStorage`); another domain clears the person.
- **The sheet** (`SignaturePreviewSheet`, beside the other confirm sheet: `WriteRouteTests` allows the
  operator's confirmation in that one file): "Replace Alice Anders's signature", the New and Current
  panes, the warnings, `SignatureChanges.keptFirst` ("Gmail keeps no copy, so it's read and kept on this Mac first"), the command with
  the body masked, and Cancel and "Replace Signature", both off while it runs (the sheet stays until
  the run ends).
- **The result** is a banner above the screen: "Replaced …'s signature. The one it replaced is kept on this Mac." with
  "Put Back…" (the run's kept signatures, previewed), or
  "Couldn't set the signature." with the remediation and GAM's error in a disclosure. It's announced
  once, from the window in front, and never reads the signature aloud. Saved templates' messages and the
  copy's report are announced the same way.
- **Saved templates:** Load and Delete per template, each named for VoiceOver ("Load Classic", "Delete
  Classic"); Delete and replacing on Save As are confirmed, saying no copy is kept; the quarantine
  notice names the file kept aside and where; "Copy Templates from GamGUI" shows only when GamGUI's file
  exists and never in demo mode, and reports copied, kept and left out.
- **Demo mode** keeps its templates in a fresh temporary folder each launch, never the operator's.
- **Who** (S2): "Set it for" (One person, A group's members, Everyone in an org unit, The whole company),
  then the person, a group from the tenant's groups, or an org unit; each kind says suspended accounts are
  left out. For a unit or the company, New is the render for the first of them ("Each person gets their
  own") and the button says "Review for N People…"; for a group, "Review…" (its members are read then).
- **Screenshots** (`scripts/screenshots.sh`): `signatures` (nobody: the demo admin isn't in the
  directory), `signatures-alice` (Classic loaded; Current is `Best,<br>Alice`), `person-mail` (the card),
  `narrow-signatures` (the smallest window), `signatures-staff` and `narrow-signatures-staff` (everyone
  in /Staff, Classic loaded), and `signatures-kept` and `signatures-putback` with their narrow runs. `cacheDisplay` draws a web view blank (WebKit draws in
  another process), so the debug snapshot draws each from its own `takeSnapshot` over its place.

## Kept signatures and Put Back (GamGUI #163, #164; ported 2026-11-21)
Gmail keeps no copy of a replaced signature. Every write Signatures holds keeps the one it replaces on this Mac first,
and Put Back sets a kept run's old signatures again, as a run of its own.

- **ChangeCore does the keeping (invariant 2).** `SignatureChanges.step` is the only place Signatures builds a write: each
  carries `WriteStep.KeepFirst.signature(email:setting:expectedNow:)`, plain data, never a closure. The preview refuses one
  whose `email` and `setting` aren't exactly its own write's (`keepHolds`: `GamCommands.setSignature(email, setting,
  html)`'s argv, byte for byte), or that may wait for a new account (`.badKeep`). In `Executor.run`, holding the write lock
  and after every pre-step check, a preview with such a step starts a kept run through the injected `SignatureKeeper`
  (Stores' `SignatureBackupStore`, given by `AppServices`); none, or one that can't start, refuses the whole run: "Couldn't
  make a place on this Mac to keep the old signatures, so nothing was replaced." Then, per step, before its begin record:
  - read `user <email> print signature` and `Signature.exact` it;
  - **unread** (GAM's error, no getting line, no whole row, a cut answer): the step fails, "Couldn't read their current
    signature, so it wasn't replaced: there'd be nothing to put back." with why, and the run goes on, unless the error is
    account-wide (the usual stop: "Stopped: <remediation>"), a Vault or launch failure (stops), or a cancel (stops);
  - **the domain changed** during the read (removed or imported again: its generation moved): skipped, and the run stops
    there, "Stopped: the active domain changed during the run." (the read takes seconds, so the per-step check before it
    isn't enough);
  - **changed since** (`expectedNow` set and the read differs in bytes): skipped, "Changed since that run, so it's left as
    it is: put it back by hand if you mean to.";
  - **keep** `(email, previous, setting)`; if that throws, this step and every later one are skipped, "Couldn't keep a copy
    of the old signatures on this Mac, so the run stopped.";
  - only then the begin record (its `extra.kept` names the kept run) and the held write.
  The kept run closes when the run ends (removed if it kept nobody); `RunOutcome.kept` names it when it kept someone.
  `WriteRouteTests`: only ChangeCore calls the keeper, only `AppServices` gives it one, and every `setSignature` a screen
  builds is Signatures' one keeping step or onboarding's. The executor itself refuses a `.setSignature` step with neither
  `KeepFirst` nor `newAccountFrom` (`signatureNotKept`: "Step N would replace a signature without keeping the one it
  replaces."): only a signature on an account the run makes keeps nothing. Onboarding's retry of a failed signature, a
  later run on an account that has been there since, keeps first (GamGUI's keeps nothing there).
- **The exact read** (`Signature.exact`, GamGUI's `signature_exact`), from GAM 7.52.04's printShowSignature and its CSV
  writer, read to the end: exit 0; "Getting Signatures for" on stderr (GAM skips a refused token without a word: titles
  alone, exit 0); exactly one whole row whose `User` is the person (lowercased); the `signature` cell, or "" when there's
  no such column (GAM's titles never hold one: Gmail leaves an empty signature out). GAM's titles: User, displayName,
  sendAsEmail, replyToAddress, isPrimary, isDefault, treatAsAlias, verificationStatus (`sortall` keeps them first), then
  `signature` sorted after. The CSV is read with `CSVReader` (GAM's dialect: a quoted cell, `""`, a doubled backslash).
- **The store** (`SignatureBackupStore`, GamGUI's `signature_backups.py`): `signature-backups` in the app's data folder,
  `0700`, opened without following a link; one `<13-digit ms>-<8 hex>.jsonl` per run, `0600`, `O_CREAT|O_EXCL|O_NOFOLLOW`;
  a header `{run, when, what, domain}` (`what` is the run's jobs-tray title), then `{email, previous, set}` lines, each
  `F_FULLFSYNC`ed before that person's write. Room is made only when a run that kept someone ends: the newest 5 runs not
  being written stay, and so does the run it put back (KeepFirst's `restoring`, the Put Back's source, passed to `start`),
  which then lives until a later run that keeps someone pushes it out. Nothing is pruned when a run starts, and a run that
  kept nobody is removed on close without pruning anything. `runs()` lists every regular `<id>.jsonl`, newest first, whole or with its problem (never
  dropped; a last line without a line break is an append that never finished, whose person was never written, and is
  left out, where GamGUI reads the run as not whole); `load(id)` refuses an id with `/`, NUL or a leading `.`, picks only among the listed files, and gives the
  whole run or a problem, never part of one. At most 32 MB a file, read or written (invariant 9).
- **Put Back** (`SignatureChanges.previewPutBack(id)`): loads the run now; refuses a run of another domain ("That run was
  on example.org, so it's put back only there: connect example.org on Setup first.") or one that can't be read ("That run
  can't be put back: <why>."); leaves out, by name, anyone whose old signature GAM would read as a file to load
  (`readAsKeyword`) or store as something else (`Signature.stored` differs); holds the rest as keeping steps that set
  `previous` with `expectedNow` = `Signature.stored(set)`, titled "Put back of <what>" (so its own kept run says so, and
  can be put back too), confirm step and the count typed above 25. It runs as a scope does (jobs tray, Stop, progress
  counting "left as they are"); its result: "Put back X of N signatures.", and "K were left as they are, changed since
  that run: …". No Retry (nothing to re-render).
- **The screen:** "Kept signatures", the Signatures form's last section: what's kept and for how many runs, then each run
  (its title, when, domain and how many) with Put Back… (off on another domain, said in words); an unreadable run is
  listed by its id with why, and a folder that can't be opened or listed says so ("The kept signatures couldn't be read:
  …"), never "None kept yet." (`runs()` throws; only no folder at all is none). Read when the screen opens, after each run, and with ⌘R (Read Again reads the person's
  signature and the kept runs); every run that ends reads them again itself (`SignatureChanges.loadKept` after each
  `executor.run`, one that set nobody too), and a read asked for while one is under way is read again as that one ends.
  `SignaturePutBackSheet`: who goes back (ten, then Show all), the first one's old signature,
  who is left out and why, the count typed above 25, what the run checks first, the commands masked; not the default
  button. Each result banner has Put Back… for the run it just made, a one-person write whose outcome is unknown (a
  timeout or an interruption: it may have landed) included; a write GAM refused changed nothing and offers none. Screenshots: `signatures-kept`, `signatures-putback`
  and their `narrow-` (smallest window) runs, from `Tests/Fixtures/demo/signature-backups` copied into a fresh folder.
  No new column, so `ColumnWidths` is unchanged.
- **Deviations from GamGUI, each tested:**
  - the getting line is GAM's "Getting Signatures for" (gamlib `Ent.SIGNATURE`'s plural). GamGUI looks for "Getting
    Signature for", which only its mock prints: against real GAM its every read would be "unread" and no signature
    replaced. Reported to the operator; GamGUI isn't edited from here;
  - the CSV isn't stripped (GamGUI's `parse_records` strips the whole text, so an unquoted signature, the last cell,
    loses its trailing whitespace); a row with more cells than titles, two `User` columns, or an answer cut at the
    capture's cap is unknown;
  - the header names the domain, and Put Back runs only there. GamGUI keeps one folder for every tenant and its header has
    no domain, so a Put Back after a tenant switch would read and write the other tenant's addresses;
  - a person changed since is skipped ("left as they are"), not a failure, so no Retry offers them;
  - the unread failure carries why in its message (GamGUI keeps GamGUI's sentence and puts why in a detail);
  - a keep that fails partway is cut back off the file, so the copies before it stay readable; a file never passes the
    cap a load reads (the run stops instead);
  - a read cut off by its timeout is "unread", not `.timeout` (which says a change may have been made);
  - pruning happens when a run that kept someone ends, never when one starts, and never takes the run a Put Back is
    restoring. GamGUI prunes as a run starts: putting back the oldest of five deleted it before the first step, so whoever
    that Put Back didn't restore (left out, changed since, unread, stopped) lost their only copy; and an attempt that
    kept nobody still pushed out the oldest real run (review of this branch, 2026-11-21);
  - a run being written holds an exclusive `flock` on its file, and pruning skips any file it can't lock: no store, in
    this process or another copy of the app, removes an open run (GamGUI's guard is one process's set; a lock is tried
    for up to 200 ms, since a closed run's can outlive its close for a moment, seen once in three full suite runs); each keep then
    checks its file is still linked (`fstat` `st_nlink`), so a copy is never "kept" into a removed file;
  - run ids only go forward: a new id's milliseconds are the clock's or one past the newest run's, whichever is later, so a
    clock set back never makes the newest run sort, and be pruned, as the oldest (GamGUI's are the clock's alone).
- **Not verified live** (none of it): the getting line, the titles and the CSV against real GAM; that Gmail stores and
  returns a signature exactly as GAM sent it in `html` (if it normalizes, every Put Back reads "changed since" and puts
  nothing back: safe, but owed a check); a kept run's file after a real run.
- **Parity:** `GamCommands.printSignature` is GamGUI's `print_signature`, held to `argv.json` (generated from GamGUI
  d03f5a6, `GoldenArgvTests.implemented`); `gam_output.json` holds the mock's answer for GamGUI's own read of it.

## The mock (`Tests/Fixtures/mock_gam.sh`)
- `show signature` prints GAM's shape for the address given, with the indent; with `GAM_MOCK_STATE`,
  the body the mock last set, in the form GAM stored it.
- A set for an address that isn't a user fails on its token, as every per-user write does
  (`invalid_grant: Invalid email or User ID`, exit 50, classified `.notFound`); Gmail off for the user
  (`nogmail/<user>`) is refused (exit 1); a keyword body never sets anything: a file keyword fails to
  read `html` (exit 6), a document keyword wants its file (exit 2; wording approximate).
- Accounts `create user` made are known users while the mock keeps state, so onboarding's signature set
  reaches the same handler.
- `print signature` (the exact read), from printShowSignature's print mode at 7.52.04, read to the end: "Getting
  Signatures for <u>" on stderr; CSVPrintFile's own titles (User, displayName, sendAsEmail, replyToAddress, isPrimary,
  isDefault, treatAsAlias, verificationStatus) first and in that order, then `signature` only when there is one (Gmail
  leaves an empty one out of its reply); the person's row, the primary's empty treatAsAlias and verificationStatus; the
  signature the mock last set, in the form GAM stored it, or the canned one `show signature` has. Its cell is written by
  `gam_cell`, which now quotes a value holding a CR or a LF and writes the line breaks as they are, as CPython's csv
  writer does in GAM's dialect (a backslash doubled, a quote doubled, no quoting for a backslash alone). A refused token
  (`quiet/<u>`) is the titles alone, exit 0; Gmail off, exit 73 and the titles alone; not a user, the token's refusal
  (exit 50). Other options (`compact`, `primary`…) aren't modelled. A just-created account still being set up isn't
  modelled for this read (the app never reads one: a new hire's signature keeps nothing).
- Approximations, invisible to the reader: the mock's strips are ASCII whitespace only.

## The store
- **Where:** `signatures.json` in the folder the caller names. The app's is `SignatureStore.defaultRoot`
  (`Application Support/SwiftGamGui`, beside the audit log); one store for every tenant, as in GamGUI.
  The store has no default folder, so a test or a fixture generator can't open the operator's file
  by leaving it out (GamGUI failure-log 2026-09-25). `neverTouchesRealAppData` holds that.
- **Format:** `{"version": 1, "templates": {name: body}}`. `version` is a format number, so the later
  history format (it comes with "Just do it", design doc §8) migrates the file rather than guessing.
- **GamGUI's, byte for byte** (`core/signatures.py:152-246`):
  - its three starters (Classic, Modern accent, Minimal) when there is no file; nothing is written
    until a save. An emptied store stays empty: the starters come only when there's no file at all;
  - a name is stripped as Python's `str.strip` strips (U+00A0, U+3000 and U+001C to U+001F count; a
    zero-width space doesn't), required, and at most 60 code points (not `Character`s, not UTF-16);
  - the body must not be blank after the same strip, and is kept as typed;
  - the messages: "Template name is required.", "Template name must be 60 characters or fewer.",
    "Template body is empty — put some HTML in the editor before saving." Checked in that order;
  - `names` in Python's `sorted` order: code point by code point. Swift's `<` treats "é" and "e" +
    U+0301 as equal, and UTF-16 order puts an emoji before U+FF5E;
  - names are distinct by exact text: "é" and "e" + U+0301 are two templates, as they were in GamGUI.
    The store keys by `JSONObject`, never a Swift `Dictionary`, which would merge them.
- **Native, where GamGUI could lose templates:**
  - **atomic writes:** a new file in the folder, filled and flushed, then renamed over the old one. A
    failed save leaves the old file whole and removes the new one;
  - **private from creation:** the folder is made (or set back to) `0700` before the file is created
    `0600`, so neither is ever looser, whatever the umask;
  - **an unreadable file is moved aside, never replaced:** anything that isn't this format's templates
    (bad JSON, another version, GamGUI's own shape without `version`, a non-text body, invalid UTF-8,
    over 4 MB, a link, a FIFO, a folder) is renamed to `signatures.json.unreadable-<UTC time>` (`-2`,
    `-3`… if taken, never over another) and named in `quarantined` for the screen to report; the store
    then shows the starters. GamGUI showed the starters too, and its next save destroyed the operator's
    file (`signatures.py:205-213`). A file the store can't open at all (permission denied) is left
    where it is, and the store doesn't open, so nothing can save over it;
  - **replacing is asked:** saving over a saved name throws `.exists` until the screen asks and calls
    again with `replacing: true`. Delete is the screen's to confirm. Neither keeps the old body;
  - **bounded:** a load reads at most 4 MB, and a save that would pass it is refused (`.tooLarge`), so
    the store never writes a file its next load would move aside.
- **Copying GamGUI's templates** (`copy(fromGamGUI:)`, an explicit action, once): GamGUI's file
  (`SignatureStore.gamGUIFile`) is only read, by descriptor as invariant 5 reads credentials: opened
  without following a link or blocking on a FIFO, a regular file under 4 MB, read from that same
  descriptor. Names the store lacks are copied; a name with another body keeps this app's and is
  reported (`kept`); identical ones are skipped; a name or body this store wouldn't save is left out
  and reported (`refused`). One save, only when something was copied. The screen shows the action only
  when GamGUI's file exists, and never in demo mode (S1c).

## Testing
- `SignatureScopeTests` (S2, 19 cases: with the failure sample's cap and a preview outdated while reading): GamGUI's `test_signatures.py` scopes, `test_users_web.py`'s
  signature apply cases, `test_retry_failures.py`, `test_jobs_tray.py`'s Stop and
  `test_write_routes_guarded.py`'s edited scope, against the strict mock (its `nogmail/` refusal for a
  failure; a wrapper for a slow write and a missing scope). The mock needed nothing new: the set, its
  failures and `print group-members` were already GAM's.
- `signatures.json` holds GamGUI's render (1,920 renders over the mock's directory and crafted people,
  including values that hold `{variables}` and `[[`), its curly-quote warning (1,530 templates), its
  reader (25 texts), its seeds, its store's messages and order, and GAM's own stored form and keyword
  reading.
- `SignatureStoreTests` holds the store to the fixture's messages, names and seeds (`Signature.seeds`,
  the one copy), and to what GamGUI's store did for crafted names.
- Mutants of the core and the mock (2026-10-10, 19, all killed): `{role}` from another field, a token
  skipped short, blocks dropped when set, `]]` overlapped, a curly quote left out, the warning's words,
  a blank line ending the read, `None` kept, only `\n` splitting lines, CR kept, `<br>` for `<br/>`,
  `_` kept or the body unstripped for the keyword; the mock showing canned text over a set, answering
  any address, taking a keyword body, storing the argv, not indenting, or ignoring Gmail off.
- A save is interrupted halfway (an internal `interrupt` hook) to prove the old file survives, and to
  observe the new file's mode at that moment.
- Mutants the suite kills (2026-10-10): a non-atomic write, no folder chmod, the file created `0644`
  or chmodded only after the rename, a corrupt file overwritten, a quarantine over an earlier one, a
  permission error treated as corruption, the temporary file left behind, memory updated before the
  write, a silent replace, Swift's or UTF-16 order, `Character` or UTF-16 name length, Foundation's
  whitespace, canonical-equivalence keys, links followed, no size cap, any version accepted, a copy
  that overwrites or takes refused names, and starters written on load.
