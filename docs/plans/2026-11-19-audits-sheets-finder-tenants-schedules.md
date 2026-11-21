# Plan: audit runs, Sheets export, a plain-English finder, tenant switching, schedules

**Status (2026-11-20): F2 built (Swift); F1 built in GamGUI (#170), its port next; F3 being built in GamGUI.** Asked for by the operator ("we should be"): ready-made audit runs,
direct Google Sheets export with a place to browse outputs, the on-device model turning plain English into checked GAM,
switching across Workspace tenants, and scheduled runs. That ask lifts the "not planned unless asked" entries for Sheet
export, scheduled runs and a plain-language finder (filling-the-gaps, and GamGUI's finish-the-roadmap D1), and design
doc §1's "Sheet export: dropped". Those plans' rows point here.

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

### F6 — Tenant switching from anywhere · *both apps*
A domain menu in the toolbar when more than one domain is connected; choosing one runs the same `checkAccess`
(switches only on a pass, Touch ID if the Vault session ended), disabled while busy, warns that a run in progress stops
after its step. VoiceOver: "Domain, <name>". Templates and roles stay shared across domains.

### F7 — Schedules · *a: both apps; b: Swift only, gated*
- **F7a — Due, attended.** A saved audit run (F3) or named report (F2) gets a cadence. When it's due, a notification
  ("License usage is due"); opening it runs it with one Touch ID. Reads only, never a write, a sensitive read or a Sheet
  export. Last runs kept bounded on disk for "changed since last run" (tenant data at rest in Application Support,
  `0700`): a count per run, chosen by the operator.
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
