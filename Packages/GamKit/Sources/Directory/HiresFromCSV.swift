import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Stores
import Vault

/// Hires from a CSV (GamGUI's `/onboarding/bulk`, roadmap 2.3): each row is one hire in a role, planned exactly as the Onboard
/// form plans one (`OnboardChanges.plan`), and every hire's steps are held as one preview, run once through ChangeCore.
///
/// - **Read** (`HireCSV.parse`): GamGUI's rules and words; a row refused is listed and left out, never half-read.
/// - **Resolved** (GamGUI's `resolve_hires`): a row whose role is unknown or has no steps, or sends a welcome email that no
///   longer exists, is listed and left out. Everything that doesn't write is checked before the first write
///   (`OnboardChanges.refusal`), so no row's password is stranded by a check that could have failed earlier.
/// - **Held as one preview**: each hire's steps follow the last's (`WriteStep.shifted`), so a failed create skips only that
///   hire's other steps (`requires`). A confirm always. An account-wide failure stops the run (GamGUI's `stop_reason`); Stop
///   ends it after the write in flight.
/// - **Passwords**: a created account's sign-in goes to its row's `notify` address (GAM emails it) or onto the sign-in sheet,
///   in memory only, held fifteen minutes or until Done (GamGUI's `_CREDS_TTL`).
/// - **Waiting for Google**: what a just-created account wasn't ready for is retried after GamGUI's waits, as the single flow
///   does (`Onboarding.newAccountWaits`); what still waits after the last is said not done.
@MainActor
@Observable
public final class HiresFromCSV {
    /// Everything the roles screen holds that a row needs, read once at preview.
    public struct Roles {
        public let role: (String) -> RoleTemplate?
        /// The body saved under a signature template's name.
        public let signature: (String) -> String?
        public let welcome: (String) -> WelcomeEmail?

        public init(role: @escaping (String) -> RoleTemplate?, signature: @escaping (String) -> String?,
                    welcome: @escaping (String) -> WelcomeEmail?) {
            self.role = role
            self.signature = signature
            self.welcome = welcome
        }
    }

    public enum State: Sendable {
        case idle
        /// The file couldn't be read, or nothing in it can run: why, and each row refused.
        case problem(String, errors: [String])
        case previewing(Pending)
        case running(Pending)
        case done(Done)
    }

    /// One hire as held: its plan and where its steps sit in the preview.
    public struct Held: Sendable, Identifiable {
        public let plan: OnboardChanges.Plan
        /// Its steps' indices in the preview.
        public let steps: Range<Int>
        public var id: Int { steps.lowerBound }
    }

    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        public let hires: [Held]
        /// Rows left out, in GamGUI's words.
        public let errors: [String]
        public var id: UUID { preview.id }

