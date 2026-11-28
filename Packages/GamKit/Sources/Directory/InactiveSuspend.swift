import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// Inactive users' Suspend these… (GamGUI's `/reports/inactive/preview` and `/apply`, roadmap 3.3, which its audit run's
/// Suspend these… posts its window to; plan F3): one previewed write for the bucket, through ChangeCore like every write here.
///
/// - **Read again at preview**: the run's table came from a read that may be minutes old, so the preview loads the directory
///   again (`DirectoryStore.load`, the cache's own read: the Users list updates too) and holds the people that read found for
///   the window, exactly: Confirm suspends that list once, never one rebuilt since (the executor runs only what it holds).
/// - **The connected admin is left out** by address and by Google's account ID (suspending it would sign this app out, and the
///   executor refuses it anyway); without a confirmed admin nothing is offered.
/// - **New accounts are flagged** (made inside the window, or when isn't known): a new hire who hasn't signed in yet looks
///   inactive.
/// - **The guard's rules for a destructive bulk change** apply (`Executor`, `Guard`): a confirm always; ten or more, the word
///   `confirm` typed; more than 25, the count typed too. It runs in the jobs tray, one account at a time, with Stop.
/// - Each suspend that succeeded is patched into the cached directory; one that didn't leaves the directory to be read again.
/// - **What it shows belongs to one tenant and one run**: a preview or an outcome is kept with the domain and generation it was
///   made on and the run (its read time) it was asked from, so a switch, or a newer run of the table, never shows another's
///   (review of F3, 2026-11-21; GamGUI failure-log 2026-09-25's class).
@MainActor
@Observable
public final class InactiveSuspend {
    public enum State: Sendable {
        case idle
        /// Reading the directory again.
        case checking(String)
        /// The preview the sheet shows; confirming runs exactly this.
        case previewing(Pending)
        case running(Pending)
        case done(String)
        case problem(String)
    }

    /// A held preview with what the confirm sheet says about it.
    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        /// The window the people were found for.
        public let days: Int
        /// Everyone it suspends, in address order, as held.
        public let targets: [AuditRuns.Target]
        /// Who the read found and isn't suspended: the connected admin.
        public let leftOut: [String]

