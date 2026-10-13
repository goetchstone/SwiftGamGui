import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock's group reads fail the way GAM fails them, and its groups agree with one another: a
/// mock more permissive than GAM, or one whose lists disagree, turns a live break into a green test.
@Suite("Mock groups")
struct MockGroupsTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    /// One call of the mock, with GAM's first-run banner (the lines naming the config folder) dropped.
    /// Given `state`, the mock keeps what a write changed there, as GAM's tenant would.
    private func run(_ argv: [String], state: URL? = nil) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        let result = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
        let data = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(config.lastPathComponent) }.joined(separator: "\n")
        return (result.exitCode, data, result.stderr)
    }

    @Test func aFieldGAMDoesntKnowIsAUsageError() async throws {
        let bad = try await run(["print", "groups", "fields", "email,bogus", "formatjson"])
        #expect(bad.exitCode == 2)
        #expect(bad.stderr.contains("Invalid choice (bogus)"))
        // GAM matches a field lowercased: the app's own `directMembersCount` is one.
        let app = try await run(GamCommands.printGroups().argv)
        #expect(app.exitCode == 0, "\(app.stderr)")
    }

    @Test func aGroupListWithoutFormatjsonOrWithAnotherWordIsRefused() async throws {
        #expect(try await run(["print", "groups", "fields", "email,name"]).exitCode == 2)
        #expect(try await run(["print", "groups", "fields", "email", "formatjson", "extra"]).exitCode == 2)
    }

    @Test func membersAreReadForAWholeAddressInAnyCase() async throws {
        let unknown = try await run(GamCommands.printGroupMembers(group: "xsales@example.com").argv)
        #expect(unknown.exitCode == 56, "a substring of sales@ isn't sales@")
        #expect(unknown.stderr.contains("Group: xsales@example.com, Does not exist"))
        let user = try await run(GamCommands.printGroupMembers(group: "alice@example.com").argv)
        #expect(user.exitCode == 56, "a person isn't a group")
        let upper = try await run(GamCommands.printGroupMembers(group: "SALES@example.com").argv)
        #expect(upper.exitCode == 0)
        #expect(GamOutput.records(upper.stdout).compactMap { $0["email"]?.string } == ["alice@example.com", "it@example.com"])
    }

    @Test func membersTakeOnlyTheShapeTheAppSends() async throws {
        #expect(try await run(["print", "group-members", "group", "sales@example.com", "formatjson", "extra"]).exitCode == 2)
        #expect(try await run(["print", "group-members", "group", "sales@example.com"]).exitCode == 2)
        #expect(try await run(["print", "group-members", "groups", "sales@example.com", "formatjson"]).exitCode == 2)
        #expect(try await run(["print", "group-members", "group", "", "formatjson"]).exitCode == 2)
    }

    /// One data set: each group's count is its member list's length, and each directory user's `print
    /// groups member` names exactly the groups that list them.
    @Test func theGroupsAgreeWithOneAnother() async throws {
        let list = try await run(GamCommands.printGroups().argv)
        let groups = GamOutput.records(list.stdout).map(GamGroup.init(record:))
        #expect(groups.count == 6)
        var memberOf: [String: Set<String>] = [:]
        for group in groups {
            let read = try await run(GamCommands.printGroupMembers(group: group.email).argv)
            #expect(read.exitCode == 0, "\(group.email): \(read.stderr)")
            let members = GamOutput.records(read.stdout).map(GroupMember.init(record:))
            #expect(group.membersCount == members.count, "\(group.email)'s count")
            for member in members where member.memberType == "USER" { memberOf[member.email, default: []].insert(group.email) }
        }
        let users = try String(contentsOf: Fixtures.mockGamData.appending(path: "print_users.json"), encoding: .utf8)
        for user in GamOutput.records(users).map(GamUser.init(record:)) {
            let read = try await run(GamCommands.printGroups(member: user.primaryEmail).argv)
            #expect(read.exitCode == 0)
            let listed = Set(GamOutput.records(read.stdout).compactMap { $0["email"]?.string })
            #expect(listed == memberOf[user.primaryEmail, default: []], "\(user.primaryEmail)'s groups")
        }
    }

    // MARK: writes (`update group … add|remove`), as GAM 7.48.22's doUpdateGroups fails them

    private func scratchState() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-mock-state-\(UUID().uuidString)")
    }

    private func members(_ group: String, state: URL? = nil) async throws -> [GroupMember] {
        let read = try await run(GamCommands.printGroupMembers(group: group).argv, state: state)
        #expect(read.exitCode == 0, "\(read.stderr)")
        return GamOutput.records(read.stdout).map(GroupMember.init(record:))
    }

    /// checkGroupExists runs first: an address that isn't a group, a person's included, is
    /// entityUnknownWarning's "Group: <g>, Does not exist" (the address lowercased, as GAM normalizes it),
    /// ENTITY_DOES_NOT_EXIST_RC. A substring of a group's address isn't that group.
    @Test func aWriteToAGroupGAMCantFindSaysItDoesNotExist() async throws {
        for argv in [GamCommands.addGroupMember(group: "missing-group@example.com", member: "carol@example.com").argv,
                     GamCommands.removeGroupMember(group: "missing-group@example.com", member: "carol@example.com").argv] {
            let unknown = try await run(argv)
            #expect(unknown.exitCode == 56, "\(unknown.stderr)")
            #expect(unknown.stderr.contains("Group: missing-group@example.com, Does not exist"))
        }
        let partial = try await run(GamCommands.addGroupMember(group: "XSALES@example.com", member: "carol@example.com").argv)
        #expect(partial.exitCode == 56)
        #expect(partial.stderr.contains("Group: xsales@example.com, Does not exist"))
        #expect(try await run(GamCommands.addGroupMember(group: "alice@example.com", member: "carol@example.com").argv).exitCode == 56)
        let upper = try await run(GamCommands.addGroupMember(group: "SALES@example.com", member: "carol@example.com").argv)
        #expect(upper.exitCode == 0, "\(upper.stderr)")
    }

    /// One member per call is under GAM's batch size, so a failure is `_showFailure` with Google's own
    /// words: "Group: g, Member: m, Role: R, Add Failed: Member already exists.", ACTION_FAILED_RC. The
    /// address compares case-insensitively, as the Directory API's memberKey does.
    @Test func aDuplicateAddFailsAsGAMFailsIt() async throws {
        let again = try await run(GamCommands.addGroupMember(group: "sales@example.com", member: "ALICE@example.com").argv)
        #expect(again.exitCode == 50)
        #expect(again.stderr.contains("Group: sales@example.com, Member: alice@example.com, Role: MEMBER, Add Failed: Member already exists."),
                "\(again.stderr)")
        let asOwner = try await run(GamCommands.addGroupMember(group: "sales@example.com", member: "it@example.com", role: .owner).argv)
        #expect(asOwner.exitCode == 50)
        #expect(asOwner.stderr.contains("Member: it@example.com, Role: OWNER, Add Failed: Member already exists."))
    }

    /// Google's 404 on memberKey, which GAM maps to memberNotFound and "Does not exist".
    @Test func removingANonMemberFailsAsGAMFailsIt() async throws {
        let none = try await run(GamCommands.removeGroupMember(group: "sales@example.com", member: "dana@example.com").argv)
        #expect(none.exitCode == 50)
        #expect(none.stderr.contains("Group: sales@example.com, Member: dana@example.com, Role: MEMBER, Remove Failed: Does not exist"),
                "\(none.stderr)")
        let member = try await run(GamCommands.removeGroupMember(group: "sales@example.com", member: "Alice@example.com").argv)
        #expect(member.exitCode == 0, "\(member.stderr)")
    }

    /// An address in one of the tenant's domains that is no user or group: the add fails "Does not exist".
    /// One outside them is added (an admin may add an external member whatever the group allows; GAM's
    /// `verifyallowexternal` exists to find them), and an address Google can't read is an invalid member.
    @Test func whoCanBeAddedIsWhoGoogleKnows() async throws {
        for nobody in ["nobody@example.com", "nobody@example.net", "nobody@alias.example.net"] {
            let added = try await run(GamCommands.addGroupMember(group: "sales@example.com", member: nobody).argv)
            #expect(added.exitCode == 50, "\(nobody)")
            #expect(added.stderr.contains("Member: \(nobody), Role: MEMBER, Add Failed: Does not exist"), "\(added.stderr)")
        }
        let state = scratchState()
        defer { try? FileManager.default.removeItem(at: state) }
        let guest = try await run(GamCommands.addGroupMember(group: "sales@example.com", member: "Guest@Outside.example.org").argv,
                                  state: state)
        #expect(guest.exitCode == 0, "\(guest.stderr)")
        let listed = try #require(try await members("sales@example.com", state: state).first { $0.email == "guest@outside.example.org" })
        #expect(listed.memberType == "USER" && listed.role == "MEMBER")
        #expect(listed.status.isEmpty, "GAM shows no status for an external member")
        let quoted = try await run(GamCommands.addGroupMember(group: "sales@example.com", member: "a\"b@example.org").argv)
        #expect(quoted.exitCode == 50)
        #expect(quoted.stderr.contains("Add Failed: Invalid Input: memberKey"), "\(quoted.stderr)")
    }

    /// With GAM_MOCK_STATE every read follows the writes: the group's members, a person's groups and the
    /// group's count. Without it a write changes nothing.
    @Test func theReadsFollowTheWrites() async throws {
        let state = scratchState()
        defer { try? FileManager.default.removeItem(at: state) }
        #expect(try await run(GamCommands.addGroupMember(group: "Sales@example.com", member: "Carol@example.com", role: .owner).argv,
                              state: state).exitCode == 0)
        let carol = try #require(try await members("sales@example.com", state: state).first { $0.email == "carol@example.com" })
        #expect(carol.role == "OWNER" && carol.memberType == "USER" && carol.status == "ACTIVE")
        let theirs = try await run(GamCommands.printGroups(member: "carol@example.com").argv, state: state)
        #expect(GamOutput.records(theirs.stdout).compactMap { $0["email"]?.string } == ["it@example.com", "sales@example.com"])
        let list = try await run(GamCommands.printGroups().argv, state: state)
        #expect(GamOutput.records(list.stdout).map(GamGroup.init(record:)).first { $0.email == "sales@example.com" }?.membersCount == 3)
        #expect(try await run(GamCommands.addGroupMember(group: "sales@example.com", member: "carol@example.com").argv,
                              state: state).exitCode == 50, "a duplicate now")

        #expect(try await run(GamCommands.removeGroupMember(group: "sales@example.com", member: "alice@example.com").argv,
                              state: state).exitCode == 0)
        #expect(try await members("sales@example.com", state: state).map(\.email) == ["it@example.com", "carol@example.com"])
        let hers = try await run(GamCommands.printGroups(member: "alice@example.com").argv, state: state)
        #expect(GamOutput.records(hers.stdout).compactMap { $0["email"]?.string } == ["staff@example.com"])
        #expect(try await run(GamCommands.removeGroupMember(group: "sales@example.com", member: "alice@example.com").argv,
                              state: state).exitCode == 50, "not a member now")
        // A group added as a member is a GROUP; a suspended person is SUSPENDED.
        #expect(try await run(GamCommands.addGroupMember(group: "it@example.com", member: "staff@example.com").argv, state: state).exitCode == 0)
        #expect(try await run(GamCommands.addGroupMember(group: "it@example.com", member: "bob@example.com").argv, state: state).exitCode == 0)
        let it = try await members("it@example.com", state: state)
        #expect(it.first { $0.email == "staff@example.com" }?.memberType == "GROUP")
        #expect(it.first { $0.email == "bob@example.com" }?.status == "SUSPENDED")

        #expect(try await run(GamCommands.addGroupMember(group: "staff@example.com", member: "carol@example.com").argv).exitCode == 0)
        #expect(try await members("staff@example.com").contains { $0.email == "carol@example.com" } == false,
                "without state, nothing is kept")
    }

    /// Only the shape the app sends (`update group <g> add <role> <member>`, `… remove <member>`): one group,
    /// one member, no option words. A list, a missing or empty member, an extra word, and every other
    /// subcommand are refused rather than answered in a guessed shape, as is a group added to itself (GAM's
    /// cycle refusal isn't modelled).
    @Test func aWriteTakesOnlyTheShapeTheAppSends() async throws {
        for argv in [["update", "group", "sales@example.com", "add"],
                     ["update", "group", "sales@example.com", "add", "member"],
                     ["update", "group", "sales@example.com", "add", "member", ""],
                     ["update", "group", "sales@example.com", "remove", ""],
                     ["update", "group", "sales@example.com", "add", "member", "carol@example.com", "extra"],
                     ["update", "group", "sales@example.com", "add", "usersonly", "carol@example.com"],
                     ["update", "group", "sales@example.com", "add", "member", "preview", "carol@example.com"],
                     ["update", "group", "sales@example.com", "add", "member", "delivery", "daily", "carol@example.com"],
                     ["update", "group", "sales@example.com,staff@example.com", "add", "member", "carol@example.com"],
                     ["update", "group", "sales@example.com", "add", "member", "carol@example.com,dana@example.com"],
                     ["update", "group", "sales@example.com", "sync", "member", "carol@example.com"],
                     ["update", "group", "sales@example.com", "update", "owner", "alice@example.com"],
                     ["update", "group", "", "add", "member", "carol@example.com"],
                     ["update", "group", "sales@example.com", "add", "member", "sales@example.com"]] {
            let refused = try await run(argv)
            #expect(refused.exitCode == 2, "\(argv): \(refused.stderr)")
        }
        for role in GamCommands.GroupRole.allCases {
            let added = try await run(GamCommands.addGroupMember(group: "sales@example.com", member: "carol@example.com", role: role).argv)
            #expect(added.exitCode == 0, "\(role): \(added.stderr)")
        }
    }
}
