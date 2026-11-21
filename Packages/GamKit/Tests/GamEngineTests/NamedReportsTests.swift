import Foundation
import Testing
@testable import GamEngine

/// Reports' named reports (GamGUI #151, `tests/test_named_reports.py` at 2286631): each names one runnable read in the vendored
/// catalog, and the admin token's scope is held, not held or unknown, never guessed.
@Suite("Named reports")
struct NamedReportsTests {
    /// Named by grammar, not by id (which moves with every GAM bump): a bump that renames one, or makes it match two commands,
    /// fails here rather than opening the wrong read.
    @Test(arguments: NamedReport.all)
    func eachNamesOneRunnableRead(_ report: NamedReport) throws {
        let command = try #require(report.command(in: CommandCatalogTests.catalog), "\(report.syntax) is not exactly one runnable read")
        #expect(command.runnable && command.risk == .read && !command.uncertain)
        #expect(command.syntax == report.syntax || command.syntax.hasPrefix(report.syntax + " "))
    }

    @Test func theKeysAreUniqueAndEachNamesAToken() {
        let keys = NamedReport.all.map(\.key)
        #expect(keys.count == 9 && Set(keys).count == 9)
        #expect(Set(NamedReport.all.map(\.token)) == [.admin, .serviceAccount])
        #expect(NamedReport.all.allSatisfy { $0.scope.hasPrefix("https://www.googleapis.com/auth/") })
    }

    @Test(arguments: [
        (["https://www.googleapis.com/auth/apps.licensing"], true as Bool?),
        (["https://www.googleapis.com/auth/apps.licensing.readonly"], true),
        (["https://www.googleapis.com/auth/admin.directory.user"], false),
        ([], false),
    ])
    func theAdminTokensScopeIsHeldOrNot(_ granted: [String], _ held: Bool?) throws {
        let licenses = try #require(NamedReport.all.first { $0.key == "licenses" })
        #expect(licenses.adminScopeHeld(granted) == held)
    }

    @Test func aTokenWhoseScopesCantBeReadIsUnknownNeverHeld() throws {
        let licenses = try #require(NamedReport.all.first { $0.key == "licenses" })
        #expect(licenses.adminScopeHeld(nil) == nil)
    }

    @Test func aServiceAccountReadIsNeverClaimedHeld() throws {
        let alerts = try #require(NamedReport.all.first { $0.key == "alerts" })
        #expect(alerts.adminScopeHeld([alerts.scope]) == nil)
    }

    /// A scope that only looks like the one wanted is not it: the match is on bytes, not Unicode equivalence or a prefix.
    @Test func onlyTheScopeItselfOrItsReadOnlyFormCounts() throws {
        let groups = try #require(NamedReport.all.first { $0.key == "group_members" })
        #expect(groups.adminScopeHeld([groups.scope + ".member"]) == false)
        #expect(groups.adminScopeHeld([groups.scope + "/"]) == false)
        #expect(groups.adminScopeHeld([groups.scope.uppercased()]) == false)
    }

    /// A catalog in which a name matches two runnable reads, or none, opens nothing; a write that matches is never counted.
    @Test func twoMatchesOrNoneOpenNothing() throws {
        let line = { (id: String, syntax: String, risk: Int) in
            #"{"id": "\#(id)", "category": "Licenses", "subcategory": "", "name": "", "raw_syntax": "\#(syntax)", "verb": "print", "risk": \#(risk), "uncertain": false, "description": ""}"#
        }
        let catalog = { (lines: [String]) throws -> CommandCatalog in
            try CommandCatalog(json: Data((#"{"version": "0", "commands": ["# + lines.joined(separator: ", ") + "]}").utf8))
        }
        let licenses = try #require(NamedReport.all.first { $0.key == "licenses" })
        let withAWrite = try catalog([line("a", "gam print licenses", 0), line("b", "gam print licenses skus <SKUIDList>", 2)])
        #expect(licenses.command(in: withAWrite)?.id == "a")
        let two = try catalog([line("a", "gam print licenses", 0), line("b", "gam print licenses skus <SKUIDList>", 0)])
        #expect(two.commands.filter { $0.runnable }.count == 2 && licenses.command(in: two) == nil)
        #expect(licenses.command(in: try catalog([line("a", "gam print licensesx", 0)])) == nil)
    }
}
