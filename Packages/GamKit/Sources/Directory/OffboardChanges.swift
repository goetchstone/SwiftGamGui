import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// Offboarding Off1, the read-only plan: exactly what GamGUI's eight-step offboarding would run for a
/// leaver and a manager, and no way to run it. Ports GamGUI's preview (`routes/lifecycle.py`
/// `offboard_preview`): the form's own refusals, both addresses against a directory read within the last
/// five minutes (never an older one), the leaver's mail delegates, the directory's display names for the
/// auto-reply, then the steps (`Offboarding.steps`) as the `WriteStep`s ChangeCore would hold.
///
/// It reads and plans; it never writes. It has no executor, so it can't hold a preview or run one, and a
/// source scan holds that it never names one (`OffboardChangesTests.offboardingCantWrite`). Running the
/// plan is Off2's, through ChangeCore.
@MainActor
@Observable
public final class OffboardChanges {
    /// What the operator filled in. A plan belongs to the form it was made from.
    public struct Form: Equatable, Sendable {
        public var leaver = ""
        public var manager = ""
        public var subject = Offboarding.defaultSubject
        public var message = Offboarding.defaultMessage
        /// The manager's reminder, this many days out (at least one, as GamGUI's `_days`).
        public var days = 30
        /// Also invited to the reminder (IT or HR), optional.
        public var invitee = ""
        /// Steps ticked as already done by an earlier run: not run, and they count as succeeded.
        public var done: Set<Offboarding.Step> = []
        /// Steps left out ("doesn't apply"): not run, and never counted as succeeded. Only the optional ones.
        public var notApplicable: Set<Offboarding.Step> = []

        public init() {}
    }

    /// The auto-reply as senders will read it.
    public struct Autoreply: Equatable, Sendable {
        public let subject: String
        public let message: String
    }

    /// What happens to one step.
    public enum Status: Equatable, Sendable {
        /// It runs this `gam` line.
        case runs(commandLine: String)
        /// Ticked as already done: not run, and counts as succeeded.
        case alreadyDone
        /// Left out: not run, and what that costs.
        case leftOut(cost: String)
    }

    /// One of the eight steps, as the plan lists it.
    public struct Row: Identifiable, Sendable {
        public let key: Offboarding.Step
        public let label: String
        public let summary: String
        public let status: Status
        public var id: Offboarding.Step { key }
    }

    /// GamGUI's `_offboard_preview.html`, as values.
    public struct Plan: Sendable {
        public let form: Form
        /// The directory's accounts, by their primary addresses: what every step acts on.
        public let leaver: GamUser
        public let manager: GamUser
        /// "Offboarding carol@example.com — 8 steps", or how many run.
        public let header: String
        /// Said before anything runs; none blocks.
        public let warnings: [String]
        /// All eight steps, in run order.
        public let rows: [Row]
        public let whatStopsWhat: String
        /// Nil when the auto-reply is left out.
        public let autoreply: Autoreply?
        public let notes: [String]
        /// The writes that would run, in order, each needing the earlier ones `requires` names: what
        /// Off2 will hold through ChangeCore. Nothing here runs them.
        public let steps: [WriteStep]
    }

    /// Why there is no plan, in words.
    public struct Blocked: Equatable, Sendable {
        public let form: Form
        public let reason: String
    }

    public enum State: Sendable {
        case idle
        case checking(Form)
        case planned(Plan)
        case blocked(Blocked)
    }

    /// GamGUI's user-list TTL: an older list is read again before the addresses are checked.
    public static let directoryFreshness: TimeInterval = 300

    /// The last plan or refusal, while it belongs to the connected tenant.
    public var state: State {
        guard let shown, shown.domain == setup.active, shown.generation == setup.generation else { return .idle }
        return shown.state
    }

    public var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    private var shown: (state: State, domain: Domain?, generation: Int)?
    /// Counts plans asked for: a slower, older one never replaces a newer one.
    private var asked = 0
    private let setup: SetupModel
    private let directory: DirectoryStore
    private let access: UserAccess
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    /// `now` and `calendar` give the operator's day (the reminder's date) and the directory's age.
    public init(setup: SetupModel, directory: DirectoryStore, access: UserAccess, now: @escaping @Sendable () -> Date = Date.init,
                calendar: Calendar = .current) {
        self.setup = setup
        self.directory = directory
        self.access = access
        self.now = now
        self.calendar = calendar
    }

    /// Back to the form.
    public func clear() {
        shown = nil
    }

    /// The auto-reply block while the form is filled in (GamGUI's `/offboard/autoreply`), from the directory
    /// as loaded: nothing is read while typing. Nil when the auto-reply is left out.
    public func autoreply(for form: Form) -> Autoreply? {
        guard !form.notApplicable.contains(.vacation) else { return nil }
        let block = Offboarding.composeAutoreply(user: form.leaver, manager: form.manager, subject: form.subject,
                                                 message: form.message, directory: directory.users ?? [])
        return Autoreply(subject: block.subject, message: block.message)
    }

    // MARK: the plan

