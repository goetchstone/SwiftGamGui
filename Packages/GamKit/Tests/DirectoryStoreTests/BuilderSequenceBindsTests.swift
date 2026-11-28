import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Roadmap 5.2 against the strict mock: GamGUI's `tests/test_sequence_binds.py` screen cases. A later step's field takes
/// `=stepN.Column` from an earlier read; the read runs at the preview, and the filled-in steps are what is held and run.
@MainActor
@Suite("Builder sequence binds", .serialized)
final class BuilderSequenceBindsTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-binds-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: BuilderChanges
    let argvLog: URL
    let auditURL: URL
    let state: URL

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        state = scratch.appending(path: "mock-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), currentActor: { @MainActor in setup.connectedAdmin },
                                adminAccountID: { @MainActor in setup.connectedAdminID }, tenant: { @MainActor in setup.active.map { ($0, setup.generation) } },
                                extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                                                   "GAM_MOCK_STATE": state.path])
        let access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_STATE": state.path]
        changes = BuilderChanges(executor: executor, setup: setup, directory: directory, access: access,
                                 readAudit: ReadAudit(log: AuditLog(url: auditURL)))
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect() async throws {
        let folder = scratch.appending(path: "gamcfg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: "admin@example.com").write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
        await directory.load()
    }

    private func command(_ id: String) throws -> CuratedCommand {
        try #require(CuratedCommand.all.first { $0.id == id })
    }

    private func pending() throws -> BuilderChanges.Pending {
        guard case .previewing(let pending) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return pending
    }

    private var problem: String? {
        if case .problem(let words) = changes.state { words } else { nil }
    }

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

    private func writes() -> [[String]] { calls().filter { $0.first == "user" || $0.first == "update" } }

    /// Add each of step 1's people to staff@ (a change that signs nobody out: the mock's read lists the admin too).
    private func queueTheAdd(_ column: String = "primaryEmail") throws {
        changes.addToSequence(try command("build.add_group_member"),
                              values: ["group": "staff@example.com", "member": "=step1.\(column)", "role": "member"])
    }

    private func queueTheRead() throws {
        changes.addToSequence(try command("build.find_users"), values: ["query": "orgUnitPath=/Staff"])
        #expect(changes.sequenceRefusal == nil && changes.sequence.last?.isRead == true)
    }

    /// `test_a_write_runs_once_for_each_row_of_an_earlier_read`: shown before it runs, held filled in, run once each.
    @Test func aWriteRunsOnceForEachRowOfAnEarlierRead() async throws {
        try await connect()
        try queueTheRead()
        try queueTheAdd()
        #expect(changes.sequenceRefusal == nil, "\(changes.sequenceRefusal ?? "")")
        let bound = try #require(changes.sequence.last)
        #expect(bound.source(in: changes.sequence) == 1 && bound.target == "each primaryEmail")
        await changes.previewSequence()
        let pending = try pending()
        let people = pending.preview.steps.compactMap(\.shownArgv.last)
        #expect(!people.isEmpty && people.allSatisfy { $0.hasSuffix("@example.com") }, "\(people)")
        #expect(writes().isEmpty, "the read ran; nothing was written")
        #expect(calls().contains { $0.starts(with: ["print", "users"]) })
        await changes.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(writes() == people.map { ["update", "group", "staff@example.com", "add", "member", $0] })
    }

    @Test func onlyAReadCanFeedALaterStep() async throws {
        try await connect()
        let signout = try command("build.signout_user")
        let field = try #require(signout.fields.first).key
        changes.addToSequence(signout, values: [field: "carol@example.com"])
        changes.addToSequence(signout, values: [field: "=step1.primaryEmail"])
        #expect(changes.sequenceRefusal?.contains("only a read's result") == true && changes.sequence.count == 1)
        changes.addToSequence(signout, values: [field: "=step5.primaryEmail"])
        #expect(changes.sequenceRefusal == "There's no step 5 before this one.")
    }

    @Test func movingTheReadAfterItsStepBlocksThePreview() async throws {
        try await connect()
        try queueTheRead()
        let signout = try command("build.signout_user")
        changes.addToSequence(signout, values: [try #require(signout.fields.first).key: "=step1.primaryEmail"])
        changes.moveInSequence(from: 0, to: 1)
        await changes.previewSequence()
        #expect(problem?.contains("isn't before it any more") == true && writes().isEmpty)
    }

    @Test func aColumnTheReadLacksBlocksThePreview() async throws {
        try await connect()
        try queueTheRead()
        let signout = try command("build.signout_user")
        changes.addToSequence(signout, values: [try #require(signout.fields.first).key: "=step1.managerEmail"])
        await changes.previewSequence()
        #expect(problem?.contains("a row with no managerEmail") == true && problem?.contains("Its columns:") == true)
        #expect(writes().isEmpty)
    }

    /// The fan-out counts toward the guard's typed count, as a bulk run's people do.
    @Test func theFanOutCountsForTheGuard() async throws {
        try await connect()
        try queueTheRead()
        try queueTheAdd()
        await changes.previewSequence()
        #expect(try pending().preview.typedCountAbove == Guard.countConfirmAbove)
    }

    /// The export writes the filled-in steps, never the binding.
    @Test func theExportWritesTheFilledInSteps() async throws {
        try await connect()
        try queueTheRead()
        try queueTheAdd()
        await changes.previewSequence()
        let file = try await changes.exportSequence(try pending()).get()
        #expect(file.contains("add member") && !file.contains("=step1"))
    }
}
