import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The response to a compromised account (docs/plans/2026-10-19-compromised-account.md): Check Account reads, and changes
/// nothing, what an attacker commonly changes; the operator picks what to undo; the lock and the picks are held as one
/// ChangeCore preview and run once on the operator's confirm, as offboarding's are. The person stays employed: no
/// manager, no hand-over.
///
/// The run is the executor's (invariant 2): the plan's preview, held as shown, with the person's address to type, only
/// `requires` stopping a step, and the account read fresh just before it starts, refused if it changed or is the admin
/// this app is connected as. Stop takes effect between steps. After the run, the account is checked again.
@MainActor
@Observable
public final class CompromisedChanges {
    /// What the operator chose. A plan belongs to the form and the check it was made from.
    public struct Form: Equatable, Sendable {
        public var person = ""
        /// The reset was already done (in the Admin console, say): not run, and counts as succeeded. The lock steps a run
        /// already did are ticked here too, for the rest, and only for the person that run was for (`restOf`).
        public var done: Set<Compromised.Step> = []
        /// The person whose run `done`'s lock steps came from ("Preview the Rest"); empty when only the reset is ticked.
        public var restOf = ""
        /// The switched steps that run (`Compromised.Step.switchable`).
        public var switchedOn: Set<Compromised.Step> = Compromised.Step.onByDefault
        /// The check's filters to delete, by ID; its delegates and send-as addresses to remove.
        public var filters: Set<String> = []
        public var delegates: Set<String> = []
        public var sendAs: Set<String> = []

        public init() {}

        /// A new form for `person`, as another screen's "Secure Account…" starts one: nothing ticked as done or picked,
        /// IMAP and POP off on.
        public init(person: String) {
            self.person = person
        }

        /// The picks of what `check` no longer lists dropped: a check again after a run lists what's left.
        public mutating func keepPicks(in check: Check) {
            filters.formIntersection(((try? check.filters.get()) ?? []).map(\.id))
            delegates.formIntersection((try? check.delegates.get()) ?? [])
            sendAs.formIntersection(((try? check.sendAs.get()) ?? []).filter { !$0.isPrimary }.map(\.address))
        }
    }

    /// What Check Account read for one person, on one tenant: each read on its own, a failure in GAM's words.
    public struct Check: Sendable, Identifiable {
        public let id = UUID()
        /// The address as typed: the screen shows the check while the field still says it.
        public let asked: String
        public let user: GamUser
        public let account: Compromised.Account
        public let filters: Result<[Compromised.Filter], UserAccess.Problem>
        public let forwarding: Result<Compromised.Forwarding?, UserAccess.Problem>
        public let forwardingAddresses: Result<[Compromised.ForwardingAddress], UserAccess.Problem>
        public let delegates: Result<[String], UserAccess.Problem>
        public let sendAs: Result<[Compromised.SendAs], UserAccess.Problem>
        public let adminRoles: Result<[Compromised.AdminRole], UserAccess.Problem>
        /// What's worth saying first (`Compromised.findings`).
        public let findings: [String]
        /// The admin this app is connected as is this person: nothing here can run (the sign-out would delete the app's
        /// own token).
        public let isConnectedAdmin: Bool

        /// This check is for what the field says now.
        public func isFor(_ typed: String) -> Bool {
            let typed = Guard.normalized(PythonText.strip(typed))
            return typed == Guard.normalized(asked) || typed == Guard.normalized(user.primaryEmail)
        }
    }

    public enum CheckState: Sendable {
        case idle
        case checking(String)
        case checked(Check)
        /// The account couldn't be read: the address and why.
        case failed(String, String)
    }

    /// What happens to one step.
    public enum Status: Equatable, Sendable {
        case runs(commandLine: String)
        case alreadyDone
    }

    public struct Row: Identifiable, Sendable {
        public let id: Int
        public let key: Compromised.Step
        public let label: String
        public let summary: String
        public let status: Status
    }

    public struct Plan: Sendable, Identifiable {
        public let id = UUID()
        public let form: Form
        /// The check the picks came from.
        public let check: UUID
        public let person: GamUser
        public let header: String
        public let rows: [Row]
        public let whatStopsWhat: String
        public let steps: [WriteStep]
        /// The held preview a confirm runs, exactly `steps`; nil when this build has no GAM (only shown).
        public let preview: HeldPreview?

        public var runningRows: [Row] { rows.filter { if case .runs = $0.status { true } else { false } } }

        var shownOnly: Plan {
            Plan(form: form, check: check, person: person, header: header, rows: rows, whatStopsWhat: whatStopsWhat,
                 steps: steps, preview: nil)
        }
    }

    public struct Blocked: Equatable, Sendable {
        public let form: Form
        public let reason: String
    }

