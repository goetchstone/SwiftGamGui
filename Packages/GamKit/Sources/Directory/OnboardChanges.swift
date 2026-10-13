import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Onboard screen's writes (slice O1): one hire, previewed as one held preview of GamGUI's steps in
/// GamGUI's order and with its gates (`provision_hire`), confirmed once, run once through ChangeCore. Ports
/// GamGUI's `routes/onboarding.py` single flow and its incidents:
/// - the run is the preview: the form, the role, the signature and the password as previewed, never read
///   again (failure-log 2026-09-23, "nobody had previewed");
/// - everything that doesn't write is checked before the first write, so nothing can strand a just-created
///   account's one-time password (failure-log 2026-09-22, "stranded");
/// - the password is shown once, on the card, and held nowhere else (failure-log 2026-09-22, "feed").
///
/// A just-created account's signature, calendars and task list wait for Google (`newAccountFrom`); the
/// model sleeps GamGUI's waits and asks the executor to retry, Stop ends a wait at once, and what still
/// waits after the last round is said in GamGUI's words. Nothing here runs `gam` itself.
@MainActor
@Observable
public final class OnboardChanges {
    // MARK: what a hire's run does

    /// One step of a plan, as the screen shows it.
    public struct Row: Sendable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case account
            case signature(template: String)
            case group(String)
            case calendar(String)
            case taskList(title: String)
            case task(String)
        }

        public let index: Int
        public let kind: Kind
        /// The step in words, for the screen and VoiceOver.
        public let label: String
        /// The command as the operator and the audit see it: the password masked, a task's list id a
        /// placeholder until the run knows it.
        public let shownArgv: [String]

        public var id: Int { index }
    }

    /// What a run does for one hire, as previewed: what the sheet, the run panel, the card and a retry are
    /// made from. It holds no argv and no password.
    public struct Plan: Sendable {
        public let hire: Hire
        public let role: RoleTemplate
        public let email: String
        /// GamGUI's `res["name"]`: the name, else first and last, else the address.
        public let name: String
        public let first: String
        public let last: String
        /// Whose Google Tasks gets the checklist: the form's, else the hire.
        public let assignee: String
        public let title: String
        public let creates: Bool
        /// The role's org unit, or `/`.
        public let orgUnit: String
        /// The template name and the body the run sets, as held; nil when nothing is set.
        public let signature: Signature?
        public let rows: [Row]
        public let warnings: [String]
        /// A retry's plan (design D8): a list id that already exists, for tasks on it.
        public let existingListID: String?

        public struct Signature: Sendable, Equatable {
            public let template: String
            public let body: String
        }

        public var taskCount: Int { rows.count { if case .task = $0.kind { true } else { false } } }
    }

    /// A held preview and what the confirm sheet says about it.
    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        public let plan: Plan
        public let isRetry: Bool
        /// "One new hire: 12 steps", for the sheet's summary (the guard counts steps as targets).
        public let summary: String
        public let confirmLabel: String
        /// The create's password, for the card once the create ends: never shown from here.
        let password: TemporaryPassword?

        public var id: UUID { preview.id }
    }

    /// The run panel: the plan's rows with how each went.
    public struct Run: Sendable {
        public let plan: Plan
        public let isRetry: Bool
        /// Each step's result; nil while it hasn't ended.
        public internal(set) var results: [RunOutcome.Step?]
        public internal(set) var auditProblem: String?
        /// Steps that waited for Google and were given up, with why (GamGUI's reasons and GAM's last error).
        public internal(set) var notDone: [Int: NotDone]
        public internal(set) var ended = false

        public struct NotDone: Sendable, Equatable {
            public let reason: String
            /// GAM's last error, for a disclosure.
            public let detail: String?
        }
    }

    /// The one-time sign-in card (design D4): shown as soon as the create ends, held fifteen minutes or
    /// until Done. The password is read only by the card's own view.
    public struct Card: Sendable, Identifiable {
        public enum SignatureStatus: Sendable, Equatable {
            case none, pending(String), applied(String), waiting(String), notApplied(String)
        }

        public let id = UUID()
        public let name: String
        public let email: String
        public let orgUnit: String
        public let password: TemporaryPassword
        /// The create didn't finish (a timeout or an interruption): the account may or may not exist.
        public let unsure: Bool
        public internal(set) var signature: SignatureStatus
        let shownAt: ContinuousClock.Instant
    }

    /// The new-account wait (GamGUI's FinishJob for one hire).
    public struct Finishing: Sendable {
        public enum Phase: Sendable, Equatable { case waiting, trying, done, stopped, gaveUp }
        public let email: String
        public internal(set) var phase: Phase
        /// Rounds tried so far, of `rounds`.
        public internal(set) var round: Int
        public let rounds: Int
        public internal(set) var nextTryAt: ContinuousClock.Instant?
        /// Steps still waiting.
        public internal(set) var waiting: Int
        public var isLive: Bool { phase == .waiting || phase == .trying }
    }

    public private(set) var pending: Pending?
    public private(set) var run: Run?
    /// Why a preview wasn't made, or a confirm didn't run, in the operator's words.
    public private(set) var problem: String?
    public private(set) var finishing: Finishing?
    public private(set) var isRunning = false
    /// Counts accounts created, so a screen showing the directory reads it again.
    public private(set) var accountsCreated = 0
    private var heldCard: Card?
    /// The create's password while its run is going: on the card once the create ends, or dropped.
    private var creatingPassword: TemporaryPassword?

    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    private let waits: [Duration]
    private let makePassword: @Sendable () -> TemporaryPassword
    private let now: @Sendable () -> ContinuousClock.Instant
    private let timeout: Duration
    private var finishTask: Task<Void, Never>?
    private var cardTimer: Task<Void, Never>?

    /// The card is held this long (GamGUI's `_CREDS_TTL`); `ContinuousClock` counts time asleep.
    public static let cardLifetime: Duration = .seconds(15 * 60)

    /// `waits`, `makePassword`, `now` and `timeout` are for tests: GamGUI's waits, a system-random password,
    /// the clock, and the create's time limit.
    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore,
                waits: [Duration] = Onboarding.newAccountWaits,
                makePassword: @escaping @Sendable () -> TemporaryPassword = { TemporaryPassword.generate() },
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                timeout: Duration = GamRunner.defaultTimeout) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.waits = Array(waits.prefix(Executor.newAccountRounds))
        self.makePassword = makePassword
        self.now = now
        self.timeout = timeout
    }

    /// Tests: until the wait for Google has ended.
    func waitForFinishing() async {
        await finishTask?.value
    }

    /// A run or a wait for Google is going on: no new preview, and quitting asks first.
    public var isBusy: Bool { isRunning || finishing?.isLive == true }

    /// What quitting now would cut short, for the quit alert; nil when nothing would.
    public var interruptible: String? {
        if isRunning, let email = run?.plan.email { return "Onboarding \(email.isEmpty ? "the new hire" : email) is still running." }
        if let finishing, finishing.isLive {
            return "Onboarding \(finishing.email) is still waiting for Google to finish the new account."
        }
        return nil
    }

    /// The sign-in card while it's held.
    public var card: Card? {
        guard let heldCard, now() - heldCard.shownAt <= Self.cardLifetime else { return nil }
        return heldCard
    }

    /// The connected admin: the assignee the form starts with (§9 Q7: warehouse staff may not use Tasks;
    /// blank still means the hire, so the argv is GamGUI's for the same input).
    public var defaultAssignee: String { setup.connectedAdmin ?? "" }

    // MARK: previewing a hire

    /// Holds `hire` in `role` as one preview, after every check that doesn't write. `signatureTemplate` is
    /// the body saved under the role's signature name, or nil when there's none of that name.
    public func preview(hire: Hire, role: RoleTemplate, signatureTemplate: String?) async {
        guard !isBusy else { return }
        // The tenant the screen's reads (the directory's warnings) belong to, before any await.
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        problem = nil
        if let refusal = Self.refusal(hire: hire, role: role) {
            discardPending()
            problem = refusal
            return
        }
        // A new account's card would replace one not yet handed over: its password exists nowhere else.
        if hire.createAccount, let card {
            discardPending()
            problem = "Print or copy the sign-in details for \(card.email), then click Done, before creating another account."
            return
        }
        let password = hire.createAccount ? makePassword() : nil
        let planned = Self.plan(hire: hire, role: role, signatureTemplate: signatureTemplate, password: password, timeout: timeout)
        let plan = planned.plan.adding(warnings: directoryWarnings(planned.plan))
        await hold(planned.steps, plan: plan, password: password, isRetry: false, expecting: tenant)
    }

    /// GamGUI's checks, in its words (`routes/onboarding.py:267-330`), all before the preview is held; and
    /// GAM's 60-character name limit, which GAM would refuse as a usage error.
    public nonisolated static func refusal(hire: Hire, role: RoleTemplate) -> String? {
        let email = PythonText.strip(hire.email)
        if !email.isEmpty, !Address.looksLikeEmail(email) {
            return "That does not look like a valid email address for the new hire."
        }
        if role.steps.isEmpty { return "That role has no steps yet \u{2014} add some in Role templates." }
        if hire.createAccount {
            if email.isEmpty { return "Enter the new hire's email to create the account." }
            let names = Onboarding.splitName(name: hire.name, first: hire.first, last: hire.last)
            if names.first.isEmpty || names.last.isEmpty {
                return "Enter the new hire's first and last name to create the account."
            }
            if names.first.unicodeScalars.count > nameLimit || names.last.unicodeScalars.count > nameLimit {
                return "Google takes a first or last name of at most \(nameLimit) characters."
            }
        }
        let assignee = PythonText.strip(hire.assignee).isEmpty ? email : PythonText.strip(hire.assignee)
        if assignee.isEmpty { return "Enter the assignee (who does the setup) or the new hire's email." }
        if !Address.looksLikeEmail(assignee) { return "The assignee does not look like a valid email address." }
        return nil
    }

    /// GAM's `getString(maxLen=60)` for a user's first and last name.
    public nonisolated static let nameLimit = 60

    /// GamGUI's `provision_hire` as steps, in its order and with its gates (design D2): the account (when
    /// creating), its signature (only for an account this run creates), each group and calendar (when
    /// there's an address), then the checklist and its tasks on the assignee. After a create, every step
    /// requires it, and those GamGUI parks wait for Google. Pure: the caller previews the steps.
    public nonisolated static func plan(hire: Hire, role: RoleTemplate, signatureTemplate: String?, password: TemporaryPassword?,
                                        timeout: Duration = GamRunner.defaultTimeout) -> (plan: Plan, steps: [WriteStep]) {
        let email = PythonText.strip(hire.email), name = PythonText.strip(hire.name)
        let names = Onboarding.splitName(name: hire.name, first: hire.first, last: hire.last)
        let assignee = PythonText.strip(hire.assignee).isEmpty ? email : PythonText.strip(hire.assignee)
        let title = Onboarding.checklistTitle(name: hire.name, email: hire.email, role: role.name)
        let creates = hire.createAccount && password != nil
        let fullName = PythonText.strip(names.first + " " + names.last)
        let shownName = !name.isEmpty ? name : !fullName.isEmpty ? fullName : email
        var steps: [WriteStep] = [], rows: [Row] = [], warnings: [String] = []
        func add(_ step: WriteStep, _ kind: Row.Kind, _ label: String) {
            rows.append(Row(index: steps.count, kind: kind, label: label, shownArgv: step.shownArgv))
            steps.append(step)
        }
        let afterCreate = creates ? [0] : []
        if creates, let password {
            add(WriteStep(password.createUser(email: email, firstName: names.first, lastName: names.last, orgUnit: role.orgUnit),
                          target: email, summary: "Create the Google account \(email)", secrets: [password.secret], timeout: timeout),
                .account, "Create the Google account \(email)")
        }
        var signature: Plan.Signature?
        if creates, !role.signature.isEmpty {
            if let html = Onboarding.signatureHTML(template: signatureTemplate, email: email, first: names.first, last: names.last) {
                if Signature.readAsKeyword(html) != nil {
                    warnings.append("The \u{201C}\(role.signature)\u{201D} signature renders as a word GAM reads as a file to load, "
                        + "so it isn't set. Change the template on Signatures.")
                } else {
                    signature = Plan.Signature(template: role.signature, body: html)
                    add(WriteStep(GamCommands.setSignature(email: email, signature: html, html: true), target: email,
                                  summary: "Set \(email)'s Gmail signature to \u{201C}\(role.signature)\u{201D}",
                                  requires: afterCreate, about: ["signature": role.signature], newAccountFrom: 0),
                        .signature(template: role.signature), "Signature \u{201C}\(role.signature)\u{201D}")
                }
            } else {
                warnings.append("The role's signature \u{201C}\(role.signature)\u{201D} isn't saved on Signatures, so no signature "
                    + "is set.")
            }
        }
        if !email.isEmpty {
            for group in role.groups {
                add(WriteStep(GamCommands.addGroupMember(group: group, member: email), target: email,
                              summary: "Add \(email) to \(group)", requires: afterCreate, about: ["group": group]),
                    .group(group), "Add to \(group)")
            }
            for calendar in role.calendars {
                add(WriteStep(GamCommands.subscribeCalendar(email: email, calendarID: calendar), target: email,
                              summary: "Subscribe \(email) to \(calendar)", requires: afterCreate, about: ["calendar": calendar],
                              newAccountFrom: creates ? 0 : nil),
                    .calendar(calendar), "Subscribe to \(calendar)")
            }
        }
        // GamGUI's `fresh and assignee.lower() == email.lower()`: the hire's own list waits too.
        let listWaits = creates && PythonText.lower(assignee) == PythonText.lower(email)
        let list = steps.count
        add(WriteStep(GamCommands.createTaskList(assignee: assignee, title: title), target: assignee,
                      summary: "Create the checklist \u{201C}\(title)\u{201D} in \(assignee)'s Google Tasks", requires: afterCreate,
                      about: ["title": title], newAccountFrom: listWaits ? 0 : nil),
            .taskList(title: title), "Checklist \u{201C}\(title)\u{201D} for \(assignee)")
        for task in role.steps {
            add(WriteStep.task(assignee: assignee, title: task, onListFrom: list, target: assignee, summary: "Task: \(task)",
                               requires: afterCreate, newAccountFrom: listWaits ? 0 : nil),
                .task(task), "Task: \(task)")
        }
        let plan = Plan(hire: hire, role: role, email: email, name: shownName, first: names.first, last: names.last,
                        assignee: assignee, title: title, creates: creates, orgUnit: Onboarding.shownOrgUnit(role.orgUnit),
                        signature: signature, rows: rows, warnings: warnings, existingListID: nil)
        return (plan, steps)
    }

    /// What the cached directory says about the addresses: a create for an address already taken, or a run
    /// for one the directory hasn't got.
    private func directoryWarnings(_ plan: Plan) -> [String] {
        guard let users = directory.users else {
            return ["The directory isn't loaded, so the addresses weren't checked against it."]
        }
        func find(_ address: String) -> (user: GamUser, isAlias: Bool)? {
            let key = Guard.normalized(address)
            if let user = users.first(where: { Guard.normalized($0.primaryEmail) == key }) { return (user, false) }
            return users.first { $0.aliases.contains { Guard.normalized($0) == key } }.map { ($0, true) }
        }
        var warnings: [String] = []
        if !plan.email.isEmpty, let found = find(plan.email) {
            if plan.creates {
                warnings.append(found.isAlias
                    ? "\(plan.email) is an alias of \(found.user.primaryEmail): Google will refuse to create it."
                    : "\(plan.email) is already in the directory: Google will refuse to create it.")
            }
        } else if !plan.email.isEmpty, !plan.creates {
            warnings.append("\(plan.email) isn't in the directory, so its steps will fail. (An account created in the last "
                + "few minutes shows after Users \u{2192} Refresh.)")
        }
        if Guard.normalized(plan.assignee) != Guard.normalized(plan.email), find(plan.assignee) == nil {
            warnings.append("\(plan.assignee) isn't in the directory: Google Tasks needs a user there.")
        }
        return warnings
    }

    private func hold(_ steps: [WriteStep], plan: Plan, password: TemporaryPassword?, isRetry: Bool,
                      expecting: (domain: Domain, generation: Int)?) async {
        discardPending()
        guard let executor else {
            problem = "This build has no GAM. Build the app again after running scripts/fetch_gam.sh."
            return
        }
        switch await executor.preview(steps, confirmStep: true, expecting: expecting) {
        case .success(let preview):
            let count = steps.count
            pending = Pending(preview: preview, plan: plan, isRetry: isRetry,
                              summary: isRetry ? "Retry \(count) step\(count == 1 ? "" : "s") for \(plan.email.isEmpty ? plan.assignee : plan.email)"
                                               : "One new hire: \(count) step\(count == 1 ? "" : "s")",
                              confirmLabel: isRetry ? "Retry \(count) Step\(count == 1 ? "" : "s")"
                                                    : plan.creates ? "Create Account and Onboard" : "Create the Task List",
                              password: password)
        case .failure(let refusal):
            problem = refusal.message
        }
    }

    /// Cancel, or a new preview: the held one is dropped at once, its password with it (design D3g).
    public func cancelPreview() {
        discardPending()
    }

    private func discardPending() {
        guard let pending else { return }
        self.pending = nil
        let id = pending.id
        Task { [executor] in await executor?.discard(id) }
    }

    // MARK: confirming

    /// Runs `pending` once, exactly as held, while it's the preview the sheet shows. Each step's result shows
    /// as it ends; the card appears the moment the create does.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, let shown = self.pending, shown.id == pending.id else { return }
        self.pending = nil
        problem = nil
        isRunning = true
        defer { isRunning = false }
        // What the panel showed before: back on screen if this confirm is refused (a retry's run, say).
        let previous = run
        run = Run(plan: pending.plan, isRetry: pending.isRetry, results: Array(repeating: nil, count: pending.plan.rows.count),
                  auditProblem: nil, notDone: [:])
        // The password leaves the pending here and lives only until the create ends: then on the card, or nowhere.
        creatingPassword = pending.password
        let (events, observer) = AsyncStream<(Int, RunOutcome.Step)>.makeStream()
        let watcher = Task { @MainActor [weak self] in
            for await (index, result) in events { self?.record(result, at: index) }
        }
        let outcome = await executor.run(pending.preview, confirmation: confirmation, progress: observer)
        observer.finish()
        await watcher.value
        creatingPassword = nil
        if let refusal = outcome.refusal {
            run = previous
            problem = refusal
            return
        }
        guard var run else { return }
        for (index, result) in outcome.steps.enumerated() { run.results[index] = result }
        run.auditProblem = outcome.auditProblem
        run.ended = true
        self.run = run
        updateCardSignature()
        if pending.plan.creates, outcome.steps.first?.isSucceeded == true {
            accountsCreated += 1
            // A read: the directory shows the account (Google can lag; Users → Refresh shows it later).
            Task { [directory] in await directory.load() }
        }
        if let retry = outcome.retry { startFinishing(retry) }
    }

    /// One step's result as it ends. The create's: the card, or no card (a failed create never shows its
    /// password; one that may have run shows it, marked unsure).
    private func record(_ result: RunOutcome.Step, at index: Int) {
        guard var run, index < run.results.count else { return }
        run.results[index] = result
        self.run = run
        if case .account = run.plan.rows[index].kind, let made = creatingPassword {
            creatingPassword = nil
            if result.isSucceeded || result.mayHaveChanged {
                showCard(Card(name: run.plan.name, email: run.plan.email, orgUnit: run.plan.orgUnit, password: made,
                              unsure: !result.isSucceeded,
                              signature: run.plan.signature.map { .pending($0.template) } ?? .none, shownAt: now()))
            }
        }
        updateCardSignature()
    }

    private func showCard(_ card: Card) {
        heldCard = card
        cardTimer?.cancel()
        let id = card.id
        cardTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.cardLifetime)
            guard !Task.isCancelled else { return }
            self?.dropCard(ifExpired: id)
        }
    }

    /// Drops the card once its fifteen minutes are up (the timer's call; a test's after moving the clock).
    func dropCard(ifExpired id: UUID) {
        guard let heldCard, heldCard.id == id, now() - heldCard.shownAt > Self.cardLifetime else { return }
        self.heldCard = nil
    }

    /// Done on the card: the password is dropped now.
    public func doneWithCard() {
        heldCard = nil
        cardTimer?.cancel()
        cardTimer = nil
    }

    /// The card says how the signature went, from the run's own rows.
    private func updateCardSignature() {
        guard var card = heldCard, let run, !run.isRetry, let index = run.plan.rows.firstIndex(where: {
            if case .signature = $0.kind { true } else { false }
        }), case .signature(let template) = run.plan.rows[index].kind else { return }
        let status: Card.SignatureStatus = switch run.results[index] {
        case nil: .pending(template)
        case .succeeded?: .applied(template)
        case .waiting?: run.notDone[index] == nil ? .waiting(template) : .notApplied(template)
        default: .notApplied(template)
        }
        guard card.signature != status else { return }
        card.signature = status
        heldCard = card
    }

    // MARK: waiting for Google

    private func startFinishing(_ handle: PendingRetry) {
        guard let run else { return }
        let waiting = run.results.count { $0?.isWaiting == true }
        finishing = Finishing(email: run.plan.email, phase: .waiting, round: 0, rounds: waits.count, nextTryAt: nil, waiting: waiting)
        finishTask = Task { [weak self] in await self?.finish(handle) }
    }

    /// GamGUI's `finish_new_accounts`: before each round, sleep the next wait (Stop cancels the sleep at once),
    /// then retry what still waits, as the confirmed run continued.
    private func finish(_ first: PendingRetry) async {
        guard let executor else { return }
        var handle = first
        for wait in waits {
            finishing?.phase = .waiting
            finishing?.nextTryAt = now() + wait
            do {
                try await Task.sleep(for: wait)
            } catch {
                await executor.abandon(handle)
                giveUp(Onboarding.stoppedReason, phase: .stopped)
                return
            }
            finishing?.phase = .trying
            finishing?.nextTryAt = nil
            let (events, observer) = AsyncStream<(Int, RunOutcome.Step)>.makeStream()
            let watcher = Task { @MainActor [weak self] in
                for await (index, result) in events { self?.retried(result, at: index) }
            }
            let outcome = await executor.retry(handle, progress: observer)
            observer.finish()
            await watcher.value
            finishing?.round += 1
            if let refusal = outcome.refusal {
                giveUp(refusal, phase: .gaveUp)
                return
            }
            if var run {
                for (index, result) in outcome.steps.enumerated() { run.results[index] = result }
                if let problem = outcome.auditProblem { run.auditProblem = problem }
                self.run = run
            }
            updateCardSignature()
            finishing?.waiting = run?.results.count { $0?.isWaiting == true } ?? 0
            if Task.isCancelled {
                if let next = outcome.retry { await executor.abandon(next) }
                giveUp(Onboarding.stoppedReason, phase: .stopped)
                return
            }
            guard let next = outcome.retry else { break }
            handle = next
        }
        // GamGUI's last word: what still waits isn't done. A round the executor still holds is dropped now.
        if run?.results.contains(where: { $0?.isWaiting == true }) == true {
            await executor.abandon(handle)
            giveUp(Onboarding.notReadyReason, phase: .gaveUp)
        } else {
            finishing?.phase = .done
        }
    }

    private func retried(_ result: RunOutcome.Step, at index: Int) {
        guard var run, index < run.results.count else { return }
        run.results[index] = result
        self.run = run
        updateCardSignature()
    }

    /// Every step still waiting is not done: GamGUI's reason, with GAM's last error when it had one.
    private func giveUp(_ reason: String, phase: Finishing.Phase) {
        guard var run else { return }
        for (index, result) in run.results.enumerated() {
            guard case .waiting(let message)? = result else { continue }
            let detail = message.hasPrefix("Waits for step") ? nil : message
            run.notDone[index] = Run.NotDone(reason: reason, detail: detail)
        }
        self.run = run
        finishing?.phase = phase
        finishing?.nextTryAt = nil
        updateCardSignature()
    }

    /// Stop: the wait ends at once, and what still waits is said not done.
    public func stopFinishing() {
        finishTask?.cancel()
    }

    // MARK: after the run

    /// The steps a retry would preview again: failed, given up, or skipped because of one of those; never
    /// the create (a new account needs a new password, from the form).
    public var failedSteps: [Row] {
        guard let run, run.ended, !(finishing?.isLive ?? false) else { return [] }
        if run.plan.creates, let first = run.results.first, first?.isSucceeded != true { return [] }
        return run.plan.rows.filter { row in
            guard let result = run.results[row.index] else { return false }
            if case .account = row.kind { return false }
            return !result.isSucceeded
        }
    }

    /// Design D8: exactly the steps that failed or were given up, previewed again from the plan this model
    /// held (the same signature, groups and calendars; tasks on the list that exists, or the list and every
    /// task if it doesn't). No create and no waiting: the account is there now. It needs a Confirm click.
    public func previewRetry() async {
        guard !isBusy, let run else { return }
        let failed = Set(failedSteps.map(\.index))
        guard !failed.isEmpty else { return }
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        let planned = Self.retryPlan(run.plan, results: run.results, failed: failed)
        await hold(planned.steps, plan: planned.plan, password: nil, isRetry: true, expecting: tenant)
    }

    /// The retry's steps (pure). The rows keep the plan's order; a task goes on the list made again, or on
    /// the list that exists by the id it printed.
    public nonisolated static func retryPlan(_ plan: Plan, results: [RunOutcome.Step?], failed: Set<Int>)
        -> (plan: Plan, steps: [WriteStep]) {
        var steps: [WriteStep] = [], rows: [Row] = []
        func add(_ step: WriteStep, _ row: Row) {
            rows.append(Row(index: steps.count, kind: row.kind, label: row.label, shownArgv: step.shownArgv))
            steps.append(step)
        }
        let listIndex = plan.rows.firstIndex { if case .taskList = $0.kind { true } else { false } }
        let knownID: String? = listIndex.flatMap { index -> String? in
            guard case .succeeded(let output)? = results[index] else { return nil }
            return Executor.taskListID(printed: output)
        } ?? plan.existingListID
        let taskFailed = plan.rows.contains { if case .task = $0.kind { failed.contains($0.index) } else { false } }
        // The list again, with every task, when it failed or gave no id its tasks could use.
        let listAgain = listIndex.map { failed.contains($0) } == true || (taskFailed && knownID == nil)
        var newList: Int?
        for row in plan.rows {
            switch row.kind {
            case .account:
                continue
            case .signature(let template):
                guard failed.contains(row.index), let signature = plan.signature else { continue }
                add(WriteStep(GamCommands.setSignature(email: plan.email, signature: signature.body, html: true), target: plan.email,
                              summary: "Set \(plan.email)'s Gmail signature to \u{201C}\(template)\u{201D}",
                              about: ["signature": template]), row)
            case .group(let group):
                guard failed.contains(row.index) else { continue }
                add(WriteStep(GamCommands.addGroupMember(group: group, member: plan.email), target: plan.email,
                              summary: "Add \(plan.email) to \(group)", about: ["group": group]), row)
            case .calendar(let calendar):
                guard failed.contains(row.index) else { continue }
                add(WriteStep(GamCommands.subscribeCalendar(email: plan.email, calendarID: calendar), target: plan.email,
                              summary: "Subscribe \(plan.email) to \(calendar)", about: ["calendar": calendar]), row)
            case .taskList(let title):
                guard listAgain else { continue }
                newList = steps.count
                add(WriteStep(GamCommands.createTaskList(assignee: plan.assignee, title: title), target: plan.assignee,
                              summary: "Create the checklist \u{201C}\(title)\u{201D} in \(plan.assignee)'s Google Tasks",
                              about: ["title": title]), row)
            case .task(let title):
                if let newList {
                    add(WriteStep.task(assignee: plan.assignee, title: title, onListFrom: newList, target: plan.assignee,
                                       summary: "Task: \(title)"), row)
                } else if failed.contains(row.index), let knownID {
                    add(WriteStep(GamCommands.createTask(assignee: plan.assignee, taskListID: knownID, title: title),
                                  target: plan.assignee, summary: "Task: \(title)"), row)
                }
            }
        }
        let retry = Plan(hire: plan.hire, role: plan.role, email: plan.email, name: plan.name, first: plan.first, last: plan.last,
                         assignee: plan.assignee, title: plan.title, creates: false, orgUnit: plan.orgUnit, signature: plan.signature,
                         rows: rows, warnings: [], existingListID: newList == nil ? knownID : nil)
        return (retry, steps)
    }

    #if DEBUG
    /// Debug builds' screenshots only: a finished run's panel for `hire`, as if the account were made and its
    /// signature and calendars were waiting for Google: the card with a seeded, made-up password, and the
    /// wait going on. Nothing is held and no `gam` runs.
    public func showDemoResult(hire: Hire, role: RoleTemplate, signatureTemplate: String?) {
        var seeded = DemoGenerator()
        let password = TemporaryPassword.generate(using: &seeded)
        let plan = Self.plan(hire: hire, role: role, signatureTemplate: signatureTemplate, password: password).plan
        let notReady = "GAM failed (unknown, exit=50): User: \(plan.email), User Set Failed: access_denied: Requested client not authorized"
        let results: [RunOutcome.Step?] = plan.rows.map { row in
            switch row.kind {
            case .signature, .calendar: .waiting(message: notReady)
            case .taskList: .succeeded(output: "MockTasklist_1")
            default: .succeeded(output: "")
            }
        }
        run = Run(plan: plan, isRetry: false, results: results, auditProblem: nil, notDone: [:], ended: true)
        heldCard = Card(name: plan.name, email: plan.email, orgUnit: plan.orgUnit, password: password, unsure: false,
                        signature: plan.signature.map { .waiting($0.template) } ?? .none, shownAt: now())
        finishing = Finishing(email: plan.email, phase: .waiting, round: 1, rounds: waits.count, nextTryAt: now() + .seconds(40),
                              waiting: results.count { $0?.isWaiting == true })
    }

    private struct DemoGenerator: RandomNumberGenerator {
        var state: UInt64 = 0x5EED
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }
    #endif

    /// Back to the form for another hire, once nothing is running or waiting.
    public func startAnother() {
        guard !isBusy else { return }
        discardPending()
        problem = nil
        run = nil
        finishing = nil
    }
}

