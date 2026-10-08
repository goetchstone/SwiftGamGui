import Dispatch
import Foundation

/// The app's credential store: GAM's three credentials per domain, in a `SecretStore` (the Keychain in
/// the app). It holds no copy of any secret itself: every call reads the store, and a shared
/// authentication session in the store keeps that to one prompt per burst.
public actor Vault {
    /// How long one authentication covers reads. Measured on `ContinuousClock`, which keeps counting
    /// while the Mac sleeps (GamGUI failure-log 2026-09-24: an expiry that paused during sleep).
    public static let defaultSessionLifetime: Duration = .seconds(600)

    private let store: any SecretStore
    private let sessionLifetime: Duration
    private let clock = ContinuousClock()
    private var sessionStarted: ContinuousClock.Instant?

    public init(store: any SecretStore, sessionLifetime: Duration = Vault.defaultSessionLifetime) {
        self.store = store
        self.sessionLifetime = sessionLifetime
    }

    /// Every stored credential for `domain`. Throws `missing` when a credential GAM needs is absent,
    /// and `keychain` for any other store failure.
    public func credentials(for domain: Domain) async throws -> [Credential: Secret] {
        if let started = sessionStarted, clock.now - started >= sessionLifetime {
            lock()
        }
        var found: [Credential: Secret] = [:]
        for credential in Credential.allCases {
            if let data = try await offMainThread({ [store] in try store.read(credential, for: domain) }) {
                found[credential] = Secret(data)
            }
        }
        sessionStarted = sessionStarted ?? clock.now
        let missing = Credential.required.filter { found[$0] == nil }
        guard missing.isEmpty else { throw VaultError.missing(domain, missing) }
        return found
    }

    /// Creates or replaces a credential.
    public func store(_ secret: Secret, as credential: Credential, for domain: Domain) async throws {
        try await offMainThread { [store] in try store.write(secret.bytes, as: credential, for: domain) }
    }

    /// Makes `set` the domain's whole set (import, copy): a credential not in it is removed, so an
    /// old `client_secrets.json` can't outlive the import that dropped it. A set is whole or absent: when
    /// a write fails part-way (a refused prompt, a locked Mac), the domain's credentials are removed
    /// rather than left a mix of old and new, which could pass Check access as neither tenant's set.
    /// If that removal is refused too, its error is the one thrown, since something is still stored.
    public func replaceSet(_ set: [Credential: Secret], for domain: Domain) async throws {
        let missing = Credential.required.filter { set[$0] == nil }
        guard missing.isEmpty else { throw VaultError.missing(domain, missing) }
        do {
            for credential in Credential.removalOrder.reversed() {
                if let secret = set[credential] {
                    try await store(secret, as: credential, for: domain)
                } else {
                    try await offMainThread { [store] in try store.delete(credential, for: domain) }
                }
            }
        } catch {
            try await remove(domain)
            throw error
        }
    }

    /// Replaces a credential only while it still holds `original`, the value the call started with: a
    /// removed one stays removed, and one replaced meanwhile (a re-import) keeps its new value. Returns
    /// whether it replaced anything. For GAM's refreshed `oauth2.txt`.
    @discardableResult
    public func refresh(_ secret: Secret, as credential: Credential, for domain: Domain, replacing original: Secret) async throws -> Bool {
        try await offMainThread { [store] in
            try store.replace(secret.bytes, as: credential, for: domain, ifCurrent: original.bytes)
        }
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
        sessionStarted = nil
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
