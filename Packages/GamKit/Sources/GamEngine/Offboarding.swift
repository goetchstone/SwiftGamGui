import Foundation

/// GamGUI's offboarding routine (`core/lifecycle.py`) and its preview's checks and words
/// (`web/routes/lifecycle.py`, `_offboard_preview.html`) as a pure core: the eight steps a leaver's
/// offboarding runs, in order, each one `gam` write built by `GamCommands` with what it needs to have
/// succeeded first, and the directory's verdict on the two addresses. No suspend and no group removal:
/// the leaver keeps a live mailbox so the delegate, the auto-reply and the transfer work. Held byte for
/// byte to Tests/Fixtures/offboarding.json, generated from frozen GamGUI. A template can add native steps to
/// GamGUI's eight (`Step.addable`, docs/plans/2026-10-13-offboarding-options.md); with none added, every routine
/// is GamGUI's. Text is handled by Unicode scalar, as Python does, never by `Character`.
public enum Offboarding {
    /// The steps, in run order: GamGUI's eight (its keys) and the native ones a template adds.
    public enum Step: String, CaseIterable, Sendable {
        case password
        case clearRecovery = "clear_recovery"
        case revoke, forward
        case forwardingFilters = "forwarding_filters"
        case delegate, vacation, transfer
        case secondaryCalendars = "secondary_calendars"
        case calacls, reminder
        case hideFromDirectory = "hide_from_directory"

        /// GamGUI's eight, in its run order: every routine its fixture holds.
        public static let gamgui: [Step] = [.password, .revoke, .forward, .delegate, .vacation, .transfer, .calacls, .reminder]
        /// The native steps a template may add, in run order. Each runs only when added.
        public static let addable: [Step] = [.clearRecovery, .forwardingFilters, .secondaryCalendars, .hideFromDirectory]

        /// GamGUI's `STEP_NAMES` (and the added steps' own): the step as the form's boxes and the run log name it.
        public var name: String {
            switch self {
            case .password: "Reset password"
            case .clearRecovery: "Clear recovery email & phone"
            case .revoke: "Revoke access & sign out"
            case .forward: "Turn off forwarding"
            case .forwardingFilters: "Remove filters that forward"
            case .delegate: "Set delegate"
            case .vacation: "Auto-reply"
            case .transfer: "Transfer Drive & Calendar"
            case .calacls: "Remove from everyone's calendars"
            case .reminder: "Manager reminder"
            case .secondaryCalendars: "Hand over secondary calendars"
            case .hideFromDirectory: "Hide from the directory"
            }
        }

        /// What an added step is for, said beside its switch; nil for GamGUI's eight.
        public var addedNote: String? {
            switch self {
            case .clearRecovery: "So “Forgot password?” can't send a code to their own phone or address and undo the reset. "
                + "The old values aren't kept."
            case .forwardingFilters: "Deletes each Gmail filter that forwards their mail: turning forwarding off doesn't stop "
                + "those. The whole filter goes, with its other actions."
            case .secondaryCalendars: "Makes the manager the owner of each secondary calendar they own: Google deletes "
                + "those with the account, and the transfer doesn't move them."
            case .hideFromDirectory: "Colleagues stop being offered their address; mail to it still arrives. Google can "
                + "take up to a day."
            default: nil
            }
        }

        /// GamGUI's `NOT_APPLICABLE_COST`: what leaving the step out costs, said beside it. Nil for the
        /// minimum lock (the reset, the sign-out and forwarding off), which always runs.
        public var leftOutCost: String? {
            switch self {
            case .delegate: "Nobody is given access to the leaver's mailbox."
            case .vacation: "No auto-reply: people who email the leaver get no notice."
            case .transfer: "Drive files and calendars are not transferred: deleting the account loses them."
            case .calacls: "Colleagues' calendars stay shared with the leaver's address."
            case .reminder: "No reminder: nothing prompts the account's deletion later."
            case .password, .revoke, .forward, .clearRecovery, .forwardingFilters, .secondaryCalendars, .hideFromDirectory: nil
            }
        }
    }

    /// Why a routine can't be built.
    public enum Invalid: Error, Equatable, Sendable {
        /// A step outside `optionalSteps` was left out (GamGUI's ValueError, its words).
        case notOptional(String)
        /// A step outside `Step.addable` was added.
        case notAddable(String)
        /// A date outside Python's (years 1 to 9999).
        case outOfRange
    }

    /// Why the leaver's delegates couldn't be read, in GAM's words (GamGUI's `GAMError.message`).
    public struct Unread: Error, Sendable, Equatable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    /// The steps an operator may leave out ("doesn't apply"): the hand-over, the sweep and the reminder.
    public static let optionalSteps: [Step] = [.delegate, .vacation, .transfer, .calacls, .reminder]

