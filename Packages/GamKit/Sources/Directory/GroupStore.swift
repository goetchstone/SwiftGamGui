import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The tenant's groups as one `gam print groups` left them (GamGUI's group cache), for the Groups screen.
/// It loads only when asked: GamGUI reads groups when its Groups board first needs them, not on connect.
/// What it holds belongs to the tenant it was loaded for, as the directory's users do: a switch of the
/// connected domain hides it, and stops a load that was running.
@MainActor
@Observable
public final class GroupStore {
    public typealias Problem = DirectoryStore.Problem

    private var snapshot: Snapshot?
    /// The load running, and the tenant it runs for.
    private var inFlight: (task: Task<Void, Never>, domain: Domain, generation: Int)?
    /// Like the groups, a problem belongs to the tenant it was met under.
    private var failure: (problem: Problem, domain: Domain?, generation: Int)?

    private struct Snapshot {
        let groups: [GamGroup]
        let loadedAt: Date
        let domain: Domain
        let generation: Int
        /// Which list this is: the rows worked out from it key on this.
        let revision: Int
    }

    /// The last snapshot's revision.
    @ObservationIgnored private var revisions = 0
    /// The list as last searched, and what for. Not observed: it is filled while a view reads it.
    @ObservationIgnored private var listed: (revision: Int, query: String, rows: [GamGroup])?

    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    private let now: @Sendable () -> Date

    public init(setup: SetupModel, runner: AuthenticatedRunner?, now: @escaping @Sendable () -> Date = Date.init) {
        self.setup = setup
        self.runner = runner
        self.now = now
        setup.onTenantChange { [weak self] in self?.tenantChanged() }
    }

    /// A load runs for the connected tenant; one still running for an earlier tenant isn't this one's.
    public var isLoading: Bool {
        guard let inFlight else { return false }
        return inFlight.domain == setup.active && inFlight.generation == setup.generation
    }

    /// The old tenant's load stops: `gam` is sent SIGTERM, and its credentials are wiped as the call
    /// unwinds. Nothing new starts: the screen loads the next tenant's groups when it's shown.
    private func tenantChanged() {
        inFlight?.task.cancel()
        inFlight = nil
    }

    /// GamGUI's group finder (`_pick`), without its cap of 15: the groups whose address or name holds the
    /// search, compared as Python compares (lowercased by `str.lower()`, then scalar by scalar), in GAM's
    /// order. Worked out again only when the list or the search changes.
    public func rows(query: String) -> [GamGroup]? {
        guard let current else { return nil }
        if let listed, listed.revision == current.revision, listed.query == query { return listed.rows }
        let needle = Array(PythonText.lower(PythonText.strip(query)).unicodeScalars)
        let rows = needle.isEmpty ? current.groups : current.groups.filter { group in
            [group.email, group.name].contains { UserFilter.contains(Array(PythonText.lower($0).unicodeScalars), needle) }
        }
        listed = (current.revision, query, rows)
        return rows
    }

    /// The groups, while they belong to the connected tenant.
    public var groups: [GamGroup]? { current?.groups }

    /// Why there are no groups, while it still applies to the connected tenant.
    public var problem: Problem? {
        guard let failure, failure.domain == setup.active, failure.generation == setup.generation else { return nil }
        return failure.problem
    }
    public var loadedAt: Date? { current?.loadedAt }

    private var current: Snapshot? {
        guard let snapshot, snapshot.domain == setup.active, snapshot.generation == setup.generation else { return nil }
        return snapshot
    }

    /// Loads the connected tenant's groups with one `gam print groups` (GamGUI's fields); while a load for
    /// it is already running, waits for that one instead of starting a second. A domain-wide read: it gets
    /// the long timeout.
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
        let read = GamCommands.printGroups()
        failure = nil
        let task = Task { await perform(read, as: domain, generation: generation, runner: runner) }
        inFlight = (task, domain, generation)
        return task
    }

    private func perform(_ read: GamRead, as domain: Domain, generation: Int, runner: AuthenticatedRunner) async {
        defer {
            if inFlight?.domain == domain, inFlight?.generation == generation { inFlight = nil }
        }
        let outcome: Result<([GamGroup], Date), any Error>
        do {
            let result = try await runner.run(read, as: domain, timeout: GamRunner.domainWideTimeout)
            // A large tenant's list takes a while to parse: not on the main actor.
            let now = now
            outcome = .success(try await Task.detached { (try Self.groups(from: result, argv: read.argv), now()) }.value)
        } catch {
            outcome = .failure(error)
        }
        // A switch while loading: these belong to the old tenant, so they're dropped.
        guard setup.active == domain, setup.generation == generation else { return }
        switch outcome {
        case .success(let (groups, loadedAt)):
            revisions += 1
            snapshot = Snapshot(groups: groups, loadedAt: loadedAt, domain: domain, generation: generation, revision: revisions)
        case .failure(let error):
            failure = (Self.problem(for: error, argv: read.argv), domain, generation)
        }
    }

    /// The groups in a finished run, or why there are none. Output the runner cut at its cap is refused:
    /// a partial list would pass for the whole one.
    nonisolated static func groups(from result: GamResult, argv: [String]) throws -> [GamGroup] {
        guard result.exitCode == 0 else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        guard !result.stdoutTruncated else { throw DirectoryStore.Truncated() }
        return GamOutput.records(result.stdout).map(GamGroup.init(record:))
    }

    nonisolated static func problem(for error: any Error, argv: [String]) -> Problem {
        guard error is DirectoryStore.Truncated else { return DirectoryStore.problem(for: error, argv: argv) }
        return Problem(summary: "There are more groups than one call can return yet (GAM printed more than "
            + "\(GamRunner.outputCap / 1_048_576) MiB), so none are shown rather than some.", detail: nil)
    }
}
