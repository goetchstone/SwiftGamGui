# The Groups screen

**One line:** the tenant's groups, read by one `gam print groups` when the screen is first shown, and a
selected group's members, read by `gam print group-members` each time its page opens (slice A). From a
group's page, people are added with a role and a member removed, each through ChangeCore (slice B); a
person's own groups also change on their page in Users.

**Owns invariants:** the tenant generation (shared with the directory: a screen never shows one tenant's
data as another's), #9 (bounded reads: output cut at the runner's cap is refused, and only the last eight
groups' members are kept; a result names at most five failures), #11 (the reads and both writes are
GamGUI's builders, held to `argv.json`) and, for the writes, #2 (ChangeCore only; a confirm runs the
preview its sheet shows, once).

**Enforcement home:** `Tests/DirectoryStoreTests/GroupStoreTests.swift` (the stores against the strict
mock), `Tests/DirectoryStoreTests/GroupChangesTests.swift` (the writes end to end: argv log, audit, mock
state), `Tests/GamEngineTests/MockGroupsTests.swift` (the mock's group reads and writes fail as GAM fails,
and its groups agree with one another), `DirectoryTests.groupsAndMembersReadAsGamGUIReadsThem` (the
models, held to `gam_models.json`), and `WriteRouteTests` (only `ChangePreviewSheet.swift` confirms).

## Files
- `Packages/GamKit/Sources/Directory/GroupStore.swift`: the list. DirectoryStore's reviewed shape: a
  snapshot tagged with domain, generation and revision; a load in flight and a problem, each tagged too.
- `Packages/GamKit/Sources/Directory/GroupMembers.swift`: a group's members. UserAccess's shape: keyed
  by the address as `Guard.normalized` compares it, the domain and the generation; the last eight kept.
- `Packages/GamKit/Sources/Directory/GroupChanges.swift`: the writes (slice B). SignatureChanges' shape:
  a held preview, a confirm that runs only the one shown, a result in words.
- `Packages/GamKit/Sources/Setup/SetupModel.swift`: `onTenantChange(_:)`, the list of tenant observers.
- `App/GroupsView.swift` (the page, Add Members, the result banner), `App/ChangePreviewSheet.swift`
  (`GroupPreviewSheet`, the confirm), `App/AppServices.swift`, `App/GamGUIApp.swift` (the sidebar's
  Groups), `App/Spikes.swift` (the demo fill; a snapshot captures a sheet open over the screen).
- `Tests/Fixtures/mock_gam.sh`: the group data set, the strict `print groups` and `print group-members`
  handlers, and `update group … add|remove` with its state.

## How it works
- **The list loads lazily, as GamGUI's does** (`groups.py`: the board reads groups when it first needs
  them). The screen's `.task(id: setup.generation)` loads when it's shown and nothing is held for this
  tenant; **Refresh** (⌘R) reads again. Connecting a domain loads the directory, never the groups.
- **Argv:** `GamCommands.printGroups()` (`print groups fields email,name,description,directMembersCount
  formatjson`) with the domain-wide timeout, and `printGroupMembers(group:)` (`print group-members group
  <g> formatjson`) with the default one, as GamGUI runs them. No new builder.
- **Tenant rules:** the list, a problem and a group's members belong to the domain and generation they
  were read under, and are hidden once either changes. A switch cancels a list load in flight (its `gam`
  is stopped and its credentials wiped) and starts nothing; a members read still running is dropped
  when it ends, and never shows as "Reading" under the next tenant.
- **Search:** GamGUI's `_pick` without its cap of 15 (the table is lazy, as Users' is): the stripped
  query, Python's `str.lower()`, a scalar substring of the address or the name, in GAM's order. Worked
  out once per list and search (`rows(query:)`).
- **Members:** sorted once, at load, in GamGUI's order: owner, manager, member, any other role; then the
  address lowercased, compared code point by code point as Python compares (Swift's `<` takes a
  decomposed "é" for the composed one); members alike keep GAM's order, as Python's stable `sorted`
  does. The page's search is GamGUI's: the address or the role. No member count is shown in the list:
  GamGUI parses it and never shows it, and it would go stale after a write.
- **The page:** the name as the heading (header trait), the address (selectable), the description, a
  member search, a count line ("N members", or "T of A members match “q”"), and each member with their
  role and anything else in words (group, suspended). The address-less CUSTOMER row (everyone in the
  organization) reads "customer", as GamGUI's does. A nested group that is one of the tenant's gets
  **Show Group**, which opens its page (GamGUI links it to its board). Members are read a quarter second
  after a page opens, so arrowing down the list starts no `gam` for the groups passed over.
