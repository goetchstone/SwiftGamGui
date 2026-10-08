import Foundation
import Security
import Synchronization

public enum VaultError: Error, Equatable, Sendable {
    /// A Keychain call failed for any reason but "no such item". Never read as absence: a refused
    /// delete once read as success with the secret still stored (GamGUI failure-log 2026-10-01).
    case keychain(OSStatus)
    case missing(Domain, [Credential])
    case accessControlUnavailable
}

/// Where credentials live. `read` returns nil only for "no such item"; every other failure throws.
public protocol SecretStore: Sendable {
    func read(_ credential: Credential, for domain: Domain) throws -> Data?
    func write(_ data: Data, as credential: Credential, for domain: Domain) throws
    /// Removing an item that isn't there is not an error; any other failure throws.
    func delete(_ credential: Credential, for domain: Domain) throws
    /// Every domain with at least one stored credential. Reads attributes only, never secret data.
    func domains() throws -> [Domain]
    /// Ends the authenticated session, so the next read asks for Touch ID or the password again.
    func endSession()
}

/// An in-memory store for tests and the demo tenant. A failure can be queued per operation with the
/// exact `OSStatus` the Keychain returns, so callers are tested against real failures, not just absence.
public final class MemoryStore: SecretStore {
    public enum Operation: Sendable, Hashable { case read, write, delete, domains }

    private struct State {
        var items: [String: Data] = [:]
        var failures: [Operation: OSStatus] = [:]
        var reads = 0
        var sessionsEnded = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// The next call of `operation` throws `VaultError.keychain(status)`.
    public func failNext(_ operation: Operation, with status: OSStatus) {
        state.withLock { $0.failures[operation] = status }
    }

    public var readCount: Int { state.withLock { $0.reads } }
    public var sessionsEnded: Int { state.withLock { $0.sessionsEnded } }

    private func key(_ credential: Credential, _ domain: Domain) -> String {
        "\(domain.name)/\(credential.rawValue)"
    }

    private func check(_ operation: Operation, in state: inout State) throws {
        if let status = state.failures.removeValue(forKey: operation) {
            throw VaultError.keychain(status)
        }
    }

    public func read(_ credential: Credential, for domain: Domain) throws -> Data? {
        try state.withLock { state in
            state.reads += 1
            try check(.read, in: &state)
            return state.items[key(credential, domain)]
        }
    }

    public func write(_ data: Data, as credential: Credential, for domain: Domain) throws {
        try state.withLock { state in
            try check(.write, in: &state)
            state.items[key(credential, domain)] = data
        }
    }

    public func delete(_ credential: Credential, for domain: Domain) throws {
        try state.withLock { state in
            try check(.delete, in: &state)
            state.items[key(credential, domain)] = nil
        }
    }

    public func domains() throws -> [Domain] {
        try state.withLock { state in
            try check(.domains, in: &state)
            return Set(state.items.keys.compactMap { $0.split(separator: "/").first.flatMap { Domain(String($0)) } })
                .sorted()
        }
    }

    public func endSession() {
        state.withLock { $0.sessionsEnded += 1 }
    }
}
