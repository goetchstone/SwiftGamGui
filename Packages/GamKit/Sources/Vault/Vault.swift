import Dispatch
import Foundation

/// The app's credential store: GAM's three credentials per domain, in a `SecretStore` (the Keychain in
/// the app). It holds no copy of any secret itself: every call reads the store, and a shared
/// authentication session in the store keeps that to one prompt per burst.
public actor Vault {
    private let store: any SecretStore

    public init(store: any SecretStore) {
        self.store = store
    }

    /// Every stored credential for `domain`. Throws `missing` when a credential GAM needs is absent,
    /// and `keychain` for any other store failure.
    public func credentials(for domain: Domain) async throws -> [Credential: Secret] {
        var found: [Credential: Secret] = [:]
        for credential in Credential.allCases {
            if let data = try await offMainThread({ [store] in try store.read(credential, for: domain) }) {
                found[credential] = Secret(data)
            }
        }
        let missing = Credential.required.filter { found[$0] == nil }
        guard missing.isEmpty else { throw VaultError.missing(domain, missing) }
        return found
    }

    public func store(_ secret: Secret, as credential: Credential, for domain: Domain) async throws {
        try await offMainThread { [store] in try store.write(secret.bytes, as: credential, for: domain) }
    }

    public func domains() async throws -> [Domain] {
        try await offMainThread { [store] in try store.domains() }
    }

    /// Removes the domain's credentials, the most dangerous first. Stops at the first refusal, so a
    /// domain is never reported gone while something of it is still stored.
    public func remove(_ domain: Domain) async throws {
        for credential in Credential.removalOrder {
            try await offMainThread { [store] in try store.delete(credential, for: domain) }
        }
    }

    /// Ends the authenticated session: the next read prompts again.
    public func lock() {
        store.endSession()
    }

    /// Keychain calls can block on a Touch ID prompt: run them on a GCD thread, never on the
    /// cooperative pool or the main thread.
    private func offMainThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
