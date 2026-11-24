# Plan: audit runs, Sheets export, a plain-English finder, tenant switching, schedules

**Status (2026-11-21): F1, F2, F3, F5a and F6 built (Swift); F4 and F5b in review; F7a in GamGUI; signature backups
first (operator, 2026-11-21), built.** Asked for by the operator ("we should be"): ready-made audit runs,
direct Google Sheets export with a place to browse outputs, the on-device model turning plain English into checked GAM,
switching across Workspace tenants, and scheduled runs. That ask lifts the "not planned unless asked" entries for Sheet
export, scheduled runs and a plain-language finder (filling-the-gaps, and GamGUI's finish-the-roadmap D1), and design
doc §1's "Sheet export: dropped". Those plans' rows point here.

**Status (2026-11-21): signature backups first (operator, 2026-11-21).** Before this plan's tasks: every Signatures run
keeps the signatures it replaces on this Mac (ChangeCore reads each exactly and keeps it before the write), and Put Back
sets a kept run's old ones again, ported from GamGUI's #163 and #164 (`docs/domains/signatures.md`, "Kept signatures").

**Both apps.** Per GamGUI's roadmap ("one feature, two PRs, GamGUI first"), each task below that GamGUI can have is
added to its roadmap and built there first, then here from regenerated fixtures. Two are Swift-only, listed deviations
with no parity fixture: **F5** (Apple's on-device model has no Python route) and **F7b** (the Keychain). GamGUI gets
F5's deterministic half (the command glosses) if it wants it.

Read for this plan: the code and plans of both apps (a mapping run, 2026-11-19, checked by a second reader), the D&D
game's model lab (`~/dandd/game/docs/DM-MODEL.md`) and swiftabapit's unattended read-only key (its invariant 3, plan
D5). Model lessons are shared across projects in the user skill `apple-on-device-model`.

## What exists today

| Asked | Today |
|---|---|
| Inactive user sweep | Reports' "Inactive (90+ days)" bucket from the cached directory (`DirectoryReport.swift`), Show in Users; no action |
| Shared Drive ACL export | `print shareddriveacls` runnable in the Builder, CSV export; not a named report |
| License usage | `print licenses` runnable in the Builder; no seats-on-suspended join |
| Classroom audit | Class index, class card, who can create classes, a person's classes (read only); no domain-wide audit |
| Super-admin token review | Connected apps: `print tokens` for every **non-suspended** account, grouped and flagged; not narrowed to admins |
| Sheets export | Refused on purpose: `todrive` is in `keywordsThatChange`; CSV via a save panel, written `0600` |
| File browser | None; exports go where the operator saves them |
| Plain-English → GAM | None; the model only words facts (incident, report, connected apps) |
| Tenants | Several domains connect and switch from Setup (`SetupModel.checkAccess` → `activate`, generation bump) |
| Schedules | None; the Jobs tray holds write runs since launch |

## Tasks, in order

### F1 — Reads are recorded, and every record names its domain · *both apps*
Audit runs and schedules run many domain-wide reads, some sensitive; today reads leave no record (gaps slice 5). Add a
read record (command, domain, origin, row count, no rows) and `extra.domain` on every write record
(`ChangeCore.extra(for:)`). The Audit screen filters by domain. Prerequisite for F2–F7.

*As built (2026-11-21, GamGUI #170 merged as `4eb8165`, fixtures regenerated from it):* every catalog read run from the Builder
is recorded once it ends (`ReadAudit`, written by `UserAccess.catalogRead`: `read`, target, masked argv, `ok`, `extra.command`,
`origin` `builder`, `rows` for a table, `error`, the domain; never the output), and every record names its domain
(`AuditLog.record(domain:)`, no default). Audit filters by domain (Unknown for older records), searches it, and exports
GamGUI's three new columns; Home's failures and the incident report pass reads over (`AuditLog.readActions`). The generator
now records GamGUI's `catalog_read` over chosen outputs and a domain-named log (`audit.json` `reads`, `audit_screen.json`).
Listed differences (runbooks audit-reports.md, catalog-builder.md): sensitive reads stay browse-only, the operator's choice, so
`sensitive_read` is read but never written; no `sequence` origin (no Builder sequences here); a read the app quits during
leaves no record (a cancelled one is recorded, in this app's words, though nothing cancels one yet); the domain list bounded
at 100. Not live yet: one Builder read on the operator's tenant, then its record in Audit.

### F2 — Named reports · *port GamGUI 3.1 (#151, merged as `2286631`)*
Nine domain-wide reads by name, each opening its Builder read with CSV export: licenses, shared drives, shared drive
permissions and the rest of #151's table. Fixtures regenerated from GamGUI at its merge.

*As built (2026-11-20):* on Reports, a "Domain-wide reads" section; each pane opens its read in the Builder and says the
access it needs (runbook audit-reports.md). **No fixture regeneration in this PR**, a change of plan: the fixtures' GamGUI
commit (`8f9e766`) is 25 merges before #151, and regenerating brought in that whole drift (a roster planner change, GamGUI's
stores setting a file aside, and more), which is its own PR, a **parity catch-up** to GamGUI's main before the F1 port. #151's
one fixture-held change, the Alert Center scope in Setup's Admin-console link, came with it (offered, never verified, as in
GamGUI). Found on the way: GamGUI's role and signature stores (`RunbookStore`, `SignatureStore`,
since #142) crash on a file that isn't UTF-8 instead of setting it aside; this app sets it aside (a GamGUI fix, from GamGUI).

### F3 — Audit runs · *both apps*
A run is a fixed list of reads (no writes), started by the operator, Stop between steps, each step's table kept for
the run, bounded (invariant 9). The five asked for:
1. **Inactive users**: the bucket with a window picker; flag anyone created inside the window (a new hire who hasn't
   signed in); "Suspend these…" is one previewed write per bucket (roadmap D3 / 3.3), targets re-read at preview.
2. **Shared drive permissions**: every shared drive's ACL; external and "anyone with the link" rows first; drives whose
   only organizer is suspended or leaving.
3. **License usage**: `print licenses` joined to the directory: seats on suspended accounts, seats per SKU (roadmap 4.3).
4. **Classroom**: all courses with owner, state and counts; classes owned by suspended accounts; stale classes. Read
   only, offline until an Education domain is there to check it (the Classroom plan).
5. **Admin token review**: `print admins` joined to `print tokens` **including suspended admins** (today's report
   skips them); AI and broad scopes flagged. Revoke stays in Incident's previewed flow.
GAM grammar lines and output fields are read from GAM's source at the pin when each is built; the mock answers as GAM
does (CLAUDE.md, "the mock lies").

*As built, first half (2026-11-21, GamGUI #171 merged as `086d2f8`, fixtures regenerated from it):* Reports lists **Audit
runs**; each run is a pane (`AuditRunPanel`) over `AuditRunner` (the steps, Stop between them, each step's table kept for
the tenant) and `AuditRuns` (GamGUI's `core/audit_runs.py`: the steps, the unknown rules, the tables and flags). Each step
is one `print` read without `todrive` and leaves one read record (`ReadAudit.Origin.auditRun`, command `<run>/<step>`).
Inactive users (window 30 to 365, flags `new account` and `admin`) leads to **Suspend these…** (`InactiveSuspend`, GamGUI's
Reports preview, roadmap 3.3, which this app didn't have): the directory read again, the connected admin left out, one
previewed write through the executor. License usage joins `print licenses` (new builder) to the directory. The generator
now runs GamGUI's own audit-run code and `audit_read` over edge cases (`audit_runs.json`), so the port is held to it.
Listed differences (runbook audit-reports.md, "Audit runs"): a run isn't in the jobs tray (which lists the executor's
writes; its Stop is on its pane, and it goes on while another screen shows); a domain switch stops a run (GamGUI reads on
and discards); Suspend these… is reached from the run only. Not live yet: one run of each on the operator's tenant (reads),
counts checked against the Admin console (Billing → Licenses).

*As built, second half (2026-11-21, GamGUI #172 merged as `db579c7`, fixtures regenerated from it):* Shared drive permissions
(each drive's own members, users and groups only: outside members first, drives no active organizer looks after, drives GAM
listed but didn't read the members of; no claim about link sharing), Classroom (every class with owner, state and counts;
suspended and unlisted owners; stale classes) and the admin token review (`print admins recursive`, a holder GAM couldn't name
joined by ID or kept as unknown, then `print tokens users` for those admins, suspended ones included; AI by name and broad
access flagged). A step whose 56 or 73 keeps its rows is `partial` and its read record says so; a read for an earlier
step's people doesn't run when that step has no answer. Four builders ported (`printSharedDrives`, `printSharedDriveACLs`,
`printAllAdmins`, `printTokens(users:)`) and `printCourses(counts:)`. "Being offboarded" is an offboarding started in this app
(`OffboardChanges.leaversStarted`). The generator holds all of it to GamGUI's own code. Not live yet: none of the three; the
Classroom run waits for an Education domain.

### F4 — Sheets export and Files · *both apps; reverses design doc §1*
- **Export to a Google Sheet…** beside Export CSV…, a curated **write** through ChangeCore: the preview holds the read's
  exact argv plus `todrive` options, says the Sheet holds a **fresh read** (its rows can differ from the table on
  screen), is audited as `export_to_sheet` (or `sensitive_export`), and shows the URL GAM prints as a link.
  `keywordsThatChange` stays: `todrive` is never a typed value.
- Defaults (change on the operator's word): owned by the connected admin, never shared, `tdnobrowser` and `tdnoemail`
  passed (GamGUI passes neither: a listed, tested deviation, or GamGUI adds them too).
- First: the mock prints GAM's real `todrive` output from `CSVPrintFile` at the pin (today it prints the CSV); then a
  parity fixture; then one live export on the operator's yes. G3-style scope check: the service account's Drive scope.
- **Files**: a read-only list of what the app made: exports it saved (a bounded recent list: path and time, Show in
  Finder), Sheet URLs read back from `export_to_sheet` records, incident evidence folders. Runs no `gam`, never lists
  the run or setup folders.

*As built, F4 (2026-11-21; GamGUI #174, `38ea01b`, fixtures generated from it):* Export to a Google Sheet… beside the Builder's
Export CSV… (⇧⌘E), for a table GAM's `todrive` takes: a curated write (`SheetExports`, `GamCommands.exportToSheet`), its preview
holding the read's exact argv then `todrive tdtitle "<domain> - <command>" tdnobrowser true tdnoemail true` (GamGUI's
`todrive_args`, held to `argv.json`), after a Drive and Sheets scope check (a refused scope offers no Export, with Setup's link,
which now offers the Sheets scope: `setup.json`); run once from that preview, audited `export_to_sheet`, its outcome read from
the upload's own lines (`SheetExport`, GamGUI's `sheet_export.py` word for word; the executor keeps what a write's output says,
`RunOutcome.noted`, and which steps ran, `began`). Every read path refuses a read carrying `todrive` in any spelling GAM reads.
The mock answers `todrive` as GAM 7.52.04's `writeCSVToDrive` does, read from GAM's source (GamGUI's mock the lead). Files, a
sidebar screen, read only: the Sheets read back from the log, each incident's evidence counted by descriptor, the CSVs saved.
Runbooks catalog-builder.md, guard-audit.md, gam-runner.md, setup-credentials.md; SECURITY.md. Deviations from GamGUI, each
listed there: two records per export (begin, end), never `sensitive_export` (sensitive reads stay browse-only); Files also lists
the last 50 CSVs saved through a save panel, and has a sidebar entry; a catalog command whose `todrive` is on a later grammar
line isn't offered (this catalog holds first lines); the export also refuses a read that isn't a `print`/`report` read; a link
is stricter (no empty port, `[`, `\`); GAM's error is shown, not behind a disclosure. After its review (2026-11-21): "Nothing
was made" only where GAM's source shows no file exists (Drive off, Create Failed and Not Created are unknown; Create Failed is
GAM's own `Drive Folder: root` line only; the last line naming another account than the admin's primary address is unknown),
each a deviation from GamGUI's `UPLOAD_LINES`, which have the same gaps; the runner refuses a read carrying `todrive`; Files reads
only export end records through checked descriptors and lists every CSV save panel. The regeneration brings GamGUI #172's
and #175's builders, listed as not ported (`print_courses` takes `counts` as GamGUI's does); `audit_runs.json` stays at
`086d2f8`, #172's three new runs being F3b's to port. Not verified: no export has run on a real domain (the first waits on the
operator's yes); the mock's upload lines are GAM's source, never seen live; screenshots come from CI.

### F5 — Plain English to a checked command · *Swift only; the D&D model's method*
The model never writes GAM syntax. It narrows and fills; code checks and builds; the result is a draft (invariant 10).
1. **Descriptions without a model**: port GamGUI's `gloss()` (grammar-derived) so all 1,052 commands have words to be
   found by; plain search improves on its own.
2. **Narrow in steps** (the whole catalog's names are ~3,800 tokens, half the 8,192 context; past ~40 choices picks get
   worse): pick a **category** (54, ~200 tokens) → pick a **command** in it (Users, 418, through its subcategories) →
   **fill that command's slots** from its own grammar line. Curated builders are offered first. Each step: a fresh
   session, `DynamicGenerationSchema` `anyOf` the listed ids (plus "none"), labels only, greedy, a short reasoning field
   first, no example sentences.
3. **Slots copy the operator's words**; code checks each: a closed set is its type, a person or group is looked up in the
   cached directory (not found → flagged, never invented), one re-ask naming the fault, then the slot is left empty.
4. **Ambiguity**: three samples; if they split, ask with the two options named.
5. **Code builds** through `GamCommands.catalogRead` / the curated builder: the parity-held argv, the `todrive`/`doit`
   refusals, required slots. The Builder opens with the command and fields filled and the exact `gam` line shown. A read
   runs on Run; a curated write goes to its preview and confirm. The model reads only the operator's own sentence.
6. **Measured, not guessed**: Apple's Evaluations framework under `swift test`, on demand (`SWIFTGAMGUI_MODEL=1`):
   ~30 samples from the operator's kinds of request, a held-out split, code metrics (right command, right slots, no
   invented value, latency). Kept only if it beats plain search on the held-out samples.

*As built, F5a (2026-11-21, step 1; GamGUI `d03f5a6`, fixture generated from it):* GamGUI's `gloss()` and its noun tables
ported (`CommandGloss.swift`), so all 1,052 catalog commands carry their words (`Command.gloss`), each held byte for byte to
GamGUI's own run over this repo's catalog (`catalog_glosses.json`, `scripts/gen_catalog_glosses.py`, run by `bump_gam.py`).
The Builder's search finds GamGUI's finds plus a command whose gloss holds every word typed ("backup codes", "chrome
devices"), its rows read "Reads · List users." as GamGUI's do, and a command's page leads with it (runbook catalog-builder.md).
GamGUI's #132 (continuation lines joined) isn't ported; over GamGUI's own catalog one gloss differs, so the fixture is GamGUI's
code over this repo's catalog. About 80 glosses say little (a placeholder for a verb, "Calendar.", "Create for a user.", one
"Show details for for"): GamGUI's to fix first. Not done: the model (steps 2 to 6, F5b), and screenshots from CI.

*As built, F5b (2026-11-21, steps 2 to 6; Swift only):* **kept**: on the held-out samples the finder found the right command
for 6 of 13, the Builder's search for 1 of 13 (first result and top three alike). `CommandFinder` (Assist) takes the commands
as plain words (the runnable reads' glosses, the curated commands' names), so the model module still reaches no command; the
Builder's Ask in Plain English… sheet (`App/PlainEnglishFinder.swift`) hands back a `FinderDraft` (an id and the fields' words)
through `requested`, and the Builder fills the fields and shows the exact `gam` line: Run, or Preview… and confirm, as always
(`WriteRouteTests.theFinderReachesNoRunOrTicket`). Runbook catalog-builder.md has the details. Changed from the plan, each by
measurement on the dev samples:
- **See or change comes first**, a two-way pick with no none (every request is one; offered none, it said none for 2 of 22
  questions). A change picks among the curated changes alone and a read never reaches one. Offered first as a pick of their
  own, the curated commands drafted changes for questions ("Is bob suspended?" became Suspend account; "does carol have an
  auto reply turned on", Set vacation): a pick almost never says none. Curated reads lead their categories' lists instead.
- **Categories largest first**, with a line naming the subcategories of the one big category ("Users holds: Calendars, …"):
  its bare name doesn't say a person's signature or Drive files are in it, and asked for them the category pick said none.
- A text field shows GAM's grammar word (`Device (<CrOSDeviceID>)`): without it, "chromebook" was copied into a device-ID field.
- **A choice is held to the request's words too** (left at its default otherwise): given "put alice in the sales group", the
  model filled Role with member, which the request never said; the same pick could have been owner. Found by the held-out
  run's no-invented-value check, so the held-out numbers below are given before and after.
- Alike glosses (`print users` and `print users select …`) are one choice; the filled fields pick among them.

Measured with Apple's Evaluations under `swift test`, on demand (`SWIFTGAMGUI_MODEL=1 swift test --package-path Packages/GamKit
--filter CommandFinderEvals`): 22 dev and 13 held-out requests of the operator's kinds (user lookups, group membership,
licenses, signatures, offboarding reads and changes, devices, shared drives, two that nothing fits), against the strict
mock's people, in `Tests/Fixtures/finder` with the saved runs. Greedy, so a run repeats.

| Run (dev) | Right command | Category right | Fields right | Invented a value | Seconds, mean / most |
|---|---|---|---|---|---|
| Plan as written: category, subcategory, command | 8 of 22 | 0.57 | 0.86 | 0 | 3.5 / 6.8 |
| Curated commands a pick of their own, first | 11 of 22 | 0.80 | 0.80 | 0 | 3.6 / 7.4 |
| See or change first | 11 of 22 | 0.67 | 0.90 | 0 | 3.4 / 6.1 |
| No none in see or change; the line naming Users' subcategories; the grammar word | 14 of 22 | 0.76 | 0.92 | 0 | 4.4 / 7.2 |

| Held-out, run once, at the last row | Right first | Right in top three |
|---|---|---|
| The finder | 6 of 13 (asked which of two on 3; the other never the right one) | (no list: one command, or a question) |
| The Builder's search, the sentence as typed | 1 of 13 (the request nothing fits) | 1 of 13 |
| A word ranker (not in the app: commands ranked by the request's words in their name and gloss) | 1 of 13 | 2 of 13 |

After the choice fix, the held-out run again: 6 of 13, no invented value (before it, 1 of 13 had one: the role). See or change
was right on every sample a command fits, in both splits; fields right on every held-out sample whose command was right. The word ranker found
9 of 22 on dev but 1 of 13 held out: a word search fits the words it was written for, where the model's reading of new words
held better. Still wrong on dev (no held-out case is read one by one): "Is bob suspended?" (Users, then no subcategory), "find
all suspended users" (List users, not Find users), a person's groups and "who's in the sales group?" (the wrong category),
"how many licenses" (category none since the Users line), Drive files (Shared Drives), a person's shared drives and a drive's
permissions (the drive list instead), and two people swapped ("give dana access to bob's mailbox" made dana the mailbox's
owner; code can't tell, the exact command and the preview show it). The three-sample ask held the right command on no sample
whose greedy pick was wrong, at two calls (about 1.5 s) each time: kept as the plan says, worth measuring again. Not done:
screenshots (the sheet needs the model, which CI hasn't), and the operator's own use.

*Review (2026-11-21, a gam-command-reviewer pass; none broke invariant 10):* five defects fixed, each with a test that failed
before. A value must be the request's whole words ("Carol" had passed for "Reset Caroline's password", "manager" for "the
managers group", "delete" for "is deleted", "bob" inside bob@gmail.com), and is kept as the request writes it (it had kept the
model's "SENIOR\nENGINEER", and cut "Children's" to "Children": a possessive is dropped from a name only); the eval's
invented-value check uses the same rule. The Builder sets a page's fields from a draft in the page's init and lets the draft
go once taken (it had refilled them whenever the command reopened), and the scan holds what runs as a page appears, and what
that calls, free of any run, read or preview (an `.onAppear { …; run() }` had passed it). Cancel stops the model's work
(the other command's fill had still opened after it). The commands are made once, `FinderCatalog` (Assist and GamEngine
only), for the app and the samples alike. Then the evaluation again, once: held out 6 of 13 (fields right on every one whose
command was right, no invented value), dev 14 of 22, both as before; slower this run (held out 5.8 s mean, 9.4 s at most;
dev 4.6 and 7.6), not looked into. The fixes came from the review, not from held-out results.

### F6 — Tenant switching from anywhere · *both apps*
A domain menu in the toolbar when more than one domain is connected; choosing one runs the same `checkAccess`
(switches only on a pass, Touch ID if the Vault session ended), disabled while busy, warns that a run in progress stops
after its step. VoiceOver: "Domain, <name>". Templates and roles stay shared across domains.

*As built (2026-11-21, ported from GamGUI #173 merged as `c5230a1`; no fixture changed: #173 touched GamGUI's web routes,
vault cache and job words, none of which `gen_fixtures.py` records):* a toolbar button named "Domain, <domain>" (signed in
as its admin) while another domain is stored, its panel listing the others, and the menu bar's Domain menu (Switch
Domain… ⇧⌘D, each domain, Setup…). A switch is `SetupModel.checkAccess`, the one Setup's Check Access runs: it says
first what it would stop and reads nothing until Switch Anyway names those runs, asks again after a pass with no await
before the activation, takes one check at a time, and answers a failed check, a refusing Keychain (Touch ID refused), a
token naming no admin and a second check in GamGUI's words (`DomainMenu`). A switch stops each run after its step ("Stopped:
you switched to <new> — N not attempted." in the tray), drops every per-domain store's state, every change model's preview
and result and the executor's held previews, withholds Retry from runs on the old domain, and makes the window's screen
again. Listed deviations (runbook setup-credentials.md): reads aren't jobs here, so only write runs are warned of; the
menu is disabled while Setup works rather than while any request runs; no unsaved incident export exists to drop.
An adversarial review the same day found nine holes (the wait for Google and an unhanded password not warned of, a
stopped run parked, a preview held past the switch's drop, nil → B called a switch, Setup remade by its own check, a
change through no domain not remaking the screen, a stale warning, no scan on the agreement to stop): each fixed, with
a test where one can be written (runbook setup-credentials.md). Not live yet: a switch between two real domains.

### F7 — Schedules · *a: both apps; b: Swift only, gated*
- **F7a — Due, attended.** A saved audit run (F3) or named report (F2) gets a cadence. When it's due, a notification
  ("License usage is due"); opening it runs it with one Touch ID. Reads only, never a write, a sensitive read or a Sheet
  export. Last runs kept bounded on disk for "changed since last run" (tenant data at rest in Application Support,
  `0700`): a count per run, chosen by the operator.

  *As built, F7a part A (2026-11-24, ported from GamGUI #176 merged as `73498c4`, fixtures regenerated from it):* the five
  audit runs each take a cadence per domain (daily, weekly, monthly; GamGUI's due rules, month ends clamped) and say when
  they're due on Home (a card, due first; ⌥⌘1–5 open a run) and at the top of the run's pane on Reports; the pane's Run (⌘R)
  is the one click that runs it, recorded as ever (origin `audit_run`). A scheduled run that read every step keeps its tables
  in `AuditScheduleStore` (`0700` folders opened one from the other by descriptor, never through a link; `0600` files read
  `O_NONBLOCK` as regular files under a cap; 5 runs unless changed, at most 12; 50,000 rows a table; one `flock` for every
  change), and the next run says what's new and gone in each table since the last kept run that read it whole. GamGUI's
  second review's five rules are in: a run with any step unanswered compares nothing; kept runs are ordered by a sequence,
  and a last count dated after now says to check the clock; a save or delete drops the run's stale keep note; an unreadable
  kept run is said and stops the comparison; the folder is held by descriptor and files are read `O_NONBLOCK` as regular
  files only. Per domain: a switch shows that domain's schedules and keeps; Setup's Remove deletes a removed domain's and its
  confirmation says so. The pane, SECURITY.md and the runbook (`docs/domains/audit-reports.md`, "audit-run schedules") say
  the kept tables are tenant data at rest. Also from #176: a shared drive read with no row at exit 0 is unknown, never no
  drive (failure-log 2026-11-24), and both drive tables are partial when a drive's members weren't read. Held to GamGUI by
  `schedules.json` (due days and words in two time zones, changed-since, a run of keeps, prunes and deletes); deviations
  listed in the runbook. **No notification** (follow-up): GamGUI says due only on Home and the run's page, and so does this
  app; a local notification, posted only while the app runs, running nothing and opening only the run's pane, is the
  follow-up if the operator wants one. Not here: part B (named reports' schedules, GamGUI #178, not merged). Not run on a real
  domain; the screens are seen only in CI's pictures.
- **F7b — Unattended, read-only, only on the operator's yes to an invariant change.** Truly unattended runs can't keep
  invariant 4 (user presence on every secret). swiftabapit's answer: an optional **read-only** credential stored without
  user presence, accepted only after every write probe is refused, and usable only by a type with no route to a write.
  For GAM: a **second service account** whose domain-wide delegation holds only `.readonly` scopes, so Google refuses
  any write; a `GamRead`-only runner path; launched by a LaunchAgent; results to the bounded store; never a write,
  `todrive` or sensitive read. It changes invariant 4's text, so it goes through RULE-FEEDBACK and `improve-rules`, not
  this plan.

## Order and checks

F1 → F2 → F3 → F6 → F4 → F7a → F5 → F7b (if asked). Each its own PR off `main`, GamGUI first where both apps have it.
Live checks are read-only on the operator's go; F4's first Sheet export, and every write, needs the operator's yes for
that action. Screens: accessible as built, screenshots per PR.

## Not planned

Writing GAM syntax with the model; tool calling; a browser over the whole Drive; scheduled writes of any kind.
