import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// Invariant 3 for the typed builders: a `GamRead` is one GamGUI's catalog rule calls confidently
/// read-only, so a write mistyped as a read (which any caller could then run) fails here. The rule is
/// GamGUI's `core/catalog/parser.py`: the first known verb among the first six tokens decides.
@Suite("Command kinds")
struct CommandKindTests {
    /// GamGUI's `_READ`, `_DESTRUCTIVE` and `_LOW`, exported by `scripts/gen_fixtures.py` (invariant 11).
    static let verbSets: (read: Set<String>, destructive: Set<String>, low: Set<String>) = {
        let object = try! JSONSerialization.jsonObject(with: GoldenArgvTests.fixture) as! [String: Any]
        let constants = object["constants"] as! [String: Any]
        func set(_ key: String) -> Set<String> { Set(constants[key] as! [String]) }
        return (set("CATALOG_READ_VERBS"), set("CATALOG_DESTRUCTIVE_VERBS"), set("CATALOG_LOW_VERBS"))
    }()
    static var readVerbs: Set<String> { verbSets.read }

    /// Reads GamGUI's verb rule can't place, each reviewed. Nothing else may be added without the same.
    static let reviewedReads: [String: String] = [
        // The catalog has `check serviceaccount` as uncertain: `check` isn't in the verb sets. It only
        // reports whether delegation is authorized; GamGUI's Setup runs it as its read-only verify.
        "check_svcacct": "verifies domain-wide delegation; changes nothing",
    ]

    /// Arguments drawn from a closed set: they keep the fixture's valid value.
    static let closedArguments: Set = ["role", "privacy", "action", "detail"]

    /// The first known verb in `argv`, GamGUI's way, or nil when none is known (uncertain).
    static func verb(_ argv: [String]) -> String? {
        argv.prefix(6).first { verbSets.read.contains($0) || verbSets.destructive.contains($0) || verbSets.low.contains($0) }
    }

    /// Each builder called once with placeholder values (`<email>`), so no operator value can be
    /// mistaken for a verb: the verb comes from the builder's own tokens.
    static let builtOnce = Result { try buildAll() }
    func commands() throws -> [(name: String, command: any GamCommand)] { try Self.builtOnce.get() }

    static func buildAll() throws -> [(name: String, command: any GamCommand)] {
        let document = GoldenArgvTests().document
        return try GoldenArgvTests.implemented.keys.sorted().map { name in
            let item = try #require(document.cases.first { $0.builder == name && $0.argv != nil }, "\(name) has no case")
            var kwargs: [String: GoldenArgvTests.Value] = [:]
            for (key, value) in item.kwargs {
                switch value {
                case .string where !closedArguments.contains(key): kwargs[key] = .string("<\(key)>")
                case .strings: kwargs[key] = .strings(["<\(key)>"])
                default: kwargs[key] = value
                }
            }
            return (name, try GoldenArgvTests.implemented[name]!(GoldenArgvTests.Args(kwargs)))
        }
    }

    @Test func everyReadIsConfidentlyReadOnly() throws {
        var reads = 0
        for (name, command) in try commands() where command is GamRead {
            reads += 1
            if Self.reviewedReads[name] != nil {
                #expect(Self.verb(command.argv) == nil, "\(name) now has a known verb: drop its review")
                continue
            }
            let verb = Self.verb(command.argv)
            #expect(verb.map(Self.readVerbs.contains) == true, "\(name) is a GamRead but its verb is \(verb ?? "unknown")")
        }
        #expect(reads == 24)
    }

    @Test func noWriteHasAReadVerb() throws {
        var writes = 0
        for (name, command) in try commands() where command is GamWrite {
            writes += 1
            let verb = Self.verb(command.argv)
            #expect(!(verb.map(Self.readVerbs.contains) ?? false), "\(name) is a GamWrite but reads (\(verb ?? ""))")
        }
        #expect(writes == 34)
    }

    @Test func theVerbSetsAreGamGUIs() {
        #expect(Self.verbSets.read.contains("print") && Self.verbSets.destructive.contains("delete")
                && Self.verbSets.low.contains("create"))
        #expect(Self.verbSets.read.isDisjoint(with: Self.verbSets.destructive.union(Self.verbSets.low)))
    }

    /// Each write builder's action, by GamGUI's builder name. Exact: a swapped pair (a delete tagged as
    /// an undelete) would let a per-action rule allow the wrong write.
    static let actions: [String: WriteAction] = [
        "create_user": .createUser, "update_organization": .updateOrganization,
        "add_calendar_acl": .addCalendarACL, "add_calendar_acl_cal": .addCalendarACL,
        "delete_calendar_acl": .deleteCalendarACL, "delete_calendar_acl_cal": .deleteCalendarACL,
        "subscribe_calendar": .subscribeCalendar, "remove_calendar": .removeCalendar, "delete_event": .deleteEvent,
        "reset_password": .resetPassword, "signout_user": .signOutUser, "deprovision_user": .deprovisionUser,
        "create_datatransfer": .createDataTransfer, "remove_all_calendar_acls": .removeAllCalendarACLs,
        "add_calendar_event": .addCalendarEvent, "delete_user": .deleteUser, "undelete_user": .undeleteUser,
        "create_tasklist": .createTaskList, "create_task": .createTask, "send_email": .sendEmail,
        "set_signature": .setSignature, "add_delegate": .addDelegate, "remove_delegate": .removeDelegate,
        "set_vacation": .setVacation, "vacation_off": .vacationOff,
        "add_forwarding_address": .addForwardingAddress, "set_forward": .setForward, "forward_off": .forwardOff,
        "create_user_alias": .createUserAlias, "delete_alias": .deleteAlias,
        "create_group": .createGroup, "add_group_member": .addGroupMember, "remove_group_member": .removeGroupMember,
    ]

    @Test func everyWriteNamesExactlyItsOwnAction() throws {
        var named: Set<WriteAction> = []
        for (name, command) in try commands() {
            guard let write = command as? GamWrite, name != "set_suspended" else { continue }
            #expect(write.action == Self.actions[name], "\(name) is tagged \(write.action)")
            named.insert(write.action)
        }
        #expect(Set(Self.actions.keys) == Set(try commands().filter { $0.command is GamWrite }.map(\.name)).subtracting(["set_suspended"]))
        // Suspend and unsuspend are one GamGUI builder but different writes.
        #expect(GamCommands.setSuspended(email: "a@example.com", suspended: true).action == .suspendUser)
        #expect(GamCommands.setSuspended(email: "a@example.com", suspended: false).action == .unsuspendUser)
        #expect(named.union([.suspendUser, .unsuspendUser]) == Set(WriteAction.allCases))
    }

    /// Every builder in the source is one this suite (and the golden test) checks: a Swift-only builder
    /// returning `GamRead` would otherwise skip the read-only rule.
    @Test func everyBuilderInTheSourceIsChecked() throws {
        let source = try String(contentsOf: Fixtures.repoRoot.appending(path: "Packages/GamKit/Sources/GamEngine/GamCommands.swift"),
                                encoding: .utf8)
        let reads = source.matches(of: /-> GamRead\b/).count, writes = source.matches(of: /-> GamWrite\b/).count
        let mints = source.matches(of: /\bGam(Read|Write)\(/).count
        #expect(reads == 24 && writes == 34, "a builder was added or removed: hold it here and in GoldenArgvTests")
        #expect(mints == reads + writes, "one builder per command made")
        #expect(try commands().count == reads + writes)
    }
}
