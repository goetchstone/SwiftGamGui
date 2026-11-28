import Foundation
@testable import GamEngine
import Testing

/// Close Out (roadmap 4.5): GamGUI's `tests/test_closeout.py` cases for the argv, `pick`, `steps` and `transfer_refusal`.
@Suite("Close Out")
struct CloseOutTests {
    static let alice = "alice@example.com"
    static let seat = Licenses.Seat(user: alice, productID: "Google-Apps", product: "Google Workspace", skuID: "1010020028",
                                    sku: "Business Standard")

    static func role(_ id: String) -> Compromised.AdminRole {
        Compromised.AdminRole(record: ["roleAssignmentId": .string(id), "role": .string("_SEED_ADMIN_ROLE"), "scopeType": .string("CUSTOMER")])
    }

    static func found(_ change: (inout CloseOut.Found) -> Void = { _ in }) -> CloseOut.Found {
        var found = CloseOut.Found(user: alice)
        found.orgUnit = "/Staff"
        found.archived = false
        found.aliases = ["a.anders@example.com"]
        found.groups = ["sales@example.com", "staff@example.com"]
        found.roles = [role("9170001")]
        found.seats = [seat]
        found.units = ["/", "/Leavers", "/Staff"]
        found.transfers = []
        change(&found)
        return found
    }

    static func asked(_ change: (inout CloseOut.Asked) -> Void) -> CloseOut.Asked {
        var asked = CloseOut.Asked()
        change(&asked)
        return asked
    }

    @Test func theNewWritesAreOneElementEach() throws {
        #expect(try GamCommands.deleteAdminRole(assignmentID: "9170001").argv == ["delete", "admin", "9170001"])
        #expect(GamCommands.setArchived(email: Self.alice).argv == ["update", "user", Self.alice, "archived", "on"])
        #expect(try GamCommands.moveAlias(alias: "a.anders@example.com", to: "bob@example.com").argv
                == ["update", "alias", "a.anders@example.com", "user", "bob@example.com"])
    }

    @Test func whatGamWouldReadAsMoreThanOneIsRefused() {
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.deleteAdminRole(assignmentID: "9170001 9170002") }
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.deleteAdminRole(assignmentID: "") }
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.moveAlias(alias: "a@example.com,b@example.com", to: "bob@example.com") }
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.moveAlias(alias: "a@example.com", to: "bob@example.com carol@example.com") }
    }

    @Test func archivingCountsAsCuttingAnAccountOff() {
        #expect(GamCommands.setArchived(email: Self.alice).cutsOff == Self.alice)
    }

    @Test func onlyWhatTheReadFoundIsPickedAndAnythingElseIsNamed() {
        let (picks, stale) = CloseOut.pick(Self.found(), Self.asked {
            $0.groups = ["Sales@example.com", "gone@example.com"]
            $0.roles = ["9170001"]
            $0.orgUnit = "/Leavers"
            $0.state = .suspend
            $0.seats = [Self.seat.key]
            $0.aliases = ["a.anders@example.com"]
        })
        #expect(picks.groups == ["sales@example.com"] && picks.roles.map(\.id) == ["9170001"])
        #expect(picks.orgUnit == "/Leavers" && picks.state == .suspend && picks.seats.count == 1)
        #expect(stale == ["gone@example.com"])
    }

    @Test func aPickOfSomethingNotOfferedIsStale() {
        let cases: [(CloseOut.Found, CloseOut.Asked)] = [
            (Self.found { $0.suspended = true }, Self.asked { $0.state = .suspend }),       // never offered: already suspended
            (Self.found { $0.archived = nil }, Self.asked { $0.state = .archive }),         // unread is never "not archived"
            (Self.found { $0.units = nil }, Self.asked { $0.orgUnit = "/Leavers" }),        // the units unread: nowhere to move to
            (Self.found { $0.groups = nil }, Self.asked { $0.groups = ["sales@example.com"] }),
        ]
        for (found, asked) in cases { #expect(!CloseOut.pick(found, asked).stale.isEmpty, "\(asked)") }
    }

    @Test func theStepsRunInThePlansOrderEachFromItsBuilder() throws {
        let (picks, _) = CloseOut.pick(Self.found(), Self.asked {
            $0.groups = ["staff@example.com"]
            $0.roles = ["9170001"]
            $0.orgUnit = "/Leavers"
            $0.state = .suspend
            $0.seats = [Self.seat.key]
            $0.aliases = ["a.anders@example.com"]
        })
        let steps = try CloseOut.steps(Self.alice, picks, manager: "bob@example.com")
        #expect(steps.map(\.key) == ["group", "role", "org_unit", "suspend", "license", "alias"])
        #expect(steps.map(\.write.argv) == [
            GamCommands.removeGroupMember(group: "staff@example.com", member: Self.alice).argv,
            try GamCommands.deleteAdminRole(assignmentID: "9170001").argv,
            GamCommands.moveUserToOrgUnit(orgUnit: "/Leavers", email: Self.alice).argv,
            GamCommands.setSuspended(email: Self.alice, suspended: true).argv,
            try GamCommands.removeLicense(email: Self.alice, productID: "Google-Apps", skuID: "1010020028").argv,
            try GamCommands.moveAlias(alias: "a.anders@example.com", to: "bob@example.com").argv,
        ])
        #expect(steps.last?.alias == "a.anders@example.com" && steps.dropLast().allSatisfy { $0.alias == nil })
    }

    @Test func aPlanThatCantRunAsAskedIsRefused() {
        let cases: [(CloseOut.Asked, String)] = [
            (Self.asked { $0.state = .archive; $0.seats = [Self.seat.key] }, ""),     // archiving already swaps the license
            (Self.asked { $0.aliases = ["a.anders@example.com"] }, ""),               // nowhere to move them
            (Self.asked { $0.aliases = ["a.anders@example.com"] }, Self.alice),       // onto the account they're on
        ]
        for (asked, manager) in cases {
            let (picks, _) = CloseOut.pick(Self.found(), asked)
            #expect(throws: CloseOut.Refused.self) { try CloseOut.steps(Self.alice, picks, manager: manager) }
        }
    }

    @Test func anUnfinishedOrUnreadTransferOffersNothing() {
        func transfer(_ application: String, _ status: String) -> Offboarding.DataTransfer {
            Offboarding.DataTransfer(record: ["id": .string("t1"), "application": .string(application), "status": .string(status)])
        }
        #expect(CloseOut.transferRefusal(Self.alice, nil)?.contains("Couldn't check whether a data transfer") == true)
        #expect(CloseOut.transferRefusal(Self.alice, [transfer("Drive and Docs", "inProgress")])?
                    .contains("hasn't finished (Drive and Docs (inProgress))") == true)
        #expect(CloseOut.transferRefusal(Self.alice, [transfer("Calendar", "failed")]) == nil, "stopped: said, not refused")
        #expect(CloseOut.transferRefusal(Self.alice, []) == nil)
        // A row without a status is unfinished as far as anyone can tell, never completed.
        #expect(CloseOut.transferRefusal(Self.alice, [Offboarding.DataTransfer(record: ["id": .string("t2")])])?
                    .contains("status unknown") == true)
    }

    @Test func aCSVWithoutItsTitlesIsUnreadNeverNone() {
        #expect(GamOutput.titled("", column: "id") == nil)
        #expect(GamOutput.titled("A notice\n", column: "id") == nil)
        #expect(GamOutput.titled("Getting transfers\nid,status\n", column: "id")?.isEmpty == true)
        #expect(GamOutput.titled("id,status\nt1,completed\n", column: "id")?.count == 1)
    }
}
