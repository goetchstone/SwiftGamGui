import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Stores
import Vault

/// The audit runs (plan F3, GamGUI #171's `web/routes/audit_runs.py`): each run a fixed list of reads (`AuditRuns`), started by
/// the operator, one step after another, with Stop between steps. Nothing here writes: each step is one `print` read without
/// `todrive` (`AuditRuns.isAuditRead`, checked before GAM runs), and each leaves one read record (`ReadAudit`, origin
/// `audit_run`, the command `<run>/<step>`, the domain and the rows, never the output; a named report run here, plan F7a, is
/// origin `named_report` and its command the report's key).
///
/// - **Stop** is checked before each step: the step in flight finishes and is recorded, the rest are not run, and every table
///   that needs them says unknown.
/// - **A failed step is unknown** (GAM's remediation, its own line beside it) and the run goes on: the tables that don't need it
///   still stand. Output without the step's table, or a table with no row where there must be one, is unknown too.
/// - **Kept for the tenant** it was read on: each step's table, in memory, until a switch (which stops a run going: GAM is
///   stopped and the step in flight is recorded as interrupted) or the app quits. One of each run at a time: a second Run
///   while it goes is ignored.
/// - **Bounded** (invariant 9): while a run goes only its steps are shown, at most one line each; a finished table shows its
///   first `AuditRuns.rowsShown` rows, and its CSV is the whole of it.
/// - **A scheduled run** (plan F7a, `RunSchedules`): once it ended on the domain it read, its tables are compared with its last
///   kept run's and it is kept on this Mac (`AuditScheduleStore.afterRun`, off the main actor); a run that ends after a switch
///   isn't kept. A schedule never starts a run: only `start`, from a screen, does.
@MainActor
@Observable
public final class AuditRunner {
    /// One step's line while a run goes and once it ended: what it read, and why it has no answer.
    public struct Line: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let ok: Bool
        public let why: String
    }

    /// A run going now.
    public struct Progress: Sendable, Equatable {
        public let run: AuditRuns.Run
        /// Steps ended so far, in order.
        public internal(set) var lines: [Line] = []
        /// The step in flight.
        public internal(set) var current: String = ""
        /// Stop was asked: the step in flight finishes, none after it begins.
        public internal(set) var stopping = false

        public var total: Int { run.steps.count }
        public var done: Int { lines.count }
    }

    public enum State: Sendable {
        case running(Progress)
        case finished(AuditRuns.Outcome)
    }

    /// Fixed words, never an error's own text: GamGUI's.
    public nonisolated static let noTable = "GAM ended without writing the table, so this step has no answer."
    public nonisolated static let noRowUnsaid = "GAM wrote no row and didn't say there were none, which it does when there are. A "
        + "service-account token Google refuses ends this way, so this step has no answer: check the domain's access on Setup."
    public nonisolated static let timedOut = "GAM didn't finish in the hour a read is allowed, so this step has no answer."
    public nonisolated static let stoppedBefore = "The run was stopped before this step."
    public nonisolated static let interrupted = "Stopped before GAM finished, so nothing was read."
    public nonisolated static let needsEarlier = "It reads for the people an earlier step found, and that step has no answer, so "
        + "nothing was read."
    public nonisolated static let unnamedWarning = "GAM said it couldn't read an account but not which, so none of this step stands."

    /// GamGUI's words for a step whose rows stand without the accounts GAM named.
    public nonisolated static func someUnread(_ accounts: [String]) -> String {
        "GAM couldn't read \(accounts.joined(separator: ", ")), and read the rest: what it couldn't read is unknown, not none."
    }

    private struct Kept {
        var state: State
        let domain: Domain
        let generation: Int
        let serial: Int
    }

    private var kept: [String: Kept] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var serial = 0
    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    private let audit: ReadAudit?
    private let now: @Sendable () -> Date
    /// Tests only: the mock's state folder.
    var environment: [String: String] = [:]
    /// Who has an offboarding started in this app (lowercased): the shared drives' "being offboarded" organizers, asked once the
    /// run's reads are done (GamGUI's `offboard_jobs`).
    @ObservationIgnored public var leaving: @MainActor () -> Set<String> = { [] }
    /// The schedules (plan F7a): a scheduled run's tables are compared with its last kept run's and kept here. None: nothing is
    /// kept or compared.
    @ObservationIgnored public var schedules: AuditScheduleStore?
    /// The time zone a comparison's words say a kept run's time in.
    @ObservationIgnored public var clock = AuditSchedules.Clock()
    /// Told once a run of the connected tenant ended and its keep is done: its schedule and kept runs are read again.
    @ObservationIgnored public var ended: @MainActor (AuditRuns.Run) async -> Void = { _ in }
    /// Tests only: called as each step's line is added (its index), before the next step is decided: where a test presses Stop
    /// at a known point, with no timer.
    @ObservationIgnored var afterEachStep: (@MainActor (Int) -> Void)?

    public init(setup: SetupModel, runner: AuthenticatedRunner?, audit: ReadAudit?, now: @escaping @Sendable () -> Date = Date.init) {
        self.setup = setup
        self.runner = runner
        self.audit = audit
        self.now = now
        setup.onTenantChange { [weak self] in self?.tenantChanged() }
    }

    /// The run's state, while it belongs to the connected tenant.
    public func state(of run: AuditRuns.Run) -> State? {
        guard let kept = kept[run.key], kept.domain == setup.active, kept.generation == setup.generation else { return nil }
        return kept.state
    }

    public func isRunning(_ run: AuditRuns.Run) -> Bool {
        if case .running? = state(of: run) { return true }
        return false
    }

    /// Why a run can't start now, in words, or nil when it can. Inactive users takes one of `AuditRuns.windows`.
    public func refusal(_ run: AuditRuns.Run, days: Int) -> String? {
        if run == AuditRuns.inactiveUsers, !AuditRuns.windows.contains(days) { return "Pick one of the windows the run offers." }
        if setup.active == nil { return "Connect a domain on Setup first." }
        if runner == nil || audit == nil { return "This build has no GAM. Build the app again after running scripts/fetch_gam.sh." }
        return nil
    }

    /// Starts `run` on the connected tenant, its window `days` for Inactive users (ignored by the others). A run of the same
    /// kind still going is left to go on (a second press joins it). Returns why it didn't start, or nil.
    @discardableResult
    public func start(_ run: AuditRuns.Run, days: Int = DirectoryReport.inactiveDays) -> String? {
        if let refusal = refusal(run, days: days) { return refusal }
        guard !isRunning(run), let domain = setup.active, let runner, let audit else { return nil }
        let generation = setup.generation
        serial += 1
        let mine = serial
        kept[run.key] = Kept(state: .running(Progress(run: run)), domain: domain, generation: generation, serial: mine)
        let environment = environment
        tasks[run.key] = Task {
            await perform(run, days: run == AuditRuns.inactiveUsers ? days : 0, domain: domain, generation: generation,
                          serial: mine, runner: runner, audit: audit, environment: environment)
        }
        return nil
    }

    /// Asks a going run to stop before its next step. False when it isn't going.
    @discardableResult
    public func stop(_ run: AuditRuns.Run) -> Bool {
        guard var current = kept[run.key], case .running(var progress) = current.state, isRunning(run) else { return false }
        progress.stopping = true
        current.state = .running(progress)
        kept[run.key] = current
        return true
    }

    /// What the run's pane said of its keep no longer holds once its schedule or kept runs change: dropped.
    public func keepChanged(_ run: AuditRuns.Run) {
        guard var current = kept[run.key], case .finished(var outcome) = current.state else { return }
        outcome.keptNote = ""
        outcome.keptProblem = false
        current.state = .finished(outcome)
        kept[run.key] = current
    }

    /// Waits for the run's task (tests, and a caller that wants the result).
    public func finish(_ run: AuditRuns.Run) async {
        await tasks[run.key]?.value
    }

    /// A switch stops the old tenant's runs: GAM is stopped and the step in flight recorded as interrupted.
    private func tenantChanged() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
    }

    private func progress(_ run: AuditRuns.Run, serial: Int) -> Progress? {
        guard let kept = kept[run.key], kept.serial == serial, case .running(let progress) = kept.state else { return nil }
        return progress
    }

    private func update(_ run: AuditRuns.Run, serial: Int, _ change: (inout Progress) -> Void) {
        guard var current = kept[run.key], current.serial == serial, case .running(var progress) = current.state else { return }
        change(&progress)
        current.state = .running(progress)
        kept[run.key] = current
    }

    private func perform(_ run: AuditRuns.Run, days: Int, domain: Domain, generation: Int, serial: Int, runner: AuthenticatedRunner,
                         audit: ReadAudit, environment: [String: String]) async {
        var reads: [AuditRuns.StepRead] = [], tables = AuditRuns.Tables()
        for (index, step) in run.steps.enumerated() {
            guard !Task.isCancelled, let progress = progress(run, serial: serial) else { return }
            if progress.stopping {
                reads += run.steps[index...].map { AuditRuns.StepRead(step: $0, state: .notRun, why: Self.stoppedBefore) }
                break
            }
            update(run, serial: serial) { $0.current = step.title }
            let read: AuditRuns.StepRead
            // A read for what an earlier step found (the admins' apps), when that step has no table: nothing to run.
            if let gam = AuditRuns.read(step, tables: tables) {
                switch await Self.read(gam, step: step, command: run.command(step), origin: run.named.isEmpty ? .auditRun : .namedReport,
                                       as: domain, runner: runner, audit: audit,
                                       environment: environment) {
                case .read(let records, let users, let unread):
                    let empty = AuditRuns.implausiblyEmpty(step, rows: records.count)
                    read = AuditRuns.StepRead(step: step, state: !empty.isEmpty ? .unknown : unread.isEmpty ? .read : .partial,
                                              why: !empty.isEmpty ? empty : unread.isEmpty ? "" : Self.someUnread(unread),
                                              rows: records.count, unread: unread)
                    if empty.isEmpty {
                        if step == AuditRuns.directory { tables.users = users } else { tables.rows[step.key] = records }
                    }
                case .unknown(let why, let detail):
                    read = AuditRuns.StepRead(step: step, state: .unknown, why: why, detail: detail)
                }
            } else {
                read = AuditRuns.StepRead(step: step, state: .unknown, why: Self.needsEarlier)
            }
            reads.append(read)
            update(run, serial: serial) {
                $0.lines.append(Line(id: step.key, title: step.title, ok: read.state == .read || read.state == .partial, why: read.why))
                $0.current = ""
            }
            afterEachStep?(index)
        }
        guard !Task.isCancelled, setup.active == domain, setup.generation == generation, progress(run, serial: serial) != nil else { return }
        let at = now(), leaving = leaving()
        let findings = await Task.detached { [reads, tables] in
            AuditRuns.findings(for: run, reads: reads, tables: tables, now: at, days: days, leaving: leaving)
        }.value
        guard setup.active == domain, setup.generation == generation, progress(run, serial: serial) != nil else { return }
        var outcome = AuditRuns.Outcome(run: run, reads: reads, findings: findings, tables: tables, when: at, days: days)
        if let schedules {
            // A scheduled run: compared with its last kept run, then kept, on the domain it read. Off the main actor: a domain's
            // tables can be tens of thousands of rows.
            let scheduled = outcome.scheduledTables, answered = outcome.answered, clock = clock
            let after = await Task.detached {
                schedules.afterRun(domain, run: run.key, tables: scheduled, days: days, answered: answered,
                                   when: at.timeIntervalSince1970, clock: clock)
            }.value
            (outcome.changes, outcome.keptNote, outcome.keptProblem) = (after.changes, after.note, after.problem)
            guard setup.active == domain, setup.generation == generation, progress(run, serial: serial) != nil else { return }
        }
        kept[run.key] = Kept(state: .finished(outcome), domain: domain, generation: generation, serial: serial)
        tasks[run.key] = nil
        await ended(run)
    }

    /// What one step's read gave.
    enum Found: Sendable {
        /// Its records, the directory's as users, and the accounts GAM named as unread (its rows stand without them).
        case read([GamOutput.Record], users: [GamUser]?, unread: [String])
        /// Why it has no answer, and GAM's own line.
        case unknown(why: String, detail: String)
    }

    /// One step's read as `domain`, recorded once it ended (GamGUI's `audit_read`), parsed off the main actor. Only a `print`
    /// read without `todrive` runs here. A read the log couldn't record isn't used: it says so instead.
    nonisolated static func read(_ read: GamRead, step: AuditRuns.Step, command: String, origin: ReadAudit.Origin, as domain: Domain,
                                 runner: AuthenticatedRunner,
                                 audit: ReadAudit, environment: [String: String]) async -> Found {
        guard AuditRuns.isAuditRead(read.argv) else {
            return .unknown(why: "An audit run reads with a print command, and never exports.", detail: "")
        }
        let (found, outcome): (Found, ReadAudit.Outcome)
        do {
            let result = try await runner.run(read, as: domain, timeout: GamRunner.domainWideTimeout, extraEnvironment: environment)
            (found, outcome) = await Task.detached { Self.found(result, step: step, argv: read.argv) }.value
        } catch is CancellationError {
            (found, outcome) = (.unknown(why: interrupted, detail: ""), .interrupted)
        } catch GamRunnerError.timedOut {
            let error = GamError(exitCode: nil, stderr: "", argv: read.argv)
            (found, outcome) = (.unknown(why: timedOut, detail: error.message), .failed(error.message))
        } catch {
            let why = SetupModel.message(for: error)
            (found, outcome) = (.unknown(why: why, detail: ""), .failed(why))
        }
        do {
            try audit.record(command: command, target: "", argv: read.argv, domain: domain, origin: origin, outcome: outcome)
        } catch {
            return .unknown(why: "The read ended, but the audit log couldn't record it (\(error.localizedDescription)), so it isn't "
                            + "used. Check the disk has room, then run it again.", detail: "")
        }
        return found
    }

    /// A finished read as the step's answer, and as its record says it (`AuditRuns.answer`): an exit that is neither the step's
    /// answer nor a partial one is GAM's failure, output cut at the runner's cap is never whole, output without the step's
    /// table isn't its answer, and a warning exit that names nobody is unknown whole.
    nonisolated static func found(_ result: GamResult, step: AuditRuns.Step, argv: [String]) -> (Found, ReadAudit.Outcome) {
        guard !result.stdoutTruncated else {
            let why = "GAM printed more than \(GamRunner.outputCap / 1_048_576) MiB, so this wasn't all read."
            return (.unknown(why: why, detail: ""), .failed(why))
        }
        switch AuditRuns.answer(result, step: step, argv: argv) {
        case .failure(.gam(let error)):
            return (.unknown(why: error.remediation, detail: error.message), .failed(error.message))
        case .failure(.incomplete(let incomplete)):
            let why = incomplete.reason.hasPrefix("GAM ended without writing") ? noTable
                : incomplete.reason.hasPrefix(AuditRuns.noRowUnsaid) ? noRowUnsaid : unnamedWarning
            return (.unknown(why: why, detail: ""), .failed(incomplete.reason))
        case .success(let (records, unread)):
            let users = step == AuditRuns.directory ? records.map(GamUser.init(record:)) : nil
            return (.read(records, users: users, unread: unread), .read(rows: records.count, partial: !unread.isEmpty))
        }
    }
}
