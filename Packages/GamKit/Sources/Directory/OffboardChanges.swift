import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// Offboarding a leaver: exactly what GamGUI's eight-step offboarding runs for a leaver and a manager, held
/// as one ChangeCore preview and run once on the operator's confirm. Ports GamGUI's preview and run
/// (`routes/lifecycle.py` `offboard_preview` and `offboard_run`): the form's own refusals, both addresses
/// against a directory read within the last five minutes (never an older one), the leaver's mail delegates,
/// the directory's display names for the auto-reply, then the steps (`Offboarding.steps`) as `WriteStep`s.
///
/// The run is the executor's (invariant 2): the plan's preview, held as shown, with the leaver's address to
/// type (ChangeCore D), only `requires` stopping a step (B), the sweep tolerating its benign notices (A), and
/// both accounts read fresh just before it starts, refused if either changed. Stop takes effect between steps
/// (C). One offboarding at a time; quitting while it runs asks first.
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

        /// The form filled from `template`: the steps it leaves out, the auto-reply, the reminder and its invitee.
        /// The addresses and the "already done" ticks are this leaver's, and stay.
        public mutating func apply(_ template: Offboarding.Template) {
            notApplicable = template.leftOut
            subject = template.subject
            message = template.message
            days = template.days
            invitee = template.invitee
        }

        /// What saving this form as a template keeps.
        public var template: Offboarding.Template {
            Offboarding.Template(leftOut: notApplicable, subject: subject, message: message, days: days, invitee: invitee)
        }
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
    public struct Plan: Sendable, Identifiable {
        public let id = UUID()
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
        /// The writes that run, in order, each needing the earlier ones `requires` names.
        public let steps: [WriteStep]
        /// The held preview a confirm runs, exactly `steps`; nil when this build has no GAM (the plan is then
        /// only shown).
        public let preview: HeldPreview?

        /// The row each step runs for, in order.
        public var runningRows: [Row] { rows.filter { if case .runs = $0.status { true } else { false } } }

        /// The same plan without its preview: shown, never run.
        var shownOnly: Plan {
            Plan(form: form, leaver: leaver, manager: manager, header: header, warnings: warnings, rows: rows,
                 whatStopsWhat: whatStopsWhat, autoreply: autoreply, notes: notes, steps: steps, preview: nil)
        }
    }

    /// A confirmed run: each step's result as it ends.
    public struct Run: Sendable {
        public let plan: Plan
        /// One per `plan.steps`, nil until it ends.
        public internal(set) var results: [RunOutcome.Step?]
        public internal(set) var ended = false
        /// Stop was asked: the step running finishes, nothing after it begins.
        public internal(set) var stopping = false
        public internal(set) var auditProblem: String?

        /// GamGUI's `_offboard_run.html` heading: complete, interrupted, stopped or incomplete, then what
        /// succeeded, failed, didn't run and was left out.
        public var summary: String {
            let rows = plan.runningRows
            let total = rows.count
            let succeeded = results.filter { $0?.isSucceeded == true }.count
            func names(_ match: (RunOutcome.Step) -> Bool) -> [String] {
                zip(rows, results).compactMap { row, result in result.map(match) == true ? row.label : nil }
            }
            let failed = names { if case .failed = $0 { true } else { false } }
            let notRun = names { if case .skipped = $0 { true } else { false } }
            let leftOut = plan.rows.filter { if case .leftOut = $0.status { true } else { false } }.map(\.label)
            var text = "Offboarding \(word) — \(succeeded) of \(total) step\(total == 1 ? "" : "s") succeeded"
            if !failed.isEmpty { text += "; failed: " + failed.joined(separator: ", ") }
            if !notRun.isEmpty { text += "; not run: " + notRun.joined(separator: ", ") }
            if !leftOut.isEmpty { text += "; left out: " + leftOut.joined(separator: ", ") }
            return text + "."
        }

        /// Every step that runs succeeded.
        public var isComplete: Bool { ended && results.allSatisfy { $0?.isSucceeded == true } }

        var word: String {
            if isComplete { return "complete" }
            if results.contains(where: { if case .failed(let message, _)? = $0 { message == Executor.interrupted } else { false } }) {
                return "interrupted"
            }
            if results.contains(where: { $0 == .skipped(reason: Executor.stopped) }) { return "stopped" }
            return ended ? "incomplete" : "running"
        }

        /// The sign-out didn't run to completion: the leaver may still be signed in (GamGUI's note).
        public var mayStillBeSignedIn: Bool {
            guard ended, let index = plan.runningRows.firstIndex(where: { $0.key == .revoke }) else { return false }
            return results[index]?.isSucceeded != true
        }

        /// What to do next, in GamGUI's words: finish what didn't run, or when the account may be deleted.
        public var next: String {
            let transferRuns = !plan.form.notApplicable.contains(.transfer)
            if !isComplete {
                return "To finish: fix what the failed step reports, then Preview the Rest: it ticks the steps that "
                    + "succeeded as already done and leaves out the same steps as before."
                    + (transferRuns ? " Don't delete the account until the Drive & Calendar transfer has succeeded and finished." : "")
            }
            if plan.form.notApplicable.contains(.reminder) {
                return "No reminder was set (it was left out). When it's safe, delete the account"
                    + (transferRuns ? ", after the transfer has finished." : ".")
            }
            return "The manager now has a calendar reminder. When they confirm it's safe, delete the account."
        }

        /// The form for the rest: the steps that succeeded (or were already done) ticked as done, the same left
        /// out, so a new preview runs only what's left (GamGUI's "tick the ✓ steps").
        public var rest: Form {
            var form = plan.form
            for (row, result) in zip(plan.runningRows, results) where result?.isSucceeded == true { form.done.insert(row.key) }
            return form
        }
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

    /// The run going on, or the last one, while it belongs to the connected tenant.
    public var run: Run? {
        guard let ran, ran.domain == setup.active, ran.generation == setup.generation else { return nil }
        return ran.run
    }
    public private(set) var isRunning = false
    /// Why a confirm didn't run, in the operator's words.
    public private(set) var problem: String?

    /// What quitting now would cut short, for the quit alert; nil when nothing would.
    public var interruptible: (what: String, consequence: String)? {
        guard isRunning, let run = ran?.run else { return nil }
        return ("Offboarding \(run.plan.leaver.primaryEmail) is still running.",
                "The steps not yet run won't be, and the one running now may stop partway: check it in Google before running it again.")
    }

    private var shown: (state: State, domain: Domain?, generation: Int)?
    private var ran: (run: Run, domain: Domain, generation: Int)?
    /// Counts plans asked for: a slower, older one never replaces a newer one.
    private var asked = 0
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    private let access: UserAccess
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    /// `now` and `calendar` give the operator's day (the reminder's date) and the directory's age. Without an
    /// executor (no GAM) a plan is only shown.
    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, access: UserAccess,
                now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.access = access
        self.now = now
        self.calendar = calendar
    }

    /// Back to the form: a held preview is dropped.
    public func clear() {
        discardHeld()
        shown = nil
        problem = nil
    }

    /// The form changed under a plan: its preview is dropped (GamGUI refuses a run of an edited form). The plan
    /// stays on screen, only shown: changing the form back doesn't make it runnable again.
    public func formChanged(_ form: Form) {
        guard case .planned(let plan) = state, plan.form != form, plan.preview != nil, let at = shown else { return }
        discardHeld()
        shown = (.planned(plan.shownOnly), at.domain, at.generation)
    }

    private func discardHeld() {
        guard case .planned(let plan)? = shown?.state, let id = plan.preview?.id else { return }
        Task { [executor] in await executor?.discard(id) }
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
        guard !isRunning else {
            problem = "An offboarding is running: wait for it to finish, then preview again."
            return
        }
        discardHeld()
        problem = nil
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
        // Held as shown: the leaver's address to type, only `requires` stopping a step, and both accounts read
        // fresh just before the run, refused if either changed since this check (GamGUI re-checks a list).
        var preview: HeldPreview?
        if let executor, let domain = tenant.domain {
            let admin = setup.connectedAdmin ?? ""
            let precondition: @Sendable () async throws -> Bool = { [access] in
                let nowLeaving = try await access.account(user, in: domain)
                let nowTakingOver = try await access.account(boss, in: domain)
                return Self.unchanged(nowLeaving, since: leaving) && Self.unchanged(nowTakingOver, since: takingOver)
                    && Guard.normalized(nowLeaving.primaryEmail) != Guard.normalized(admin)
            }
            switch await executor.preview(steps, confirmStep: true, expecting: (domain, tenant.generation),
                                          stopsAtAccountWideFailure: false, typedAddress: user, precondition: precondition) {
            case .success(let held): preview = held
            case .failure(let refusal): return refuse(refusal.message)
            }
        }
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
            notes: Offboarding.notes(days: days, notApplicable: form.notApplicable), steps: steps, preview: preview)))
        // A plan that arrived after a newer one, or on another tenant, is dropped with its preview.
        if case .planned(let shownPlan)? = shown?.state, shownPlan.preview?.id == preview?.id { return }
        if let id = preview?.id { await executor?.discard(id) }
    }

    /// The account is the one the preview showed: its primary address, and whether it's suspended or an admin
    /// (the preview's warnings), unchanged.
    nonisolated static func unchanged(_ now: GamUser, since then: GamUser) -> Bool {
        Guard.normalized(now.primaryEmail) == Guard.normalized(then.primaryEmail) && now.suspended == then.suspended
            && now.isAdmin == then.isAdmin && now.isDelegatedAdmin == then.isDelegatedAdmin
    }

    // MARK: the run

    /// Runs `plan`'s preview once, exactly as held, while it's the plan the screen shows: each step's result as it
    /// ends. The executor refuses it without the leaver's address typed, after its fifteen minutes, on another
    /// tenant, or when either account changed. The directory is read again after it.
    public func confirm(_ plan: Plan, _ confirmation: OperatorConfirmation) async {
        guard !isRunning, let executor, let preview = plan.preview, case .planned(let shownPlan) = state,
              shownPlan.preview?.id == preview.id, let domain = setup.active else { return }
        problem = nil
        isRunning = true
        let generation = setup.generation
        ran = (Run(plan: plan, results: Array(repeating: nil, count: plan.steps.count)), domain, generation)
        // The Mac doesn't idle to sleep under an hour-long sweep.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Offboarding \(plan.leaver.primaryEmail)")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            isRunning = false
        }
        let (events, observer) = AsyncStream<(Int, RunOutcome.Step)>.makeStream()
        let watcher = Task { @MainActor [weak self] in
            for await (index, result) in events { self?.record(result, at: index) }
        }
        let outcome = await executor.run(preview, confirmation: confirmation, progress: observer)
        observer.finish()
        await watcher.value
        if let refusal = outcome.refusal {
            ran = nil
            problem = refusal
            return
        }
        guard var run = ran?.run else { return }
        for (index, result) in outcome.steps.enumerated() { run.results[index] = result }
        run.auditProblem = outcome.auditProblem
        run.ended = true
        ran = (run, domain, generation)
        // The plan is spent; the panel shows the run. A read: the directory as the run left it.
        shown = nil
        await directory.load()
    }

    /// Stop between steps (GamGUI's Stop): the step running finishes, nothing after it begins.
    public func stop() async {
        guard isRunning, let id = ran?.run.plan.preview?.id, let executor else { return }
        if await executor.stopAfterCurrentStep(id), var run = ran?.run, let at = ran {
            run.stopping = true
            ran = (run, at.domain, at.generation)
        }
    }

    /// The finished run's panel is dismissed: back to the form.
    public func dismissRun() {
        guard !isRunning else { return }
        ran = nil
    }

    #if DEBUG
    /// Debug builds' screenshots only: the shown plan's run, finished, every step done (the sweep's notices
    /// tolerated), as the panel shows one. Nothing runs.
    public func showDemoRun() {
        guard case .planned(let plan) = state, let domain = setup.active else { return }
        discardHeld()
        let results: [RunOutcome.Step?] = plan.runningRows.map { row in
            .succeeded(output: row.key == .calacls ? Executor.toleratedOutput : "")
        }
        ran = (Run(plan: plan, results: results, ended: true), domain, setup.generation)
        shown = nil
    }
    #endif

    private func record(_ result: RunOutcome.Step, at index: Int) {
        guard let at = ran, index < at.run.results.count else { return }
        var run = at.run
        run.results[index] = result
        ran = (run, at.domain, at.generation)
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
        // GamGUI's `offboard_plan` record: what was left out goes in the first step's audit.
        let leftOut = Offboarding.Step.allCases.filter(notApplicable.contains).map(\.rawValue).joined(separator: ",")
        return running.enumerated().map { index, step in
            var about = ["offboard": leaver]
            if step.key == .transfer { about["new_owner"] = manager }
            if index == 0, !leftOut.isEmpty { about["not_applicable"] = leftOut }
            return WriteStep(step.write, target: step.key == .reminder ? manager : leaver, summary: step.summary,
                             requires: step.requires.compactMap { needed in running.firstIndex { $0.key == needed } },
                             about: about, timeout: step.timeout,
                             tolerating: step.key == .calacls ? Executor.sweepTolerable : [])
        }
    }
}