    /// The routine's steps in run order: GamGUI's eight and those `adding` names.
    public static func routine(adding: Set<Step> = []) -> [Step] {
        Step.allCases.filter { Step.gamgui.contains($0) || adding.contains($0) }
    }

    public static let defaultSubject = "{employee} is no longer with the company"
    public static let defaultMessage = "Thank you for your email. {employee} is no longer with the company. "
        + "For assistance, please reach out to {manager}, who will be glad to help or direct your message "
        + "to the appropriate person. We appreciate your understanding."

    /// One transfer, one argv element: a second same-user transfer 409s while the first runs.
    public static let transferServices = "drive,calendar"
    /// Every Drive file the leaver owns, private and shared: left to the API's default, files they had
    /// shared might stay behind, and be lost when the account is deleted.
    public static let transferPrivacy = GamCommands.TransferPrivacy.all

    // MARK: what stops what

    /// GamGUI's `REQUIRES`: what each step needs to have succeeded before it runs. The reset gates
    /// everything; the delegate (the first write to the manager) gates the auto-reply, the transfer and
    /// the reminder; no transfer, no reminder (deleting before the transfer loses the files). The revoke,
    /// forwarding off, the auto-reply and the sweep gate nothing. An added step needs the reset, and gates nothing.
    public static func requires(_ step: Step) -> [Step] {
        switch step {
        case .password: []
        case .revoke, .forward, .delegate, .calacls, .clearRecovery, .forwardingFilters, .secondaryCalendars, .hideFromDirectory:
            [.password]
        case .vacation, .transfer: [.password, .delegate]
        case .reminder: [.password, .delegate, .transfer]
        }
    }

    /// GamGUI's `effective_requires`: `requires(step)` with each step left out replaced by that step's own
    /// requirements. A step left out never counts as succeeded (unlike one ticked as done), so it can't
    /// satisfy a dependency itself.
    public static func effectiveRequires(_ step: Step, notApplicable: Set<Step> = []) -> [Step] {
        var out: [Step] = []
        for needed in requires(step) {
            for step in notApplicable.contains(needed) ? effectiveRequires(needed, notApplicable: notApplicable) : [needed]
            where !out.contains(step) {
                out.append(step)
            }
        }
        return out
    }

    // MARK: the auto-reply

    /// GamGUI's `fill_autoreply`: `{employee}` (the departing person), then `{manager}` and `{contact}`
    /// (who to reach instead), each replaced in turn, as Python's `str.replace` does.
    public static func fillAutoreply(_ text: String, employee: String, manager: String) -> String {
        replacing(replacing(replacing(text, "{employee}", with: employee), "{manager}", with: manager), "{contact}", with: manager)
    }

    /// `str.replace`: every non-overlapping `token`, left to right, by scalar.
    static func replacing(_ text: String, _ token: String, with value: String) -> String {
        let scalars = Array(text.unicodeScalars), token = Array(token.unicodeScalars)
        var out = String.UnicodeScalarView(), index = 0
        while index < scalars.count {
            if scalars[index...].starts(with: token) {
                out.append(contentsOf: value.unicodeScalars)
                index += token.count
            } else {
                out.append(scalars[index])
                index += 1
            }
        }
        return String(out)
    }

    // MARK: the two addresses

    /// The directory's verdict on an offboarding's two addresses: errors block it, warnings are shown.
    public struct AddressCheck: Sendable {
        public var user: GamUser?
        public var manager: GamUser?
        public var errors: [String] = []
        public var warnings: [String] = []
    }

