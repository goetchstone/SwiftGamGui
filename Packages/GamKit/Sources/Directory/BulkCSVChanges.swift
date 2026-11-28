import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Stores
import Vault

/// Change many people from a CSV (roadmap 4.6, GamGUI's `/users/csv`): the file read (`BulkCSV.parse`), the directory and,
/// when a row names one, the org units read fresh, each row planned (`BulkCSV.plan`), and every change held as one preview
/// through ChangeCore like every write here.
///
/// - **Each person's writes** are their profile (`updateProfile`, the whole organizations and phones lists) then their move,
///   the move needing the profile. The first carries `KeepFirst.unchanged`: the person is read again right before it, and
///   nothing changes for them if their organizations, phones or org unit moved since the preview.
/// - **The guard** counts each write (Swift's guard counts steps, GamGUI's each person): past 25 the number of changes is
///   typed, never fewer than GamGUI asks for. Confirm always; Stop after the write in flight; a failure every later person
///   would share stops it.
/// - **The undo**: the preview's "before" (`BulkCSV.beforeCSV`) saved as a CSV of the same columns.
@MainActor
@Observable
public final class BulkCSVChanges {
    public enum State: Sendable {
        case idle
        /// Reading the directory and the org units.
        case checking
        case previewing(Pending)
        case running(Pending)
        case done(Done)
        case problem(String)
    }

    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        public let changes: [BulkCSV.Change]
        /// Each row refused, in GamGUI's words.
        public let refused: [String]
        public let notes: [String]
        public let unchanged: Int
        /// The undo file's bytes.
        public let before: [UInt8]
        /// Changed values the undo can't put back.
        public let blanks: Int
        /// Each step's person, in the held order.
        let owners: [Int]

