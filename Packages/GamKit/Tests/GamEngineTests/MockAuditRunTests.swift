import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock's answers to the audit runs' reads (plan F3), each as GAM 7.52.04 answers it, and each way GAM fails or
/// passes over something without a word, which the runs must read as unknown, never as none.
@Suite("Mock audit-run reads")
struct MockAuditRunTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    /// One call, with GAM's first-run banner dropped from stdout; `state` names the mock's state markers to make.
    private func run(_ argv: [String], state: [String] = []) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let config = try Fixtures.placeholderConfigDirectory()
        let folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-mock-state-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: folder)
        }
        for marker in state {
            let url = folder.appending(path: marker)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let environment = Fixtures.mockEnvironment.merging(state.isEmpty ? [:] : ["GAM_MOCK_STATE": folder.path]) { $1 }
        let result = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
        let data = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(config.lastPathComponent) }.joined(separator: "\n")
        return (result.exitCode, data, result.stderr)
    }

    static let licenseTitles = "userId,productId,productDisplay,skuId,skuDisplay"

    /// `print licenses`: every seat, GAM's titles and display names; a suspended account's seats and a seat on an address the
    /// directory doesn't hold are there to be found.
    @Test func everySeatIsListed() async throws {
        let read = try await run(["print", "licenses"])
        #expect(read.exitCode == 0)
        let rows = GamOutput.records(read.stdout)
        #expect(read.stdout.hasPrefix(Self.licenseTitles + "\n"))
        #expect(rows.count == 7)
        #expect(rows.filter { $0["userId"] == .string("bob@example.com") }.count == 2)
        #expect(rows.contains { $0["userId"] == .string("left@example.com") })
        #expect(rows.allSatisfy { $0["skuDisplay"]?.string?.isEmpty == false })
    }

    /// GAM passes over a product Google refuses without a word or a code: titles alone, or one product gone, exit 0. Without
    /// the License Manager scope it exits 15 before any read.
    @Test func aRefusedProductIsPassedOverAndANoScopeTokenExits15() async throws {
        let silent = try await run(["print", "licenses"], state: ["licenses_silent"])
        #expect(silent.exitCode == 0 && GamOutput.records(silent.stdout).isEmpty && silent.stderr.isEmpty)
        #expect(silent.stdout.hasPrefix(Self.licenseTitles))
        let partial = try await run(["print", "licenses"], state: ["licenses_partial"])
        #expect(partial.exitCode == 0 && partial.stderr.isEmpty)
        #expect(GamOutput.records(partial.stdout).count == 6)
        #expect(!partial.stdout.contains("Google-Vault"))
        let refused = try await run(["print", "licenses"], state: ["nolicensing"])
        #expect(refused.exitCode == 15 && refused.stderr.contains("License Manager API"))
        #expect(GamOutput.records(refused.stdout).isEmpty)
    }

    /// Only the bare command is modelled: the app names no product or SKU.
    @Test func anotherShapeIsNotModelled() async throws {
        for argv in [["print", "licenses", "countsonly"], ["print", "licenses", "products", "Google-Apps"]] {
            let read = try await run(argv)
            #expect(read.exitCode == 2 && read.stderr.contains("isn't modelled"), "\(argv)")
        }
    }

    /// A directory read Google refused part way: the rows GAM had and exit 50, never the whole directory.
    @Test func aDirectoryThatStopsShortWritesWhatItHadAndExits50() async throws {
        let argv = ["print", "users", "fields", GamCommands.cacheFields.joined(separator: ","), "formatjson"]
        let whole = try await run(argv)
        #expect(whole.exitCode == 0 && GamOutput.records(whole.stdout).count == 5)
        let short = try await run(argv, state: ["directory_fails"])
        #expect(short.exitCode == 50 && short.stderr.contains("Print Failed"))
        #expect(GamOutput.records(short.stdout).count == 1)
    }

    /// Shared drives as the admin: every drive (`User,id,name,JSON`), and every drive's own permissions, one row each (users and
    /// groups only), a drive with none one row of `{}`. No drive is GAM's none, exit 60; a refused list is the titles and 50; a
    /// drive whose permissions Google refused is simply missing, exit 0.
    @Test func sharedDrivesAndTheirMembers() async throws {
        let drives = ["print", "shareddrives", "noorgunits", "formatjson"]
        let acls = ["print", "shareddriveacls", "oneitemperrow", "shownopermissionsdrives", "true", "formatjson"]
        let listed = try await run(drives)
        #expect(listed.exitCode == 0 && listed.stdout.hasPrefix("User,id,name,JSON\n") && GamOutput.records(listed.stdout).count == 4)
        let members = try await run(acls)
        let rows = GamOutput.records(members.stdout)
        #expect(members.exitCode == 0 && members.stdout.hasPrefix("User,id,name,createdTime,JSON\n"))
        #expect(rows.count == 6, "five members and the drive with none")
        let types = Set(rows.compactMap { $0["permission"]?.object?["type"]?.string })
        #expect(types == ["user", "group"], "a shared drive's members are users and groups only")
        #expect(rows.contains { $0["name"] == .string("Unused") && $0["permission"] == nil })
        let none = try await run(drives, state: ["nodrives"])
        #expect(none.exitCode == 60 && GamOutput.records(none.stdout).isEmpty && none.stdout.hasPrefix("User,id,name,JSON"))
        let refused = try await run(acls, state: ["denied/drives"])
        #expect(refused.exitCode == 50 && refused.stderr.contains("Print Failed") && GamOutput.records(refused.stdout).isEmpty)
        let dropped = try await run(acls, state: ["acl_dropped/0ALEGALuk9PVA"])
        #expect(dropped.exitCode == 0 && dropped.stderr.isEmpty && !dropped.stdout.contains("Legal hold"))
        // GamGUI #176: every drive dropped is GAM's 60, as for none; a service-account token Google refused without a word is the
        // titles alone at 0, from both reads.
        let all = ["0AFINANCEuk9PVA", "0ALEGALuk9PVA", "0AOLDuk9PVA", "0AUNUSEDuk9PVA"].map { "acl_dropped/" + $0 }
        let everyDropped = try await run(acls, state: all)
        #expect(everyDropped.exitCode == 60 && GamOutput.records(everyDropped.stdout).isEmpty)
        for argv in [drives, acls] {
            let silent = try await run(argv, state: ["drive_token_silent"])
            #expect(silent.exitCode == 0 && silent.stderr.isEmpty && GamOutput.records(silent.stdout).isEmpty
                    && silent.stdout.hasPrefix("User,id,name,"), "\(argv)")
        }
        for argv in [["print", "shareddrives"], ["print", "shareddriveacls", "formatjson"]] {
            let read = try await run(argv)
            #expect(read.exitCode == 2 && read.stderr.contains("isn't modelled"), "\(argv)")
        }
    }

    /// `print admins recursive`: every assignment, a group's expanded to its member (bob@, suspended) with both addresses, and a
    /// service account's row naming no person; holders GAM couldn't name are `assignedToUnknown` True with the ID alone, exit 0;
    /// a refusal is 12 before any row.
    @Test func everyAdminRoleAGroupsMembersIncluded() async throws {
        let argv = ["print", "admins", "recursive"]
        let all = try await run(argv)
        let rows = GamOutput.records(all.stdout)
        #expect(all.exitCode == 0 && rows.count == 4)
        #expect(rows.contains { $0["assignedToUser"] == .string("bob@example.com") && $0["assignedToGroup"] == .string("it-admins@example.com") })
        #expect(rows.contains { $0["assignedToServiceAccount"]?.string?.isEmpty == false && $0["assignedToUser"] == .string("") })
        let unnamed = try await run(argv, state: ["admin_unnamed"])
        let found = GamOutput.records(unnamed.stdout).filter { $0["assignedToUnknown"] == .string("True") }
        #expect(unnamed.exitCode == 0 && unnamed.stdout.split(separator: "\n").count == 7 && found.count == 2)
        #expect(found.allSatisfy { $0["assignedToUser"] == .string("") && $0["assignedTo"]?.string?.isEmpty == false })
        let refused = try await run(argv, state: ["denied/admins"])
        #expect(refused.exitCode == 12 && GamOutput.records(refused.stdout).isEmpty)
    }

    /// `print tokens users a,b`: those accounts' grants, a suspended one's included; an account GAM couldn't read is named and
    /// the rest read, 56 (73 outside the domain); a refusal is 12.
    @Test func theNamedAccountsTokensSuspendedOnesIncluded() async throws {
        let read = try await run(["print", "tokens", "users", "alice@example.com,bob@example.com"])
        let users = Set(GamOutput.records(read.stdout).compactMap { $0["user"]?.string })
        #expect(read.exitCode == 0 && users == ["alice@example.com", "bob@example.com"], "bob@ is suspended and still read")
        let gone = try await run(["print", "tokens", "users", "alice@example.com,bob@example.com"], state: ["tokens_gone/bob@example.com"])
        #expect(gone.exitCode == 56 && gone.stderr.contains("User: bob@example.com, Does not exist (2/2)"))
        #expect(Set(GamOutput.records(gone.stdout).compactMap { $0["user"]?.string }) == ["alice@example.com"])
        let outside = try await run(["print", "tokens", "users", "alice@example.com,pat@partner.org"])
        #expect(outside.exitCode == 73 && outside.stderr.contains("User: pat@partner.org, Service not applicable"))
        let refused = try await run(["print", "tokens", "users", "alice@example.com"], state: ["denied/tokens"])
        #expect(refused.exitCode == 12)
    }

    /// `print courses … show all countsonly`: each class's counts in its JSON and two count columns; a roster GAM couldn't read
    /// counts 0 without a word.
    @Test func everyClassWithItsCounts() async throws {
        let argv = ["print", "courses", "states", "active,archived,provisioned,declined,suspended", "show", "all", "countsonly",
                    "fields", "id,name,section,room,coursestate,ownerid,creationtime,updatetime,alternatelink", "formatjson"]
        let read = try await run(argv)
        let rows = GamOutput.records(read.stdout)
        #expect(read.exitCode == 0 && read.stdout.hasPrefix("id,JSON,JSON-teachers,JSON-students\n") && rows.count == 4)
        let biology = try #require(rows.first { $0["name"] == .string("Biology") })
        #expect(biology["teachers"]?.int == 1 && (biology["students"]?.int ?? 0) > 0)
        let gone = try await run(argv, state: ["roster_gone/500000000001"])
        let unread = try #require(GamOutput.records(gone.stdout).first { $0["name"] == .string("Biology") })
        #expect(gone.exitCode == 0 && gone.stderr.isEmpty && unread["teachers"]?.int == 0 && unread["students"]?.int == 0)
        let other = try await run(["print", "courses", "show", "teachers", "formatjson"])
        #expect(other.exitCode == 2 && other.stderr.contains("isn't modelled"))
    }

    /// The directory names when each account was made, as GAM prints a time (formatLocalTime): the inactive run's "new
    /// account" flag reads it, so the mock never leaves every account's creation unknown.
    @Test func everyAccountSaysWhenItWasMade() async throws {
        let read = try await run(["print", "users", "fields", GamCommands.cacheFields.joined(separator: ","), "formatjson"])
        for user in GamOutput.records(read.stdout) {
            let made = try #require(user["creationTime"]?.string)
            #expect(made.count == 20 && made.hasSuffix("Z") && made.dropFirst(10).hasPrefix("T"), "\(made)")
        }
    }
}