    /// GamGUI's `check_addresses`: both addresses found in the directory by primary address. Unknown is an
    /// error (a typo'd manager would have the mailbox, Drive and reminder handed to nobody after the reset);
    /// so is an alias (the sweep matches ACLs by primary address), the same person twice (GAM refuses a
    /// transfer to oneself), and the admin the app is connected as (revoking it deletes the app's own token
    /// mid-run). An admin role, or a suspended leaver or manager, is a warning.
    public static func checkAddresses(_ directory: [GamUser], user: String, manager: String, connectedAdmin: String = "")
        -> AddressCheck
    {
        // Python dicts: a later record with the same key replaces an earlier one.
        var byEmail: [[Unicode.Scalar]: GamUser] = [:], byAlias: [[Unicode.Scalar]: GamUser] = [:]
        for person in directory { byEmail[key(person.primaryEmail)] = person }
        for person in directory {
            for alias in person.aliases { byAlias[key(alias)] = person }
        }
        var check = AddressCheck()
        func find(_ address: String, _ role: String) -> GamUser? {
            if let found = byEmail[key(address)] { return found }
            if let owner = byAlias[key(address)] {
                check.errors.append("\(address) is an alias of \(owner.primaryEmail) — enter the primary address as the \(role).")
            } else {
                check.errors.append("\(address) isn't in the directory — check the \(role)'s address (an account created in the "
                    + "last few minutes shows after Users → Refresh).")
            }
            return nil
        }
        check.user = find(user, "departing user")
        check.manager = find(manager, "manager")
        if let leaver = check.user, !connectedAdmin.isEmpty, key(leaver.primaryEmail) == key(connectedAdmin) {
            check.errors.append("GamGUI is connected as \(leaver.primaryEmail), so it can't offboard that account: "
                + "revoking its access would delete GamGUI's own authorization partway through. "
                + "Run the offboarding from another admin's GamGUI setup.")
            return check
        }
        if let leaver = check.user, let manager = check.manager, key(leaver.primaryEmail) == key(manager.primaryEmail) {
            check.errors.append("The departing user and the manager are the same account — enter the manager "
                + "who takes over the mailbox and files.")
            return check
        }
        if let leaver = check.user {
            if leaver.isAdmin {
                check.warnings.append("\(leaver.primaryEmail) is a super admin. Offboarding doesn't remove the role — revoke it in the "
                    + "Admin console. If GamGUI is connected as this account, “\(Step.revoke.name)” deletes GamGUI's "
                    + "own authorization (its OAuth token) and the later steps fail.")
            } else if leaver.isDelegatedAdmin {
                check.warnings.append("\(leaver.primaryEmail) holds a delegated admin role — offboarding doesn't "
                    + "remove it; revoke it in the Admin console.")
            }
            if leaver.suspended {
                check.warnings.append("\(leaver.primaryEmail) is already suspended — the mailbox steps (delegate, "
                    + "auto-reply) and “\(Step.revoke.name)” may fail for a suspended account.")
            }
        }
        if let manager = check.manager, manager.suspended {
            check.warnings.append("The manager \(manager.primaryEmail) is suspended — the delegate, the Drive & "
                + "Calendar transfer and the reminder all go to this account and will likely fail.")
        }
        return check
    }

    /// Python's `.lower()`, compared by scalar.
    private static func key(_ address: String) -> [Unicode.Scalar] { Array(PythonText.lower(address).unicodeScalars) }

    // MARK: the steps

    /// One step of the routine: what it's called and does, the one write it runs, what must have succeeded
    /// first, and how long its `gam` may take.
    public struct Planned: Sendable {
        public let key: Step
        public let label: String
        public let summary: String
        public let write: GamWrite
        /// `effectiveRequires(key, notApplicable:)`.
        public let requires: [Step]
        /// The sweep is one domain-wide call that visits every user; every other step is one account's.
        public let timeout: Duration
    }

