import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// One person's groups and mail delegates, read live when their page opens (GamGUI's `/users/groups` and
/// `/users/delegates`, lazy-loaded the same way). Kept only for the tenant, generation and person they were
/// read for, so a switch never shows one tenant's memberships as another's.
@MainActor
@Observable
public final class UserAccess {
    public struct Lists: Sendable, Equatable {
        /// Group addresses the person is a member of.
        public let groups: [String]
        /// Addresses delegated access to the person's mailbox.
        public let delegates: [String]
    }

    private struct Loaded {
        let email: String
        let domain: Domain
        let generation: Int
        let result: Result<Lists, Problem>
    }

    public struct Problem: Error, Sendable, Equatable {
        public let summary: String
    }

    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    private var loaded: Loaded?
    public private(set) var loading: String?
    private var latest: UUID?
    /// Tests only: the mock's state folder, so a read sees what a write just changed.
    var environment: [String: String] = [:]

    public init(setup: SetupModel, runner: AuthenticatedRunner?) {
        self.setup = setup
        self.runner = runner
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
        guard let loaded, loaded.email == email, loaded.domain == setup.active, loaded.generation == setup.generation
        else { return nil }
        return loaded
    }

    /// Two reads as the connected domain: `print groups member` and `print delegates`.
    public func load(_ email: String) async {
        guard let domain = setup.active, let runner else { return }
        let generation = setup.generation
        // The latest request wins: a slower read for someone selected earlier never replaces it.
        let request = UUID()
        latest = request
        loading = email
        defer { if latest == request { loading = nil } }
        let result: Result<Lists, Problem>
        do {
            let groups = try await Self.read(GamCommands.printGroups(member: email), with: runner, as: domain, environment)
            let delegates = try await Self.read(GamCommands.printDelegates(email: email), with: runner, as: domain, environment)
            result = .success(Lists(groups: Self.groups(from: groups), delegates: Self.delegates(from: delegates)))
        } catch let problem as Problem {
            result = .failure(problem)
        } catch is CancellationError {
            return
        } catch {
            result = .failure(Problem(summary: "Couldn't read \(email)'s groups and delegates (\(type(of: error)))."))
        }
        // A switch while reading: these belong to the old tenant, so they're dropped.
        guard latest == request, !Task.isCancelled, setup.active == domain, setup.generation == generation else { return }
        loaded = Loaded(email: email, domain: domain, generation: generation, result: result)
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
