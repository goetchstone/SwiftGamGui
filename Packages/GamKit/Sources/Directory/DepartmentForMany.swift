import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// A department for many (GamGUI's `/users/bulk`, roadmap 2.1): one department set on a group's active members or on a pasted
/// list of addresses, each person's title kept. One previewed write per person, through ChangeCore like every write here.
///
/// - **Who**: the cached directory's active users whose address is a group member's (read live at preview, as Signatures'
///   group scope reads it) or one pasted (commas or new lines, any case). Someone not in the directory, or suspended, is left
///   out, as GamGUI leaves them out.
/// - **Each title is kept**: GAM's `organization … primary` sets title and department together, so each step carries the
///   person's title as the directory had it at preview. The confirm runs exactly what was held (invariant 2); GamGUI reads the
///   titles again at Apply, a difference only when a title changes between preview and confirm.
/// - **The guard's rules for many** (`Guard`): a confirm always. It runs one person at a time, in the jobs tray and here, with
///   Stop after the write in flight; a failure every later person would share (sign-in expired, a scope missing) stops it
///   (`HeldPreview.stopsAtAccountWideFailure`, GamGUI's `bulk.stop_reason`).
/// - **Retry the N that failed** previews exactly those people again, still active, with the same department, on the tenant it
///   ran on.
/// - Each write that succeeded is patched into the cached directory; one that failed has the directory read again (a timeout
///   may still have applied it: GamGUI's `invalidate_users`).
@MainActor
@Observable
public final class DepartmentForMany {
    public enum State: Sendable {
        case idle
        /// Reading the group's members.
        case checking
        /// The preview the sheet shows; confirming runs exactly this.
        case previewing(Pending)
        case running(Pending)
        case done(Done)
        case problem(String)
    }

    /// Whom the department is set for.
    public enum Who: Sendable, Hashable {
        /// A group's members, read live when the preview is made.
        case group(String)
        /// Addresses pasted, separated by commas or new lines.
        case pasted(String)
    }

    /// A held preview with what the sheet says about it.
    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        public let department: String
        /// Everyone it sets, one write each, in the held steps' order.
        public let people: [GamUser]
        public let isRetry: Bool
        /// Who was left out, and why, in words.
        public let notes: [String]

