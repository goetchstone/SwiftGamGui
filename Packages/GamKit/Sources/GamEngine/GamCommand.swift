import Foundation
/// A `gam` argv, typed by what it does to the tenant (design: docs/plans/2026-10-09-write-path-options.md,
/// option A). Only GamKit builds one: a read any caller may run, a write only ChangeCore's executor can.
/// `package`, so code outside GamKit can't declare a command type of its own.
package protocol GamCommand: Sendable, Equatable {
    var argv: [String] { get }
}

/// A command that only reads. `AuthenticatedRunner.run` takes these and nothing else, so code outside
/// GamKit (views, App Intents, a model's tool) can read the tenant but has no argv it could write with.
/// Every read builder is held to GamGUI's read-only rule by `CommandKindTests` (invariant 3).
public struct GamRead: GamCommand, Hashable {
    public let argv: [String]
    /// What GAM reads on its standard input (`file -`, roadmap 5.4), or nil for none (`/dev/null`). Never shown or audited.
    package let input: Data?

    /// `internal`: GamEngine's builders are the only source, the catalog's promoted reads included (`catalogRead`, for a
    /// command only `CommandCatalog` makes). Not even GamKit's other targets can make one.
    init(_ argv: [String], input: Data? = nil) {
        self.argv = argv
        self.input = input
    }
}

/// A command that changes the tenant. Nothing outside GamKit can run one: it reaches `gam` only through
/// ChangeCore's executor (invariant 2). `action` is fixed by the builder, never inferred from argv or
/// from a model, so a per-action rule (preview, confirm, §8's "Just do it") is decided by code.
public struct GamWrite: GamCommand {
    public let argv: [String]
    public let action: WriteAction
    /// What GAM reads on its standard input (`csv -`, roadmap 5.4), or nil for none. Never shown or audited: a signature run's
    /// rows ride here, not in the argv.
    package let input: Data?

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
        case .addDriveMember, .setDriveMemberRole, .removeDriveMember:
            // GAM exits 0 without a word when Google refuses its token (createDriveFileACL and kin skip the admin): only its
            // "Drive File/Folder ID: <drive>, Permission ID: " line says the change was made (GamGUI's `drive_acl_done`).
            guard argv.count > 3 else { return Self.saidNothing }
            return output.contains("Drive File/Folder ID: \(argv[3]), Permission ID: ") ? nil
                : "GAM exited without saying it did this, so it may not have happened. Show the drive's members again."
        case .createAdmin:
            // `create admin` exits 0 with no line when Google answers internalError: the role may or may not have been given.
            return output.contains("Admin Role Assignment: ") ? nil
                : "GAM exited without saying it did this, so it may not have happened. List their roles (`print admins user`) to see whether it was given."
        case .deleteGroup:
            return argv.count > 2 && PythonText.lower(output).contains("group: \(PythonText.lower(argv[2])),") ? nil
                : "GAM exited without saying it did this, so it may not have happened. Look for the group on Groups."
        case .renameUser:
            return argv.count > 2 && PythonText.lower(output).contains("user: \(PythonText.lower(argv[2])),") ? nil
                : "GAM exited without saying it did this, so it may not have happened. Look the person up on Users."
        case .exportToSheet:
            // An exit 0 that printed no link is no answer: whether a Sheet was made can't be told (plan F4, GamGUI's `verify`).
            return SheetExport.sheetURL(output).isEmpty ? SheetExport.noLink : nil
        default:
            return nil
        }
    }

    /// What this write's own output says that its audit record keeps too, read whether GAM exited 0 or not (a warning exit can
    /// follow the write itself); empty for every write but a Sheet export, whose link, else which of the upload's own failure
    /// lines GAM printed about `owner`, the admin whose Drive it is (`SheetExport.noted`, GamGUI's `_run_write` `noted`). Never
    /// the output itself.
    public func noted(stdout: String, stderr: String, owner: String) -> [String: String] {
        switch action {
        case .exportToSheet: SheetExport.noted(stdout: stdout, stderr: stderr, owner: owner)
        // Who GAM's own "Set" line names (roadmap 5.4): its csv parent takes no child's exit code, so this is the result.
        case .setSignaturesFast: ["set": SignaturesFast.updated(stdout: stdout).sorted().joined(separator: ",")]
        default: [:]
        }
    }

    static let saidNothing = "GAM exited without saying it did this, so it may not have happened. Check the account again."

    init(_ argv: [String], action: WriteAction, input: Data? = nil) {
        self.argv = argv
        self.action = action
        self.input = input
    }

    /// The account this write cuts off from Google, as its builder put it in the argv; nil for any other write. Deleted,
    /// suspended, its OAuth tokens deleted (`deprovision`: GamGUI's own token went this way, its failure-log 2026-09-24), its
    /// password changed or its sessions ended. Whether GAM's token outlives the last two isn't proven, so they count. Run on
    /// the admin this app signs in as, any of them signs the app out with no way back from here: ChangeCore refuses that.
    public var cutsOff: String? {
        switch action {
        // A new primary address (roadmap 5.1): whether the token and the service account's sign-in as that address outlive a
        // rename isn't proven, so it counts.
        // Archived can't sign in either (Close Out, roadmap 4.5).
        case .deleteUser, .suspendUser, .resetPassword, .setPassword, .renameUser, .archiveUser: argv[2]
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
    /// A shared drive's members (roadmap 4.7, GamGUI #185).
    case addDriveMember, setDriveMemberRole, removeDriveMember
    /// Close Out (roadmap 4.5, GamGUI #183).
    case archiveUser, deleteAdminRole, moveAlias
    /// A person's whole organizations and phones lists from a CSV (roadmap 4.6, GamGUI #184).
    case updateProfile
    /// A person's license seats (roadmap 4.3, GamGUI #175).
    case addLicense, swapLicense, removeLicense
    /// Org units (roadmap 4.2, GamGUI #169).
    case moveOrgUnit, createOrgUnit, renameOrgUnit, deleteOrgUnit
    /// Many signatures in one GAM call (roadmap 5.4, GamGUI #193).
    case setSignaturesFast = "set_signatures_fast"
    /// The closed list of Builder writes (roadmap 5.1, GamGUI #189).
    case renameUser, deleteGroup, createAdmin
    /// A read's table to a new Google Sheet in the connected admin's Drive (plan F4): named as GamGUI's record names it, so both
    /// apps' logs read alike and Files finds either's.
    case exportToSheet = "export_to_sheet"
}

/// Permission to run one `GamWrite`, minted only by ChangeCore's executor once a held preview has passed
/// every check (design doc §6). `package`, so the app can't make one; `WriteRouteTests` holds that no
/// other GamKit target does either.
package struct WriteTicket: Sendable {
    package init() {}
}
