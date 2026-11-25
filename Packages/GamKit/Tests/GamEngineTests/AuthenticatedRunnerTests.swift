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

    /// Plan F4's review: the one public door a read takes to GAM refuses a read GAM would read as carrying `todrive`, in any
    /// spelling, whichever builder made it, before the Vault is read: no Sheet is made with no preview, record or confirm.
    @Test func aReadCarryingTodriveNeverReachesGam() async throws {
        let log = base.appending(path: "argv.log")
        for spelling in ["todrive", "To_Drive", " TODRIVE "] {
            await #expect(throws: GamRunnerError.self) {
                _ = try await runner().run(GamRead(["user", "alice@example.com", "print", "delegates", spelling]), as: example,
                                           extraEnvironment: Fixtures.mockEnvironment.merging(["GAM_MOCK_ARGV_LOG": log.path]) { $1 })
            }
        }
        #expect(!FileManager.default.fileExists(atPath: log.path), "GAM never ran")
        #expect(try leftovers().isEmpty, "no credentials materialized")
    }

    @Test func aRefreshedTokenIsWrittenBack() async throws {
        _ = try await runner().run(GamRead(["info", "user", "alice@example.com"]), as: example,
                                   extraEnvironment: Fixtures.mockEnvironment.merging(["GAM_MOCK_REFRESH": "1"]) { $1 })
        #expect(try store.read(.oauth2, for: example) == Data("refreshed-token-payload\n".utf8))
        #expect(try store.read(.oauth2Service, for: example) == Data("{\"placeholder\": \"oauth2service\"}".utf8))
    }

    /// A gam that says it has started, then refreshes its token only once the test lets it: a handshake, not a sleep, so a
    /// busy runner can't put the test's change before the call (failure log 2026-11-14, as 2026-11-13's stop timing).
    final class HeldGam {
        let folder = FileManager.default.temporaryDirectory.appending(path: "held-gam-\(UUID().uuidString)")
        var script: URL { folder.appending(path: "gam") }
        var started: URL { folder.appending(path: "started") }
        var go: URL { folder.appending(path: "go") }

        init() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Bounded: it refreshes after 30 s even without the word, so a broken test fails rather than hangs.
            let body = "#!/bin/sh\n: > '\(started.path)'\ni=0\nwhile [ ! -e '\(go.path)' ] && [ $i -lt 600 ]; do sleep 0.05; "
                + "i=$((i+1)); done\nprintf 'refreshed\\n' > \"$GAMCFGDIR/oauth2.txt\"\n"
            try Data(body.utf8).write(to: script)
            chmod(script.path, 0o755)
        }
        deinit { try? FileManager.default.removeItem(at: folder) }

        /// Returns once gam is running, its credentials loaded.
        func waitUntilStarted() async throws {
            try await yieldWhile(every: .milliseconds(50)) { !FileManager.default.fileExists(atPath: started.path) }
        }

        func letItFinish() throws { try Data().write(to: go) }
    }

    @Test func aDomainRemovedMidCallStaysRemoved() async throws {
        // A gam that refreshes its token only after the operator has removed the domain.
        let gam = try HeldGam()
        let vault = Vault(store: store)
        let authenticated = AuthenticatedRunner(runner: GamRunner(binary: gam.script), vault: vault, runtimeDirectory: base)
        async let call = authenticated.run(GamRead(["info"]), as: example)
        try await gam.waitUntilStarted()
        try await vault.remove(example)
        try gam.letItFinish()
        _ = try await call
        #expect(try await vault.domains().isEmpty)
        #expect(try store.read(.oauth2, for: example) == nil)
    }

    @Test func aDomainReImportedMidCallKeepsItsNewToken() async throws {
        // PR #8's review: a load's write-back replaced a re-imported token with the old admin's.
        let gam = try HeldGam()
        let vault = Vault(store: store)
        let authenticated = AuthenticatedRunner(runner: GamRunner(binary: gam.script), vault: vault, runtimeDirectory: base)
        async let call = authenticated.run(GamRead(["info"]), as: example)
        try await gam.waitUntilStarted()
        try store.write(Data("new-admin-token".utf8), as: .oauth2, for: example)
        try gam.letItFinish()
        _ = try await call
        #expect(try store.read(.oauth2, for: example) == Data("new-admin-token".utf8))
    }

    @Test func gamsFirstRunBannerNeverReachesTheCaller() async throws {
        // Real GAM prints it on stdout on every call, each having a fresh config directory (checked on
        // the 7.48.22 build; the mock now does the same). The users read the app sends: the mock models
        // only that shape.
        let result = try await runner().run(GamCommands.printUsers(fields: GamCommands.cacheFields), as: example,
                                            extraEnvironment: Fixtures.mockEnvironment)
        #expect(result.exitCode == 0, "\(result.stderr)")
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