    /// GamGUI's `build_offboard_steps`: the eight steps in order, every one returned (for the preview to
    /// show) with the steps left out (`notApplicable`, only `optionalSteps`) routed around, and the native steps
    /// `adding` names in their places. The caller runs only the steps not left out. `employeeName` and
    /// `managerContact` are the directory's display forms, used only in the auto-reply's text; `manager` is what
    /// the delegate, the transfer and the reminder act on. `ownedCalendars` are what "Hand over secondary calendars"
    /// hands to the manager, and `forwardingFilters` what "Remove filters that forward" deletes: added, each needs at
    /// least one. With nothing added the steps are GamGUI's, byte for byte.
    public static func steps(user: String, manager: String, subject: String, message: String, days: Int, today: Day,
                             notify: String = "", employeeName: String = "", managerContact: String = "",
                             notApplicable: Set<Step> = [], adding: Set<Step> = [],
                             ownedCalendars: [UserCalendar] = [], forwardingFilters: [MailFilter] = []) throws -> [Planned] {
        guard notApplicable.isSubset(of: optionalSteps) else {
            throw Invalid.notOptional("only \(optionalSteps.map(\.rawValue).joined(separator: ", ")) can be left out; "
                + "the reset, the sign-out and forwarding off always run")
        }
        guard adding.isSubset(of: Step.addable) else {
            throw Invalid.notAddable("only \(Step.addable.map(\.rawValue).joined(separator: ", ")) can be added")
        }
        guard !adding.contains(.secondaryCalendars) || !ownedCalendars.isEmpty else {
            throw Invalid.notAddable("secondary_calendars needs the calendars to hand over")
        }
        guard !adding.contains(.forwardingFilters) || !forwardingFilters.isEmpty else {
            throw Invalid.notAddable("forwarding_filters needs the filters to remove")
        }
        let filterDelete = adding.contains(.forwardingFilters)
            ? try GamCommands.deleteFilters(email: user, filterIDs: forwardingFilters.map(\.id)) : nil
        let targets = forwardingFilters.map(\.forward).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        // Built only when added: it needs the calendars, and refuses an empty list.
        let handOver = adding.contains(.secondaryCalendars)
            ? try GamCommands.transferCalendarOwnership(calendarIDs: ownedCalendars.map(\.calendarID), to: manager) : nil
        let employee = employeeName.isEmpty ? user : employeeName
        let contact = managerContact.isEmpty ? manager : managerContact
        let subject = fillAutoreply(subject, employee: employee, manager: contact)
        let message = fillAutoreply(message, employee: employee, manager: contact)
        let body = HTMLText.autoreplyHTML(message)   // what's sent; the summary shows `message`
        let due = try today.adding(days: days), end = try due.adding(days: 1)
        let reminderSummary = "Offboarding \(user): confirm with IT whether to delete the account"
        let moved = notApplicable.contains(.transfer) ? "nothing transferred" : "data + calendars transferred to \(manager)"
        let reminderDescription = "\(user) was offboarded on \(today.iso) (password reset; \(moved)). When you're sure it's "
            + "safe, tell IT to delete the account."
        let sweepMinutes = minutes(GamRunner.domainWideTimeout)
        let steps: [(Step, String, String, GamWrite?)] = [
            (.password, "Reset password",
             "Set \(user)'s password to a random one nobody is shown, so the old password stops working (the mailbox stays live)",
             GamCommands.resetPassword(email: user)),
            (.clearRecovery, Step.clearRecovery.name,
             "Remove \(user)'s recovery email and recovery phone, so “Forgot password?” can't send them a code and undo the "
                + "reset. The old values aren't kept",
             GamCommands.clearRecovery(email: user)),
            (.revoke, Step.revoke.name,
             "Sign \(user) out of every web and device session, delete their app passwords, invalidate their 2-Step "
                + "Verification backup codes and revoke every connected app's access (OAuth tokens). 2-Step Verification "
                + "itself is left on",
             GamCommands.deprovisionUser(email: user)),
            // Always, not only when a read saw it on: the leaver can switch it on until the sign-out.
            (.forward, Step.forward.name,
             "Turn off automatic forwarding of \(user)'s incoming mail (harmless if it's already off). Gmail filters that "
                + "forward mail are not changed",
             GamCommands.forwardOff(email: user)),
            (.forwardingFilters, Step.forwardingFilters.name,
             "Delete \(user)'s \(forwardingFilters.count) Gmail filter\(forwardingFilters.count == 1 ? " that forwards" : "s that forward") mail (to "
                + "\(targets.joined(separator: ", "))). The whole filter goes, with any other actions it has",
             filterDelete),
            (.delegate, "Set delegate", "Give \(manager) delegate access to \(user)'s mailbox",
             GamCommands.addDelegate(email: user, delegate: manager)),
            (.vacation, "Set auto-responder", "Auto-reply — “\(subject)”: \(message)",
             GamCommands.setVacation(email: user, subject: subject, message: body)),
            (.transfer, "Transfer Drive & Calendar ownership",
             "Transfer \(user)'s Drive/Docs (private and shared files) and calendars to \(manager)",
             GamCommands.createDataTransfer(oldOwner: user, service: transferServices, newOwner: manager, privacy: transferPrivacy)),
            (.secondaryCalendars, Step.secondaryCalendars.name,
             "Make \(manager) the owner of \(user)'s secondary calendars (\(ownedCalendars.map { "“\($0.label)”" }.joined(separator: ", "))), "
                + "so deleting the account doesn't delete them. GAM checks each with the admin's own access first: one the admin "
                + "can't see fails “Not Found” and is handed over in the Admin console",
             handOver),
            (.calacls, "Remove from everyone's calendars",
             "Remove \(user)'s access to every active user's primary calendar — one domain-wide call that visits every "
                + "user, so it can take many minutes (stopped and reported failed after \(sweepMinutes) min). Secondary "
                + "calendars shared with \(user), and suspended users' calendars, are not swept",
             GamCommands.removeAllCalendarACLs(email: user)),
            (.reminder, "\(days)-day reminder for \(manager)",
             "Add a calendar reminder on \(manager)"
                + (notify.isEmpty ? "" : " (also invites \(notify), who gets an invitation email)")
                + " for \(due.iso) to confirm deletion",
             GamCommands.addCalendarEvent(calendar: manager, summary: reminderSummary, start: due.iso, end: end.iso,
                                          description: reminderDescription, attendee: notify)),
            (.hideFromDirectory, Step.hideFromDirectory.name,
             "Hide \(user) from the directory and address autocomplete (Google can take up to a day); mail to the address "
                + "still arrives",
             GamCommands.hideFromDirectory(email: user)),
        ]
        let routine = routine(adding: adding)
        return steps.compactMap { key, label, summary, write in
            guard routine.contains(key), let write else { return nil }
            return Planned(key: key, label: label, summary: summary, write: write,
                           requires: effectiveRequires(key, notApplicable: notApplicable),
                           timeout: key == .calacls ? GamRunner.domainWideTimeout : GamRunner.defaultTimeout)
        }
    }

