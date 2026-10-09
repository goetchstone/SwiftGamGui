import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The directory as one `gam print users` left it, for every screen that counts or lists people
/// (GamGUI's user cache). It loads only when asked, never on its own, and what it holds belongs to the
/// tenant it was loaded for: a switch of the connected domain hides it, and a load that was running
/// when the tenant changed is dropped (GamGUI failure-log 2026-09-25: a tenant switch left the old
/// tenant's data live).
@MainActor
@Observable
public final class DirectoryStore {
    public struct Problem: Equatable, Sendable {
        /// What to do about it.
        public let summary: String
        /// What GAM said, when it said something.
        public let detail: String?
    }

    private var snapshot: Snapshot?
    /// The load running, and the tenant it runs for.
    private var inFlight: (task: Task<Void, Never>, domain: Domain, generation: Int)?
    /// Like the users, a problem belongs to the tenant it was met under: a load that failed while its
    /// domain was being removed must not speak for the next one.
    private var failure: (problem: Problem, domain: Domain?, generation: Int)?

    private struct Snapshot {
        let users: [GamUser]
        let reports: [DirectoryReport]
        let loadedAt: Date
        let domain: Domain
        let generation: Int
    }

    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    private let now: @Sendable () -> Date

    public init(setup: SetupModel, runner: AuthenticatedRunner?, now: @escaping @Sendable () -> Date = Date.init) {
        self.setup = setup
        self.runner = runner
        self.now = now
        setup.tenantDidChange = { [weak self] in self?.tenantChanged() }
    }

    /// A load runs for the connected tenant. One still running for an earlier tenant isn't this
    /// tenant's, and doesn't stop it loading (PR #8's review: it once held "Loading…" under the next
    /// tenant, for up to the hour-long timeout).
    public var isLoading: Bool {
        guard let inFlight else { return false }
        return inFlight.domain == setup.active && inFlight.generation == setup.generation
    }

    /// The old tenant's load stops: `gam` is sent SIGTERM, and its credentials are wiped as the call
    /// unwinds, rather than reading on for the domain that was just removed or switched away from.
    private func tenantChanged() {
        inFlight?.task.cancel()
        inFlight = nil
        // A domain just connected: load it, as the operator asked (2026-10-09), rather than waiting for a
        // click. A disconnect loads nothing.
        if setup.active != nil { start() }
    }

    /// The users, while they belong to the connected tenant.
    public var users: [GamUser]? { current?.users }
    /// GamGUI's reports over those users, as of the load.
    public var reports: [DirectoryReport]? { current?.reports }

    /// Why there are no users, while it still applies to the connected tenant.
    public var problem: Problem? {
        guard let failure, failure.domain == setup.active, failure.generation == setup.generation else { return nil }
        return failure.problem
    }
    public var loadedAt: Date? { current?.loadedAt }

    private var current: Snapshot? {
        guard let snapshot, snapshot.domain == setup.active, snapshot.generation == setup.generation else { return nil }
        return snapshot
    }

    /// One `gam print users` with the fields every screen uses, as the connected domain. A domain-wide
    /// read: it gets the long timeout.
    /// Loads the connected tenant's users; while a load for it is already running (the one connecting
    /// started), waits for that one instead of starting a second.
    public func load() async {
        if isLoading, let running = inFlight?.task {
            await running.value
            return
        }
        await start()?.value
    }

    /// Starts a load and marks it running before returning, so a click meanwhile can't start a second.
    /// Nil when one is already running or nothing can load.
    @discardableResult
    private func start() -> Task<Void, Never>? {
        guard !isLoading else { return nil }
        let generation = setup.generation
        guard let domain = setup.active else {
            failure = (Problem(summary: "Connect a domain on Setup first.", detail: nil), nil, generation)
            return nil
        }
        guard let runner else {
            failure = (Problem(summary: "This build has no GAM. Build the app again after running scripts/fetch_gam.sh.",
                               detail: nil), domain, generation)
            return nil
        }
        let read = GamCommands.printUsers(fields: GamCommands.cacheFields)
        failure = nil
        let task = Task { await perform(read, as: domain, generation: generation, runner: runner) }
        inFlight = (task, domain, generation)
        return task
    }

    private func perform(_ read: GamRead, as domain: Domain, generation: Int, runner: AuthenticatedRunner) async {
        defer {
            if inFlight?.domain == domain, inFlight?.generation == generation { inFlight = nil }
        }
        let outcome: Result<([GamUser], [DirectoryReport], Date), any Error>
        do {
            let result = try await runner.run(read, as: domain, timeout: GamRunner.domainWideTimeout)
            // Parsing and counting a large directory takes a while: not on the main actor.
            let now = now
            outcome = .success(try await Task.detached {
                let users = try Self.users(from: result, argv: read.argv), at = now()
                return (users, DirectoryReport.build(users, now: at), at)
            }.value)
        } catch {
            outcome = .failure(error)
        }
        guard setup.active == domain, setup.generation == generation else { return }
        switch outcome {
        case .success(let (users, reports, loadedAt)):
            snapshot = Snapshot(users: users, reports: reports, loadedAt: loadedAt, domain: domain, generation: generation)
        case .failure(let error):
            failure = (Self.problem(for: error, argv: read.argv), domain, generation)
        }
    }

    /// GAM output too large for the runner's cap.
    struct Truncated: Error {}

    /// The users in a finished run, or why there are none. Output the runner cut at its cap is refused:
    /// counting a partial list would report a smaller directory as if it were the whole one.
    nonisolated static func users(from result: GamResult, argv: [String]) throws -> [GamUser] {
        guard result.exitCode == 0 else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        guard !result.stdoutTruncated else { throw Truncated() }
        return GamOutput.records(result.stdout).map(GamUser.init(record:))
    }

    nonisolated static func problem(for error: any Error, argv: [String]) -> Problem {
        switch error {
        case let failure as GamError:
            return Problem(summary: failure.remediation, detail: failure.message)
        case GamRunnerError.timedOut:
            let failure = GamError(exitCode: nil, stderr: "", argv: argv)
            return Problem(summary: failure.remediation, detail: failure.message)
        case is Truncated:
            return Problem(summary: "The directory is larger than one call can return yet (GAM printed more than "
                + "\(GamRunner.outputCap / 1_048_576) MiB), so nothing is shown rather than part of it.", detail: nil)
        default:
            return Problem(summary: SetupModel.message(for: error), detail: nil)
        }
    }
}

extension Array where Element == GamUser {
    public var suspendedCount: Int { filter(\.suspended).count }
    public var adminCount: Int { filter(\.isAdmin).count }
}