        /// GamGUI's `tally_hires`.
        public var creates: Int { hires.count { $0.plan.creates } }
        public var notifies: Int { hires.count { $0.plan.creates && !PythonText.strip($0.plan.hire.notify).isEmpty } }
        public var sheets: Int { creates - notifies }
        /// Hires per role, in code-point order.
        public var perRole: [(role: String, count: Int)] {
            Dictionary(grouping: hires, by: \.plan.role.name).map { ($0.key, $0.value.count) }
                .sorted { $0.role.unicodeScalars.lexicographicallyPrecedes($1.role.unicodeScalars) }
        }
    }

    /// A run as it goes, counted per hire as each hire's last step ends.
    public struct Progress: Sendable, Equatable {
        public var total: Int
        public var stepsDone = 0
        public var steps: Int
        public var stopping = false
        /// Waiting for Google before trying again; nil while running.
        public var waitingUntil: ContinuousClock.Instant?

        public init(total: Int, steps: Int) {
            self.total = total
            self.steps = steps
        }
    }

    public struct Done: Sendable {
        public let message: String
        /// Each hire, with how it went in words.
        public let hires: [(name: String, outcome: String, ok: Bool)]
    }

    /// A created account's sign-in details, for the sheet (design D4). The password is read only by the sheet's view.
    public struct Credential: Sendable, Identifiable {
        public let id = UUID()
        public let name: String
        public let email: String
        public let orgUnit: String
        public let password: TemporaryPassword
        /// The create didn't finish: the account may or may not exist.
        public let unsure: Bool
    }

    public private(set) var state: State = .idle
    public private(set) var progress: Progress?
    private var heldCredentials: (cards: [Credential], shownAt: ContinuousClock.Instant)?
    /// Drops the cards once their fifteen minutes are up, as the one-hire card's timer does.
    private var cardTimer: Task<Void, Never>?
    /// Each create's password, by the step that creates it: the sheet's once the create ends, or dropped.
    private var passwords: [Int: TemporaryPassword] = [:]
    private var serial = 0

    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    private let waits: [Duration]
    private let makePassword: @Sendable () -> TemporaryPassword
    private let now: @Sendable () -> ContinuousClock.Instant
    /// The wait for Google going now: Stop cancels it at once.
    private var sleeper: Task<Void, any Error>?

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, waits: [Duration] = Onboarding.newAccountWaits,
                makePassword: @escaping @Sendable () -> TemporaryPassword = { TemporaryPassword.generate() },
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.waits = Array(waits.prefix(Executor.newAccountRounds))
        self.makePassword = makePassword
        self.now = now
        setup.onTenantChange { [weak self] in
            guard let self, !self.isBusy else { return }
            self.dismiss()
        }
    }

    public var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    /// The sign-in sheet while it's held.
    public var credentials: [Credential] {
        guard let heldCredentials, now() - heldCredentials.shownAt <= OnboardChanges.cardLifetime else { return [] }
        return heldCredentials.cards
    }

    /// The operator printed or saved the sheet: the passwords go now.
    public func doneWithCredentials() {
        heldCredentials = nil
        cardTimer?.cancel()
        cardTimer = nil
    }

    /// Drops the cards once their fifteen minutes are up (the timer's call; a test's after moving the clock).
    func dropCredentialsIfExpired() {
        guard let held = heldCredentials, now() - held.shownAt > OnboardChanges.cardLifetime else { return }
        heldCredentials = nil
    }

    /// One account's details were handed over: its password goes now.
    public func doneWith(_ id: Credential.ID) {
        guard var held = heldCredentials else { return }
        held.cards.removeAll { $0.id == id }
        heldCredentials = held.cards.isEmpty ? nil : held
        if heldCredentials == nil { cardTimer?.cancel() }
    }

    // MARK: previewing

    /// Reads `bytes`, resolves each row against `roles`, and holds every hire it can run as one preview.
    public func preview(_ bytes: [UInt8], roles: Roles) async {
        guard !isBusy else { return }
        serial += 1
        let serial = serial
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        guard let executor else {
            state = .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.", errors: [])
            return
        }
        if !credentials.isEmpty {
            state = .problem("Print or save the sign-in details from the last run, then click Done, before creating more accounts.",
                             errors: [])
            return
        }
        let (rows, parseErrors) = HireCSV.parse(bytes)
        if rows.isEmpty, parseErrors.isEmpty {
            state = .problem("No hires found in the CSV.", errors: [])
            return
        }
        var errors = parseErrors, hires: [Held] = [], steps: [WriteStep] = [], held: [Int: TemporaryPassword] = [:]
        var roleOf: [String: RoleTemplate?] = [:]
        for row in rows {
            let who = !row.hire.email.isEmpty ? row.hire.email : !row.hire.name.isEmpty ? row.hire.name : "a row"
            if roleOf[row.role] == nil { roleOf[row.role] = .some(roles.role(row.role)) }
            guard let role = roleOf[row.role] ?? nil, !role.steps.isEmpty else {
                errors.append("\(who): unknown role '\(row.role)' (or it has no steps).")
                continue
            }
            let welcome = roles.welcome(role.welcome)
            if row.hire.sendWelcome, welcome == nil {
                errors.append("\(who): role '\(row.role)' sends the welcome email '\(role.welcomeName)', which no longer exists.")
                continue
            }
            if let refusal = OnboardChanges.refusal(hire: row.hire, role: role) {
                errors.append("Row \(row.line): \(refusal)")
                continue
            }
            let password = row.hire.createAccount ? makePassword() : nil
            let planned = OnboardChanges.plan(hire: row.hire, role: role,
                                              signatureTemplate: role.signature.isEmpty ? nil : roles.signature(role.signature),
                                              welcome: welcome.map { (name: role.welcomeName, email: $0) }, password: password)
            let offset = steps.count
            if let password, planned.plan.creates { held[offset] = password }
            hires.append(Held(plan: planned.plan, steps: offset..<(offset + planned.steps.count)))
            steps += planned.steps.map { $0.shifted(by: offset) }
        }
        guard !hires.isEmpty else {
            state = .problem("Nothing to run \u{2014} every row had an unknown role or was invalid.", errors: errors)
            return
        }
        let n = hires.count
        let result = await executor.preview(steps, confirmStep: true, expecting: tenant,
                                            title: "Bulk onboarding \u{2014} \(n) hire\(n == 1 ? "" : "s")")
        guard serial == self.serial else {
            if case .success(let preview) = result { await executor.discard(preview.id) }
            return
        }
        switch result {
        case .success(let preview):
            passwords = held
            state = .previewing(Pending(preview: preview, hires: hires, errors: errors))
        case .failure(let refusal):
            state = .problem(refusal.message, errors: errors)
        }
    }

    // MARK: running

    /// Runs `pending` once, exactly as held, while it's the preview shown; then retries what Google wasn't ready for.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        state = .running(pending)
        let stepCount = pending.preview.steps.count
        progress = Progress(total: pending.hires.count, steps: stepCount)
        var results = [RunOutcome.Step?](repeating: nil, count: stepCount)
        let (events, observer) = AsyncStream<(Int, RunOutcome.Step)>.makeStream()
        let watcher = Task { @MainActor [weak self] in
            for await (index, result) in events where index < stepCount {
                results[index] = result
                self?.progress?.stepsDone += 1
            }
            return results
        }
        var outcome = await executor.run(pending.preview, confirmation: confirmation, progress: observer)
        observer.finish()
        results = await watcher.value
        if let refusal = outcome.refusal {
            progress = nil
            passwords = [:]
            state = .problem(refusal, errors: [])
            return
        }
        for (index, step) in outcome.steps.enumerated() { results[index] = step }
        keepCredentials(pending, results)
        // GamGUI's FinishJob: not after a stop of any kind (Stop, or a failure every later step would share).
        var stopped = outcome.steps.count < stepCount || outcome.steps.contains { if case .skipped(let why) = $0 { Self.isStop(why) } else { false } }
        var handle = stopped ? nil : outcome.retry
        if stopped, let retry = outcome.retry { await executor.abandon(retry) }
        // Why what still waits isn't done: Google not ready (the waits ran out), Stop, or a retry refused.
        var waitEnded = Onboarding.notReadyReason
        for wait in waits where handle != nil && !stopped {
            progress?.waitingUntil = now() + wait
            let sleep = Task { try await Task.sleep(for: wait) }
            sleeper = sleep
            do { try await sleep.value } catch {
                stopped = true
                waitEnded = Onboarding.stoppedReason
                break
            }
            sleeper = nil
            progress?.waitingUntil = nil
            outcome = await executor.retry(handle!, progress: nil)
            if let refusal = outcome.refusal {
                handle = nil
                waitEnded = refusal
                break
            }
            for (index, step) in outcome.steps.enumerated() where index < stepCount { results[index] = step }
            handle = outcome.retry
            if progress?.stopping == true {
                stopped = true
                waitEnded = Onboarding.stoppedReason
            }
        }
        if let handle { await executor.abandon(handle) }
        sleeper = nil
        progress = nil
        state = .done(Self.done(pending, results, waitEnded: waits.isEmpty ? nil : waitEnded))
        accountsChanged(pending, results)
    }

    /// Stop after the write in flight, or end a wait for Google at once.
    public func stop() async {
        guard case .running(let pending) = state, let executor else { return }
        progress?.stopping = true
        sleeper?.cancel()
        _ = await executor.stopAfterCurrentStep(pending.id)
    }

    /// Each create that ended (or may have) puts its password on the sheet, unless GAM emailed it.
    private func keepCredentials(_ pending: Pending, _ results: [RunOutcome.Step?]) {
        var cards: [Credential] = []
        for hire in pending.hires where hire.plan.creates {
            guard let password = passwords[hire.steps.lowerBound], let result = results[hire.steps.lowerBound] else { continue }
            let unsure = !result.isSucceeded && result.mayHaveChanged
            // GAM emailed a create that ended; one that may have landed may not have sent its email, so it has a card too.
            let emailed = !PythonText.strip(hire.plan.hire.notify).isEmpty
            guard emailed ? unsure : (result.isSucceeded || unsure) else { continue }
            cards.append(Credential(name: hire.plan.name, email: hire.plan.email, orgUnit: hire.plan.orgUnit, password: password,
                                    unsure: unsure))
        }
        passwords = [:]
        heldCredentials = cards.isEmpty ? nil : (cards, now())
        cardTimer?.cancel()
        guard !cards.isEmpty else { return }
        cardTimer = Task { [weak self] in
            try? await Task.sleep(for: OnboardChanges.cardLifetime)
            guard !Task.isCancelled else { return }
            self?.dropCredentialsIfExpired()
        }
    }

    /// A step skipped because the run stopped: Stop (`Executor.stopped`), or a failure every later step would share
    /// ("Stopped: …", GamGUI's `stop_reason`).
    nonisolated static func isStop(_ why: String) -> Bool {
        why == Executor.stopped || why.hasPrefix("Stopped")
    }

    private func accountsChanged(_ pending: Pending, _ results: [RunOutcome.Step?]) {
        guard pending.hires.contains(where: { $0.plan.creates && results[$0.steps.lowerBound]?.isSucceeded == true }),
              setup.isConnected(to: pending.preview) else { return }
        let directory = directory
        Task { await directory.load() }
    }

    /// GamGUI's `_onboard_bulk_status.html`: hires done, each hire's outcome, the accounts created.
    /// `waitEnded` is why what still waits for Google isn't done (nil when there was no wait).
    nonisolated static func done(_ pending: Pending, _ results: [RunOutcome.Step?], waitEnded: String?) -> Done {
        var ok = 0, created = 0, notified = 0, notRun = 0, stoppedBy: String?
        var rows: [(String, String, Bool)] = []
        for hire in pending.hires {
            let mine = hire.steps.map { results[$0] }
            let who = hire.plan.email.isEmpty ? hire.plan.name : hire.plan.email
            let unrun = mine.allSatisfy { result in
                guard let result else { return true }
                if case .skipped(let why) = result, isStop(why) {
                    if stoppedBy == nil { stoppedBy = why }
                    return true
                }
                return false
            }
            if unrun {
                notRun += 1
                rows.append((who, "Not attempted.", false))
                continue
            }
            if hire.plan.creates, mine.first??.isSucceeded == true {
                created += 1
                if !PythonText.strip(hire.plan.hire.notify).isEmpty { notified += 1 }
            }
            var failed: [String] = []
            for (row, result) in zip(hire.plan.rows, mine) {
                switch result {
                case .succeeded?: continue
                case .failed(let message, let kind)?: failed.append("\(row.label): \(kind?.remediation ?? message)")
                case .waiting?: failed.append("\(row.label): \(waitEnded ?? "waiting for Google")")
                case .skipped(let why)?: failed.append("\(row.label): \(why)")
                case nil: failed.append("\(row.label): not run")
                }
            }
            if failed.isEmpty { ok += 1 }
            rows.append((who, failed.isEmpty ? "Done." : failed.joined(separator: "; "), failed.isEmpty))
        }
        let total = pending.hires.count
        var message = "Onboarded \(ok) of \(total) hire\(total == 1 ? "" : "s")"
        if created > 0 {
            message += "; \(created) account\(created == 1 ? "" : "s") created"
                + (notified > 0 ? " (\(notified) emailed by GAM)" : "")
        }
        message += "."
        if notRun > 0 {
            let why = stoppedBy == nil || stoppedBy == Executor.stopped ? "Stopped by you" : stoppedBy!
            message = "\(why) \u{2014} \(notRun) not attempted. " + message
        }
        return Done(message: message, hires: rows)
    }

    /// Back to choosing a file; a held preview simply expires unused, its passwords with it.
    public func dismiss() {
        guard !isBusy else { return }
        serial += 1
        if case .previewing(let pending) = state {
            let id = pending.id
            Task { [executor] in await executor?.discard(id) }
        }
        passwords = [:]
        state = .idle
    }
}