    /// Python's `f"{seconds / 60:g}"`, for a whole or half minute count.
    static func minutes(_ duration: Duration) -> String {
        let minutes = Double(duration.components.seconds) / 60
        return minutes == minutes.rounded() ? String(Int(minutes)) : String(minutes)
    }

    // MARK: the preview's reads (web/routes/lifecycle.py)

    /// GamGUI's `_resolve_name`: the first directory user whose primary address is `email` (compared
    /// lowercased, not stripped), by their full name; otherwise `email` as given.
    public static func displayName(of email: String, in directory: [GamUser]) -> String {
        let wanted = key(email)
        return directory.first { key($0.primaryEmail) == wanted }?.fullName ?? email
    }

    /// GamGUI's `_manager_contact`: the manager as senders can reach them, "Jane Smith (jane@example.com)",
    /// or the address alone when the directory has no other name; "[manager]" before one is entered.
    public static func managerContact(_ email: String, in directory: [GamUser]) -> String {
        let email = PythonText.strip(email)
        if email.isEmpty { return "[manager]" }
        let name = displayName(of: email, in: directory)
        return !name.isEmpty && key(name) != key(email) ? "\(name) (\(email))" : email
    }

    /// GamGUI's `_compose_autoreply`: the auto-reply exactly as senders will read it, with both names from
    /// the directory and readable placeholders for an address not entered yet. An empty subject or message
    /// is the default one.
    public static func composeAutoreply(user: String, manager: String, subject: String, message: String,
                                        directory: [GamUser]) -> (subject: String, message: String) {
        let user = PythonText.strip(user), manager = PythonText.strip(manager)
        var employee = user.isEmpty ? "" : displayName(of: user, in: directory)
        if employee.isEmpty { employee = user.isEmpty ? "[departing user]" : user }
        let contact = managerContact(manager, in: directory)
        return (fillAutoreply(subject.isEmpty ? defaultSubject : subject, employee: employee, manager: contact),
                fillAutoreply(message.isEmpty ? defaultMessage : message, employee: employee, manager: contact))
    }

    /// GamGUI's `_delegate_warning`: re-adding an existing delegate fails in GAM ("already exists"), and a
    /// failed read of the leaver's delegates means the same Gmail access is broken for the delegate step,
    /// which runs after the irreversible reset and stops the routine when it fails. A warning, not a block:
    /// the read may have failed for a passing reason. Nil when there is nothing to say.
    public static func delegateWarning(user: String, manager: String, delegates: Result<[String], Unread>) -> String? {
        switch delegates {
        case .failure(let unread):
            return "Couldn't read \(user)'s mail delegates (\(unread.reason)). The delegate step uses the same Gmail "
                + "access, so it will likely fail too — after the password has been reset, and a failed "
                + "delegate stops the routine. Fix the cause and preview again."
        case .success(let delegates):
            guard delegates.contains(where: { key($0) == key(manager) }) else { return nil }
            return "\(manager) already has delegate access to \(user)'s mailbox. GAM fails a second add, and a "
                + "failed delegate stops the routine — tick “\(Step.delegate.name)” as already done."
        }
    }

    /// The secondary calendars the leaver owns: the transfer doesn't move them, and Google deletes them with the
    /// account (Workspace accounts, from 2026-10-05). A failed read is said too: it's the delete that loses them, so
    /// the operator has to look. Nil when they own none. At most five are named.
    public static func secondaryCalendarsWarning(user: String, calendars: Result<[UserCalendar], Unread>) -> String? {
        switch calendars {
        case .failure(let unread):
            return "Couldn't check whether \(user) owns secondary calendars (\(unread.reason)). Google deletes the secondary "
                + "calendars a deleted account owns: check before the account is deleted."
        case .success(let owned):
            guard !owned.isEmpty else { return nil }
            let named = owned.prefix(5).map { "“\($0.label)”" }.joined(separator: ", ")
                + (owned.count > 5 ? " and \(owned.count - 5) more" : "")
            return "\(user) owns \(owned.count) secondary calendar\(owned.count == 1 ? "" : "s"): \(named). The Drive & Calendar "
                + "transfer doesn't move \(owned.count == 1 ? "it" : "them"), and Google deletes \(owned.count == 1 ? "it" : "them") "
                + "with the account: add “\(Step.secondaryCalendars.name)”, or hand \(owned.count == 1 ? "it" : "each") over "
                + "before the account is deleted."
        }
    }

