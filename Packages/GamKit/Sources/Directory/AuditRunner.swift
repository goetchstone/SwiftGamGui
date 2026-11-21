import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The audit runs (plan F3, GamGUI #171's `web/routes/audit_runs.py`): each run a fixed list of reads (`AuditRuns`), started by
/// the operator, one step after another, with Stop between steps. Nothing here writes: each step is one `print` read without
/// `todrive` (`AuditRuns.isAuditRead`, checked before GAM runs), and each leaves one read record (`ReadAudit`, origin
/// `audit_run`, the command `<run>/<step>`, the domain and the rows, never the output).
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
    public nonisolated static let timedOut = "GAM didn't finish in the hour a read is allowed, so this step has no answer."
    public nonisolated static let stoppedBefore = "The run was stopped before this step."
    public nonisolated static let interrupted = "Stopped before GAM finished, so nothing was read."

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
            let found = await Self.read(step, command: run.command(step), as: domain, runner: runner, audit: audit,
                                        environment: environment)
            let read: AuditRuns.StepRead
            switch found {
            case .read(let records, let users):
                let empty = AuditRuns.implausiblyEmpty(step, rows: records.count)
                read = AuditRuns.StepRead(step: step, state: empty.isEmpty ? .read : .unknown, why: empty, rows: records.count)
                if empty.isEmpty {
                    if step == AuditRuns.directory { tables.users = users } else { tables.rows[step.key] = records }
                }
            case .unknown(let why, let detail):
                read = AuditRuns.StepRead(step: step, state: .unknown, why: why, detail: detail)
            }
            reads.append(read)
            update(run, serial: serial) {
                $0.lines.append(Line(id: step.key, title: step.title, ok: read.state == .read, why: read.why))
                $0.current = ""
            }
            afterEachStep?(index)
        }
        guard !Task.isCancelled, setup.active == domain, setup.generation == generation, progress(run, serial: serial) != nil else { return }
        let at = now()
        let findings = await Task.detached { [reads, tables] in
            AuditRuns.findings(for: run, reads: reads, tables: tables, now: at, days: days)
        }.value
        guard setup.active == domain, setup.generation == generation, progress(run, serial: serial) != nil else { return }
        kept[run.key] = Kept(state: .finished(AuditRuns.Outcome(run: run, reads: reads, findings: findings, tables: tables, when: at,
                                                                days: days)),
                             domain: domain, generation: generation, serial: serial)
        tasks[run.key] = nil
    }

    /// What one step's read gave.
    enum Found: Sendable {
        /// Its records, and the directory's as users.
        case read([GamOutput.Record], users: [GamUser]?)
        /// Why it has no answer, and GAM's own line.
        case unknown(why: String, detail: String)
    }

    /// One step's read as `domain`, recorded once it ended (GamGUI's `audit_read`), parsed off the main actor. Only a `print`
    /// read without `todrive` runs here. A read the log couldn't record isn't used: it says so instead.
    nonisolated static func read(_ step: AuditRuns.Step, command: String, as domain: Domain, runner: AuthenticatedRunner,
                                 audit: ReadAudit, environment: [String: String]) async -> Found {
        let read = AuditRuns.read(step)
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
            try audit.record(command: command, target: "", argv: read.argv, domain: domain, origin: .auditRun, outcome: outcome)
        } catch {
            return .unknown(why: "The read ended, but the audit log couldn't record it (\(error.localizedDescription)), so it isn't "
                            + "used. Check the disk has room, then run it again.", detail: "")
        }
        return found
    }

    /// A finished read as the step's answer, and as its record says it: any exit but 0 is GAM's failure, output cut at the
    /// runner's cap is never whole, and output without the step's table isn't its answer.
    nonisolated static func found(_ result: GamResult, step: AuditRuns.Step, argv: [String]) -> (Found, ReadAudit.Outcome) {
        guard result.exitCode == 0 else {
            let error = GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
            return (.unknown(why: error.remediation, detail: error.message), .failed(error.message))
        }
        guard !result.stdoutTruncated else {
            let why = "GAM printed more than \(GamRunner.outputCap / 1_048_576) MiB, so this wasn't all read."
            return (.unknown(why: why, detail: ""), .failed(why))
        }
        switch AuditRuns.table(result.stdout, keyColumn: step.keyColumn) {
        case .failure(let incomplete):
            return (.unknown(why: noTable, detail: ""), .failed(incomplete.reason))
        case .success(let records):
            let users = step == AuditRuns.directory ? records.map(GamUser.init(record:)) : nil
            return (.read(records, users: users), .read(rows: records.count))
        }
    }
}
