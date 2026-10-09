import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// The user page's first writes, end to end against the strict mock: preview, confirm, the exact argv
/// GamGUI sends, the audit, and the cached directory patched (GamGUI's `patch_user`).
struct NotPreviewing: Error { let state: String }

@MainActor
@Suite("User changes", .serialized)
final class UserChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-users-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: UserChanges
    let argvLog: URL
    let auditURL: URL

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path])
        changes = UserChanges(executor: executor, directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect() async throws {
        let folder = scratch.appending(path: "gamcfg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "admin@example.com"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
        await directory.load()
    }

    private func user(_ email: String) throws -> GamUser {
        try #require(directory.users?.first { $0.primaryEmail == email })
    }

    private func pending() throws -> UserChanges.Pending {
        guard case .previewing(let pending) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return pending
    }

    /// The writes the mock ran, as argv (it logs each as a count then its elements, NUL-separated).
    private func writes() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.first == "update" }
    }

    @Test func aTitleAndDepartmentChangeRunsGamGUIsArgvAndPatchesTheList() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        await changes.previewOrganization(of: alice, title: "  Head of IT ", department: alice.department)
        let pending = try pending()
        #expect(!pending.isDestructive)
        #expect(pending.preview.steps.first?.shownArgv
                == ["update", "user", "alice@example.com", "organization", "title", "Head of IT", "department", alice.department, "primary"])
        await changes.confirm(pending, OperatorConfirmation(confirmed: true))
        guard case .done = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(writes() == [["update", "user", "alice@example.com", "organization", "title", "Head of IT",
                              "department", alice.department, "primary"]])
        #expect(try user("alice@example.com").title == "Head of IT", "the list shows the change without a reload")
        #expect(try user("alice@example.com").department == alice.department)
        #expect(AuditLog.records(at: auditURL).first?["action"]?.string == "updateOrganization")
    }

    @Test func anUnchangedTitleAndDepartmentIsNotAWrite() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        await changes.previewOrganization(of: alice, title: alice.title, department: " \(alice.department) ")
        guard case .problem(let message) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(message.hasPrefix("Nothing to change"))
    }

    @Test func suspendingNeedsTheConfirmClickAndUnsuspendingPatchesBack() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        #expect(!alice.suspended)
        await changes.previewSuspend(alice, suspend: true)
        let pending = try pending()
        #expect(pending.isDestructive)
        await changes.confirm(pending, OperatorConfirmation())
        #expect({ if case .problem("This change needs confirmation — preview it, then confirm.") = changes.state { true } else { false } }())
        #expect(writes().isEmpty)

        await changes.previewSuspend(alice, suspend: true)
        await changes.confirm(try self.pending(), OperatorConfirmation(confirmed: true))
        #expect(writes() == [["update", "user", "alice@example.com", "suspended", "on"]])
        #expect(try user("alice@example.com").suspended)
        #expect(directory.reports?.first { $0.key == "suspended" }?.count == directory.users?.filter(\.suspended).count)

        await changes.previewSuspend(try user("alice@example.com"), suspend: false)
        await changes.confirm(try self.pending(), OperatorConfirmation(confirmed: true))
        #expect(try !user("alice@example.com").suspended)
    }

    /// A write that fails leaves the list as it was and says why, with GAM's remediation.
    @Test func aFailedWriteSaysWhyAndPatchesNothing() async throws {
        try await connect()
        let ghost = GamUser(record: ["primaryEmail": .string("missing@example.com"), "suspended": .bool(false)])
        await changes.previewSuspend(ghost, suspend: true)
        await changes.confirm(try pending(), OperatorConfirmation(confirmed: true))
        guard case .problem(let message) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(message.contains("missing@example.com"))
        #expect(directory.users?.contains { $0.primaryEmail == "missing@example.com" } == false)
    }

    @Test func aResultShowsOnlyUnderItsOwnPerson() async throws {
        try await connect()
        await changes.previewSuspend(try user("alice@example.com"), suspend: true)
        #expect(changes.concerns("ALICE@example.com"))
        #expect(!changes.concerns("bob@example.com"))
    }

    @Test func clearingATitleSticksForACSVShapedRecordToo() {
        let csv = GamUser(record: ["primaryEmail": .string("a@example.com"), "Organization Title": .string("Sales Lead")])
        #expect(csv.title == "Sales Lead")
        #expect(csv.with(title: "", department: "").title == "")
    }

    @Test func aWriteForAnOldTenantNeverPatchesTheNewOne() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        let before = alice.title
        directory.patch("alice@example.com", on: Domain("example.com")!, generation: setup.generation + 1) {
            $0.with(title: "Wrong tenant")
        }
        #expect(try user("alice@example.com").title == before)
    }
}
