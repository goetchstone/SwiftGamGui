import ChangeCore
import Foundation
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Shared drive members (roadmap 4.7), against the strict mock: GamGUI's `tests/test_shared_drives.py`. Finance
/// (0AFINANCEuk9PVA): alice@ its only manager, pat@partner.org a contributor.
@MainActor
@Suite("Shared drive members", .serialized)
final class SharedDriveChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-drives-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let access: UserAccess
    let model: SharedDriveChanges
    let argvLog: URL
    let state: URL
    let finance = SharedDrives.Drive(id: "0AFINANCEuk9PVA", name: "Finance")

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        argvLog = scratch.appending(path: "argv.log")
        state = scratch.appending(path: "state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": state.path]
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: scratch.appending(path: "audit.jsonl")), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
        model = SharedDriveChanges(executor: executor, setup: setup, access: access)
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
    }

    private func writes() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.count > 1 && $0[1] == "drivefileacl" }
    }

    private func run() async throws {
        guard case .previewing(let pending) = model.state else { Issue.record("\(model.state)"); return }
        await model.confirm(pending, OperatorConfirmation(confirmed: true))
    }

    @Test func drivesAndMembersRead() async throws {
        try await connect()
        await model.loadDrives()
        #expect(try model.drives?.get().contains(finance) == true)
        await model.loadMembers(finance)
        let members = try #require(try model.members(of: finance)?.get())
        #expect(members.map(\.who) == ["alice@example.com", "pat@partner.org"] && members.map(\.role) == ["organizer", "writer"])
    }

    @Test func addChangeAndRemoveRunAsHeld() async throws {
        try await connect()
        await model.preview(finance, action: .add, email: "dana@example.com", kind: "user", role: "reader")
        try await run()
        await model.preview(finance, action: .role, role: "commenter", memberID: "07001")
        try await run()
        await model.preview(finance, action: .remove, memberID: "07001")
        try await run()
        #expect(writes() == [
            ["create", "drivefileacl", "shareddriveid", "0AFINANCEuk9PVA", "user", "dana@example.com", "role", "reader"],
            ["update", "drivefileacl", "shareddriveid", "0AFINANCEuk9PVA", "id:07001", "role", "commenter"],
            ["delete", "drivefileacl", "shareddriveid", "0AFINANCEuk9PVA", "id:07001"],
        ])
        guard case .done(let words) = model.state else { Issue.record("\(model.state)"); return }
        #expect(words == "Removed pat@partner.org from Finance.")
    }

    @Test func theLastManagerIsNeverRemovedOrDemoted() async throws {
        try await connect()
        await model.preview(finance, action: .remove, memberID: "100000000000000000001")
        guard case .problem(let why) = model.state else { Issue.record("\(model.state)"); return }
        #expect(why.hasPrefix("alice@example.com is Finance's only manager."))
        await model.preview(finance, action: .role, role: "writer", memberID: "100000000000000000001")
        guard case .problem = model.state else { Issue.record("\(model.state)"); return }
        #expect(writes().isEmpty)
    }

    @Test func aWriteGamSkipsWithoutAWordIsFailed() async throws {
        try await connect()
        await model.preview(finance, action: .add, email: "dana@example.com", kind: "user", role: "reader")
        try Data().write(to: state.appending(path: "drive_token_silent"))
        guard case .previewing(let pending) = model.state else { Issue.record("\(model.state)"); return }
        await model.confirm(pending, OperatorConfirmation(confirmed: true))
        guard case .problem = model.state else { Issue.record("\(model.state)"); return }
    }
}
