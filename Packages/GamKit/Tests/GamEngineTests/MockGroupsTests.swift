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
    private func run(_ argv: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        let result = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: Fixtures.mockEnvironment)
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
}