    /// Vault holds on the leaver (directly or through their org unit): Google says held data can't be transferred,
    /// and a held account can't be deleted. A failed read is said: a hold would go unseen. Nil when there's none.
    public static func vaultHoldsWarning(user: String, holds: Result<[VaultHold], Unread>, transferRuns: Bool) -> String? {
        let transfer = transferRuns ? "the Drive & Calendar transfer and " : ""
        switch holds {
        case .failure(let unread):
            return "Couldn't check \(user) for Vault holds (\(unread.reason)). A hold stops \(transfer)the account's deletion: "
                + "check in Google Vault."
        case .success(let holds):
            guard !holds.isEmpty else { return nil }
            let named = holds.prefix(5).map { hold in
                "“\(hold.hold)” in “\(hold.matter)”" + (hold.orgUnit.isEmpty ? "" : " (through the org unit \(hold.orgUnit))")
            }.joined(separator: ", ") + (holds.count > 5 ? " and \(holds.count - 5) more" : "")
            return "\(user) is under \(holds.count == 1 ? "a Vault hold" : "\(holds.count) Vault holds"): \(named). Google doesn't "
                + "transfer held data\(transferRuns ? ", so the Drive & Calendar transfer may move nothing" : ""), and the account "
                + "can't be deleted while it's held."
        }
    }

    // MARK: the form's own refusals

    /// What the preview refuses before reading anything (GamGUI's route): a step ticked both as already done
    /// and as doesn't apply (the first in run order), then nothing left to run.
    public static func tickProblem(done: Set<Step>, notApplicable: Set<Step>, adding: Set<Step> = []) -> String? {
        let routine = routine(adding: adding)
        if let both = routine.first(where: { done.contains($0) && notApplicable.contains($0) }) {
            return "“\(both.name)” is ticked both as already done and as doesn't apply — pick one."
        }
        if Set(routine).subtracting(done).subtracting(notApplicable).isEmpty {
            return "Every step is ticked as already done or left out — there is nothing to run."
        }
        return nil
    }

    // MARK: templates (native: GamGUI has none)

    /// A saved offboarding: the optional steps it leaves out, the native steps it adds, and the auto-reply, the
    /// reminder and its invitee it fills in. Everything but the two addresses and the "already done" ticks, which
    /// are one leaver's. A template only fills the form: the plan made from it is the plan that form makes,
    /// GamGUI's byte for byte when it adds nothing.
    public struct Template: Equatable, Sendable {
        /// Only `optionalSteps`: the lock (the reset, the sign-out and forwarding off) always runs.
        public var leftOut: Set<Step>
        /// Only `Step.addable`.
        public var added: Set<Step>
        /// As typed: an empty one runs the default text, as the form's does.
        public var subject: String
        public var message: String
        /// The manager's reminder, this many days out.
        public var days: Int
        /// Also invited to the reminder (IT or HR); empty for nobody.
        public var invitee: String

        public init(leftOut: Set<Step> = [], added: Set<Step> = [], subject: String = Offboarding.defaultSubject,
                    message: String = Offboarding.defaultMessage, days: Int = 30, invitee: String = "") {
            self.leftOut = leftOut
            self.added = added
            self.subject = subject
            self.message = message
            self.days = days
            self.invitee = invitee
        }

        /// The steps it runs, in run order.
        public var runs: [Step] { routine(adding: added).filter { !leftOut.contains($0) } }

        /// Why it can't be saved, in words; nil when it can.
        public var problem: String? {
            if let locked = Step.allCases.first(where: { leftOut.contains($0) && !optionalSteps.contains($0) }) {
                return Step.addable.contains(locked) ? "“\(locked.name)” isn't left out: it runs only when added."
                    : "“\(locked.name)” always runs: the reset, the sign-out and forwarding off lock the account."
            }
            if let odd = Step.allCases.first(where: { added.contains($0) && !Step.addable.contains($0) }) {
                return "“\(odd.name)” is one of GamGUI's steps: it isn't added, it runs unless left out."
            }
            guard Template.days.contains(days) else {
                return "The reminder is between \(Template.days.lowerBound) and \(Template.days.upperBound.formatted()) days out."
            }
            let invitee = PythonText.strip(invitee)
            guard invitee.isEmpty || Address.looksLikeEmail(invitee) else {
                return "The invitee “\(invitee)” isn't one email address. Enter one, like it@example.com, or leave it empty."
            }
            return nil
        }