    /// Checks `form` and plans it, as GamGUI's preview does: the form's own refusals first, then the
    /// directory (read again when older than five minutes, a failed read blocking), both addresses, the
    /// leaver's delegates (unless the delegate step won't run), and the steps.
    public func plan(_ form: Form) async {
        asked += 1
        let request = asked
        let tenant = (domain: setup.active, generation: setup.generation)
        func finish(_ state: State) {
            guard request == asked, tenant.domain == setup.active, tenant.generation == setup.generation else { return }
            shown = (state, tenant.domain, tenant.generation)
        }
        func refuse(_ reason: String) { finish(.blocked(Blocked(form: form, reason: reason))) }

        let leaver = PythonText.strip(form.leaver), manager = PythonText.strip(form.manager)
        guard !leaver.isEmpty, !manager.isEmpty else { return refuse("Enter both the departing user and the manager email.") }
        if let problem = Offboarding.tickProblem(done: form.done, notApplicable: form.notApplicable) { return refuse(problem) }
        let invitee = PythonText.strip(form.invitee)
        guard invitee.isEmpty || Address.looksLikeEmail(invitee) else {
            return refuse("The invitee “\(invitee)” isn't one email address. Enter one, like it@example.com, or leave it empty.")
        }
        guard tenant.domain != nil else { return refuse("Connect a domain on Setup first.") }
        finish(.checking(form))

        guard let users = await freshDirectory() else {
            let reason = directory.problem?.summary ?? "Something went wrong talking to GAM."
            return refuse("Couldn't read the directory to check the addresses — \(reason)")
        }
        let check = Offboarding.checkAddresses(users, user: leaver, manager: manager, connectedAdmin: setup.connectedAdmin ?? "")
        guard check.errors.isEmpty, let leaving = check.user, let takingOver = check.manager else {
            return refuse(check.errors.joined(separator: " "))
        }
        let user = leaving.primaryEmail, boss = takingOver.primaryEmail
        var warnings = check.warnings
        if !form.done.union(form.notApplicable).contains(.delegate) {
            let delegates = await access.delegates(of: user).mapError { Offboarding.Unread($0.summary) }
            if let warning = Offboarding.delegateWarning(user: user, manager: boss, delegates: delegates) { warnings.append(warning) }
        }
        // An emptied field runs the default text, as the auto-reply block shows it.
        let subject = form.subject.isEmpty ? Offboarding.defaultSubject : form.subject
        let message = form.message.isEmpty ? Offboarding.defaultMessage : form.message
        let days = max(1, form.days)
        let planned: [Offboarding.Planned]
        do {
            planned = try Offboarding.steps(
                user: user, manager: boss, subject: subject, message: message, days: days,
                today: Offboarding.Day(now(), in: calendar), notify: invitee,
                employeeName: Offboarding.displayName(of: user, in: users),
                managerContact: Offboarding.managerContact(boss, in: users), notApplicable: form.notApplicable)
        } catch Offboarding.Invalid.outOfRange {
            return refuse("The reminder would fall after the year 9999. Enter fewer days.")
        } catch {
            return refuse("\(error)")
        }
        let block = Offboarding.composeAutoreply(user: user, manager: boss, subject: subject, message: message, directory: users)
        let steps = Self.writeSteps(planned, leaver: user, manager: boss, done: form.done, notApplicable: form.notApplicable)
        var shownSteps = steps.makeIterator()
        let rows = planned.map { step in
            let status: Status = if form.done.contains(step.key) {
                .alreadyDone
            } else if form.notApplicable.contains(step.key) {
                .leftOut(cost: step.key.leftOutCost ?? "")
            } else {
                .runs(commandLine: shownSteps.next()!.commandLine)
            }
            return Row(key: step.key, label: step.label, summary: step.summary, status: status)
        }
        finish(.planned(Plan(
            form: form, leaver: leaving, manager: takingOver,
            header: Offboarding.header(user: user, done: form.done, notApplicable: form.notApplicable),
            warnings: warnings, rows: rows,
            whatStopsWhat: Offboarding.whatStopsWhat(done: form.done, notApplicable: form.notApplicable),
            autoreply: form.notApplicable.contains(.vacation) ? nil : Autoreply(subject: block.subject, message: block.message),
            notes: Offboarding.notes(days: days, notApplicable: form.notApplicable), steps: steps)))
    }

    /// The directory, no older than `directoryFreshness`: read again first when it is, and nil when that
    /// read fails. The older list is never the fallback (GamGUI plan U12b): an account may have changed.
    private func freshDirectory() async -> [GamUser]? {
        if !isFresh { await directory.load() }
        return isFresh ? directory.users : nil
    }

    private var isFresh: Bool {
        guard directory.users != nil, let loadedAt = directory.loadedAt else { return false }
        return now().timeIntervalSince(loadedAt) <= Self.directoryFreshness
    }

    /// The steps that run (neither ticked as done nor left out), as ChangeCore holds writes: each about the
    /// leaver, the reminder on the manager's calendar, and each needing the earlier steps that run and that
    /// it requires (a step ticked as done counts as succeeded).
    nonisolated static func writeSteps(_ planned: [Offboarding.Planned], leaver: String, manager: String,
                                       done: Set<Offboarding.Step>, notApplicable: Set<Offboarding.Step>) -> [WriteStep] {
        let running = planned.filter { !done.contains($0.key) && !notApplicable.contains($0.key) }
        return running.map { step in
            var about = ["offboard": leaver]
            if step.key == .transfer { about["new_owner"] = manager }
            return WriteStep(step.write, target: step.key == .reminder ? manager : leaver, summary: step.summary,
                             requires: step.requires.compactMap { needed in running.firstIndex { $0.key == needed } },
                             about: about, timeout: step.timeout)
        }
    }
}