        public var id: UUID { preview.id }
        public var count: Int { people.count }
    }

    public struct Done: Sendable {
        public let message: String
        /// Each person it failed for, with why (the first `failuresKept`), and how many in all.
        public let failures: [String]
        public let failedCount: Int
        /// Stopped, or some failed.
        public let partial: Bool
        /// What "Retry the N that failed" previews; nil when nothing failed.
        public let retry: Retry?
    }

    /// A finished run's failures, bound to the tenant it ran on.
    public struct Retry: Sendable {
        public let department: String
        public let failed: [String]
        let domain: Domain
        let generation: Int
    }

    /// A run as it goes, counted as each write ends.
    public struct Progress: Sendable, Equatable {
        public var total: Int
        public var applied = 0
        public var failed = 0
        public var stopping = false
        public var done: Int { applied + failed }

        public init(total: Int) { self.total = total }
    }

    /// People a preview lists by name (GamGUI's `targets[:200]`); the count is the whole of it.
    public nonisolated static let shown = 200
    /// The failures a finished run names (invariant 9).
    public nonisolated static let failuresKept = 200

    public private(set) var state: State = .idle
    public private(set) var progress: Progress?
    /// Tests only: the mock's state folder, for the group read.
    var environment: [String: String] = [:]
    /// Each preview and dismissal counts one: a preview whose read ends after a newer one began holds nothing shown.
    private var serial = 0
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    private let runner: AuthenticatedRunner?

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, runner: AuthenticatedRunner?) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.runner = runner
        setup.onTenantChange { [weak self] in self?.dismiss() }
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .running: true
        default: false
        }
    }

    /// GamGUI's `_pasted`: each address between commas and line ends, stripped and lowercased, once each.
    public nonisolated static func pasted(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == "," || $0.isNewline }).map { PythonText.lower(PythonText.strip(String($0))) }
            .filter { !$0.isEmpty })
    }

    /// GamGUI's `_bulk_targets`: the directory's active users whose address is one of `wanted`, lowercased, in its order.
    public nonisolated static func targets(_ users: [GamUser], wanted: Set<String>) -> [GamUser] {
        let wanted = Set(wanted.map { Array(PythonText.lower($0).unicodeScalars) })
        return users.filter { !$0.suspended && wanted.contains(Array(PythonText.lower($0.primaryEmail).unicodeScalars)) }
    }

    /// The step for one person: their department set, their title kept (GamGUI's `set_organization(title=u.title or "")`).
    nonisolated static func step(_ person: GamUser, department: String) -> WriteStep {
        WriteStep(GamCommands.updateOrganization(email: person.primaryEmail, title: person.title, department: department),
                  target: person.primaryEmail, summary: "Set \(person.primaryEmail)'s department to “\(department)”")
    }

    /// Holds `department` for everyone `who` names now. Refused, with why, without a department, a directory, or anyone found.
    public func preview(department: String, who: Who) async {
        guard !isBusy else { return }
        serial += 1
        let serial = serial
        let department = PythonText.strip(department)
        guard !department.isEmpty else {
            state = .problem("Enter a department first.")
            return
        }
        // The tenant the directory and the group read belong to, before any await.
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        guard let users = directory.users else {
            state = .problem("Load the directory on Users first.")
            return
        }
        let wanted: Set<String>
        switch who {
        case .pasted(let text):
            wanted = Self.pasted(text)
            guard !wanted.isEmpty else {
                state = .problem("Paste at least one address, or choose a group.")
                return
            }
        case .group(let group):
            state = .checking
            let read = await members(of: PythonText.strip(group), on: tenant?.domain)
            guard serial == self.serial else { return }
            switch read {
            case .success(let members): wanted = Set(members.map { PythonText.lower($0.email) })
            case .failure(let why):
                state = .problem(why.words)
                return
            }
        }
        let people = Self.targets(users, wanted: wanted)
        var notes: [String] = []
        if case .pasted = who, people.count < wanted.count {
            let missing = wanted.count - people.count
            notes.append("\(missing) of the addresses \(missing == 1 ? "isn't an active user" : "aren't active users") here "
                + "and \(missing == 1 ? "is" : "are") left out.")
        }
        await hold(people, department: department, isRetry: false, notes: notes, expecting: tenant, serial: serial)
    }

    /// "Retry the N that failed" (GamGUI's `/users/bulk/retry`): exactly a finished run's failed people still active, with its
    /// department, on the tenant it ran on. Writes nothing.
    public func previewRetry(_ retry: Retry) async {
        guard !isBusy else { return }
        serial += 1
        guard let users = directory.users else {
            state = .problem("Load the directory on Users first.")
            return
        }
        let people = Self.targets(users, wanted: Set(retry.failed))
        let gone = Set(retry.failed.map { PythonText.lower($0) }).count - people.count
        let notes = gone > 0 ? ["\(gone) of those that failed \(gone == 1 ? "is" : "are") no longer an active user and "
                                + "\(gone == 1 ? "is" : "are") left out."] : []
        await hold(people, department: retry.department, isRetry: true, notes: notes,
                   expecting: (retry.domain, retry.generation), serial: serial)
    }

    private func hold(_ people: [GamUser], department: String, isRetry: Bool, notes: [String],
                      expecting: (domain: Domain, generation: Int)?, serial: Int) async {
        guard let executor else {
            state = .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
            return
        }
        guard !people.isEmpty else {
            state = .problem(isRetry ? "None of those that failed is an active user any more."
                                     : "No active users match. " + notes.joined(separator: " "))
            return
        }
        let n = people.count, users = "\(n) user\(n == 1 ? "" : "s")"
        let held = await executor.preview(people.map { Self.step($0, department: department) }, confirmStep: true,
                                          expecting: expecting,
                                          title: isRetry ? "Department “\(department)” retry \u{2014} \(users)"
                                                         : "Department “\(department)” for \(users)")
        guard serial == self.serial else {
            if case .success(let preview) = held { await executor.discard(preview.id) }
            return
        }
        switch held {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, department: department, people: people, isRetry: isRetry, notes: notes))
        case .failure(let refusal):
            state = .problem(refusal.message)
        }
    }

    /// Why a group's members couldn't be read, in words.
    struct Why: Error {
        let words: String
        init(_ words: String) { self.words = words }
    }

    /// `print group-members group <address>`: its members, or why they couldn't be read (never taken for an empty group).
    private func members(of group: String, on domain: Domain?) async -> Result<[GroupMember], Why> {
        guard !group.isEmpty else { return .failure(Why("Choose a group first.")) }
        guard let domain, let runner else { return .failure(Why("Connect a domain on Setup first.")) }
        let read = GamCommands.printGroupMembers(group: group)
        do {
            let result = try await runner.run(read, as: domain, extraEnvironment: environment)
            guard result.exitCode == 0 else {
                let error = GamError(exitCode: result.exitCode, stderr: result.stderr, argv: read.argv)
                let why = error.kind == .notFound ? "\(group) isn't a group here." : error.remediation
                return .failure(Why("Couldn't read \(group)'s members, so nothing was previewed. \(why)"))
            }
            guard !result.stdoutTruncated else {
                return .failure(Why("\(group) has more members than one call can return, so nothing was previewed."))
            }
            return .success(GamOutput.records(result.stdout).map(GroupMember.init(record:)))
        } catch {
            let problem = DirectoryStore.problem(for: error, argv: read.argv)
            return .failure(Why("Couldn't read \(group)'s members, so nothing was previewed. \(problem.summary)"))
        }
    }

    /// Runs `pending` once, exactly as held, while it's the preview the sheet shows.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        state = .running(pending)
        progress = Progress(total: pending.count)
        let (events, observer) = AsyncStream<(Int, RunOutcome.Step)>.makeStream()
        let watcher = Task { @MainActor [weak self] in
            for await (_, result) in events {
                switch result {
                case .succeeded: self?.progress?.applied += 1
                case .failed, .waiting: self?.progress?.failed += 1
                case .skipped: break
                }
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
        let (domain, generation) = (pending.preview.domain, pending.preview.generation)
        // Once for the whole run, not once a person (GamGUI #196).
        let set = zip(pending.people, outcome.steps).filter { $0.1.isSucceeded }.map { $0.0.primaryEmail }
        directory.patchMany(set, on: domain, generation: generation) { $0.with(department: pending.department) }
        if outcome.steps.count < pending.count || !outcome.steps.allSatisfy(\.isSucceeded),
           setup.isConnected(to: pending.preview) {
            let directory = directory
            Task { await directory.load() }
        }
        // A switch while it ran (plan F6): the result is the old domain's, kept in the jobs tray and Audit, not shown here.
        guard setup.isConnected(to: pending.preview) else {
            state = .idle
            return
        }
        state = .done(Self.done(pending, outcome.steps, note: outcome.auditProblem.map { " \($0)" } ?? ""))
    }

    /// GamGUI's `_bulk_apply.html` result: how many were set, why it stopped and how many weren't attempted, who failed.
    nonisolated static func done(_ pending: Pending, _ steps: [RunOutcome.Step], note: String) -> Done {
        let total = pending.count
        var set = 0, failures: [String] = [], failed: [String] = [], notRun = 0, stoppedBy: String?
        for (index, person) in pending.people.enumerated() {
            switch index < steps.count ? steps[index] : nil {
            case .succeeded?: set += 1
            case .skipped(let reason)?:
                notRun += 1
                if stoppedBy == nil { stoppedBy = reason }
            case nil: notRun += 1
            case .failed(let message, let kind)?:
                failed.append(person.primaryEmail)
                if failures.count < failuresKept { failures.append("\(person.primaryEmail) \u{2014} \(kind?.remediation ?? message)") }
            case .waiting(let message)?:
                failed.append(person.primaryEmail)
                if failures.count < failuresKept { failures.append("\(person.primaryEmail) \u{2014} \(message)") }
            }
        }
        let message: String
        if notRun > 0 {
            let why = stoppedBy == Executor.stopped || stoppedBy == nil ? "Stopped by you \u{2014} \(notRun) not attempted."
                : "\(stoppedBy!) The remaining \(notRun) \(notRun == 1 ? "was" : "were") not attempted."
            message = "\(why) Set the department for \(set) of \(total) before stopping."
        } else {
            message = "Set the department for \(set) of \(total) user\(total == 1 ? "" : "s")."
        }
        let retry = failed.isEmpty ? nil : Retry(department: pending.department, failed: failed,
                                                 domain: pending.preview.domain, generation: pending.preview.generation)
        return Done(message: message + note, failures: failures, failedCount: failed.count,
                    partial: notRun > 0 || !failed.isEmpty, retry: retry)
    }

    /// Stop after the write in flight (GamGUI's Stop): the rest read "not attempted".
    public func stop() async {
        guard case .running(let pending) = state, let executor else { return }
        guard await executor.stopAfterCurrentStep(pending.id) else { return }
        progress?.stopping = true
    }

    /// Back to the form; a held preview simply expires unused.
    public func dismiss() {
        guard !isBusy else { return }
        serial += 1
        state = .idle
    }
}