        /// The form's own range for the reminder.
        public static let days = 1...36_500
    }

    /// The templates on first use, all the operator's to change or delete. "Hand-over" is the operator's own
    /// routine (2026-10-13): GamGUI's eight steps without the domain-wide calendar sweep. "All eight steps" is
    /// GamGUI's routine as it stands; "Lock only" is the lock alone, for a leaver whose hand-over waits.
    public static let starterTemplates: [(name: String, template: Template)] = [
        ("Hand-over", Template(leftOut: [.calacls])),
        ("All eight steps", Template()),
        ("Lock only", Template(leftOut: Set(optionalSteps))),
    ]
    /// The starter the form opens on until the operator picks another default.
    public static let starterDefault = "Hand-over"

    // MARK: the preview's words (_offboard_preview.html, lifecycle.html)

    /// The routine in one sentence, its steps named in run order (GamGUI's intro once left out the two that
    /// lock the leaver out).
    public static func intro(adding: Set<Step> = []) -> String {
        "Runs the sequence in order: " + routine(adding: adding).map(\.name).joined(separator: " → ")
            + ". The account is not deleted: that is a separate step, later."
    }

    /// "Offboarding carol@example.com — 8 steps", or how many run and why the others don't.
    public static func header(user: String, done: Set<Step>, notApplicable: Set<Step>, adding: Set<Step> = []) -> String {
        let routine = routine(adding: adding), total = routine.count
        let done = done.intersection(routine)
        guard !done.isEmpty || !notApplicable.isEmpty else { return "Offboarding \(user) — \(total) steps" }
        let runs = routine.filter { !done.contains($0) && !notApplicable.contains($0) }.count
        let why = [done.isEmpty ? nil : "\(done.count) ticked as already done",
                   notApplicable.isEmpty ? nil : "\(notApplicable.count) left out"].compactMap(\.self)
        return "Offboarding \(user) — \(runs) of \(total) steps (\(why.joined(separator: ", ")))"
    }

    /// What a failure stops, worked out from `effectiveRequires` for the steps that run, so it can't go stale
    /// as GamGUI's hand-written sentence did twice (it still names the delegate as stopping the routine,
    /// though the sweep no longer needs it, and never names forwarding).
    public static func whatStopsWhat(done: Set<Step>, notApplicable: Set<Step>, adding: Set<Step> = []) -> String {
        let runs = routine(adding: adding).filter { !done.contains($0) && !notApplicable.contains($0) }
        func names(_ steps: [Step], _ last: String) -> String {
            let quoted = steps.map { "“\($0.name)”" }
            return quoted.count > 1 ? quoted.dropLast().joined(separator: ", ") + " \(last) " + quoted.last! : quoted.joined()
        }
        var sentences: [String] = [], reported: [Step] = []
        for (index, step) in runs.enumerated() {
            // Every later step that needs this one, directly or through a step it stops.
            var stopped: [Step] = []
            for later in runs[(index + 1)...] {
                let needs = effectiveRequires(later, notApplicable: notApplicable)
                if needs.contains(step) || needs.contains(where: stopped.contains) { stopped.append(later) }
            }
            if stopped.isEmpty {
                reported.append(step)
            } else if stopped.count == runs.count - index - 1 {
                sentences.append("If “\(step.name)” fails, nothing after it runs.")
            } else {
                sentences.append("If “\(step.name)” fails, \(names(stopped, "and")) \(stopped.count == 1 ? "doesn't" : "don't") run.")
            }
        }
        if !reported.isEmpty {
            sentences.append("If \(names(reported, "or")) fails, it is reported as failed and the rest still runs.")
        }
        return sentences.joined(separator: " ")
    }

    /// The notes under the steps: the account stays active, and when it is safe to delete.
    public static func notes(days: Int, notApplicable: Set<Step>) -> [String] {
        var notes = [notApplicable.contains(.reminder)
            ? "The account stays active (its mailbox live), and no reminder is set: delete it later, when it's safe."
            : "The account stays active (its mailbox live). Deleting it is a separate step, once the manager's "
                + "\(days)-day reminder fires and they confirm with IT."]
        if !notApplicable.contains(.transfer) {
            notes.append("Drive and calendar transfers run in the background (about 10–25 minutes). Don't delete the "
                + "account until they finish, or the data not yet transferred is lost.")
        }
        return notes
    }

    // MARK: Gmail filters

    /// One Gmail filter as `print filters … formatjson` gives it: its ID, and where it forwards mail ("" for none).
    public struct MailFilter: Sendable, Equatable {
        public let id: String
        public let forward: String

        public init(id: String, forward: String = "") {
            self.id = id
            self.forward = forward
        }