- **States, in words:** not connected; connecting (with the domain); loading; a problem (the
  remediation, GAM's line selectable, **Try Again**); no groups yet; no group matches; the bottom bar's
  "N of M groups · as of <time>" with a refresh running or failing. On the page: reading members, not
  read (**Read Again**), a problem with no table, no members yet, no member matches.

## Writes (slice B)
- **GamGUI's routes, as a model.** `previewAdd(_:to:role:)` is `add_member`: the group must be one
  address ("Pick a group first."), the list not empty ("Enter the email address of the person to add."),
  and each address one address ("“x” isn't one email address. Pick someone from the suggestions, or type
  their full address."), in that order, before anything is held. `previewRemove(_:from:)` is
  `remove_preview` with `remove_member`: both addresses checked ("Pick a member to remove."; the CUSTOMER
  row has no address and no Remove). No directory check and no name lookup: GamGUI makes neither, and GAM
  says who it doesn't know. The role is the closed `GroupRole` (a picker), so GamGUI's "Pick a role"
  refusal can't arise; each role's held argv is compared with `argv.json`'s.
- **Argv:** `addGroupMember` (`update group <g> add <role> <m>`) and `removeGroupMember` (`update group
  <g> remove <m>`), GamGUI's builders. One step per member; the target is the member and `about.group` the
  group, as GamGUI's audit has them.
- **Several at once (a deliberate difference):** GamGUI's form takes one person. Here the addresses are
  split on line breaks, commas and semicolons (never spaces: "Carol Clark" stays one entry and is refused
  in GamGUI's words), stripped, and repeats dropped; they are one preview with a step each. The guard
  then applies as to any change set: 10 or more need the click (always asked anyway), more than
  `Guard.countConfirmAbove` (25) need their count typed, over 200 warn.
- **Confirm:** every group write is `confirmStep: true` (GamGUI's add has no confirm step because its
  form post is the confirmation; here the sheet is). `confirm` runs only while its preview is the one the
  sheet shows, so an edited list, another group or a replay writes nothing; the executor spends the
  preview either way. The preview is bound to the tenant the screen's reads began on (`expecting:`).
- **After a write** (any run that reached GAM, failed or not, as GamGUI's `_list_ctx` re-reads after
  every write), the group's members are read again, but only while the tenant is the one the write ran
  on: after a switch mid-write nothing of the next tenant is read for it.
- **Words:** one person in GamGUI's ("Added m to g as role.", "Removed m from g.", "Couldn't add m to g.
  <why>"), several as "Added N of M people to g as role." and why each of the first five wasn't, the rest
  counted. Why is GamGUI's remediation for GAM's kind, except GAM's member line, which is said for the
  member: already in the group, no user or group at that address, an address Google won't take, not in
  the group now. GAM's own lines are the detail ("GAM's error"), never the headline.
- **The page:** Add Members… opens one sheet: the form (addresses, Choose from the directory: GamGUI's
  type-ahead, name or address, the first 15; a role), then the preview it held (Back returns to the form
  with what was typed), closing when the run starts. Remove… opens the preview alone, with the member's
  role said (an owner: "make sure the group keeps one") and what leaving means. The result shows above the
  list, which is already the one read after it. No Undo: GamGUI has none.
- **Accessibility:** each Remove… is named "Remove <member> from <group>"; Add Members… "Add members to
  <group>"; each suggestion "Add <name>, <address>, to the addresses" (and said when chosen); every
  status is words with a symbol; the result is announced once, from the window in front.

## Invariants & failure history
- **Setup had one observer slot.** `SetupModel.tenantDidChange` was a single closure, and DirectoryStore
  took it. A second store copying that line would have silently taken it from the directory, which would
  then stop loading on connect and stop cancelling an old tenant's load. Now `onTenantChange` appends;
  `GroupStoreTests.theDirectoryStillLoadsOnConnectBesideTheGroups` and
  `DirectoryStoreTests.everyStoreOnOneSetupStopsItsOldLoad` fail with one slot.
- **Truncated output is refused, not shown as the whole** (as DirectoryStore does): "more groups than one
  call can return yet". UserAccess's own reads don't check `stdoutTruncated` yet (a known, low gap).

- **The mock lied about the writes** (slice B): `update group … add|remove` succeeded for anything, and a
  "missing" group failed with an invented 404, exit 1. It now follows doUpdateGroups at 7.48.22 (read in
  the vendored build): checkGroupExists first ("Group: <g>, Does not exist", 56, the address lowercased);
  one member is under GAM's batch size, so a failure is `_showFailure`'s member line with Google's words,
  exit 50 (duplicate "Member already exists.", an unknown in-domain address and a non-member "Does not
  exist", an unreadable address "Invalid Input: memberKey"). An earlier plan read the batch path's
  "Duplicate, already a <role>" and "Not a Member": those are the batch callback's, which one member never
  takes. `MockGroupsTests` holds each; 8 mutants of the mock fail.

## Gotchas / mock-lies traps
- **The mock lied about both reads** (found while planning): `print group-members` matched a substring
  (`xsales@` answered as sales, `SALES@` failed), printed a JSON array, and failed an unknown group as
  "400 … groupKey", exit 1; `print groups` printed NDJSON whatever it was asked. Now:
  - `print groups` takes `fields <GroupFieldNameList>` and `formatjson`; each field must be a
    `<GroupFieldName>` (grammar line 3970), matched lowercased with underscores dropped as GAM matches
    it, else GAM's invalid choice (exit 2). Only the four the app asks for, together, are modelled;
    fewer, `quotechar`, no `formatjson` and any other word are refused. It prints GAM's formatjson
    shape, `email,JSON`, in GAM's CSV dialect (`gam_row`; see the runner runbook).
  - `print group-members` takes exactly `group <g> formatjson`; the whole address, case-insensitively;
    an unknown group (a person's address included) is "Group: <g>, Does not exist", exit 56. It prints
    `group,JSON` per member, the header alone for a memberless group. The JSON holds the group too, and
    every default member field, empty where a member has none (read in GAM's source at 7.48.22).
  - **Approximate, from the vendored build's bytecode, not a tenant:** the not-found wording and exit
    code, the count as a string. The operator's first live read replaces them.
- **One data set** (`mock_gam/groups.json`, `group_members.json`): every group's `directMembersCount`
  is its member list's length, and each directory user's `print groups member` names exactly the
  groups listing them (alice: sales, staff; bob: staff; carol: it; dana: none, the header alone).
  `MockGroupsTests.theGroupsAgreeWithOneAnother` holds both. allhands' twelve members aren't in the
  mock's directory, so `print groups member` refuses them. IT's description holds a quote, a
  backslash, a newline and non-ASCII, so GAM's escaping reaches the reader (`GroupStoreTests`).
- **bash reserves `GROUPS`** (the user's group IDs): assigning it fails, and under `set -e` the mock
  exited 1 with no output at all, before any handler. (The groups now live in `mock_gam/groups.json`.)
- `gen_fixtures.py` reads `print_groups` and `print_group_members("sales@example.com")` through the mock
  and stops if the mock refuses either: re-run it after any change to their output.
- **Writes, approximate** (from the vendored build, not a tenant): Google's wording for a duplicate, a
  non-member and an unreadable address; that an external address is added whatever the group allows (GAM's
  `verifyallowexternal` exists to find such members); the success line (nothing parses it). Not modelled,
  refused with exit 2: a list of groups or members, the option words (`usersonly`, `delivery`, `preview`…),
  `sync`/`update`/`clear`, a group added to itself (Google's cycle refusal), an alias (Google adds the
  account it belongs to).
- **With `GAM_MOCK_STATE`** a written group keeps its list in `groups/<group>`; `print group-members`,
  `print groups member` (now derived from the members, in the groups' order, so its old canned answers
  still hold) and `print groups`' counts follow it. Without state a write changes nothing.

## Reads in flight (PR #35's review)
- A group's (and a person's) reads are counted per key (`ReadsInFlight`): a key is reading while any
  read of it is out, and a finished read is kept unless a later read of the same key is already in
  hand. One window arrowing past a group no longer ends another window's read of it, and an older,
  slower read never replaces a newer one. `UserAccess` had the same single-slot flaw and shares the fix.
- A page whose read is gone (another window read eight more) reads it again by itself.
- The list speaks a load's outcome ("N groups loaded.", or why not) from the window in front; Show
  Group moves the focus to the new page's heading; a refresh that drops the open group closes its page.
- **Closed:** GAM writes CSV with a backslash escape character, which neither the reader nor the mock
  modelled, so a name or description with a double quote dropped a row (the Users list too).
  Failure-log 2026-10-10, "GAM's CSV escapes".

## Testing / live-verification status
- **Writes:** argv-identical to GamGUI's (`add_group_member` as a member was confirmed live in GamGUI;
  `remove_group_member` too, and from this app's Users page on 2026-10-09). Adding as a manager or owner
  has never run live in either app. The live check needs a scratch group the operator owns, with
  throwaway members or the operator's own account, and the operator's yes for each write (docs/live-verification.md).
- **Live (2026-10-10):** on the operator's real tenant the screen listed the groups (`print groups`)
  and a group's members (`print group-members`): GAM's real formatjson output read as the mock models
  it. Still approximate: the not-found wording and exit code for an address that isn't a group (the
  screen only opens groups it listed, so it can't ask for one yet).
- Screens: CI renders `groups`, `group-sales` and `narrow-group-sales` (the smallest window with the
  sidebar and the page at their widest), and the sheets: `group-sales-add` (Add Members),
  `narrow-group-sales-add`, and `group-sales-remove` (removing the owner); the images reach
  `docs/screenshots` from that run's artifact.

## To do common tasks here
- **Another membership write** (a role change, `update group … update`; sync; clear): GamGUI has no
  builder for any, so none can be held to `argv.json`; each needs the operator's decision, the grammar,
  a mock handler that fails as GAM does, and a live proof.
- **Another group field in the list:** add it to `GamChoices.groupListFields` only with GamGUI (argv
  parity), then model it in the mock's `print groups`.
