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

    /// `internal`: GamEngine's builders are the only source (Catalog's read-only promotion, phase 4, will
    /// need a deliberate door here). Not even GamKit's other targets can make one.
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

    init(_ argv: [String], action: WriteAction) {
        self.argv = argv
        self.action = action
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
}

/// Permission to run one `GamWrite`, minted only by ChangeCore's executor once a held preview has passed
/// every check (design doc §6). `package`, so the app can't make one; `WriteRouteTests` holds that no
/// other GamKit target does either.
package struct WriteTicket: Sendable {
    package init() {}
}
