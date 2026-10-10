import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// One group's members, read live when its page opens (GamGUI's group panel reads them on every open). Kept
/// only for the tenant, generation and group they were read for, so a switch never shows one tenant's
/// members as another's; the last few groups are kept, so pages open in two windows each keep their own.
@MainActor
@Observable
public final class GroupMembers {
    public typealias Problem = DirectoryStore.Problem

    /// A group as read for one tenant: the address as `Guard` compares it, so `SALES@` is `sales@`.
    private struct Key: Hashable {
        let group: String
        let domain: Domain
        let generation: Int
    }

    private struct Loaded {
        let key: Key
        /// Which read this is: the rows worked out from it key on this.
        let revision: Int
        /// When the read started: a slower, older read of the same group never replaces it.
        let serial: Int
        let result: Result<[GroupMember], Problem>
    }

    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    /// The groups read, newest first, kept per group: two windows' pages never evict each other's members.
    /// Bounded (invariant 9), and only the connected tenant's are kept.
    private var loaded: [Loaded] = []
    /// The groups being read. Keyed by tenant too, so an old tenant's read never shows as this one's.
    private var reading = ReadsInFlight<Key>()
    private let keep: Int
    @ObservationIgnored private var revisions = 0
    /// Each kept read's rows as last searched, and what for. Not observed: it is filled while a view reads it.
    @ObservationIgnored private var listed: [Int: (query: String, rows: [GroupMember])] = [:]
    /// Tests only: the mock's state folder, so a read sees what a write just changed.
    var environment: [String: String] = [:]

    public init(setup: SetupModel, runner: AuthenticatedRunner?, keep: Int = 8) {
        self.setup = setup
        self.runner = runner
        self.keep = keep
    }

    /// A read of `group` for the connected tenant is waiting or running.
    public func isReading(_ group: String) -> Bool {
        key(group).map { reading.isRunning($0) } ?? false
    }

    /// `group`'s members in GamGUI's order, while they belong to the connected tenant.
    public func members(of group: String) -> [GroupMember]? {
        guard let loaded = current(group), case .success(let members) = loaded.result else { return nil }
        return members
    }

    /// Why `group`'s members couldn't be read, while it still applies to the connected tenant.
    public func problem(for group: String) -> Problem? {
        guard let loaded = current(group), case .failure(let problem) = loaded.result else { return nil }
        return problem
    }

    /// The members a page shows: GamGUI's member search over the last read, worked out again only when the
    /// read or the search changes.
    public func rows(_ group: String, query: String) -> [GroupMember]? {
        guard let loaded = current(group), case .success(let members) = loaded.result else { return nil }
        if let listed = listed[loaded.revision], listed.query == query { return listed.rows }
        let rows = Self.filter(members, query: query)
        listed[loaded.revision] = (query, rows)
        return rows
    }

    private func key(_ group: String) -> Key? {
        setup.active.map { Key(group: Guard.normalized(group), domain: $0, generation: setup.generation) }
    }

    private func current(_ group: String) -> Loaded? {
        guard let key = key(group) else { return nil }
        return loaded.first { $0.key == key }
    }

    /// One `gam print group-members` as the connected domain. `delay` holds it back, reading from the start:
    /// a page that opens and is left within it reads nothing (arrowing down the list).
    public func load(_ group: String, after delay: Duration = .zero) async {
        guard let domain = setup.active, let runner else { return }
        let key = Key(group: Guard.normalized(group), domain: domain, generation: setup.generation)
        let serial = reading.start(key)
        defer { reading.end(key, serial) }
        if delay > .zero {
            guard (try? await Task.sleep(for: delay)) != nil else { return }
        }
        let read = GamCommands.printGroupMembers(group: group)
        let result: Result<[GroupMember], Problem>
        do {
            let output = try await runner.run(read, as: domain, extraEnvironment: environment)
            // Sorting a large group takes a while: not on the main actor.
            result = .success(try await Task.detached { try Self.members(from: output, argv: read.argv) }.value)
        } catch {
            result = .failure(Self.problem(for: error, argv: read.argv))
        }
        // A switch while reading: these belong to the old tenant, so they're dropped. A later read of the
        // group already in hand is kept.
        guard !Task.isCancelled, setup.active == domain, setup.generation == key.generation,
              loaded.first(where: { $0.key == key }).map({ $0.serial < serial }) ?? true
        else { return }
        revisions += 1
        loaded.removeAll { $0.key.group == key.group || $0.key.domain != domain || $0.key.generation != key.generation }
        loaded.insert(Loaded(key: key, revision: revisions, serial: serial, result: result), at: 0)
        if loaded.count > keep { loaded.removeLast(loaded.count - keep) }
        listed = listed.filter { entry in loaded.contains { $0.revision == entry.key } }
    }

    /// The members in a finished run, sorted, or why there are none. Output the runner cut at its cap is
    /// refused: a partial list would pass for the whole group.
    nonisolated static func members(from result: GamResult, argv: [String]) throws -> [GroupMember] {
        guard result.exitCode == 0 else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        guard !result.stdoutTruncated else { throw DirectoryStore.Truncated() }
        return sorted(GamOutput.records(result.stdout).map(GroupMember.init(record:)))
    }

    nonisolated static func problem(for error: any Error, argv: [String]) -> Problem {
        guard error is DirectoryStore.Truncated else { return DirectoryStore.problem(for: error, argv: argv) }
        return Problem(summary: "The group has more members than one call can return yet (GAM printed more than "
            + "\(GamRunner.outputCap / 1_048_576) MiB), so none are shown rather than some.", detail: nil)
    }

    /// GamGUI's order (`_ROLE_RANK`): owners, then managers, then members, then any other role, each by
    /// address lowercased and compared code point by code point, as Python compares (Swift's `<` takes a
    /// decomposed "é" for the composed one). Members alike keep GAM's order: Swift's `sorted` is
    /// documented stable, as Python's is.
    nonisolated static func sorted(_ members: [GroupMember]) -> [GroupMember] {
        let ranks = ["OWNER": 0, "MANAGER": 1, "MEMBER": 2]
        return members
            .map { (rank: ranks[$0.role] ?? 3, email: PythonText.lower($0.email).unicodeScalars.map(\.value), member: $0) }
            .sorted { a, b in a.rank != b.rank ? a.rank < b.rank : a.email.lexicographicallyPrecedes(b.email) }
            .map(\.member)
    }

    /// GamGUI's member search: the address or the role holds it, lowercased by `str.lower()` and compared
    /// scalar by scalar.
    nonisolated static func filter(_ members: [GroupMember], query: String) -> [GroupMember] {
        let needle = Array(PythonText.lower(PythonText.strip(query)).unicodeScalars)
        guard !needle.isEmpty else { return members }
        return members.filter { member in
            [member.email, member.role].contains { UserFilter.contains(Array(PythonText.lower($0).unicodeScalars), needle) }
        }
    }
}