        public var id: UUID { preview.id }
        public var writes: Int { preview.steps.count }
        public var needsCount: Bool { preview.decision.requiresTypedCount }
    }

    /// A file read and planned that holds nothing to run: what it said.
    public struct Nothing: Sendable, Equatable {
        public let refused: [String]
        public let notes: [String]
        public let unchanged: Int
    }

    public struct Done: Sendable {
        public let message: String
        public let failures: [String]
        public let failedCount: Int
        public let partial: Bool
    }

    public struct Progress: Sendable, Equatable {
        public var total: Int
        public var done = 0
        public var failed = 0
        public var stopping = false
        public init(total: Int) { self.total = total }
    }

    public nonisolated static let failuresKept = 200

    public private(set) var state: State = .idle
    public private(set) var progress: Progress?
    public private(set) var typedProblem: String?
    /// What the last file said when it held nothing to run (every row refused, or nothing changes).
    public private(set) var nothing: Nothing?
    var environment: [String: String] = [:]
    private var serial = 0
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    private let access: UserAccess
    private let runner: AuthenticatedRunner?

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, access: UserAccess, runner: AuthenticatedRunner?) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.access = access
        self.runner = runner
        setup.onTenantChange { [weak self] in self?.dismiss() }
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .running: true
        default: false
        }
    }

    /// The template a sheet starts from: the columns this reads.
    public nonisolated static var template: [UInt8] { Array((BulkCSV.header.joined(separator: ",") + "\n").utf8) }

    /// `bytes` (a picked file) read, planned and held. Writes nothing.
    public func preview(_ bytes: [UInt8]) async {
        guard !isBusy else { return }
        serial += 1
        let serial = serial
        typedProblem = nil
        nothing = nil
        guard bytes.count <= BulkCSV.maxBytes else {
            state = .problem("That file is over 1 MB. Split it into several, or check you picked the right file.")
            return
        }
        let body: [UInt8]
        switch BulkCSV.decode(bytes) {
        case .success(let decoded): body = decoded
        case .failure(let refusal):
            state = .problem(refusal.message)
            return
        }
        guard let tenant = setup.active.map({ (domain: $0, generation: setup.generation) }), let runner else {
            state = .problem("Connect a domain on Setup first.")
            return
        }
        let parsed = await Task.detached { BulkCSV.parse(body) }.value
        guard serial == self.serial else { return }
        var refused = parsed.errors, changes: [BulkCSV.Change] = [], unchanged = 0
        if !parsed.rows.isEmpty {
            state = .checking
            let unread = "Couldn't read the directory or the org units, so nothing is offered. "
            // The directory as it is now, never the cached list: a cached record's fields are patched, its lists aren't.
            let read = GamCommands.printUsers(fields: GamCommands.cacheFields)
            let users: [GamUser]
            do {
                let result = try await runner.run(read, as: tenant.domain, timeout: GamRunner.domainWideTimeout,
                                                  extraEnvironment: environment)
                users = try DirectoryStore.users(from: result, argv: read.argv)
            } catch {
                guard serial == self.serial else { return }
                state = .problem(unread + DirectoryStore.problem(for: error, argv: read.argv).summary)
                return
            }
            var units: [String] = []
            if parsed.rows.contains(where: { $0.values["org_unit"] != nil }) {
                switch await access.orgUnits(in: tenant.domain) {
                case .success(let paths): units = paths
                case .failure(let problem):
                    guard serial == self.serial else { return }
                    state = .problem(unread + problem.summary)
                    return
                }
            }
            guard serial == self.serial else { return }
            let planned = BulkCSV.plan(parsed.rows, directory: users, units: units)
            (changes, unchanged) = (planned.changes, planned.unchanged)
            refused += planned.errors
        }
        guard !changes.isEmpty else {
            nothing = Nothing(refused: refused, notes: parsed.notes, unchanged: unchanged)
            state = .idle
            return
        }
        await hold(changes, refused: refused, notes: parsed.notes, unchanged: unchanged, expecting: tenant, serial: serial)
    }

    /// Each change's steps: its profile (the check before it), then its move (needing the profile, or carrying the check).
    nonisolated static func steps(_ changes: [BulkCSV.Change]) throws -> (steps: [WriteStep], owners: [Int]) {
        var steps: [WriteStep] = [], owners: [Int] = []
        for (index, change) in changes.enumerated() {
            let check = WriteStep.KeepFirst.unchanged(email: change.email, held: change.was)
            var first: Int?
            if change.organizations != nil || change.phones != nil {
                let write = try GamCommands.updateProfile(email: change.email, organizations: change.organizations, phones: change.phones)
                let said = BulkCSV.columns.filter { $0 != "org_unit" && change.after[$0] != nil }
                    .map { "\(PythonText.lower(BulkCSV.labels[$0]!)) to “\(change.after[$0]!)”" }
                first = steps.count
                steps.append(WriteStep(write, target: change.email, summary: "Set \(change.email)'s \(said.joined(separator: ", "))",
                                       about: ["lists": [change.organizations != nil ? "organizations" : nil,
                                                         change.phones != nil ? "phones" : nil].compactMap { $0 }.joined(separator: ",")],
                                       keepFirst: check))
                owners.append(index)
            }
            if !change.orgUnit.isEmpty {
                steps.append(WriteStep(GamCommands.moveUserToOrgUnit(orgUnit: change.orgUnit, email: change.email), target: change.email,
                                       summary: "Move \(change.email) from \(change.before["org_unit"] ?? "?") to \(change.orgUnit)",
                                       requires: first.map { [$0] } ?? [], about: ["org_unit": change.orgUnit],
                                       keepFirst: first == nil ? check : nil))
                owners.append(index)
            }
        }
        return (steps, owners)
    }

    private func hold(_ changes: [BulkCSV.Change], refused: [String], notes: [String], unchanged: Int,
                      expecting: (domain: Domain, generation: Int), serial: Int) async {
        guard let executor else {
            state = .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
            return
        }
        let built: (steps: [WriteStep], owners: [Int])
        do { built = try Self.steps(changes) } catch {
            state = .problem("A change couldn't be built, so nothing is offered. Preview the file again.")
            return
        }
        let n = changes.count
        // A failure every later person would share (a sign-in expired) stops it: the preview's default.
        let held = await executor.preview(built.steps, confirmStep: true, typedCountAbove: Guard.countConfirmAbove, expecting: expecting,
                                          title: "Change \(n) \(n == 1 ? "person" : "people") from a CSV")
        guard serial == self.serial else {
            if case .success(let preview) = held { await executor.discard(preview.id) }
            return
        }
        switch held {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, changes: changes, refused: refused, notes: notes, unchanged: unchanged,
                                        before: BulkCSV.beforeCSV(changes), blanks: BulkCSV.blanksBefore(changes), owners: built.owners))
        case .failure(let refusal):
            state = .problem(refusal.message)
        }
    }

    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        if !pending.preview.decision.typedCountMatches(confirmation.typedCount) {
            typedProblem = "Type \(pending.writes), the number of changes, to confirm."
            return
        }
        typedProblem = nil
        state = .running(pending)
        progress = Progress(total: pending.writes)
        let (events, observer) = AsyncStream<(Int, RunOutcome.Step)>.makeStream()
        let watcher = Task { @MainActor [weak self] in
            for await (_, result) in events {
                self?.progress?.done += 1
                if case .failed = result { self?.progress?.failed += 1 }
            }
        }
        let outcome = await executor.run(pending.preview, confirmation: confirmation, progress: observer)
        observer.finish()
        await watcher.value
        progress = nil
        if let refusal = outcome.refusal {
            state = .problem(refusal)
            return
        }
        // Titles, phones and units changed: the list mustn't keep the old ones.
        if setup.isConnected(to: pending.preview) {
            let directory = directory
            Task { await directory.load() }
        }
        guard setup.isConnected(to: pending.preview) else {
            state = .idle
            return
        }
        state = .done(Self.done(pending, outcome.steps, note: outcome.auditProblem.map { " \($0)" } ?? ""))
    }

    /// Per person: changed when every one of their writes ran; otherwise their first failure, with what had already changed
    /// (GamGUI's "Their title changed; the move to … failed"), or not attempted after a Stop.
    nonisolated static func done(_ pending: Pending, _ steps: [RunOutcome.Step], note: String) -> Done {
        var changed = 0, failures: [String] = [], failedCount = 0, notRun = 0, stoppedBy: String?
        for (index, change) in pending.changes.enumerated() {
            let mine = pending.owners.indices.filter { pending.owners[$0] == index }
            let results = mine.map { $0 < steps.count ? steps[$0] : nil }
            if results.allSatisfy({ $0?.isSucceeded == true }) {
                changed += 1
                continue
            }
            if let failure = results.compactMap({ step -> String? in
                switch step {
                case .failed(let message, let kind)?: kind.map { $0 == .unknown ? message : $0.remediation } ?? message
                case .waiting(let message)?: message
                default: nil
                }
            }).first {
                failedCount += 1
                let partly = mine.count > 1 && results.first??.isSucceeded == true
                    ? "Their \(BulkCSV.columns.filter { $0 != "org_unit" && change.after[$0] != nil }.map { PythonText.lower(BulkCSV.labels[$0]!) }.joined(separator: " and ")) changed; the move to \(change.orgUnit) failed: "
                    : ""
                if failures.count < failuresKept { failures.append("\(change.email) \u{2014} \(partly)\(failure)") }
                continue
            }
            notRun += 1
            if stoppedBy == nil, case .skipped(let reason)?? = results.first(where: { if case .skipped? = $0 { true } else { false } }) {
                stoppedBy = reason
            }
        }
        let total = pending.changes.count
        var message = "Changed \(changed) of \(total) \(total == 1 ? "person" : "people") from the CSV."
        if notRun > 0 {
            let why = stoppedBy == Executor.stopped || stoppedBy == nil ? "Stopped by you \u{2014} \(notRun) not attempted."
                : "\(stoppedBy!) The remaining \(notRun) \(notRun == 1 ? "was" : "were") not attempted."
            message = "\(why) " + message
        }
        return Done(message: message + note, failures: failures, failedCount: failedCount, partial: notRun > 0 || failedCount > 0)
    }

    public func stop() async {
        guard case .running(let pending) = state, let executor else { return }
        guard await executor.stopAfterCurrentStep(pending.id) else { return }
        progress?.stopping = true
    }

    public func typingChanged() { typedProblem = nil }

    public func dismiss() {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        nothing = nil
        state = .idle
    }
}
