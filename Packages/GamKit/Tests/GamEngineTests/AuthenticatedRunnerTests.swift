import Foundation
import Testing
@testable import GamEngine
import TestSupport
import Vault

@Suite("AuthenticatedRunner", .serialized)
struct AuthenticatedRunnerTests {
    let example = Domain("example.com")!
    let base: URL
    let store = MemoryStore()

    init() throws {
        base = try RuntimeDirectory.prepare(
            FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-run-\(UUID().uuidString)"))
        for credential in Credential.allCases {
            try store.write(Data("{\"placeholder\": \"\(credential.rawValue)\"}".utf8), as: credential, for: example)
        }
    }

    private func runner(binary: URL = Fixtures.mockGam) -> AuthenticatedRunner {
        AuthenticatedRunner(runner: GamRunner(binary: binary), vault: Vault(store: store), runtimeDirectory: base)
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix("gamcfg-") }
    }

    @Test func theCredentialsReachGamAndAreWipedAfterward() async throws {
        // The mock refuses any authenticated call whose GAMCFGDIR lacks the credential files.
        let result = try await runner().run(GamRead(["info", "user", "alice@example.com"]), as: example,
                                            extraEnvironment: Fixtures.mockEnvironment)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("alice@example.com"))
        #expect(try leftovers().isEmpty)
    }

    @Test func aRefreshedTokenIsWrittenBack() async throws {
        _ = try await runner().run(GamRead(["info", "user", "alice@example.com"]), as: example,
                                   extraEnvironment: Fixtures.mockEnvironment.merging(["GAM_MOCK_REFRESH": "1"]) { $1 })
        #expect(try store.read(.oauth2, for: example) == Data("refreshed-token-payload\n".utf8))
        #expect(try store.read(.oauth2Service, for: example) == Data("{\"placeholder\": \"oauth2service\"}".utf8))
    }

    @Test func aDomainRemovedMidCallStaysRemoved() async throws {
        // A gam that refreshes its token only after the operator has removed the domain.
        let script = FileManager.default.temporaryDirectory.appending(path: "slow-gam-\(UUID().uuidString)")
        try Data("#!/bin/sh\nsleep 0.6\nprintf 'refreshed\\n' > \"$GAMCFGDIR/oauth2.txt\"\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        defer { try? FileManager.default.removeItem(at: script) }
        let vault = Vault(store: store)
        let authenticated = AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base)
        async let call = authenticated.run(GamRead(["info"]), as: example)
        try await Task.sleep(for: .milliseconds(250))
        try await vault.remove(example)
        _ = try await call
        #expect(try await vault.domains().isEmpty)
        #expect(try store.read(.oauth2, for: example) == nil)
    }

    @Test func aDomainReImportedMidCallKeepsItsNewToken() async throws {
        // PR #8's review: a load's write-back replaced a re-imported token with the old admin's.
        let script = FileManager.default.temporaryDirectory.appending(path: "slow-gam-\(UUID().uuidString)")
        try Data("#!/bin/sh\nsleep 0.6\nprintf 'refreshed\\n' > \"$GAMCFGDIR/oauth2.txt\"\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        defer { try? FileManager.default.removeItem(at: script) }
        let vault = Vault(store: store)
        let authenticated = AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base)
        async let call = authenticated.run(GamRead(["info"]), as: example)
        try await Task.sleep(for: .milliseconds(250))
        try store.write(Data("new-admin-token".utf8), as: .oauth2, for: example)
        _ = try await call
        #expect(try store.read(.oauth2, for: example) == Data("new-admin-token".utf8))
    }

    @Test func gamsFirstRunBannerNeverReachesTheCaller() async throws {
        // Real GAM prints it on stdout on every call, each having a fresh config directory (checked on
        // the 7.48.22 build; the mock now does the same).
        let result = try await runner().run(GamRead(["print", "users"]), as: example, extraEnvironment: Fixtures.mockEnvironment)
        #expect(!result.stdout.contains("gamcache") && !result.stdout.contains("Initialized"))
        #expect(result.stdout.contains("alice@example.com"))
        let folder = URL(filePath: "/tmp/swiftgamgui-run/gamcfg-1")
        let stdout = "Created: /tmp/swiftgamgui-run/gamcfg-1/gamcache\r\nConfig File: /tmp/swiftgamgui-run/gamcfg-1/gam.cfg, Initialized\n"
            + "primaryEmail,JSON\r\na@example.com,\"{\"\"name\"\": \"\"x\u{2028}y\"\"}\"\n"
        #expect(AuthenticatedRunner.withoutConfigNoise(stdout, configDirectory: folder)
                == "primaryEmail,JSON\r\na@example.com,\"{\"\"name\"\": \"\"x\u{2028}y\"\"}\"\n",
                "only the banner goes; the data keeps its line endings and its U+2028")
        let crlf = "Created: /tmp/swiftgamgui-run/gamcfg-1/gamcache\r\nprimaryEmail\r\na@example.com\r\n"
        #expect(AuthenticatedRunner.withoutConfigNoise(crlf, configDirectory: folder) == "primaryEmail\r\na@example.com\r\n",
                "a CRLF banner line goes alone, not with the data after it")
    }

    @Test func missingCredentialsStopTheCallBeforeAnythingIsWritten() async throws {
        let other = Domain("other.example.org")!
        await #expect(throws: VaultError.missing(other, [.oauth2Service, .oauth2])) {
            try await runner().run(GamRead(["info", "user", "alice@example.com"]), as: other,
                                   extraEnvironment: Fixtures.mockEnvironment)
        }
        #expect(try leftovers().isEmpty)
    }

    @Test func aFailedCallIsStillWiped() async throws {
        let result = try await runner().run(GamRead(["no-such-command"]), as: example, extraEnvironment: Fixtures.mockEnvironment)
        #expect(result.exitCode == 2)
        #expect(try leftovers().isEmpty)
    }

    @Test func aTimedOutCallIsStillWiped() async throws {
        await #expect(throws: GamRunnerError.timedOut(seconds: 0)) {
            try await runner(binary: URL(filePath: "/bin/sleep")).run(GamRead(["30"]), as: example, timeout: .milliseconds(300))
        }
        #expect(try leftovers().isEmpty)
    }
}
