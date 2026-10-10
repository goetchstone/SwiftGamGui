# Signatures

**One line:** saved HTML signature templates with `{variables}` and `[[optional]]` blocks, rendered for
one person and set as their Gmail signature through ChangeCore. Built so far: the template store (S1b).
The renderer, the parser of `show signature` and the mock (S1a), and the screen and the write (S1c)
follow the plan for signatures (design doc D1–D5). GamGUI's runbook of the same name is the history
this inherits: its render rules, its 2026-09-23 apply incidents and its mock traps all carry over.

**Owns invariants:** #11 for the store's seeds, name rules, order and messages; the store's own rules
below (no template is ever lost to a failed save or an unreadable file).

**Enforcement home:** `Packages/GamKit/Tests/StoresTests/SignatureStoreTests.swift`.

## Files
- `Packages/GamKit/Sources/Stores/SignatureStore.swift`: the store.
- `Packages/GamKit/Sources/GamEngine/JSONValue.swift`: `JSONValue.parse` and `dumps`, Python's
  `json.loads` and `json.dumps`, which the store reads and writes with (shared with the audit log).

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
- `SignatureStoreTests` holds the seeds to GamGUI's source, quoted in the test, and the order and
  messages to what frozen GamGUI's store did when pointed at a temporary path. S1a's GamGUI-generated
  `Tests/Fixtures/signatures.json` takes over from both (a TODO in the test marks it).
- A save is interrupted halfway (an internal `interrupt` hook) to prove the old file survives, and to
  observe the new file's mode at that moment.
- Mutants the suite kills (2026-10-10): a non-atomic write, no folder chmod, the file created `0644`
  or chmodded only after the rename, a corrupt file overwritten, a quarantine over an earlier one, a
  permission error treated as corruption, the temporary file left behind, memory updated before the
  write, a silent replace, Swift's or UTF-16 order, `Character` or UTF-16 name length, Foundation's
  whitespace, canonical-equivalence keys, links followed, no size cap, any version accepted, a copy
  that overwrites or takes refused names, and starters written on load.
