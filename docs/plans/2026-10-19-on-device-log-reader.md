# Plan: an on-device reader for security logs

**Status (2026-10-19): PLANNED, not started.** Builds after the report reads merge (the compromised-account
sign-in and app-grant reports, and the message pull's Gmail log). The operator asked for it during a live
incident: "make it so AI could read those logs via local model".

## Why
In the 2026-10-19 incident (one account taken over, then used to mass-send phishing), the logs answered every
question that mattered: when the attacker got in and from which IP, everyone who received the email, everyone
who clicked its link, whether the lock held, whether a second mailbox was touched. Getting those answers meant
grouping about 100,000 rows of Admin console exports by hand. One false lead (a colleague's reply listed under
her own name made her mailbox look compromised) cost a wrong call to the operator. The app should do the
grouping in code, then have the on-device model explain it in plain words.

## The rule
- **Read-only.** The model reads a summary and writes text. It never builds, runs or proposes a command
  (invariant 10; the reader's code stays apart from anything that can run gam, as `App/ModelSpike.swift` does).
- **On-device only** (`SystemLanguageModel`, design doc §8). Tenant data never leaves the Mac; no cloud fallback.
- **Code finds, the model explains.** Every count and flag comes from deterministic code with tests. The model
  only words them, and each finding it writes must cite a summary item; a finding citing nothing known is dropped.
- **Works with no model.** Without one (unavailable, Apple Intelligence off, assets downloading), the screen
  shows the summary and its flags alone, and says why in words.

## The pieces
1. **Rows in.** Any GAM activity report this app reads (`report gmail`, `login`, `token`, `drive`, `takeout`,
   `mobile`, `chat`, `calendar`). All share one shape: actor, time, IP address, event name, plus event
   parameters; check each one's printed columns against GAM's source before use. Also an **Admin console CSV
   export** of the same logs, as the operator used today: read with a size cap, its columns matched by name,
   never trusted as instructions.
2. **The summary** (`Assist`, pure Swift): bounded, so it fits the model's small context window (measure it on
   this Mac with the spike; plan for a few thousand tokens):
   - per IP address: events, mailboxes touched, first and last time;
   - per person: event counts, IPs new for them this window;
   - clicks on a link domain, and who clicked;
   - sends per hour per sender;
   - anything after a time the operator gives (when the account was locked).
3. **Flags, by rule, in code:**
   - one IP acting in more than one mailbox, checked against who sent the message so a reply listed under
     its sender isn't read as a break-in;
   - a sender far above their usual volume;
   - clicks on a domain the operator names;
   - any activity after the lock time;
   - IPs from hosting providers, when that can be told without a lookup service (otherwise left out).
4. **The explanation** (`Assist`, FoundationModels): a `LanguageModelSession` with fixed instructions, given the
   summary as compact text, answering in a guided-generation `@Generable` shape: a short summary, findings
   (each with the summary item it cites), and next checks in words. Shown labelled "written by the on-device
   model", beside the summary it came from.
5. **The screen:** "Explain" on each report screen and on a CSV the operator opens; a lock-time field; the
   summary tables; the explanation. Accessible as built: VoiceOver reads each flag in words, not colour alone.

## Slices
- **R1, summary and flags, no model.** Rows in (one GAM report plus the CSV import), the summary, the flags,
  the screen. Useful on its own; most of the value.
- **R2, the model's explanation.** Availability states, the guided shape, the citation filter. Tests run on a
  stub, since CI has no model; the real model is checked by hand on this Mac.
- **R3, every report.** The other activity reports, once their reads exist.

## Tests
- The summary and the flags: fixture rows (`example.com`, made-up IPs), each rule with a case that fires and
  one that must not (a colleague's reply listed under her name, the bounce of a mass send).
- The CSV import: column order changes, a missing column, an oversized file refused, a formula-looking cell
  kept as text.
- The citation filter: a finding citing an unknown item is dropped.
- A source-scan test: the reader's files import nothing that can run gam.

## Not planned unless asked
The model choosing or filling commands, IP lookups over the network, alerts or background scanning, cloud
models, Siri.

## Questions for the operator
1. CSV import of Admin console exports in R1: yes? (It works even where an edition's API lacks a log.)
2. Where it lives: on each report screen, or one Security screen?
3. Flag thresholds: start from the defaults above and adjust after the first real use?