    public enum PlanState: Sendable {
        case idle
        case planned(Plan)
        case blocked(Blocked)
    }

    /// A confirmed run: each step's result as it ends.
    public struct Run: Sendable {
        public let plan: Plan
        public internal(set) var results: [RunOutcome.Step?]
        public internal(set) var ended = false
        public internal(set) var stopping = false
        public internal(set) var auditProblem: String?

        public var isComplete: Bool { ended && results.allSatisfy { $0?.isSucceeded == true } }

        /// "Securing carol@example.com complete — 6 of 6 steps succeeded", then what failed and didn't run.
        public var summary: String {
            let rows = plan.runningRows
            func labels(_ match: (RunOutcome.Step) -> Bool) -> [String] {
                zip(rows, results).compactMap { row, result in result.map(match) == true ? row.label : nil }
            }
            let succeeded = results.filter { $0?.isSucceeded == true }.count
            let failed = labels { if case .failed = $0 { true } else { false } }
            let notRun = labels { if case .skipped = $0 { true } else { false } }
            var text = "Securing \(plan.person.primaryEmail) \(word) — \(succeeded) of \(rows.count) step\(rows.count == 1 ? "" : "s") succeeded"
            if !failed.isEmpty { text += "; failed: " + failed.joined(separator: ", ") }
            if !notRun.isEmpty { text += "; not run: " + notRun.joined(separator: ", ") }
            return text + "."
        }

        var word: String {
            if isComplete { return "complete" }
            if results.contains(where: { $0 == .skipped(reason: Executor.stopped) }) { return "stopped" }
            return ended ? "incomplete" : "running"
        }

        /// The sign-out didn't run to completion: the attacker may still be signed in.
        public var mayStillBeSignedIn: Bool {
            guard ended, let index = plan.runningRows.firstIndex(where: { $0.key == .revoke }) else { return false }
            return results[index]?.isSucceeded != true
        }

        /// The form for the rest: the lock steps that succeeded ticked as done, the removals that succeeded unpicked.
        public var rest: Form {
            var form = plan.form
            form.restOf = plan.person.primaryEmail
            for (row, result) in zip(plan.runningRows, results) where result?.isSucceeded == true {
                switch row.key {
                case .filters: form.filters = []
                case .delegate, .sendAs: break   // the check again drops what's gone
                default: form.done.insert(row.key)
                }
            }
            return form
        }
    }

    /// The last check, while it belongs to the connected tenant.
    public var checkState: CheckState {
        guard let checked, checked.domain == setup.active, checked.generation == setup.generation else { return .idle }
        return checked.state
    }

    public var check: Check? {
        if case .checked(let check) = checkState { return check }
        return nil
    }

    /// Why the last check of `typed` failed, while the field still says it.
    public func checkFailure(for typed: String) -> String? {
        guard case .failed(let asked, let reason) = checkState,
              Guard.normalized(PythonText.strip(asked)) == Guard.normalized(PythonText.strip(typed)) else { return nil }
        return reason
    }

    public var isChecking: Bool {
        if case .checking = checkState { return true }
        return false
    }

    public var planState: PlanState {
        guard let shown, shown.domain == setup.active, shown.generation == setup.generation else { return .idle }
        return shown.state
    }

    public var run: Run? {
        guard let ran, isRunning || (ran.domain == setup.active && ran.generation == setup.generation) else { return nil }
        return ran.run
    }
    public private(set) var isRunning = false
    public private(set) var problem: String?

    /// What quitting now would cut short, for the quit alert; nil when nothing would.
    public var interruptible: (what: String, consequence: String)? {
        guard isRunning, let run = ran?.run else { return nil }
        return ("Securing \(run.plan.person.primaryEmail) is still running.",
                "The steps not yet run won't be: check the account again before running the rest.")
    }

    private var checked: (state: CheckState, domain: Domain?, generation: Int)?
    private var shown: (state: PlanState, domain: Domain?, generation: Int)?
    private var ran: (run: Run, domain: Domain, generation: Int)?
    private var asked = 0
    private let executor: Executor?
    private let setup: SetupModel
    private let access: UserAccess

    /// Without an executor (no GAM) a plan is only shown.
    public init(executor: Executor?, setup: SetupModel, access: UserAccess) {
        self.executor = executor
        self.setup = setup
        self.access = access
    }

    /// Back to an empty screen: a held preview is dropped.
    public func clear() {
        discardHeld()
        shown = nil
        checked = nil
        problem = nil
    }

    // MARK: the check

