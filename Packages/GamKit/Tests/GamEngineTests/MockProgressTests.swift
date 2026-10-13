import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock prints GAM's progress lines where GAM 7.48.22 prints them: on stderr, in the words its
/// printers write (`gam/__init__.py:2681-2722`, `show_gettings` on by default), before a failure as well as on
/// success. The mock once printed the report's line on stdout in words GAM never writes, and printed none for
/// deprovision, so no test saw a per-entity "Getting …" line reach `GamError`, which read it as an unknown
/// failure that outranked the real one (failure-log 2026-10-13, "GAM's progress read as an error").
@Suite("Mock progress")
struct MockProgressTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// One call of the mock, with GAM's first-run banner (the lines naming the config folder) dropped. `state`,
    /// when given, is the mock's state folder.
    private func run(_ argv: [String], state: URL? = nil) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        let result = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
        let data = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(config.lastPathComponent) }.joined(separator: "\n")
        return (result.exitCode, data, result.stderr)
    }

    static let report = GamCommands.reportUsers(date: "2026-06-16", parameters: ["accounts:used_quota_in_mb"]).argv

    /// doReport (:14505, :14558): "Getting Reports for all users", then the page count, which GAM writes
    /// after a CR and ends with CR LF (`show_gettings_got_nl` off, :5260-5271, :5620-5623). Stdout is the CSV
    /// alone.
    @Test func theReportsProgressIsOnStderr() async throws {
        let read = try await run(Self.report)
        #expect(read.exitCode == 0)
        #expect(Self.bytes(read.stderr) == Self.bytes("Getting Reports for all users\n\rGot 3 Reports for all users on 2026-06-16...\r\n"))
        let rows = GamOutput.records(read.stdout)
        #expect(rows.compactMap { $0["email"]?.string } == ["alice@example.com", "bob@example.com", "carol@example.com"])
        #expect(rows.first?["accounts:used_quota_in_mb"]?.string.map(Self.bytes) == Self.bytes("608873"))
    }

    /// A refused report (:14595-14596, accessErrorExit, :669-701): the refusal is what the operator sees,
    /// not the progress line before it.
    @Test func aRefusedReportSaysItWasRefused() async throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try Data().write(to: state.appending(path: "noreports"))
        let read = try await run(Self.report, state: state)
        #expect(read.exitCode == 61)
        #expect(read.stdout.isEmpty)
        let refusal = "ERROR: Customer ID: my_customer, Domain: example.com, User: admin@example.com, Access Forbidden"
        #expect(Self.bytes(read.stderr) == Self.bytes("Getting Reports for all users\n\n\(refusal)\n"))
        let error = GamError(exitCode: read.exitCode, stderr: read.stderr, argv: Self.report)
        #expect(error.kind == .permissionDenied && error.kinds == [.permissionDenied])
        #expect(Self.bytes(error.message) == Self.bytes("GAM failed (permission_denied, exit=61): \(refusal)"))
    }

    /// deprovisionUser (:74192, :74213, :74232) says what it is getting before each part, one user so no
    /// counter. A refused sign-out is the only kind of the failure.
    @Test func deprovisionSaysWhatItIsGetting() async throws {
        func getting(_ user: String) -> String {
            ["Application Specific Password IDs", "Backup Verification Codes", "Access Tokens"]
                .map { "Getting \($0) for \(user)\n" }.joined()
        }
        let done = try await run(GamCommands.deprovisionUser(email: "bob@example.com").argv)
        #expect(done.exitCode == 0)
        #expect(Self.bytes(done.stderr) == Self.bytes(getting("bob@example.com")))

        let user = "SIGNOUTFAIL@example.com"
        let refused = try await run(GamCommands.deprovisionUser(email: user).argv)
        let line = "User: \(user), Sign Out Failed: Not Authorized to access this resource/api"
        #expect(refused.exitCode == 50)
        #expect(Self.bytes(refused.stderr) == Self.bytes(getting(user) + line + "\n"))
        let error = GamError(exitCode: refused.exitCode, stderr: refused.stderr)
        #expect(error.kinds == [.scopeMissing], "no unknown failure beside it for a best-effort caller to refuse")
        #expect(Self.bytes(error.message) == Self.bytes("GAM failed (scope_missing, exit=50): \(line)"))
    }
}