extension OnboardChanges.Plan {
    func adding(warnings more: [String]) -> Self {
        Self(hire: hire, role: role, email: email, name: name, first: first, last: last, assignee: assignee, title: title,
             creates: creates, orgUnit: orgUnit, signature: signature, rows: rows, warnings: warnings + more,
             existingListID: existingListID)
    }
}

extension OnboardChanges.Run {
    /// The create's failure, said as onboarding says it (design D7): GAM's duplicate and org-unit refusals
    /// in words, a recognised kind's remediation (no license left), otherwise GAM's own line; with GAM's line
    /// as the detail. Nil unless this run's create failed.
    public var accountProblem: (summary: String, detail: String)? {
        guard plan.creates, case .failed(let message, let kind)? = results.first else { return nil }
        let summary = Onboarding.createRefusal(message, email: plan.email, orgUnit: plan.role.orgUnit)
            ?? (kind.map { $0 == .unknown ? message : $0.remediation } ?? message)
        return ("Couldn't create the account: \(summary)", message)
    }

    /// GamGUI's tallies (`_onboard_run.html`): "Added to 2 of 2 groups", "Subscribed to 1 of 1 shared
    /// calendar", "Created 6 of 6 tasks in it@example.com's Google Tasks — “…”".
    public var tallies: [String] {
        func count(_ match: (OnboardChanges.Row.Kind) -> Bool) -> (done: Int, total: Int) {
            let rows = plan.rows.filter { match($0.kind) }
            return (rows.count { results[$0.index]?.isSucceeded == true }, rows.count)
        }
        var lines: [String] = []
        let groups = count { if case .group = $0 { true } else { false } }
        if groups.total > 0 {
            lines.append("Added \(plan.email) to \(groups.done) of \(groups.total) group\(groups.total == 1 ? "" : "s").")
        }
        let calendars = count { if case .calendar = $0 { true } else { false } }
        if calendars.total > 0 {
            lines.append("Subscribed to \(calendars.done) of \(calendars.total) shared calendar\(calendars.total == 1 ? "" : "s").")
        }
        let tasks = count { if case .task = $0 { true } else { false } }
        if tasks.total > 0 {
            lines.append("Created \(tasks.done) of \(tasks.total) task\(tasks.total == 1 ? "" : "s") in \(plan.assignee)'s Google Tasks "
                + "\u{2014} \u{201C}\(plan.title)\u{201D}.")
        }
        return lines
    }
}