        public init(record: GamOutput.Record) {
            self.init(id: Fields.text(Fields.first(record, "id")), forward: record["action"]?.object?["forward"]?.string ?? "")
        }
    }

    // MARK: Vault

    /// One Vault hold that covers a person (`print vaultholds`, `printShowUserVaultHolds`): its matter, its name,
    /// and the org unit it covers them through (empty for a hold on their account).
    public struct VaultHold: Sendable, Equatable {
        public let matter: String
        public let hold: String
        public let orgUnit: String

        public init(matter: String, hold: String, orgUnit: String = "") {
            self.matter = matter
            self.hold = hold
            self.orgUnit = orgUnit
        }

        /// A `print vaultholds` row: `matterName`, `name`, `orgUnitPath` (with `User`, the ids beside them).
        public init(record: GamOutput.Record) {
            self.init(matter: Fields.text(Fields.first(record, "matterName")), hold: Fields.text(Fields.first(record, "name")),
                      orgUnit: Fields.text(Fields.first(record, "orgUnitPath")))
        }
    }

    // MARK: dates

    /// A calendar day as Python's `date`: proleptic Gregorian, years 1 to 9999, written `YYYY-MM-DD`.
    public struct Day: Hashable, Sendable {
        /// Days since 0000-12-31 (Python's `toordinal`: 0001-01-01 is 1).
        let ordinal: Int
        static let lastOrdinal = 3_652_059   // 9999-12-31

        private init?(ordinal: Int) {
            guard (1...Self.lastOrdinal).contains(ordinal) else { return nil }
            self.ordinal = ordinal
        }

        public init?(year: Int, month: Int, day: Int) {
            guard (1...9999).contains(year), (1...12).contains(month), (1...Self.days(in: month, of: year)).contains(day)
            else { return nil }
            self.init(ordinal: Self.ordinal(year: year, month: month, day: day))
        }

        /// Exactly `YYYY-MM-DD` in ASCII digits.
        public init?(iso: String) {
            let s = Array(iso.unicodeScalars)
            guard s.count == 10, s[4] == "-", s[7] == "-",
                  [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ ("0"..."9").contains(s[$0]) }) else { return nil }
            func number(_ range: Range<Int>) -> Int { Int(String(String.UnicodeScalarView(s[range])))! }
            self.init(year: number(0..<4), month: number(5..<7), day: number(8..<10))
        }

        /// The day it is at `date` where the operator is (Python's `date.today()`): in a Gregorian
        /// calendar, whatever calendar the Mac uses, in that calendar's time zone.
        public init(_ date: Date, in calendar: Calendar = .current) {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            let parts = gregorian.dateComponents([.year, .month, .day], from: date)
            self = Day(year: parts.year!, month: parts.month!, day: parts.day!)!
        }

        public var iso: String {
            let (year, month, day) = civil
            func padded(_ value: Int, _ width: Int) -> String {
                let digits = String(value)
                return String(repeating: "0", count: max(0, width - digits.count)) + digits
            }
            return "\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))"
        }

        /// `days` later (or earlier), as Python adds a `timedelta`; out of Python's range is an error.
        public func adding(days: Int) throws -> Day {
            let (sum, overflow) = ordinal.addingReportingOverflow(days)
            guard !overflow, let day = Day(ordinal: sum) else { throw Invalid.outOfRange }
            return day
        }

        static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

        static func days(in month: Int, of year: Int) -> Int {
            switch month {
            case 2: isLeap(year) ? 29 : 28
            case 4, 6, 9, 11: 30
            default: 31
            }
        }

        /// Days before the year, then the month, then the day (Python's `_ymd2ord`).
        static func ordinal(year: Int, month: Int, day: Int) -> Int {
            let y = year - 1
            let beforeYear = y * 365 + y / 4 - y / 100 + y / 400
            let beforeMonth = (1..<month).reduce(0) { $0 + days(in: $1, of: year) }
            return beforeYear + beforeMonth + day
        }

        /// Python's `_ord2ymd`, by counting down 400-, 100-, 4- and 1-year cycles.
        var civil: (year: Int, month: Int, day: Int) {
            var n = ordinal - 1
            let n400 = n / 146_097; n %= 146_097
            let n100 = n / 36_524; n %= 36_524
            let n4 = n / 1_461; n %= 1_461
            let n1 = n / 365; n %= 365
            let year = n400 * 400 + n100 * 100 + n4 * 4 + n1 + 1
            if n1 == 4 || n100 == 4 { return (year - 1, 12, 31) }
            var month = 1
            while n >= Self.days(in: month, of: year) {
                n -= Self.days(in: month, of: year)
                month += 1
            }
            return (year, month, n + 1)
        }
    }
}
