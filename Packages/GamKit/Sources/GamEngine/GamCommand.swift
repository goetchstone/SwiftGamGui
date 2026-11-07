/// A `gam` argv, typed by what it does to the tenant (design: docs/plans/2026-10-09-write-path-options.md,
/// option A). Only GamKit builds one: a read any caller may run, a write only ChangeCore's executor can.
/// `package`, so code outside GamKit can't declare a command type of its own.
package protocol GamCommand: Sendable, Equatable {
    var argv: [String] { get }
}

/// A command that only reads. `AuthenticatedRunner.run` takes these and nothing else, so code outside
/// GamKit (views, App Intents, a model's tool) can read the tenant but has no argv it could write with.
/// Every read builder is held to GamGUI's read-only rule by `CommandKindTests` (invariant 3).
public struct GamRead: GamCommand {
    public let argv: [String]

    /// `internal`: GamEngine's builders are the only source, the catalog's promoted reads included (`catalogRead`, for a
    /// command only `CommandCatalog` makes). Not even GamKit's other targets can make one.
    init(_ argv: [String]) {
        self.argv = argv
    }
}

/// A command that changes the tenant. Nothing outside GamKit can run one: it reaches `gam` only through
/// ChangeCore's executor (invariant 2). `action` is fixed by the builder, never inferred from argv or
/// from a model, so a per-action rule (preview, confirm, §8's "Just do it") is decided by code.
public struct GamWrite: GamCommand {
    public let argv: [String]
    public let action: WriteAction

    /// What's wrong with a run GAM exited 0 for, for a command GAM can leave undone without a word; nil when its output says
    /// it's done, and for every other command. The executor makes it the step's failure, so a step that didn't happen never
    /// reads as done. GAM builds the devices service first and exits 0 with no word if a refreshed token was refused
    /// (buildGAPICIDeviceServiceObject, handleOAuthTokenError), and exits 0 too while Google's operation is still going
    /// (_performCIDeviceUserAction, Msg.ACTION_IN_PROGRESS); it skips a batch of messages on serviceNotAvailable the same way
    /// (_batchDeleteModifyMessages), and a scheduled email in that batch still goes out. Every per-person Gmail write below is the
    /// same: `if not gmail: continue` after a refused token (buildGAPIServiceObject), exit 0 with no output, and each prints on success
    /// (read in GAM 7.50.00's source for each; review 2026-11-07), so saying nothing isn't doing it.
    public func notDone(output: String) -> String? {
        switch action {
        case .setForward, .forwardOff, .setVacation, .vacationOff, .imapOff, .popOff, .deleteFilters, .addDelegate, .removeDelegate,
             .deleteSendAs, .trashMessage:
            return output.allSatisfy(\.isWhitespace) ? Self.saidNothing : nil
        case .blockDeviceUser, .deleteDeviceUser:
            guard argv.count == 3, output.contains("Device User: \(argv[2]),") else { return Self.saidNothing }
            return output.contains("Action \(argv[0]) in progress")
                ? "Google took this but hasn't finished it. Check the account again before counting on it." : nil
        case .deleteMessages:
            let wanted = argv.last?.split(separator: ",").count ?? 0
            let deleted = output.split(whereSeparator: \.isNewline).count { $0.contains(", Deleted") }
            return deleted >= wanted ? nil : "GAM deleted \(deleted) of \(wanted) messages and said nothing about the rest. Check the account again."
        default:
            return nil
        }
    }

    static let saidNothing = "GAM exited without saying it did this, so it may not have happened. Check the account again."

    init(_ argv: [String], action: WriteAction) {
        self.argv = argv
        self.action = action
    }

    /// The account this write cuts off from Google, as its builder put it in the argv; nil for any other write. Deleted,
    /// suspended, its OAuth tokens deleted (`deprovision`: GamGUI's own token went this way, its failure-log 2026-09-24), its
    /// password changed or its sessions ended. Whether GAM's token outlives the last two isn't proven, so they count. Run on
    /// the admin this app signs in as, any of them signs the app out with no way back from here: ChangeCore refuses that.
    public var cutsOff: String? {
        switch action {
        case .deleteUser, .suspendUser, .resetPassword, .setPassword: argv[2]
        case .signOutUser, .deprovisionUser: argv[1]
        default: nil
        }
    }
}

/// What a `GamWrite` does, one case per write builder.
public enum WriteAction: String, Sendable, CaseIterable {
    case createUser, updateOrganization, suspendUser, unsuspendUser
    case addCalendarACL, deleteCalendarACL, subscribeCalendar, removeCalendar, deleteEvent
    case resetPassword, signOutUser, deprovisionUser, createDataTransfer, removeAllCalendarACLs
    case addCalendarEvent, deleteUser, undeleteUser
    case createTaskList, createTask, sendEmail
    case setSignature, addDelegate, removeDelegate, setVacation, vacationOff
    case addForwardingAddress, setForward, forwardOff
    case createUserAlias, deleteAlias
    case createGroup, addGroupMember, removeGroupMember
    // Native: no GamGUI builder (`GamCommands`' native section).
    case clearRecovery, hideFromDirectory, transferCalendarOwnership, deleteFilters, imapOff, popOff, deleteSendAs
    case trashMessage, deleteMessages, setPassword
    case blockDeviceUser, deleteDeviceUser
    case updatePhones
}

/// Permission to run one `GamWrite`, minted only by ChangeCore's executor once a held preview has passed
/// every check (design doc §6). `package`, so the app can't make one; `WriteRouteTests` holds that no
/// other GamKit target does either.
package struct WriteTicket: Sendable {
    package init() {}
}
