# The Groups screen

**One line:** the tenant's groups, read by one `gam print groups` when the screen is first shown, and a
selected group's members, read by `gam print group-members` each time its page opens. Read-only for
now; adding and removing members from here is slice B (a person's own groups already change on their
page in Users).

**Owns invariants:** the tenant generation (shared with the directory: a screen never shows one tenant's
data as another's), #9 (bounded reads: output cut at the runner's cap is refused, and only the last eight
groups' members are kept) and #11 (both reads are GamGUI's builders, held to `argv.json`).

**Enforcement home:** `Tests/DirectoryStoreTests/GroupStoreTests.swift` (the stores against the strict
mock), `Tests/GamEngineTests/MockGroupsTests.swift` (the mock's group reads fail as GAM fails, and its
groups agree with one another), `DirectoryTests.groupsAndMembersReadAsGamGUIReadsThem` (the models,
held to `gam_models.json`).

## Files
- `Packages/GamKit/Sources/Directory/GroupStore.swift`: the list. DirectoryStore's reviewed shape: a
  snapshot tagged with domain, generation and revision; a load in flight and a problem, each tagged too.
- `Packages/GamKit/Sources/Directory/GroupMembers.swift`: a group's members. UserAccess's shape: keyed
  by the address as `Guard.normalized` compares it, the domain and the generation; the last eight kept.
- `Packages/GamKit/Sources/Setup/SetupModel.swift`: `onTenantChange(_:)`, the list of tenant observers.
- `App/GroupsView.swift`, `App/AppServices.swift`, `App/GamGUIApp.swift` (the sidebar's Groups),
  `App/Spikes.swift` (the demo fill).
- `Tests/Fixtures/mock_gam.sh`: the group data set and the strict `print groups` and
  `print group-members` handlers.

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

## Invariants & failure history
- **Setup had one observer slot.** `SetupModel.tenantDidChange` was a single closure, and DirectoryStore
  took it. A second store copying that line would have silently taken it from the directory, which would
  then stop loading on connect and stop cancelling an old tenant's load. Now `onTenantChange` appends;
  `GroupStoreTests.theDirectoryStillLoadsOnConnectBesideTheGroups` and
  `DirectoryStoreTests.everyStoreOnOneSetupStopsItsOldLoad` fail with one slot.
- **Truncated output is refused, not shown as the whole** (as DirectoryStore does): "more groups than one
  call can return yet". UserAccess's own reads don't check `stdoutTruncated` yet (a known, low gap).

## Gotchas / mock-lies traps
- **The mock lied about both reads** (found while planning): `print group-members` matched a substring
  (`xsales@` answered as sales, `SALES@` failed), printed a JSON array, and failed an unknown group as
  "400 … groupKey", exit 1; `print groups` printed NDJSON whatever it was asked. Now:
  - `print groups` takes `fields <GroupFieldNameList>` and `formatjson`; each field must be a
    `<GroupFieldName>` (grammar line 3965), matched lowercased with underscores dropped as GAM matches
    it, else GAM's invalid choice (exit 2). Only the four the app asks for are modelled; `quotechar`, no
    `formatjson` and any other word are refused. It prints GAM's formatjson shape, `email,JSON`, with
    only the fields asked for.
  - `print group-members` takes exactly `group <g> formatjson`; the whole address, case-insensitively;
    an unknown group (a person's address included) is "Group: <g>, Does not exist", exit 56. It prints
    `group,JSON` per member, the header alone for a memberless group.
  - **Approximate, from the vendored build's bytecode, not a tenant:** the not-found wording and exit
    code, the `group` column's place, the count as a string. The operator's first live read replaces them.
- **One data set:** every group's `directMembersCount` is worked out from its member list, and each
  directory user's `print groups member` names exactly the groups listing them (alice: sales, staff;
  bob: staff; carol: it). `MockGroupsTests.theGroupsAgreeWithOneAnother` holds both. allhands' twelve
  members aren't in the mock's directory, so `print groups member` refuses them.
- **bash reserves `GROUPS`** (the user's group IDs): assigning it fails, and under `set -e` the mock
  exited 1 with no output at all, before any handler. The list is `TENANT_GROUPS`.
- `gen_fixtures.py` reads `print_groups` and `print_group_members("sales@example.com")` through the mock
  and stops if the mock refuses either: re-run it after any change to their output.

## Reads in flight (PR #35's review)
- A group's (and a person's) reads are counted per key (`ReadsInFlight`): a key is reading while any
  read of it is out, and a finished read is kept unless a later read of the same key is already in
  hand. One window arrowing past a group no longer ends another window's read of it, and an older,
  slower read never replaces a newer one. `UserAccess` had the same single-slot flaw and shares the fix.
- A page whose read is gone (another window read eight more) reads it again by itself.
- The list speaks a load's outcome ("N groups loaded.", or why not) from the window in front; Show
  Group moves the focus to the new page's heading; a refresh that drops the open group closes its page.
- **Open, its own slice:** GAM writes CSV with a backslash escape character, and the reader and mock
  don't model it, so a name or description with a double quote may drop a row (the Users list too).

## Testing / live-verification status
- Mock-tested only. **Not live yet:** the operator's first read, with a go, runs `print groups` and
  `print group-members` on one real group and on one address that isn't a group, to capture the real
  formatjson headers and the not-found wording and exit code (GamGUI's acceptance never checked
  `print group-members`).
- Screens: CI renders `groups`, `group-sales` and `narrow-group-sales` (the smallest window with the
  sidebar and the page at their widest); the images reach `docs/screenshots` from that run's artifact.

## To do common tasks here
- **Slice B (writes from the group side):** the group plan's section B: `previewAddMember` and
  `previewRemoveMember` on `UserChanges` (one preview sheet), and the mock's `update group` failures
  (duplicate, not a member, unknown member) with state.
- **Another group field in the list:** add it to `GamChoices.groupListFields` only with GamGUI (argv
  parity), then model it in the mock's `print groups`.
