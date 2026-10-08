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
        let result = try await runner().run(["info", "user", "alice@example.com"], as: example,
                                            extraEnvironment: Fixtures.mockEnvironment)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("alice@example.com"))
        #expect(try leftovers().isEmpty)
    }

    @Test func aRefreshedTokenIsWrittenBack() async throws {
        _ = try await runner().run(["info", "user", "alice@example.com"], as: example,
                                   extraEnvironment: Fixtures.mockEnvironment.merging(["GAM_MOCK_REFRESH": "1"]) { $1 })
        #expect(try store.read(.oauth2, for: example) == Data("refreshed-token-payload\n".utf8))
        #expect(try store.read(.oauth2Service, for: example) == Data("{\"placeholder\": \"oauth2service\"}".utf8))
    }

    @Test func missingCredentialsStopTheCallBeforeAnythingIsWritten() async throws {
        let other = Domain("other.example.org")!
        await #expect(throws: VaultError.missing(other, [.oauth2Service, .oauth2])) {
            try await runner().run(["info", "user", "alice@example.com"], as: other,
                                   extraEnvironment: Fixtures.mockEnvironment)
        }
        #expect(try leftovers().isEmpty)
    }

    @Test func aFailedCallIsStillWiped() async throws {
        let result = try await runner().run(["no-such-command"], as: example, extraEnvironment: Fixtures.mockEnvironment)
        #expect(result.exitCode == 2)
        #expect(try leftovers().isEmpty)
    }

    @Test func aTimedOutCallIsStillWiped() async throws {
        await #expect(throws: GamRunnerError.timedOut(seconds: 0)) {
            try await runner(binary: URL(filePath: "/bin/sleep")).run(["30"], as: example, timeout: .milliseconds(300))
        }
        #expect(try leftovers().isEmpty)
    }
}