    /// Reads, and changes nothing: the account (an alias reads as its owner), then at once its filters, forwarding and
    /// forwarding addresses, delegates, send-as addresses and admin roles. A plan made before is dropped: its picks
    /// were from the last check.
    public func check(_ typed: String) async {
        let person = PythonText.strip(typed)
        let tenant = (domain: setup.active, generation: setup.generation)
        func finish(_ state: CheckState) {
            guard tenant.domain == setup.active, tenant.generation == setup.generation else { return }
            checked = (state, tenant.domain, tenant.generation)
        }
        guard !person.isEmpty else { return finish(.failed(person, "Enter the address of the account that was taken over.")) }
        guard tenant.domain != nil else { return finish(.failed(person, "Connect a domain on Setup first.")) }
        guard !isRunning else {
            problem = "A run is going on: wait for it to finish, then check again."
            return
        }
        discardHeld()
        shown = nil
        problem = nil
        finish(.checking(person))
        let user: GamUser
        switch await access.compromisedAccount(person) {
        case .success(let read): user = read
        case .failure(let problem): return finish(.failed(person, "Couldn't read \(person): \(problem.summary)"))
        }
        let email = user.primaryEmail
        async let filters = access.filters(of: email)
        async let forwarding = access.forwarding(of: email)
        async let addresses = access.forwardingAddresses(of: email)
        async let delegates = access.delegates(of: email)
        async let sendAs = access.sendAs(of: email)
        async let roles = access.adminRoles(of: email)
        let (readFilters, readForwarding, readAddresses, readDelegates, readSendAs, readRoles)
            = await (filters, forwarding, addresses, delegates, sendAs, roles)
        let account = Compromised.Account(user)
        let admin = setup.connectedAdmin ?? ""
        let check = Check(
            asked: person, user: user, account: account, filters: readFilters, forwarding: readForwarding,
            forwardingAddresses: readAddresses, delegates: readDelegates, sendAs: readSendAs, adminRoles: readRoles,
            findings: Compromised.findings(account: account, forwarding: (try? readForwarding.get()) ?? nil,
                                           filters: try? readFilters.get(), delegates: try? readDelegates.get(),
                                           sendAs: try? readSendAs.get(), roles: try? readRoles.get()),
            isConnectedAdmin: !admin.isEmpty && Guard.normalized(admin) == Guard.normalized(email))
        finish(.checked(check))
    }

    // MARK: the plan

    /// The form with the plan's picks against `check`: held as one preview the confirm runs, or refused in words.
    public func plan(_ form: Form) async {
        guard !isRunning else {
            problem = "A run is going on: wait for it to finish, then preview again."
            return
        }
        discardHeld()
        problem = nil
        asked += 1
        let request = asked
        let tenant = (domain: setup.active, generation: setup.generation)
        func finish(_ state: PlanState) {
            guard request == asked, tenant.domain == setup.active, tenant.generation == setup.generation else { return }
            shown = (state, tenant.domain, tenant.generation)
        }
        func refuse(_ reason: String) { finish(.blocked(Blocked(form: form, reason: reason))) }

        guard let check, check.isFor(form.person) else { return refuse("Check the account first: the steps act on what it read.") }
        guard !check.isConnectedAdmin else {
            return refuse("This app is connected as \(check.user.primaryEmail), so it can't secure that account: the sign-out would "
                + "delete the app's own authorization partway through. Run it from another admin's setup.")
        }
        guard setup.connectedAdmin?.isEmpty == false else {
            return refuse("The admin this app signs in as isn't known. Check access on Setup, then preview again.")
        }
        let user = check.user.primaryEmail
        let picked = (filters: ((try? check.filters.get()) ?? []).filter { form.filters.contains($0.id) },
                      delegates: ((try? check.delegates.get()) ?? []).filter { form.delegates.contains($0) },
                      sendAs: ((try? check.sendAs.get()) ?? []).filter { !$0.isPrimary && form.sendAs.contains($0.address) }.map(\.address))
        let planned: [Compromised.Planned]
        do {
            planned = try Compromised.steps(user: user, switchedOn: form.switchedOn.intersection(Compromised.Step.switchable),
                                            filters: picked.filters, delegates: picked.delegates, sendAs: picked.sendAs,
                                            recovery: (check.account.recoveryEmail, check.account.recoveryPhone))
        } catch GamCommands.Invalid.argument(let why) {
            return refuse("Couldn't plan this: \(why). Remove it in the Admin console or Gmail's settings instead.")
        } catch {
            return refuse("\(error)")
        }
        // Only the reset is ticked by hand; the other lock steps only by a run of this same person (a rest carried to
        // the next person would skip their sign-out, review 2026-10-19).
        guard form.done.isSubset(of: [.password]) || Guard.normalized(form.restOf) == Guard.normalized(user) else {
            return refuse("Steps are ticked as already done from another person's run. Check this account again and preview.")
        }
        let done = form.done.intersection([.password, .clearRecovery, .revoke, .forward, .imapOff, .popOff])
        let running = planned.filter { !done.contains($0.key) }
        guard !running.isEmpty else { return refuse("Every step is ticked as already done: there is nothing to run.") }
        let resetIndex = running.firstIndex { $0.key == .password }
        let steps = running.enumerated().map { index, step in
            WriteStep(step.write, target: user, summary: step.summary,
                      requires: resetIndex.map { $0 == index ? [] : [$0] } ?? [], about: ["compromised": user])
        }
        var preview: HeldPreview?
        if let executor, let domain = tenant.domain {
            let seen = check.user, setup = setup
            let precondition: @Sendable () async throws -> Bool = { [access] in
                let now: GamUser
                do {
                    now = try await access.account(user, in: domain)
                } catch let problem as UserAccess.Problem {
                    throw PreconditionFailure(problem.summary)
                }
                guard let admin = await setup.connectedAdmin, !admin.isEmpty else { return false }
                return OffboardChanges.unchanged(now, since: seen) && Guard.normalized(now.primaryEmail) != Guard.normalized(admin)
            }
            switch await executor.preview(steps, confirmStep: true, expecting: (domain, tenant.generation),
                                          stopsAtAccountWideFailure: false, typedAddress: user, precondition: precondition) {
            case .success(let held): preview = held
            case .failure(let refusal): return refuse(refusal.message)
            }
        }
        var shownSteps = steps.makeIterator()
        let rows = planned.enumerated().map { index, step in
            Row(id: index, key: step.key, label: step.label, summary: step.summary,
                status: done.contains(step.key) ? .alreadyDone : .runs(commandLine: shownSteps.next()!.commandLine))
        }
        finish(.planned(Plan(form: form, check: check.id, person: check.user,
                             header: Compromised.header(user: user, runs: running.count, total: planned.count),
                             rows: rows, whatStopsWhat: Compromised.whatStopsWhat(resetRuns: resetIndex != nil),
                             steps: steps, preview: preview)))
        if case .planned(let shownPlan)? = shown?.state, shownPlan.preview?.id == preview?.id { return }
        if let id = preview?.id { await executor?.discard(id) }
    }

