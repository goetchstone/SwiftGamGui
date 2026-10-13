import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock reads a person's mail delegates the way GAM 7.48.22's `printShowDelegates` does
/// (gam/__init__.py:77232-77313): "Getting all Delegates for <user>" on stderr, the CSV on stdout, and for a
/// person without Gmail, Gmail's "Mail service not enabled" read as `serviceNotAvailable`
/// (gamlib/glgapi.py:311) and reported by `userGmailServiceNotEnabledWarning` (:2533, :2498-2502):
/// "User: <user>, Gmail Service/App not enabled", exit 73 (`SERVICE_NOT_APPLICABLE_RC`). Offboarding's
/// preview reads the leaver's delegates and warns when it can't (GamGUI failure-log 2026-09-23: a swallowed
/// failure of this read made the preview look clean).
@Suite("Mock delegates")
struct MockDelegatesTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    private func run(_ argv: [String], nogmail: String? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-delegates-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: state)
        }
        if let nogmail {
            try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
            try Data().write(to: state.appending(path: "nogmail/\(nogmail)"))
        }
        var environment = Fixtures.mockEnvironment
        environment["GAM_MOCK_STATE"] = state.path
        return try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
    }

    @Test func aPersonsDelegatesAreTheirs() async throws {
        let result = try await run(GamCommands.printDelegates(email: "carol@example.com").argv)
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout.hasSuffix("User,delegateAddress,delegationStatus\ncarol@example.com,helpdesk@example.com,accepted\n"))
        #expect(result.stderr.hasSuffix("Getting all Delegates for carol@example.com\n"))
    }

    @Test func aPersonWithoutGmailFailsAsGamDoes() async throws {
        let result = try await run(GamCommands.printDelegates(email: "carol@example.com").argv, nogmail: "carol@example.com")
        #expect(result.exitCode == 73)
        #expect(result.stderr.hasSuffix("Getting all Delegates for carol@example.com\nUser: carol@example.com, Gmail Service/App not enabled\n"),
                "\(result.stderr)")
        #expect(result.stdout.hasSuffix("User,delegateAddress,delegationStatus\n"), "GAM writes the header with no rows")
        let error = GamError(exitCode: result.exitCode, stderr: result.stderr)
        #expect(error.kind == .serviceNotEnabled)
        #expect(error.message == "GAM failed (service_not_enabled, exit=73): User: carol@example.com, Gmail Service/App not enabled")
        // Someone else's Gmail is on.
        let alice = try await run(GamCommands.printDelegates(email: "alice@example.com").argv, nogmail: "carol@example.com")
        #expect(alice.exitCode == 0 && alice.stdout.contains("assistant@example.com"))
    }
}
