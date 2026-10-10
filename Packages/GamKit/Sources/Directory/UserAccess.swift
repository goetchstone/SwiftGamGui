import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// One person's groups, mail delegates, auto-reply and signature, read live when their page opens (GamGUI's `/users/groups` and
/// `/users/delegates`, lazy-loaded the same way). Kept only for the tenant, generation and person they were
/// read for, so a switch never shows one tenant's memberships as another's; the last few people are kept,
/// so pages open in two windows each keep their own.
@MainActor
@Observable
public final class UserAccess {
    public struct Lists: Sendable, Equatable {
        /// Group addresses the person is a member of.
        public let groups: [String]
        /// Addresses delegated access to the person's mailbox.
        public let delegates: [String]
        /// Their auto-reply (`show vacation`), read on its own: a person without Gmail still shows their
        /// groups and delegates (GamGUI loads each panel separately).
        public let vacation: Result<Vacation, Problem>
        /// Their Gmail signature (`show signature`) as GAM showed it, read by GamGUI's reader
        /// (`Signature.parseShown`), "" when none is set. On its own too: Gmail off fails only this.
        public let signature: Result<String, Problem>
    }

    private struct Loaded {
        let email: String
        let domain: Domain
        let generation: Int
        /// When the read started: a slower, older read of the same person never replaces it.
        let serial: Int
        let result: Result<Lists, Problem>
    }

    /// A person as read for one tenant.
    private struct Key: Hashable {
        let email: String
        let domain: Domain
        let generation: Int
    }

    public struct Problem: Error, Sendable, Equatable {
        public let summary: String
    }

    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    /// The people read, newest first, kept per person: two windows' pages never evict each other's lists.
    /// Bounded (invariant 9), and only the connected tenant's are kept.
    private var loaded: [Loaded] = []
    /// The people being read, for the tenant they're read for: an old tenant's read never shows as this one's.
    private var reading = ReadsInFlight<Key>()
    private let keep: Int
    /// Tests only: the mock's state folder, so a read sees what a write just changed.
    var environment: [String: String] = [:]

    public init(setup: SetupModel, runner: AuthenticatedRunner?, keep: Int = 8) {
        self.setup = setup
        self.runner = runner
        self.keep = keep
    }

    /// A read of `email` is waiting or running.
    public func isReading(_ email: String) -> Bool {
        guard let domain = setup.active else { return false }
        return reading.isRunning(Key(email: email, domain: domain, generation: setup.generation))
    }

    /// The lists for `email`, while they belong to the connected tenant.
    public func lists(for email: String) -> Lists? {
        guard let loaded = current(email), case .success(let lists) = loaded.result else { return nil }
        return lists
    }

    public func problem(for email: String) -> String? {
        guard let loaded = current(email), case .failure(let problem) = loaded.result else { return nil }
        return problem.summary
    }

    private func current(_ email: String) -> Loaded? {
        loaded.first { $0.email == email && $0.domain == setup.active && $0.generation == setup.generation }
    }

    /// Four reads as the connected domain: `print groups member`, `print delegates`, `show vacation`,
    /// `show signature`.
    /// `delay` holds them back, reading from the start: a page that opens and is left within it reads
    /// nothing (arrowing down the list).
    public func load(_ email: String, after delay: Duration = .zero) async {
        guard let domain = setup.active, let runner else { return }
        let generation = setup.generation
        let key = Key(email: email, domain: domain, generation: generation)
        let serial = reading.start(key)
        defer { reading.end(key, serial) }
        if delay > .zero {
            guard (try? await Task.sleep(for: delay)) != nil else { return }
        }
        // The four reads at once: each is its own gam call.
        let environment = environment
        async let groupsRead = Self.result { try await Self.read(GamCommands.printGroups(member: email), with: runner, as: domain, environment) }
        async let delegatesRead = Self.result { try await Self.read(GamCommands.printDelegates(email: email), with: runner, as: domain, environment) }
        async let vacationRead = Self.result { try await Self.read(GamCommands.showVacation(email: email), with: runner, as: domain, environment) }
        async let signatureRead = Self.result { try await Self.read(GamCommands.showSignature(email: email), with: runner, as: domain, environment) }
        let (groups, delegates, vacation, signature) = await (groupsRead, delegatesRead, vacationRead, signatureRead)
        guard !Task.isCancelled else { return }
        let result: Result<Lists, Problem>
        switch (groups, delegates) {
        case (.success(let groups), .success(let delegates)):
            result = .success(Lists(groups: Self.groups(from: groups), delegates: Self.delegates(from: delegates),
                                    vacation: vacation.map(Vacation.init(showText:)),
                                    signature: signature.map(Signature.parseShown)))
        case (.failure(let problem), _), (_, .failure(let problem)):
            result = .failure(problem)
        }
        // A switch while reading: these belong to the old tenant, so they're dropped.
        guard !Task.isCancelled, setup.active == domain, setup.generation == generation,
              current(email).map({ $0.serial < serial }) ?? true
        else { return }
        loaded.removeAll { $0.email == email || $0.domain != domain || $0.generation != generation }
        loaded.insert(Loaded(email: email, domain: domain, generation: generation, serial: serial, result: result), at: 0)
        if loaded.count > keep { loaded.removeLast(loaded.count - keep) }
    }

    /// A read's outcome as a value, with any error worded for the screen.
    private static func result(_ body: () async throws -> String) async -> Result<String, Problem> {
        do {
            return .success(try await body())
        } catch let problem as Problem {
            return .failure(problem)
        } catch {
            return .failure(Problem(summary: "A read failed (\(type(of: error)))."))
        }
    }

    private static func read(_ read: GamRead, with runner: AuthenticatedRunner, as domain: Domain,
                             _ environment: [String: String]) async throws -> String {
        let result = try await runner.run(read, as: domain, extraEnvironment: environment)
        guard result.exitCode == 0 else {
            let error = GamError(exitCode: result.exitCode, stderr: result.stderr, argv: read.argv)
            throw Problem(summary: "\(error.message) \(error.remediation)")
        }
        return result.stdout
    }

    /// GamGUI's `list_user_groups`: the `email` column, where it holds an address.
    static func groups(from stdout: String) -> [String] {
        GamOutput.records(stdout).compactMap { $0["email"]?.string }.filter { $0.contains("@") }
    }

    /// GamGUI's `list_delegates`: `delegateAddress`, `delegate` or `Delegate Address`, whichever GAM printed.
    static func delegates(from stdout: String) -> [String] {
        GamOutput.records(stdout).compactMap { record in
            ["delegateAddress", "delegate", "Delegate Address"].lazy.compactMap { record[$0]?.string }.first { !$0.isEmpty }
        }
    }
}