    /// The form changed under a plan: its preview is dropped. The plan stays on screen, only shown.
    public func formChanged(_ form: Form) {
        guard case .planned(let plan) = planState, plan.form != form, plan.preview != nil, let at = shown else { return }
        discardHeld()
        shown = (.planned(plan.shownOnly), at.domain, at.generation)
    }

    private func discardHeld() {
        guard case .planned(let plan)? = shown?.state, let id = plan.preview?.id else { return }
        Task { [executor] in await executor?.discard(id) }
    }

    // MARK: the run

    /// Runs `plan`'s preview once, exactly as held, while it's the plan shown; then checks the account again.
    public func confirm(_ plan: Plan, _ confirmation: OperatorConfirmation) async {
        guard !isRunning, let executor, let preview = plan.preview, case .planned(let shownPlan) = planState,
              shownPlan.preview?.id == preview.id, let domain = setup.active else { return }
        problem = nil
        isRunning = true
        let generation = setup.generation
        ran = (Run(plan: plan, results: Array(repeating: nil, count: plan.steps.count)), domain, generation)
        defer { isRunning = false }
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
        shown = nil
        isRunning = false
        // A read: the account as the run left it, and anything made before the sign-out.
        await check(plan.person.primaryEmail)
    }

    /// Stop between steps: the step running finishes, nothing after it begins.
    public func stop() async {
        guard isRunning, let id = ran?.run.plan.preview?.id, let executor else { return }
        guard await executor.stopAfterCurrentStep(id) else {
            problem = "The run had already ended: there was nothing left to stop."
            return
        }
        if var run = ran?.run, let at = ran {
            run.stopping = true
            ran = (run, at.domain, at.generation)
        }
    }

    public func dismissRun() {
        guard !isRunning else { return }
        ran = nil
    }

    #if DEBUG
    /// Debug builds' screenshots only: the shown plan's run, finished, every step done. Nothing runs.
    public func showDemoRun() {
        guard case .planned(let plan) = planState, let domain = setup.active else { return }
        discardHeld()
        ran = (Run(plan: plan, results: plan.runningRows.map { _ in .succeeded(output: "") }, ended: true), domain, setup.generation)
        shown = nil
    }
    #endif

    private func record(_ result: RunOutcome.Step, at index: Int) {
        guard let at = ran, index < at.run.results.count else { return }
        var run = at.run
        run.results[index] = result
        ran = (run, at.domain, at.generation)
    }
}
