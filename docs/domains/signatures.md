# Signatures

**One line:** saved HTML signature templates with `{variables}` and `[[optional]]` blocks, rendered for
one person and set as their Gmail signature through ChangeCore. Built: the parity core (S1a: the render,
the reader of `show signature`, GAM's stored form, the strict mock), the template store (S1b), and the
screen and the write (S1c, 2026-10-10), following the plan for signatures (design doc D1–D5). Next is
the live check (S1d); a scope as a background job (S2) waits until the operator asks. GamGUI's runbook
of the same name is the history this inherits: its render rules, its 2026-09-23 apply incidents and its
mock traps all carry over.

**Owns invariants:** #11 for the render, the reader, the seeds and the store's name rules, order and
messages; the store's own rules below (no template is ever lost to a failed save or an unreadable file).

**Enforcement home:** `Packages/GamKit/Tests/GamEngineTests/SignatureTests.swift` and
`MockSignatureTests.swift`, `Packages/GamKit/Tests/StoresTests/SignatureStoreTests.swift`, all held to
`Tests/Fixtures/signatures.json` (`scripts/gen_fixtures.py`'s `signature_fixture`); the write in
`Packages/GamKit/Tests/DirectoryStoreTests/SignatureChangesTests.swift` and ChangeCore's
`ExecutorTests`; the one confirm screen in `WriteRouteTests`.

## Files
- `Packages/GamKit/Sources/GamEngine/Signature.swift`: the variables, the seeds, `render`,
  `smartQuoteWarning`, `parseShown`, `stored`, `readAsKeyword`, and the preview's `previewDocument`
  (the CSP shell) and `contentRules` (the WKContentRuleList).
- `Packages/GamKit/Sources/Stores/SignatureStore.swift`: the store.
- `Packages/GamKit/Sources/Directory/SignatureChanges.swift`: the write; `UserAccess.swift` reads the
  current signature.
- `App/SignaturesView.swift` (the screen), `App/SignatureWebView.swift` (the Rendered view and the
  Rendered | HTML pane), `App/SignatureEditor.swift`, `App/SignatureTemplates.swift` (the store for the
  screen), `SignaturePreviewSheet` in `App/ChangePreviewSheet.swift`, and the Mail tab's "Gmail
  signature" card in `App/UsersView.swift`.
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
- **Put Back Previous:** the signature as read before the change (`current`, from `UserAccess`, stamped
  with its tenant), previewed again as GAM showed it; refused on another tenant or when it's a keyword.
- **Reading the current signature:** `UserAccess` reads `show signature` with the person's other lists,
  on its own (Gmail off fails only it), parsed by `Signature.parseShown`; tenant-stamped and bounded
  like the rest.

## The screen (S1c): Signatures, and the Users Mail tab's card
- **Signatures** (sidebar, SF Symbol `signature`): Person (a menu of active people; type to jump), the
  Template editor with the variables and the `[[ ]]` rule, Preview (Current and New side by side), and
  Saved templates. The New view is the render for the chosen person, drawn a moment after typing stops
  and not held; "Review and Replace…" holds it. Why the button is off is said beside it: no domain, the
  directory loading or failed, nobody chosen, a blank template, a keyword body (refused in words before
  any preview), their current signature still being read (it's what Put Back restores).
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
  panes, the warnings, "Replaces their current Gmail signature. Gmail keeps no copy.", the command with
  the body masked, and Cancel and "Replace Signature", both off while it runs (the sheet stays until
  the run ends).
- **The result** is a banner above the screen: "Replaced …'s signature." with "Put Back Previous…", or
  "Couldn't set the signature." with the remediation and GAM's error in a disclosure. It's announced
  once, from the window in front, and never reads the signature aloud. Saved templates' messages and the
  copy's report are announced the same way.
- **Saved templates:** Load and Delete per template, each named for VoiceOver ("Load Classic", "Delete
  Classic"); Delete and replacing on Save As are confirmed, saying no copy is kept; the quarantine
  notice names the file kept aside and where; "Copy Templates from GamGUI" shows only when GamGUI's file
  exists and never in demo mode, and reports copied, kept and left out.
- **Demo mode** keeps its templates in a fresh temporary folder each launch, never the operator's.
- **Screenshots** (`scripts/screenshots.sh`): `signatures` (nobody: the demo admin isn't in the
  directory), `signatures-alice` (Classic loaded; Current is `Best,<br>Alice`), `person-mail` (the card)
  and `narrow-signatures` (the smallest window). `cacheDisplay` draws a web view blank (WebKit draws in
  another process), so the debug snapshot draws each from its own `takeSnapshot` over its place.

## The mock (`Tests/Fixtures/mock_gam.sh`)
- `show signature` prints GAM's shape for the address given, with the indent; with `GAM_MOCK_STATE`,
  the body the mock last set, in the form GAM stored it.
- A set for an address that isn't a user fails on its token, as every per-user write does
  (`invalid_grant: Invalid email or User ID`, exit 50, classified `.notFound`); Gmail off for the user
  (`nogmail/<user>`) is refused (exit 1); a keyword body never sets anything: a file keyword fails to
  read `html` (exit 6), a document keyword wants its file (exit 2; wording approximate).
- Accounts `create user` made are known users while the mock keeps state, so onboarding's signature set
  reaches the same handler.
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
- `signatures.json` holds GamGUI's render (1,920 renders over the mock's directory and crafted people,
  including values that hold `{variables}` and `[[`), its curly-quote warning (1,530 templates), its
  reader (25 texts), its seeds, its store's messages and order, and GAM's own stored form and keyword
  reading.
- `SignatureStoreTests` holds the store to the fixture's messages, names and seeds (`Signature.seeds`,
  the one copy), and to what frozen GamGUI's store did for crafted names.
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
