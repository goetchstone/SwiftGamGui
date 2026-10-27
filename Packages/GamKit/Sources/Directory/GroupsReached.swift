import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The groups here an attacker's emails went to, read for whom they reach (Incident's Who it reached,
/// docs/domains/compromised-account.md): each group's members, with GamGUI's group-members read, then the groups among
/// them, each read once, at most `limit` for the tenant's connection (invariant 9). A group read counts by its members; one
/// not read (past the limit, or a read that failed) counts on the warning's send, and why is kept to say. Nothing asked is
/// read again, but a read that failed once the screen opens again (`forgetFailures`): a reading that lists the same groups
/// never reads them in a loop.
/// Kept only for the tenant and generation they were read for.
@MainActor
@Observable
public final class GroupsReached {
    /// Each group read: its members' addresses, lowercased, a nested group's own address among them.
    public var members: [String: [String]] { current ? read.members : [:] }
    /// The groups read with GAM's CUSTOMER member: everyone in the organization.
    public var everyone: Set<String> { current ? read.everyone : [] }
    /// Why a group's members weren't read, in words: GAM's failure, or the limit.
    public var problems: [String: String] { current ? read.problems : [:] }
    /// Which reads these are: changed when a round of reads ends with anything new, and by a switch or `forget`. What a
    /// reading of them is keyed by, never the members hashed at every redraw.
    public var key: String { "\(setup.active?.name ?? "")|\(setup.generation)|\(revision)" }
    /// A round of reads is under way for the connected tenant.
    public var isReading: Bool { current && running > 0 }
    public let limit: Int

    private struct Read {
        var members: [String: [String]] = [:]
        var everyone: Set<String> = []
        var problems: [String: String] = [:]
        /// Every group asked, read or not: never asked again (but `failed`, by `forgetFailures`).
        var asked: Set<String> = []
        /// The groups whose read failed (not those past the limit).
        var failed: Set<String> = []
    }

    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    private var read = Read()
    private var tenant: (domain: Domain, generation: Int)?
    private var revision = 0
    private var running = 0
    /// Bumped by `forget` and a switch: a round still running for an older one drops what it reads.
    @ObservationIgnored private var epoch = 0
    /// Tests only: the mock's state folder.
    var environment: [String: String] = [:]

    public init(setup: SetupModel, runner: AuthenticatedRunner?, limit: Int = 20) {
        self.setup = setup
        self.runner = runner
        self.limit = limit
    }

    private var current: Bool {
        tenant.map { $0.domain == setup.active && $0.generation == setup.generation } ?? false
    }

    /// Drops every group read, so the next round reads them again.
    public func forget() {
        read = Read()
        tenant = nil
        epoch += 1
        revision += 1
    }

    /// Drops only the groups whose read failed, so the next round tries them again (the screen closing, to open anew): what
    /// was read is kept with the reading it made, which then isn't made again (the operator, 2026-10-27).
    public func forgetFailures() {
        guard !read.failed.isEmpty else { return }
        read.asked.subtract(read.failed)
        for group in read.failed { read.problems[group] = nil }
        read.failed = []
        revision += 1
    }

    /// Reads `groups` and the groups among their members, each not asked before, in order, until `limit` groups have
    /// been asked; past it, each is said not read. One `gam print group-members` a group, as the connected domain.
    public func read(_ groups: [String]) async {
        guard let domain = setup.active, let runner else { return }
        // Another tenant's, or none yet: dropped (the key already differs, with the tenant or `forget`).
        if !current {
            read = Read()
            epoch += 1
            tenant = (domain, setup.generation)
        }
        let epoch = epoch
        var queue = groups.map(Guard.normalized), changed = false
        running += 1
        defer {
            running -= 1
            if changed, self.epoch == epoch { revision += 1 }
        }
        while !queue.isEmpty {
            let group = queue.removeFirst()
            guard !group.isEmpty, read.asked.insert(group).inserted else { continue }
            changed = true
            guard read.asked.count <= limit else {
                read.problems[group] = "not read: this screen reads at most \(limit) groups"
                continue
            }
            let gam = GamCommands.printGroupMembers(group: group)
            let result: Result<[GroupMember], DirectoryStore.Problem>
            do {
                let output = try await runner.run(gam, as: domain, extraEnvironment: environment)
                // A large group takes a while to sort: not on the main actor.
                result = .success(try await Task.detached { try GroupMembers.members(from: output, argv: gam.argv) }.value)
            } catch let failure as GamError where failure.kind == .notFound {
                result = .failure(DirectoryStore.Problem(summary: "GAM finds no group at that address", detail: failure.message))
            } catch {
                result = .failure(GroupMembers.problem(for: error, argv: gam.argv))
            }
            // Forgotten, or a switch, while it read: it belongs to what was dropped.
            guard self.epoch == epoch, current else { return }
            switch result {
            case .success(let found):
                read.members[group] = found.map { Guard.normalized($0.email) }.filter { !$0.isEmpty }
                if found.contains(where: { $0.memberType == "CUSTOMER" }) { read.everyone.insert(group) }
                queue += found.filter { $0.memberType == "GROUP" }.map { Guard.normalized($0.email) }
            case .failure(let problem):
                read.problems[group] = problem.summary
                read.failed.insert(group)
            }
        }
    }
}
