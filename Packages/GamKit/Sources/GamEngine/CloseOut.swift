import Foundation

/// Close Out (roadmap 4.5, plan D2; GamGUI's `core/closeout.py`): what a leaver still has once their data transfer has
/// finished, taken away as the operator picks.
///
/// - The offboarding routine hands the leaver's Drive and calendars over; Google's transfer runs for minutes after its command,
///   and taking the leaver out of their groups, moving their org unit or suspending them can switch off what it still needs.
///   So nothing is offered while a transfer from them is unfinished, or when that can't be read: unknown is never a reason
///   to go ahead (invariant 10).
/// - Every step is off until it is picked: each group, each admin role, the org unit, suspend or archive, each license, each
///   alias (moved to the manager). None waits on another: a refused one is reported and the rest still run.
/// - The delete isn't a step: it is the person page's delete (roadmap 2.9), with its own refusals.
/// - A read that failed is said, and offers nothing in its place: groups unread are never "in no groups".
public enum CloseOut {
    /// Google's Admin Help, "Archive former employee accounts": archiving swaps the person's license for an Archived User one.
    public static let archiveSource = "https://knowledge.workspace.google.com/admin/users/archive-former-employee-accounts"
    public static let archiveSwaps = "Archiving swaps their license for an Archived User license, and Google refuses to archive "
        + "without one to give."
    /// The account fields one check reads.
    public static let recordFields = ["primaryEmail", "suspended", "archived", "orgUnitPath", "aliases"]

    public enum State: String, Sendable, CaseIterable { case suspend, archive }

    /// What one check read of a leaver. A list that is nil wasn't read: `unread` says why, and nothing is offered for it.
    public struct Found: Sendable, Equatable {
        /// The account's primary address.
        public let user: String
        public var orgUnit = ""
        public var suspended = false
        /// Nil when the record didn't say.
        public var archived: Bool?
        public var aliases: [String] = []
        public var groups: [String]?
        public var roles: [Compromised.AdminRole]?
        public var seats: [Licenses.Seat]?
        /// Every org unit, for the move.
        public var units: [String]?
        /// The transfers from them; nil: unread.
        public var transfers: [Offboarding.DataTransfer]?
        /// Why each section wasn't read (`groups`, `roles`, `units`, `seats`), in words.
        public var unread: [String: String] = [:]

        public init(user: String) { self.user = user }

        /// Why nothing is offered yet: a transfer from them unfinished, or one that couldn't be checked.
        public var refusal: String? { transferRefusal(user, transfers) }
        public var failedTransfers: [String] { Licenses.failedTransfers(transfers) }
    }

    /// GamGUI's `transfer_refusal`. A transfer that *failed* has stopped, so it doesn't refuse: the check names it.
    public static func transferRefusal(_ user: String, _ transfers: [Offboarding.DataTransfer]?) -> String? {
        guard let transfers else {
            return "Couldn't check whether a data transfer from \(user) is still running, so nothing is offered: taking them out "
                + "of groups, moving them or suspending them can stop a transfer that needs it. Check again in a moment."
        }
        let running = transfers.filter { !$0.isFinished && PythonText.lower(PythonText.strip($0.status)) != "failed" }
        guard !running.isEmpty else { return nil }
        let what = running.map { "\($0.application) (\($0.status.isEmpty ? "status unknown" : $0.status))" }.joined(separator: ", ")
        return "A data transfer from \(user) hasn't finished (\(what)), so nothing is offered yet: taking them out of groups, "
            + "moving them or suspending them can stop what it still needs. Check again once it completes."
    }

    /// What the operator picked, each matched to what a read found now.
    public struct Picks: Sendable, Equatable {
        public var groups: [String] = []
        public var roles: [Compromised.AdminRole] = []
        public var orgUnit = ""
        public var state: State?
        public var seats: [Licenses.Seat] = []
        public var aliases: [String] = []
        public init() {}
        public var isEmpty: Bool {
            groups.isEmpty && roles.isEmpty && orgUnit.isEmpty && state == nil && seats.isEmpty && aliases.isEmpty
        }
    }

    /// What the screen asks for: names, as the check showed them.
    public struct Asked: Sendable, Equatable {
        public var groups: Set<String> = []
        /// Role assignment IDs.
        public var roles: Set<String> = []
        public var orgUnit = ""
        public var state: State?
        /// Seat keys (`Licenses.Seat.key`).
        public var seats: Set<String> = []
        public var aliases: Set<String> = []
        public init() {}
    }

