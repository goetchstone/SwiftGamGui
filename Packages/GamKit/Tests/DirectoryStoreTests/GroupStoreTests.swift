import Foundation
import Security
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// The Groups screen's reads against the strict mock: GamGUI's argv byte for byte, GamGUI's search and
/// member order, the tenant rules the directory keeps, and output too large to trust refused.
@MainActor
@Suite("Groups", .serialized)
struct GroupStoreTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-groups-\(UUID().uuidString)")
    let memory = MemoryStore()
    let vault: Vault
    let base: URL
    let argvLog: URL
    let setup: SetupModel
    let groups: GroupStore
    let members: GroupMembers
    let loadedAt = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        // The mock reads its canned output from here; the runner passes it through in debug builds.
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        vault = Vault(store: memory)
        base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        argvLog = scratch.appending(path: "argv.log")
        setup = SetupModel(vault: vault, runner: nil, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        groups = GroupStore(setup: setup, runner: nil)
        members = GroupMembers(setup: setup, runner: nil)
    }

    /// The mock, each call's argv logged (NUL-separated, as the mock logs it). Given `slow`, that command
    /// takes two seconds; like real GAM (one process), it ends on SIGTERM at once.
    private func runner(slow: String? = nil) throws -> AuthenticatedRunner {
        let script = scratch.appending(path: "mock-\(UUID().uuidString).sh")
        let delay = slow.map { "case \"$1 $2\" in \"\($0)\") sleep 2 >/dev/null 2>&1 & wait $! ;; esac\n" } ?? ""
        try Data(("#!/bin/sh\ntrap 'exit 143' TERM\n\(delay)"
                  + "GAM_MOCK_ARGV_LOG='\(argvLog.path)' exec '\(Fixtures.mockGam.path)' \"$@\"\n").utf8)
            .write(to: script)
        chmod(script.path, 0o755)
        return AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base)
    }

    /// A Setup on `runner` with the stores the app builds: the directory first, then the groups.
    private func app(_ runner: AuthenticatedRunner, keep: Int = 8)
        -> (setup: SetupModel, directory: DirectoryStore, groups: GroupStore, members: GroupMembers) {
        let setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        let loadedAt = loadedAt
        return (setup, DirectoryStore(setup: setup, runner: runner), GroupStore(setup: setup, runner: runner, now: { loadedAt }),
                GroupMembers(setup: setup, runner: runner, keep: keep))
    }

    /// A GAM config folder whose oauth2.txt signs in as `admin`, imported and checked.
    private func connect(_ domain: String, in setup: SetupModel) async throws {
        let folder = scratch.appending(path: "gamcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "admin@\#(domain)"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
    }

    /// Every call the mock logged, as the bytes it was handed.
    private func calls() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls
    }

    private func calls(_ first: String, _ second: String) -> [[String]] {
        calls().filter { $0.count > 1 && $0[0] == first && $0[1] == second }
    }

    /// GamGUI's argv for `builder` with these arguments, from the parity fixture.
    private func gamguiArgv(_ builder: String, _ kwargs: [String: String] = [:]) throws -> [String] {
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Fixtures.argvJSON)) as? [String: Any])
        if kwargs.isEmpty {
            let defaults = try #require(document["defaults"] as? [String: [String: Any]])
            return try #require(defaults[builder]?["argv"] as? [String])
        }
        let cases = try #require(document["cases"] as? [[String: Any]])
        let found = cases.first { $0["builder"] as? String == builder && $0["kwargs"] as? [String: String] == kwargs }
        return try #require(found?["argv"] as? [String])
    }

    private func bytes(_ argv: [String]) -> [[UInt8]] { argv.map { Array($0.utf8) } }

    // MARK: the group list

    @Test func aLoadRunsGamGUIsReadAndKeepsGAMsOrder() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.groups.load()
        #expect(app.groups.problem == nil, "\(String(describing: app.groups.problem))")
        #expect(calls("print", "groups").map(bytes) == [bytes(try gamguiArgv("print_groups"))])
        let groups = try #require(app.groups.groups)
        #expect(groups.map(\.email) == ["allhands@example.com", "empty-group@example.com", "it@example.com",
                                        "sales@example.com", "staff@example.com", "team@example.com"])
        let sales = try #require(groups.first { $0.email == "sales@example.com" })
        #expect(sales.name == "Sales" && sales.description == "Everyone who sells" && sales.membersCount == 2)
        let it = try #require(groups.first { $0.email == "it@example.com" })
        #expect(Array(it.description.utf8) == Array("The \"IT\" team\nC:\\Support, Zoë".utf8), "read back as GAM escaped it")
        #expect(app.groups.loadedAt == loadedAt)
    }

    /// GamGUI reads groups when its board first needs them: connecting loads the directory, not the groups.
    @Test func connectingReadsNoGroups() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.directory.load()
        #expect(!app.groups.isLoading && app.groups.groups == nil)
        #expect(calls("print", "groups").isEmpty)
        #expect(calls("print", "users").count == 1)
    }

    /// With the group list on the same Setup, connecting still loads the directory: Setup's one observer slot
    /// would have gone to the store made last.
    @Test func theDirectoryStillLoadsOnConnectBesideTheGroups() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        #expect(app.directory.isLoading, "the directory wasn't told the domain connected")
        await app.directory.load()
        #expect(app.directory.users?.isEmpty == false)
    }

    @Test func anotherTenantNeverSeesTheList() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.groups.load()
        #expect(app.groups.rows(query: "") != nil)
        try await connect("example.org", in: app.setup)
        #expect(app.groups.groups == nil && app.groups.rows(query: "") == nil, "example.com's groups, shown as example.org's")
        try await connect("example.com", in: app.setup)
        #expect(app.groups.groups == nil, "a later generation of the same domain loads again")
    }

    @Test func aTenantSwitchStopsTheOldLoad() async throws {
        let app = app(try runner(slow: "print groups"))
        try await connect("example.com", in: app.setup)
        let clock = ContinuousClock(), started = clock.now
        let groups = app.groups
        let old = Task { await groups.load() }
        while !groups.isLoading { await Task.yield() }
        try await connect("example.org", in: app.setup)
        #expect(!groups.isLoading, "a switch starts no group load")
        await old.value
        #expect(clock.now - started < .seconds(1.5), "the old load's gam was stopped, not waited for")
        #expect(groups.groups == nil && groups.problem == nil)
        await groups.load()
        #expect(groups.groups?.isEmpty == false, "example.org loads")
    }

    @Test func aFailedLoadSaysWhyUntilOneSucceeds() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.directory.load()
        memory.failNext(.read, with: errSecInteractionNotAllowed)
        await app.groups.load()
        #expect(app.groups.problem?.summary == "Your Mac is locked. Unlock it and try again.")
        #expect(app.groups.groups == nil)
        await app.groups.load()
        #expect(app.groups.problem == nil && app.groups.groups != nil)
    }

    @Test func nothingLoadsUntilADomainIsConnected() async {
        await groups.load()
        #expect(groups.groups == nil)
        #expect(groups.problem?.summary == "Connect a domain on Setup first.")
    }

    @Test func aCutOrFailedListShowsNothingButWhy() throws {
        let argv = GamCommands.printGroups().argv
        let cut = GamResult(exitCode: 0, stdout: "email,JSON\nsales@example.com,\"{}\"\n", stderr: "",
                            stdoutTruncated: true, stderrTruncated: false)
        #expect(throws: DirectoryStore.Truncated.self) { try GroupStore.groups(from: cut, argv: argv) }
        #expect(GroupStore.problem(for: DirectoryStore.Truncated(), argv: argv).summary
                == "There are more groups than one call can return yet (GAM printed more than 8 MiB), so none are shown rather than some.")
        let failed = GamResult(exitCode: 50, stdout: "", stderr: "ERROR: 403: Request had insufficient authentication scopes",
                               stdoutTruncated: false, stderrTruncated: false)
        #expect(throws: GamError.self) { try GroupStore.groups(from: failed, argv: argv) }
    }

    /// GamGUI's finder: the address or the name, stripped and case-insensitive, in GAM's order. Searched once
    /// per list and search: asking again (a click) returns the same rows.
    @Test func theListIsSearchedAsGamGUISearchesIt() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.groups.load()
        let all = try #require(app.groups.rows(query: ""))
        #expect(all.count == 6)
        #expect(app.groups.rows(query: " SALES ")?.map(\.email) == ["sales@example.com"])
        #expect(app.groups.rows(query: "empty group")?.map(\.email) == ["empty-group@example.com"], "by name")
        #expect(app.groups.rows(query: "everyone")?.isEmpty == true, "a description isn't searched")
        let staff = try #require(app.groups.rows(query: "staff"))
        let again = try #require(app.groups.rows(query: "staff"))
        #expect(staff.withUnsafeBufferPointer { $0.baseAddress } == again.withUnsafeBufferPointer { $0.baseAddress },
                "asked again with nothing changed, the list was searched again")
    }

    // MARK: a group's members

    @Test func aGroupsMembersAreReadWithGamGUIsArgvOwnersFirst() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.members.load("sales@example.com")
        #expect(calls("print", "group-members").map(bytes)
                == [bytes(try gamguiArgv("print_group_members", ["group": "sales@example.com"]))])
        let sales = try #require(app.members.members(of: "sales@example.com"))
        #expect(sales.map(\.email) == ["alice@example.com", "it@example.com"])
        #expect(sales.map(\.role) == ["OWNER", "MEMBER"] && sales.map(\.memberType) == ["USER", "GROUP"])

        await app.members.load("staff@example.com")
        let staff = try #require(app.members.members(of: "staff@example.com"))
        #expect(staff.map(\.role) == ["MANAGER", "MEMBER", "MEMBER"])
        #expect(staff.map(\.email) == ["bob@example.com", "", "alice@example.com"], "by address within a role, as GamGUI sorts")
        #expect(staff.first?.status == "SUSPENDED" && staff[1].memberType == "CUSTOMER")
        #expect(app.members.members(of: "SALES@example.com") != nil, "an address in another case is the same group")
    }

    /// GamGUI's `_ROLE_RANK`, then the address lowercased, code point by code point (a decomposed "é" sorts
    /// with "e", where Swift's comparison would take it for the composed one); members alike keep GAM's order,
    /// as Python's stable `sorted` does.
    @Test func membersAreOrderedAsGamGUIOrdersThem() {
        let read: [(String, String)] = [("b@example.com", "MEMBER"), ("z@example.com", "member"), ("x@example.com", "STRANGE"),
                                        ("o@example.com", "OWNER"), ("m@example.com", "MANAGER"), ("B@example.com", "MEMBER"),
                                        ("\u{E9}@example.com", "MEMBER"), ("f@example.com", "MEMBER"), ("e\u{301}@example.com", "MEMBER")]
        let sorted = GroupMembers.sorted(read.map { GroupMember(record: ["email": .string($0.0), "role": .string($0.1)]) })
        let expected = ["o@example.com", "m@example.com", "b@example.com", "B@example.com", "e\u{301}@example.com",
                        "f@example.com", "z@example.com", "\u{E9}@example.com", "x@example.com"]
        #expect(sorted.map { Array($0.email.utf8) } == expected.map { Array($0.utf8) })
    }

    /// GamGUI's member search (`test_members_come_a_page_at_a_time_and_filter_server_side`): the address or
    /// the role holds it.
    @Test func membersAreSearchedByAddressOrRole() {
        let people = (0..<120).map { GroupMember(record: ["email": .string(String(format: "m%03d@example.com", $0))]) }
            + [GroupMember(record: ["email": .string("lead@example.com"), "role": .string("OWNER")]),
               GroupMember(record: ["email": .string("subteam@example.com"), "type": .string("GROUP")])]
        #expect(GroupMembers.filter(people, query: "m11").count == 10)
        #expect(GroupMembers.filter(people, query: " Owner ").map(\.email) == ["lead@example.com"])
        #expect(GroupMembers.filter(people, query: "zzz").isEmpty)
        #expect(GroupMembers.filter(people, query: "").count == 122)
    }

    @Test func aPagesRowsAreSearchedOncePerReadAndSearch() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.members.load("staff@example.com")
        #expect(app.members.rows("staff@example.com", query: "manager")?.map(\.email) == ["bob@example.com"])
        let rows = try #require(app.members.rows("staff@example.com", query: "example"))
        let again = try #require(app.members.rows("staff@example.com", query: "example"))
        #expect(rows.map(\.email) == ["bob@example.com", "alice@example.com"])
        #expect(rows.withUnsafeBufferPointer { $0.baseAddress } == again.withUnsafeBufferPointer { $0.baseAddress })
    }

    @Test func aGroupGAMCantFindSaysSoAndShowsNoMembers() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.members.load("nosuch@example.com")
        let problem = try #require(app.members.problem(for: "nosuch@example.com"))
        #expect(problem.summary == GamError.Kind.notFound.remediation)
        #expect(problem.detail?.contains("Group: nosuch@example.com, Does not exist") == true)
        #expect(app.members.members(of: "nosuch@example.com") == nil && app.members.rows("nosuch@example.com", query: "") == nil)
    }

    @Test func aCutMemberListIsRefused() throws {
        let argv = GamCommands.printGroupMembers(group: "sales@example.com").argv
        let cut = GamResult(exitCode: 0, stdout: "group,JSON\n", stderr: "", stdoutTruncated: true, stderrTruncated: false)
        #expect(throws: DirectoryStore.Truncated.self) { try GroupMembers.members(from: cut, argv: argv) }
        #expect(GroupMembers.problem(for: DirectoryStore.Truncated(), argv: argv).summary.hasPrefix(
            "The group has more members than one call can return yet"))
    }

    /// Only the last few groups are kept (invariant 9), the oldest going first, and only for their tenant.
    @Test func membersAreKeptPerGroupBoundedAndForTheirTenant() async throws {
        let app = app(try runner(), keep: 2)
        try await connect("example.com", in: app.setup)
        for group in ["sales@example.com", "staff@example.com", "it@example.com"] { await app.members.load(group) }
        #expect(app.members.members(of: "sales@example.com") == nil, "past the bound")
        #expect(app.members.members(of: "staff@example.com") != nil && app.members.members(of: "it@example.com") != nil)
        try await connect("example.org", in: app.setup)
        #expect(app.members.members(of: "it@example.com") == nil, "example.com's members, shown as example.org's")
    }

    /// A read still running when the tenant changes is the old tenant's: it never shows as this one's, and
    /// what it read is dropped.
    @Test func aReadForAnotherTenantNeverShows() async throws {
        let app = app(try runner(slow: "print group-members"))
        try await connect("example.com", in: app.setup)
        let members = app.members
        let read = Task { await members.load("sales@example.com") }
        while !members.isReading("sales@example.com") { await Task.yield() }
        try await connect("example.org", in: app.setup)
        #expect(!members.isReading("sales@example.com"))
        await read.value
        #expect(members.members(of: "sales@example.com") == nil)
    }

    /// A nested group's row opens its page: the tenant's group at an address, in any case.
    @Test func aGroupIsFoundByItsAddressInAnyCase() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        #expect(app.groups.group(at: "sales@example.com") == nil, "not loaded yet")
        await app.groups.load()
        #expect(app.groups.group(at: " SALES@Example.com ")?.email == "sales@example.com")
        #expect(app.groups.group(at: "nobody@example.com") == nil)
        try await connect("example.org", in: app.setup)
        #expect(app.groups.group(at: "sales@example.com") == nil, "example.com's group, found under example.org")
    }

    /// Two windows on one group: the second arrows past it (its read cancelled while it waits), and the
    /// first window's read, still running, still shows as reading and is kept (PR #35's review).
    @Test func aNewerReadCancelledWhileWaitingLeavesTheOlderOne() async throws {
        let app = app(try runner(slow: "print group-members"))
        try await connect("example.com", in: app.setup)
        let members = app.members
        let first = Task { await members.load("sales@example.com") }
        while !members.isReading("sales@example.com") { await Task.yield() }
        let second = Task { await members.load("sales@example.com", after: .seconds(30)) }
        await Task.yield()
        second.cancel()
        await second.value
        #expect(members.isReading("sales@example.com"), "the first window's read still runs")
        await first.value
        #expect(members.members(of: "sales@example.com") != nil, "the first window's read was thrown away")
    }

    /// An older read that finishes after a newer one is in hand doesn't replace it.
    @Test func anOlderReadNeverReplacesANewerOne() async throws {
        let marker = scratch.appending(path: "first-call")
        let script = scratch.appending(path: "mock-first-slow.sh")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Only the first member read is slow (connecting runs gam too).
        try Data(("#!/bin/sh\ntrap 'exit 143' TERM\ncase \"$1 $2\" in \"print group-members\") "
                  + "if [ ! -e '\(marker.path)' ]; then : > '\(marker.path)'; sleep 2 >/dev/null 2>&1 & wait $!; fi ;; esac\n"
                  + "exec '\(Fixtures.mockGam.path)' \"$@\"\n").utf8).write(to: script)
        chmod(script.path, 0o755)
        let app = app(AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base))
        try await connect("example.com", in: app.setup)
        let members = app.members
        let older = Task { await members.load("sales@example.com") }
        while !FileManager.default.fileExists(atPath: marker.path) { await Task.yield() }
        await members.load("sales@example.com")
        let newer = try #require(members.rows("sales@example.com", query: ""))
        await older.value
        let after = try #require(members.rows("sales@example.com", query: ""))
        #expect(newer.withUnsafeBufferPointer { $0.baseAddress } == after.withUnsafeBufferPointer { $0.baseAddress },
                "the older read replaced the newer one")
    }

    /// A page left before its delay is up reads nothing, and isn't left reading.
    @Test func aDelayedReadLeftEarlyReadsNothing() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        let members = app.members
        let read = Task { await members.load("sales@example.com", after: .seconds(30)) }
        while !members.isReading("sales@example.com") { await Task.yield() }
        read.cancel()
        await read.value
        #expect(!members.isReading("sales@example.com"))
        #expect(calls("print", "group-members").isEmpty)
    }
}
