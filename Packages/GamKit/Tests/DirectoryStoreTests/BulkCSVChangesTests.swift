import ChangeCore
import Foundation
@testable import Directory
@testable import GamEngine
import Setup
@testable import Stores
import TestSupport
import Testing
import Vault

/// Change many people from a CSV (roadmap 4.6), against the strict mock: GamGUI's `tests/test_bulk_csv.py` screen cases.
/// The mock's alice is IT Director in IT, in /Staff, with no phone; its tree is /Sales, /Sales/West, /Staff and /Students.
@MainActor
@Suite("Bulk CSV changes", .serialized)
final class BulkCSVChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-bulkcsv-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let access: UserAccess
    let runner: AuthenticatedRunner
    let executor: Executor
    let argvLog: URL
    let state: URL
    let auditURL: URL
    let changes: BulkCSVChanges
    static let alice = "alice@example.com"

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        state = scratch.appending(path: "state")
        auditURL = scratch.appending(path: "audit.jsonl")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": state.path]
        let setup = setup
        executor = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
        changes = BulkCSVChanges(executor: executor, setup: setup, directory: directory, access: access, runner: runner)
        changes.environment = ["GAM_MOCK_STATE": state.path]
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect() async throws {
        let folder = scratch.appending(path: "config")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: "admin@example.com").write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
        await directory.load()
    }

    /// The writes the mock ran, as argv.
    private func writes() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.starts(with: ["update"]) }
    }

    private func pending() throws -> BulkCSVChanges.Pending {
        guard case .previewing(let pending) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return pending
    }

    @Test func thePreviewShowsNowAndAfterHoldsItAndWritesNothing() async throws {
        try await connect()
        await changes.preview(Array("email,title,phone\nalice@example.com,Head of IT,'+1 555 0100\n".utf8))
        let pending = try pending()
        let change = try #require(pending.changes.first)
        #expect(change.before == ["title": "IT Director", "phone": ""] && change.after == ["title": "Head of IT", "phone": "+1 555 0100"])
        #expect(pending.writes == 1 && pending.blanks == 1, "an empty phone before can't be put back by the undo")
        #expect(String(decoding: pending.before, as: UTF8.self) == "email,title,department,phone,org_unit\r\nalice@example.com,IT Director,,,\r\n")
        #expect(writes().isEmpty)
    }

    /// `test_change_runs_exactly_the_held_argv_once_audited`: the profile, then the move, once; a second confirm runs nothing.
    @Test func theChangeRunsExactlyTheHeldArgvOnceAudited() async throws {
        try await connect()
        await changes.preview(Array("email,title,org_unit\nalice@example.com,Head of IT,/\n".utf8))
        let pending = try pending()
        await changes.confirm(pending, OperatorConfirmation(confirmed: true))
        guard case .done(let done) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(done.message == "Changed 1 of 1 person from the CSV." && !done.partial)
        #expect(writes() == [["update", "user", Self.alice, "organization", "title", "Head of IT", "department", "IT", "primary"],
                             ["update", "org", "/", "move", "user", Self.alice]])
        let actions = AuditLog.records(at: auditURL).filter { $0["extra"]?.object?["phase"]?.string == "end" }.compactMap { $0["action"]?.string }
        #expect(actions.filter { $0 == "updateProfile" }.count == 1)
        await changes.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(writes().count == 2, "a preview runs once")
    }

    /// `test_someone_who_changed_since_the_preview_is_left_as_they_are`: a phone added elsewhere after the preview, and the
    /// list sent from the old read would delete it: nothing changes for them.
    @Test func someoneWhoChangedSinceThePreviewIsLeftAsTheyAre() async throws {
        try await connect()
        await changes.preview(Array("email,department\nalice@example.com,Sales\n".utf8))
        let pending = try pending()
        try FileManager.default.createDirectory(at: state.appending(path: "phones"), withIntermediateDirectories: true)
        try Data(#"[{"type": "home", "value": "555 0002"}]"#.utf8).write(to: state.appending(path: "phones/\(Self.alice)"))
        await changes.confirm(pending, OperatorConfirmation(confirmed: true))
        guard case .done(let done) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(done.failedCount == 1 && done.failures.first?.contains("changed since the preview") == true)
        #expect(writes().isEmpty)
    }

    /// Every row refused, or nothing to change: nothing is held, and what the file said is shown.
    @Test func aFileThatChangesNothingHoldsNothing() async throws {
        try await connect()
        await changes.preview(Array("email,title,org_unit\nnobody@example.com,X,\nalice@example.com,IT Director,/Nowhere\n".utf8))
        guard case .idle = changes.state, let nothing = changes.nothing else { Issue.record("\(changes.state)"); return }
        #expect(nothing.refused.count == 2 && nothing.refused[0].contains("isn't an account here") && nothing.refused[1].contains("/Nowhere"))
        await changes.preview(Array("email,title\nalice@example.com,IT Director\n".utf8))
        #expect(changes.nothing?.unchanged == 1 && changes.nothing?.refused.isEmpty == true)
        #expect(writes().isEmpty)
    }

    /// The check before each write is held to the account its own write changes: any other is refused before anything is held.
    @Test func theCheckIsOfTheAccountTheWriteChanges() async throws {
        try await connect()
        let profile = try GamCommands.updateProfile(email: Self.alice, phones: [])
        let move = GamCommands.moveUserToOrgUnit(orgUnit: "/", email: Self.alice)
        let other = GamCommands.addGroupMember(group: "sales@example.com", member: Self.alice)
        for (write, email, holds) in [(profile, Self.alice, true), (profile, "bob@example.com", false), (move, Self.alice, true),
                                      (move, "bob@example.com", false), (other, Self.alice, false)] {
            let step = WriteStep(write, target: Self.alice, summary: "", keepFirst: .unchanged(email: email, held: ""))
            switch await executor.preview([step]) {
            case .success(let held):
                #expect(holds, "\(write.argv) checked as \(email)")
                await executor.discard(held.id)
            case .failure(let refusal):
                #expect(!holds && refusal == .badKeep(step: 0), "\(write.argv) checked as \(email): \(refusal)")
            }
        }
        #expect(writes().isEmpty)
    }

    /// Review of #220: a Stop between a person's profile and their move says their title changed, never "not attempted".
    @Test func aStopBetweenTheProfileAndTheMoveSaysWhatChanged() async throws {
        try await connect()
        await changes.preview(Array("email,title,org_unit\nalice@example.com,Head of IT,/\n".utf8))
        let pending = try pending()
        let done = BulkCSVChanges.done(pending, [.succeeded(output: ""), .skipped(reason: Executor.stopped)], note: "")
        #expect(done.partial && done.failedCount == 1)
        #expect(done.failures == ["alice@example.com \u{2014} Their title changed; the move to / wasn't attempted: \(Executor.stopped)"])
        #expect(!done.message.contains("not attempted"), "\(done.message)")
        changes.dismiss()
    }
}