    /// GamGUI's `pick`: the picks that name something `found` has, in the read's order, and the ones that don't (read since,
    /// or never offered): the caller refuses those, never runs them.
    public static func pick(_ found: Found, _ asked: Asked) -> (picks: Picks, stale: [String]) {
        var stale: [String] = []
        func matched<T>(_ asked: Set<String>, _ have: [T]?, _ name: (T) -> String) -> [T] {
            let wanted = Set(asked.map { PythonText.lower(PythonText.strip($0)) }.filter { !$0.isEmpty })
            let known = Set((have ?? []).map { PythonText.lower(name($0)) })
            stale += wanted.subtracting(known).sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            return (have ?? []).filter { wanted.contains(PythonText.lower(name($0))) }
        }
        var picks = Picks()
        let unit = PythonText.strip(asked.orgUnit)
        if !unit.isEmpty, !(found.units ?? []).contains(where: { $0.utf8.elementsEqual(unit.utf8) }) { stale.append(unit) }
        if let state = asked.state, (state == .suspend && found.suspended) || (state == .archive && found.archived != false) {
            stale.append(state.rawValue)
        }
        picks.groups = matched(asked.groups, found.groups) { $0 }
        picks.roles = matched(asked.roles, found.roles) { $0.id }
        picks.orgUnit = unit.utf8.elementsEqual(found.orgUnit.utf8) ? "" : unit
        picks.state = asked.state
        picks.seats = matched(asked.seats, found.seats) { $0.key }
        picks.aliases = matched(asked.aliases, found.aliases) { $0 }
        return (picks, stale)
    }

    /// One picked step: the write and what it says.
    public struct Step: Sendable {
        public let key: String
        public let label: String
        public let summary: String
        public let write: GamWrite
        /// The alias a move takes, read again as theirs right before it (`WriteStep.KeepFirst.aliasOf`).
        public let alias: String?
    }

    public struct Refused: Error, Sendable, Equatable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    /// GamGUI's `steps`: every picked step in run order, for `user`'s primary address: groups, admin roles, org unit, suspend
    /// or archive, licenses, aliases.
    public static func steps(_ user: String, _ picks: Picks, manager: String = "") throws(Refused) -> [Step] {
        if picks.state == .archive, !picks.seats.isEmpty {
            throw Refused("\(archiveSwaps) So a license isn't removed as well: pick archive or the licenses")
        }
        if !picks.aliases.isEmpty, !GamCommands.isOneAddress(manager) { throw Refused("name the manager to move the aliases to") }
        if !picks.aliases.isEmpty, PythonText.lower(PythonText.strip(manager)) == PythonText.lower(PythonText.strip(user)) {
            throw Refused("an alias can't be moved to the account it's on")
        }
        if !picks.groups.allSatisfy(GamCommands.isOneAddress) { throw Refused("each group is one address") }
        var planned: [Step] = []
        for group in picks.groups {
            planned.append(Step(key: "group", label: "Take them out of \(group)",
                                summary: "Remove \(user) from \(group). An admin role held through that group goes with it.",
                                write: GamCommands.removeGroupMember(group: group, member: user), alias: nil))
        }
        for role in picks.roles {
            let write: GamWrite
            do { write = try GamCommands.deleteAdminRole(assignmentID: role.id) } catch { throw Refused("a role assignment is named by its numeric ID") }
            planned.append(Step(key: "role", label: "Remove the admin role \(role.role)",
                                summary: "Remove \(user)'s \(role.words) role. Only roles assigned to them directly are listed here.",
                                write: write, alias: nil))
        }
        if !picks.orgUnit.isEmpty {
            planned.append(Step(key: "org_unit", label: "Move them to \(picks.orgUnit)",
                                summary: "Move \(user) to the org unit \(picks.orgUnit): its policies apply to them from then on.",
                                write: GamCommands.moveUserToOrgUnit(orgUnit: picks.orgUnit, email: user), alias: nil))
        }
        switch picks.state {
        case .suspend?:
            planned.append(Step(key: "suspend", label: "Suspend the account",
                                summary: "Suspend \(user): nobody can sign in to it. Unsuspending undoes it.",
                                write: GamCommands.setSuspended(email: user, suspended: true), alias: nil))
        case .archive?:
            planned.append(Step(key: "archive", label: "Archive the account", summary: "Archive \(user): nobody can sign in to it. \(archiveSwaps)",
                                write: GamCommands.setArchived(email: user), alias: nil))
        case nil: break
        }
        for seat in picks.seats {
            let write: GamWrite
            do { write = try GamCommands.removeLicense(email: user, productID: seat.productID, skuID: seat.skuID) } catch {
                throw Refused("the license \(seat.sku) can't be named to GAM")
            }
            planned.append(Step(key: "license", label: "Remove the license \(seat.sku)",
                                summary: "Remove \(user)'s \(seat.sku) license. “\(Licenses.mightLoseData)” \(Licenses.reassignWait)",
                                write: write, alias: nil))
        }
        for alias in picks.aliases {
            let write: GamWrite
            do { write = try GamCommands.moveAlias(alias: alias, to: manager) } catch { throw Refused("an alias is moved to one account, each one address") }
            planned.append(Step(key: "alias", label: "Move the alias \(alias) to \(manager)",
                                summary: "Mail to \(alias) goes to \(manager) instead. GAM removes it from \(user), then adds it to "
                                    + "\(manager): if the add fails, the alias is on nobody, and you add it to \(manager) on their page.",
                                write: write, alias: alias))
        }
        return planned
    }

    /// What a failed alias move says, whatever GAM's own words were: it may have come after the delete.
    public static func aliasMayBeOnNobody(_ alias: String, user: String, manager: String) -> String {
        "\(alias) may now be on nobody: GAM removes it from \(user) before adding it to \(manager). Check \(user)'s page, and add it "
            + "to \(manager) on theirs if it's gone."
    }
}