        public var id: UUID { preview.id }
        public var count: Int { targets.count }
        /// How many were made inside the window, or when isn't known.
        public var new: Int { targets.count(where: \.new) }
        /// The word `confirm` must be typed (the guard's, for ten or more).
        public var needsWord: Bool { preview.decision.requiresTypedConfirmation }
        /// The count must be typed too (more than 25).
        public var needsCount: Bool { preview.decision.requiresTypedCount }
    }

    /// People a preview lists by name (GamGUI's `_SUSPEND_SHOWN`); the count is the whole of it.
    public nonisolated static let shown = 200
    /// Failures a result names; the rest are counted (invariant 9).
    nonisolated static let failuresSaid = 5
    public nonisolated static let adminUnconfirmed = "This app can't confirm which account it signs in as, so it can't leave that "
        + "account out of a suspend. Import the credentials again on Setup, then preview again."

    /// The state as it was set, with the tenant it belongs to and the run it was asked from.
    private var raw: (state: State, domain: Domain?, generation: Int, about: Date?) = (.idle, nil, 0, nil)
    /// The run (its read time) the last preview was asked from.
    private var about: Date?

    /// What the screen shows, while it belongs to the connected tenant: another tenant's preview or outcome never shows. Set, it
    /// belongs to the connected tenant and the run the last preview was asked from.
    public private(set) var state: State {
        get {
            guard raw.domain == setup.active, raw.generation == setup.generation else { return .idle }
            return raw.state
        }
        set { raw = (newValue, setup.active, setup.generation, about) }
    }

    /// The state, when it was asked from the run read at `when`: a newer run's table never shows an older run's outcome.
    public func state(about when: Date) -> State {
        raw.about == when ? state : .idle
    }
    /// A typed word or count on the sheet that isn't the guard's: said there, and the preview isn't spent (the executor spends a
    /// preview it refuses). Cleared once the typing changes or the preview goes.
    public private(set) var typedProblem: String?
    /// Counts each typed refusal, so the sheet says it again on a repeated wrong attempt.
    public private(set) var typedRefusals = 0
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    private let now: @Sendable () -> Date

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.now = now
        setup.onTenantChange { [weak self] in self?.tenantChanged() }
    }

    /// A switch drops what was shown for the old tenant (a run going on goes on, in the jobs tray, and keeps its own tenant).
    private func tenantChanged() {
        guard !isBusy else { return }
        raw = (.idle, nil, 0, nil)
        typedProblem = nil
    }

    /// Reading or running, on whichever tenant: one at a time.
    public var isBusy: Bool {
        switch raw.state {
        case .checking, .running: true
        default: false
        }
    }

    /// Reads the directory again and holds, for `days`, the people a suspend would act on. Refused, with why, for a window the
    /// run doesn't offer, without a confirmed connected admin, or when the read fails: nothing is offered then. `about` is the
    /// run (its read time) it's asked from, so only that run's table shows what comes of it.
    public func preview(days: Int, about run: Date? = nil) async {
        guard !isBusy else { return }
        typedProblem = nil
        about = run
        guard AuditRuns.windows.contains(days) else {
            state = .problem("Pick one of the windows the run offers, then preview again.")
            return
        }
        guard let executor else {
            state = .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
            return
        }
        // The tenant the preview is bound to, before the read.
        guard let domain = setup.active else {
            state = .problem("Connect a domain on Setup first.")
            return
        }
        let generation = setup.generation
        guard let admin = setup.connectedAdmin, !PythonText.strip(admin).isEmpty else {
            state = .problem(Self.adminUnconfirmed)
            return
        }
        let before = directory.revision
        state = .checking("Reading the directory again…")
        await directory.load()
        guard setup.active == domain, setup.generation == generation else {
            state = .problem("The connected domain changed while the directory was read, so nothing is offered. Preview again.")
            return
        }
        // A load that succeeded clears the problem and makes a new list (a new revision).
        guard directory.problem == nil, let users = directory.users, directory.revision != before else {
            state = .problem("Couldn't read the directory again, so nothing is offered. "
                             + (directory.problem?.summary ?? "Try again."))
            return
        }
        let (targets, leftOut) = AuditRuns.inactiveToSuspend(users, admin: admin, adminID: setup.connectedAdminID, days: days, now: now())
        guard !targets.isEmpty else {
            state = .done("Read again just now: no active account has gone \(days) days without signing in"
                          + (leftOut.isEmpty ? "" : ", apart from the one this app is connected as") + ". Nothing to suspend.")
            return
        }
        let steps = targets.map { target in
            WriteStep(GamCommands.setSuspended(email: target.email, suspended: true), target: target.email,
                      summary: "Suspend \(target.email)", risk: .destructive)
        }
        let n = targets.count
        switch await executor.preview(steps, confirmStep: true, typedCountAbove: Guard.countConfirmAbove,
                                      expecting: (domain, generation), title: "Suspend \(n) inactive account\(n == 1 ? "" : "s")") {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, days: days, targets: targets, leftOut: leftOut))
        case .failure(let refusal):
            state = .problem(refusal.message)
        }
    }

    /// Runs `pending` once, exactly as held, while it's the preview the sheet shows. A word or count typed that isn't the guard's
    /// is said here first, so nothing runs and the preview isn't spent. Each suspend that succeeded is patched into the cached
    /// directory, on the tenant it ran on only; one that failed has the directory read again (its outcome may not be known).
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        let decision = pending.preview.decision
        if pending.needsWord, !Guard.normalized(confirmation.typedWord).utf8.elementsEqual(Guard.typedWord.utf8) {
            typedProblem = "Type confirm to suspend \(pending.count == 1 ? "it" : "them")."
            typedRefusals += 1
            return
        }
        if !decision.typedCountMatches(confirmation.typedCount) {
            typedProblem = "Type \(pending.count), the number of accounts, to confirm."
            typedRefusals += 1
            return
        }
        typedProblem = nil
        state = .running(pending)
        // Its outcome belongs to the tenant it ran on, whatever is connected by the time it ends.
        let (domain, generation, asked) = (pending.preview.domain, pending.preview.generation, raw.about)
        func ended(_ state: State) { raw = (state, domain, generation, asked) }
        let outcome = await executor.run(pending.preview, confirmation: confirmation)
        if let refusal = outcome.refusal {
            ended(.problem(refusal))
            return
        }
        var suspended: [String] = [], failed: [(email: String, why: String)] = []
        for (target, step) in zip(pending.targets, outcome.steps) {
            switch step {
            case .succeeded:
                suspended.append(target.email)
            case .failed(let message, let kind):
                failed.append((target.email, kind?.remediation ?? message))
            case .skipped(let reason), .waiting(let reason):
                failed.append((target.email, reason))
            }
        }
        // Once for the whole run, not once a person (GamGUI #196).
        directory.patchMany(suspended, on: pending.preview.domain, generation: pending.preview.generation) { $0.with(suspended: true) }
        let unrun = pending.count - outcome.steps.count
        if !failed.isEmpty, setup.active == pending.preview.domain, setup.generation == pending.preview.generation {
            let directory = directory
            Task { await directory.load() }
        }
        let note = outcome.auditProblem.map { " \($0)" } ?? ""
        let total = pending.count
        var words = "Suspended \(suspended.count) of \(total) account\(total == 1 ? "" : "s")."
        if !failed.isEmpty || unrun > 0 {
            let said = failed.prefix(Self.failuresSaid).map { "\($0.email): \($0.why)" }
            let more = failed.count - said.count
            words += " Not suspended: " + said.joined(separator: "; ")
                + (more > 0 ? "; and \(more) more" : "") + (unrun > 0 ? "\(said.isEmpty ? "" : "; ")\(unrun) not run" : "") + "."
        }
        words += " Each can be unsuspended from their page on Users." + note
        ended(failed.isEmpty && unrun == 0 ? .done(words) : .problem(words))
    }

    /// The typed word or count changed: an earlier mismatch no longer stands.
    public func typingChanged() {
        typedProblem = nil
    }

    /// Back to the run's table; a held preview simply expires unused.
    public func dismiss() {
        guard !isBusy else { return }
        typedProblem = nil
        state = .idle
    }
}
