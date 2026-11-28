import ChangeCore
import Foundation
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Org units (roadmap 4.2), against the strict mock: GamGUI's `tests/test_org_unit_move.py`. The mock's tree is /Sales,
/// /Sales/West, /Staff and /Students; alice, admin and dana are in /Staff, carol in /Students, bob (suspended) in /Staff.
@MainActor
@Suite("Org unit moves", .serialized)
final class OrgUnitMoveTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-ou-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let access: UserAccess
    let runner: AuthenticatedRunner
    let executor: Executor
    let argvLog: URL
    let state: URL

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        state = scratch.appending(path: "state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": state.path]
        let setup = setup
        executor = Executor(runner: runner, audit: AuditLog(url: scratch.appending(path: "audit.jsonl")), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
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

    private func moves() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.starts(with: ["update", "org"]) }
    }

    private func marker(_ name: String) throws { try Data().write(to: state.appending(path: name)) }

    // MARK: the tree

    @Test func theTreeIsTheRootThenEveryUnit() async throws {
        try await connect()
        #expect(try await access.orgUnits().get() == ["/", "/Sales", "/Sales/West", "/Staff", "/Students"])
        try marker("org_units_notice")
        #expect(try await access.orgUnits().get() == ["/", "/Sales", "/Sales/West", "/Staff", "/Students"], "a notice before the titles")
        try marker("no_org_units")
        #expect(try await access.orgUnits().get() == ["/"], "none below the root, and GAM still wrote its titles")
    }

    @Test func aTreeWithoutTitlesIsUnreadNeverOnlyTheRoot() {
        #expect(OrgUnits.paths("") == nil && OrgUnits.paths("A banner GAM printed\n") == nil)
        #expect(OrgUnits.paths("orgUnitPath,name,description\n/A,A,\"x\u{2028}y\"\n") == ["/", "/A"])
    }

    @Test func aRefusedReadIsSaid() async throws {
        try await connect()
        try marker("org_units_refused")
        guard case .failure = await access.orgUnits() else { Issue.record("read as an answer"); return }
    }

    // MARK: one person

    @Test func onePersonMovesOnceFromWhereTheyAre() async throws {
        try await connect()
        let changes = UserChanges(executor: executor, directory: directory)
        let carol = try #require(directory.users?.first { $0.primaryEmail == "carol@example.com" })
        await changes.previewMoveOrgUnit(carol, to: "/Students", access: access)
        guard case .problem(let same) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(same == "carol@example.com is already in /Students.")
        await changes.previewMoveOrgUnit(carol, to: "/Nowhere", access: access)
        guard case .problem(let unknown) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(unknown == "“/Nowhere” isn't an org unit here: pick one from the list.")
        await changes.previewMoveOrgUnit(carol, to: "/Sales/West", access: access)
        guard case .previewing(let pending) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(pending.preview.steps.first?.summary == "Move carol@example.com from /Students to /Sales/West")
        #expect(moves().isEmpty)
        await changes.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(moves() == [["update", "org", "/Sales/West", "move", "user", "carol@example.com"]])
        #expect(directory.users?.first { $0.primaryEmail == "carol@example.com" }?.orgUnitPath == "/Sales/West")
    }

    // MARK: many

    @Test func manyMoveAsHeldSuspendedIncludedNestedSaid() async throws {
        try await connect()
        let many = OrgUnitForMany(executor: executor, setup: setup, directory: directory, access: access, runner: runner)
        many.environment = ["GAM_MOCK_STATE": state.path]
        await many.preview(orgUnit: "/Sales", who: .pasted("bob@example.com, carol@example.com\nnobody@example.com"))
        guard case .previewing(let pending) = many.state else { Issue.record("\(many.state)"); return }
        #expect(pending.people.map(\.primaryEmail) == ["bob@example.com", "carol@example.com"], "bob is suspended and moves")
        #expect(pending.missing == ["nobody@example.com"])
        await many.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(moves().map(\.last) == ["bob@example.com", "carol@example.com"])
        guard case .done(let done) = many.state else { Issue.record("\(many.state)"); return }
        #expect(done.message == "Moved 2 of 2 people to /Sales." && done.retry == nil)
        await many.preview(orgUnit: "/Nowhere", who: .pasted("carol@example.com"))
        guard case .problem(let unknown) = many.state else { Issue.record("\(many.state)"); return }
        #expect(unknown == "“/Nowhere” isn't an org unit here: pick one from the list.")
        await many.preview(orgUnit: "/Sales", who: .group("sales@example.com"))
        guard case .previewing(let fromGroup) = many.state else { Issue.record("\(many.state)"); return }
        #expect(fromGroup.people.map(\.primaryEmail) == ["alice@example.com"] && fromGroup.nested == ["it@example.com"])
    }
}
