import Foundation
import Security
import Testing
@testable import Vault

@Suite("Vault")
struct VaultTests {
    let example = Domain("example.com")!

    private func filled(_ store: MemoryStore, _ credentials: [Credential] = Credential.allCases) throws {
        for credential in credentials {
            try store.write(Data("placeholder-\(credential.rawValue)".utf8), as: credential, for: example)
        }
    }

    @Test func aDomainHasOneSpelling() {
        #expect(Domain("  Example.COM\n")?.name == "example.com")
        #expect(Domain("Example.com") == Domain("example.com"))
        for bad in ["", "nodot", "a/b.com", "-x.com", "x.com.", "a..b.com", "ex ample.com", "é.com"] {
            #expect(Domain(bad) == nil, "\(bad) should be refused")
        }
    }

    @Test func aSecretNeverPrintsItsBytes() {
        let secret = Secret(Data("hunter2-private-key".utf8))
        var dumped = ""
        dump(secret, to: &dumped)
        for text in ["\(secret)", String(reflecting: secret), dumped] {
            #expect(!text.contains("hunter2"))
        }
    }

    @Test func credentialsAreReturnedWhenTheRequiredOnesExist() async throws {
        let store = MemoryStore()
        try filled(store, [.oauth2Service, .oauth2])
        let found = try await Vault(store: store).credentials(for: example)
        #expect(Set(found.keys) == [.oauth2Service, .oauth2])
    }

    @Test func aMissingRequiredCredentialIsReportedByName() async throws {
        let store = MemoryStore()
        try filled(store, [.oauth2, .clientSecrets])
        await #expect(throws: VaultError.missing(example, [.oauth2Service])) {
            try await Vault(store: store).credentials(for: example)
        }
    }

    @Test func aRefusedReadIsAnErrorNotAbsence() async throws {
        let store = MemoryStore()
        try filled(store)
        store.failNext(.read, with: errSecUserCanceled)
        await #expect(throws: VaultError.keychain(errSecUserCanceled)) {
            try await Vault(store: store).credentials(for: example)
        }
    }

    @Test func removalGoesMostDangerousFirstAndStopsAtARefusal() async throws {
        let store = MemoryStore()
        try filled(store)
        let vault = Vault(store: store)
        store.failNext(.delete, with: errSecInteractionNotAllowed)
        await #expect(throws: VaultError.keychain(errSecInteractionNotAllowed)) {
            try await vault.remove(example)
        }
        // Nothing was removed, so the domain is still listed and still usable.
        #expect(try await vault.domains() == [example])
        try await vault.remove(example)
        #expect(try await vault.domains().isEmpty)
        #expect(try store.read(.oauth2Service, for: example) == nil)
    }

    @Test func aFailedWriteKeepsTheOldValue() async throws {
        let store = MemoryStore()
        try filled(store)
        store.failNext(.write, with: errSecInteractionNotAllowed)
        await #expect(throws: VaultError.keychain(errSecInteractionNotAllowed)) {
            try await Vault(store: store).store(Secret(Data("new".utf8)), as: .oauth2, for: example)
        }
        #expect(try store.read(.oauth2, for: example) == Data("placeholder-oauth2".utf8))
    }

    @Test func refreshNeverCreatesARemovedCredential() async throws {
        let vault = Vault(store: MemoryStore())
        #expect(try await vault.refresh(Secret(Data("token".utf8)), as: .oauth2, for: example,
                                        replacing: Secret(Data("placeholder-oauth2".utf8))) == false)
        #expect(try await vault.domains().isEmpty)
    }

    @Test func theAuthenticatedSessionExpires() async throws {
        let store = MemoryStore()
        try filled(store)
        _ = try await Vault(store: store).credentials(for: example)
        _ = try await Vault(store: store).credentials(for: example)
        #expect(store.sessionsEnded == 0, "within the default lifetime nothing is ended")
        let shortLived = Vault(store: store, sessionLifetime: .zero)
        _ = try await shortLived.credentials(for: example)
        _ = try await shortLived.credentials(for: example)
        #expect(store.sessionsEnded == 1, "the second read starts a fresh session")
    }

    @Test func lockingEndsTheAuthenticatedSession() async {
        let store = MemoryStore()
        await Vault(store: store).lock()
        #expect(store.sessionsEnded == 1)
    }

    @Test func storingReplacesTheValue() async throws {
        let store = MemoryStore()
        try filled(store)
        let vault = Vault(store: store)
        try await vault.store(Secret(Data("new".utf8)), as: .oauth2, for: example)
        #expect(try await vault.credentials(for: example)[.oauth2] == Secret(Data("new".utf8)))
    }

    @Test func aReplacedSetIsWholeOrAbsent() async throws {
        let store = MemoryStore()
        try filled(store)
        let vault = Vault(store: store)
        let new: [Credential: Secret] = [.oauth2Service: Secret(Data("new-key".utf8)), .oauth2: Secret(Data("new-token".utf8))]
        // Incomplete: refused before anything is written.
        await #expect(throws: VaultError.missing(example, [.oauth2Service])) {
            try await vault.replaceSet([.oauth2: Secret(Data("x".utf8))], for: example)
        }
        #expect(try store.read(.oauth2, for: example) == Data("placeholder-oauth2".utf8))
        // Whole: the old client_secrets.json goes with the set that dropped it.
        try await vault.replaceSet(new, for: example)
        #expect(try store.read(.oauth2Service, for: example) == Data("new-key".utf8))
        #expect(try store.read(.clientSecrets, for: example) == nil)
        // Refused part-way: nothing of either set is left.
        store.failNext(.write, with: errSecUserCanceled, skipping: 1)
        await #expect(throws: VaultError.keychain(errSecUserCanceled)) {
            try await vault.replaceSet([.oauth2Service: Secret(Data("k3".utf8)), .oauth2: Secret(Data("t3".utf8))], for: example)
        }
        #expect(try store.domains().isEmpty)
    }
}
