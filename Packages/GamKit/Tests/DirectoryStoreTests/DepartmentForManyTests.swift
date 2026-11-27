@testable import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import Stores
import TestSupport
import Testing
import Vault

/// A department for many (roadmap 2.1), previewed, confirmed and run through ChangeCore against the strict mock with its
/// argv log. Ports GamGUI's bulk department cases (`tests/test_users_web.py`'s `/users/bulk`, `test_retry_failures.py`,
/// `test_bulk.py`'s stop rules). The mock's directory: admin, alice (IT Director) and dana in /Staff, carol in /Students,
/// bob suspended; staff@example.com holds alice and bob.
@MainActor
@Suite("Department for many", .serialized)
final class DepartmentForManyTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-dept-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let runner: AuthenticatedRunner
    let base: URL
    let argvLog: URL
    let auditURL: URL
    let state: URL
    let gam = Fixtures.mockGam
    let confirmed = OperatorConfirmation(confirmed: true)

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        runner = AuthenticatedRunner(runner: GamRunner(binary: gam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        state = scratch.appending(path: "mock-state")
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func model(writer: AuthenticatedRunner? = nil) -> DepartmentForMany {
        let setup = setup
        let executor = Executor(runner: writer ?? runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
        let model = DepartmentForMany(executor: executor, setup: setup, directory: directory, runner: runner)
        model.environment = ["GAM_MOCK_STATE": state.path]
        return model
    }

    private func connect(_ domain: String = "example.com", admin: String = "admin@example.com") async throws {
        let folder = scratch.appending(path: "config-\(domain)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "\#(admin)"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
        await directory.load()
    }

    private func pending(_ model: DepartmentForMany) throws -> DepartmentForMany.Pending {
        guard case .previewing(let pending) = model.state else { throw NotPreviewing(state: "\(model.state)") }
        return pending
    }

    private func problem(_ model: DepartmentForMany) throws -> String {
        guard case .problem(let words) = model.state else { throw NotPreviewing(state: "\(model.state)") }
        return words
    }

    private func done(_ model: DepartmentForMany) throws -> DepartmentForMany.Done {
        guard case .done(let done) = model.state else { throw NotPreviewing(state: "\(model.state)") }
        return done
    }

    /// The organization writes the mock ran, as argv.
    private func writes() -> [[String]] { calls().filter { $0.count > 3 && $0[0] == "update" && $0[3] == "organization" } }

    private func calls() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls
    }

    private func wrapped(_ prefix: String) throws -> AuthenticatedRunner {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let script = scratch.appending(path: "mock-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(prefix)exec '\(gam.path)' \"$@\"\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        return AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base)
    }

    private static func user(_ email: String, suspended: Bool = false) -> GamUser {
        GamUser(record: ["primaryEmail": .string(email), "suspended": .bool(suspended)])
    }

    // MARK: who

    /// GamGUI's `_pasted` and `_bulk_targets`: commas or line ends, any case, once each; active users only, in the directory's order.
    @Test func pastedAddressesMatchActiveUsersOnly() {
        #expect(DepartmentForMany.pasted(" A@e.com, b@e.com\n\nA@E.COM \r\n c@e.com ,") == ["a@e.com", "b@e.com", "c@e.com"])
        let users = [Self.user("C@e.com"), Self.user("a@e.com"), Self.user("b@e.com", suspended: true), Self.user("z@e.com")]
        #expect(DepartmentForMany.targets(users, wanted: ["a@e.com", "b@e.com", "c@e.com"]).map(\.primaryEmail) == ["C@e.com", "a@e.com"])
    }

    /// Each step keeps the person's title, byte for byte GamGUI's `set_organization(title=u.title or "")`.
    @Test func eachStepKeepsTheTitle() async throws {
        try await connect()
        let model = model()
        await model.preview(department: " Sales ", who: .pasted("alice@example.com\ncarol@example.com\nbob@example.com\nnobody@example.com"))
        let pending = try pending(model)
        #expect(pending.department == "Sales" && pending.people.map(\.primaryEmail) == ["alice@example.com", "carol@example.com"])
        #expect(pending.notes == ["2 of the addresses aren't active users here and are left out."])
        #expect(pending.preview.steps.map(\.write.argv) == [
            ["update", "user", "alice@example.com", "organization", "title", "IT Director", "department", "Sales", "primary"],
            ["update", "user", "carol@example.com", "organization", "title", pending.people[1].title, "department", "Sales", "primary"],
        ])
        #expect(pending.preview.title == "Department “Sales” for 2 users")
        #expect(writes().isEmpty, "a preview writes nothing")
    }

    /// A group's active members, read live; a group that can't be read is said, never taken for an empty one.
    @Test func aGroupsActiveMembersAreTheTargets() async throws {
        try await connect()
        let model = model()
        await model.preview(department: "Ops", who: .group("staff@example.com"))
        #expect(try pending(model).people.map(\.primaryEmail) == ["alice@example.com"], "bob is suspended")
        await model.preview(department: "Ops", who: .group("nosuch@example.com"))
        #expect(try problem(model) == "Couldn't read nosuch@example.com's members, so nothing was previewed. nosuch@example.com isn't a group here.")
    }

    @Test func nothingIsHeldWithoutADepartmentOrAnyone() async throws {
        try await connect()
        let model = model()
        await model.preview(department: "  ", who: .pasted("alice@example.com"))
        #expect(try problem(model) == "Enter a department first.")
        await model.preview(department: "Ops", who: .pasted(" , \n"))
        #expect(try problem(model) == "Paste at least one address, or choose a group.")
        await model.preview(department: "Ops", who: .pasted("bob@example.com"))
        #expect(try problem(model).hasPrefix("No active users match."))
        #expect(writes().isEmpty)
    }

    // MARK: the run

    /// The confirm runs what the preview held, once; each department lands in the cached directory.
    @Test func theConfirmRunsThePreviewOnceAndPatchesTheDirectory() async throws {
        try await connect()
        let model = model()
        await model.preview(department: "Sales", who: .pasted("alice@example.com, dana@example.com"))
        await model.confirm(try pending(model), OperatorConfirmation())
        #expect(writes().isEmpty, "a bare confirm")
        #expect(try problem(model) == "This change needs confirmation — preview it, then confirm.")
        await model.preview(department: "Sales", who: .pasted("alice@example.com, dana@example.com"))
        let held = try pending(model)
        await model.confirm(held, confirmed)
        await model.confirm(held, confirmed)
        #expect(writes() == held.preview.steps.map(\.write.argv), "once, as held")
        let ran = try done(model)
        #expect(ran.message == "Set the department for 2 of 2 users." && !ran.partial && ran.retry == nil)
        #expect(directory.users?.first { $0.primaryEmail == "dana@example.com" }?.department == "Sales")
    }

    /// GamGUI's retry: a failure is named with why, and its retry previews exactly those people with the same department.
    @Test func aRetryPreviewsExactlyTheFailed() async throws {
        try await connect()
        let failing = try wrapped("""
            if [ "$1" = update ] && [ "$3" = carol@example.com ]; then echo 'ERROR: carol is busy' >&2; exit 1; fi

            """)
        let model = model(writer: failing)
        await model.preview(department: "Sales", who: .pasted("alice@example.com\ncarol@example.com\ndana@example.com"))
        await model.confirm(try pending(model), confirmed)
        let ran = try done(model)
        #expect(ran.message == "Set the department for 2 of 3 users." && ran.partial && ran.failedCount == 1)
        #expect(ran.failures.count == 1 && ran.failures[0].hasPrefix("carol@example.com \u{2014} "))
        let retry = try #require(ran.retry)
        #expect(retry.failed == ["carol@example.com"] && retry.department == "Sales")
        await model.previewRetry(retry)
        let again = try pending(model)
        #expect(again.isRetry && again.people.map(\.primaryEmail) == ["carol@example.com"])
        #expect(again.preview.title == "Department “Sales” retry \u{2014} 1 user")
    }

    /// A retry after a switch is refused: its people were the old tenant's.
    @Test func aRetryOnAnotherTenantIsRefused() async throws {
        try await connect()
        let failing = try wrapped("""
            if [ "$1" = update ]; then echo 'ERROR: busy' >&2; exit 1; fi

            """)
        let model = model(writer: failing)
        await model.preview(department: "Sales", who: .pasted("carol@example.com"))
        await model.confirm(try pending(model), confirmed)
        let retry = try #require(try done(model).retry)
        try await connect("example.org", admin: "admin@example.org")
        await model.previewRetry(retry)
        #expect(try problem(model) == Executor.PreviewRefusal.tenantChanged.message)
    }

    /// GamGUI's `stop_requested`: Stop ends the run after the write in flight; the rest never run.
    @Test func stopEndsTheRunAfterTheWriteInFlight() async throws {
        try await connect()
        let model = model(writer: try wrapped("[ \"$1\" = update ] && sleep 0.3\n"))
        await model.preview(department: "Sales", who: .pasted("admin@example.com, alice@example.com, carol@example.com, dana@example.com"))
        let pending = try pending(model)
        let run = Task { await model.confirm(pending, confirmed) }
        try await yieldWhile(every: .milliseconds(20)) { (model.progress?.done ?? 0) < 1 }
        await model.stop()
        #expect(model.progress?.stopping == true)
        await run.value
        let set = writes().count
        #expect(set >= 1 && set < 4, "\(set) ran")
        #expect(try done(model).message == "Stopped by you \u{2014} \(4 - set) not attempted. Set the department for \(set) of 4 before stopping.")
    }

    /// GamGUI's `stop_reason`: a failure every later person would share (a scope not granted) stops the run there.
    @Test func anAccountWideFailureStopsTheRun() async throws {
        try await connect()
        let failing = try wrapped("""
            if [ "$1" = update ]; then echo 'ERROR: 403: Request had insufficient authentication scopes' >&2; exit 50; fi

            """)
        let model = model(writer: failing)
        await model.preview(department: "Sales", who: .pasted("alice@example.com, carol@example.com, dana@example.com"))
        await model.confirm(try pending(model), confirmed)
        let ran = try done(model)
        #expect(ran.failedCount == 1 && ran.message.hasPrefix("Stopped: ") && ran.message.contains("The remaining 2 were not attempted."))
    }
}
