import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// The Builder's curated writes, end to end against the strict mock (invariant 2): built as GamGUI builds them, held, run on the
/// Confirm click only, exactly as held, audited with the command; and the checks GamGUI's Builder doesn't make.
@MainActor
@Suite("Builder changes", .serialized)
final class BuilderChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-builder-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: BuilderChanges
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
        // As the app makes it: the admin Setup connected, asked at each preview and run.
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), currentActor: { @MainActor in setup.connectedAdmin },
                                adminAccountID: { @MainActor in setup.connectedAdminID }, tenant: { @MainActor in setup.active.map { ($0, setup.generation) } },
                                extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                                                   "GAM_MOCK_STATE": scratch.appending(path: "mock-state").path])
        changes = BuilderChanges(executor: executor, setup: setup, directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Connected as `admin` (the mock's directory has alice@example.com, whose alias is a.anders@example.com).
    private func connect(as admin: String = "admin@example.com", loadingTheDirectory: Bool = true) async throws {
        let folder = scratch.appending(path: "gamcfg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: admin).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
        if loadingTheDirectory { await directory.load() }
    }

    private func command(_ id: String) throws -> CuratedCommand {
        try #require(CuratedCommand.all.first { $0.id == id })
    }

    private func pending() throws -> BuilderChanges.Pending {
        guard case .previewing(let pending) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return pending
    }

    private var problem: String? {
        if case .problem(let text) = changes.state { return text }
        return nil
    }

    /// Every call the mock ran, as argv (it logs each as a count then its elements, NUL-separated).
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

    /// A curated write is held, refused without the Confirm click, then run once exactly as held, audited with its command.
    @Test func aWriteRunsAsHeldOnTheConfirmClick() async throws {
        try await connect()
        let add = try command("build.add_group_member")
        await changes.preview(add, values: ["group": " sales@example.com", "member": "carol@example.com", "role": "manager"])
        let pending = try pending()
        #expect(!pending.isDestructive && pending.preview.needsConfirmClick)
        #expect(pending.preview.steps.first?.shownArgv == ["update", "group", "sales@example.com", "add", "manager", "carol@example.com"])
        #expect(pending.preview.steps.first?.target == "sales@example.com")
        #expect(pending.preview.title == "Add member to group for sales@example.com")
        let before = calls().count
        await changes.confirm(pending, OperatorConfirmation())
        #expect(problem == "This change needs confirmation — preview it, then confirm.")
        #expect(calls().count == before)

        await changes.preview(add, values: ["group": "sales@example.com", "member": "carol@example.com", "role": "manager"])
        await changes.confirm(try self.pending(), OperatorConfirmation(confirmed: true))
        guard case .done(let said) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(said == "Done: Add member to group: sales@example.com.")
        #expect(calls().dropFirst(before) == [["update", "group", "sales@example.com", "add", "manager", "carol@example.com"]])
        let end = try #require(AuditLog.records(at: auditURL).first { $0["extra"]?.object?["phase"]?.string == "end" })
        #expect(end["extra"]?.object?["command"]?.string == "build.add_group_member")
    }

    /// A destructive one says so and still runs only on the click: a transfer of Drive and Calendar, every file moving.
    @Test func aDestructiveWriteIsSaidAndRunsAsHeld() async throws {
        try await connect()
        await changes.preview(try command("build.transfer_data"),
                              values: ["old_owner": "carol@example.com", "service": "drive,calendar", "new_owner": "alice@example.com"])
        let pending = try pending()
        #expect(pending.isDestructive)
        let before = calls().count
        await changes.confirm(pending, OperatorConfirmation(confirmed: true))
        guard case .done = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(calls().dropFirst(before)
                == [["create", "datatransfer", "carol@example.com", "drive,calendar", "alice@example.com", "all"]])
    }

    /// GamGUI's risk, never below ChangeCore's floor for the write: a random password and a removed alias are destructive here.
    @Test func everyWriteIsHeldAtItsRiskOrTheFloor() throws {
        struct File: Decodable {
            struct Command: Decodable {
                struct Case: Decodable { let values: [String: String] }
                let id: String
                let risk: Int
                let cases: [Case]
            }
            let commands: [Command]
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: Fixtures.directory.appending(path: "catalog_curated.json")))
        var writes = 0
        for expected in file.commands where CuratedCommand.elsewhere[expected.id] == nil {
            let curated = try command(expected.id)
            guard case .write(let write) = try curated.built(try #require(expected.cases.first).values) else { continue }
            writes += 1
            let gamgui = try #require(Risk(rawValue: expected.risk))
            #expect(BuilderChanges.risk(curated) == max(gamgui, write.action.minimumRisk), "\(expected.id)")
            #expect(WriteStep(write, target: "x", summary: "", risk: BuilderChanges.risk(curated)).risk == BuilderChanges.risk(curated))
        }
        #expect(writes == 18)
    }

    /// A read isn't held (the Builder runs it), and the form's refusals are said before anything is held.
    @Test func aReadOrAWrongFormIsRefused() async throws {
        try await connect()
        await changes.preview(try command("build.print_delegates"), values: ["email": "alice@example.com"])
        #expect(problem == "List mailbox delegates only reads: run it instead.")
        await changes.preview(try command("build.create_alias"), values: ["alias": "c@example.com"])
        #expect(problem == "Fill in User.")
        await changes.preview(try command("build.create_alias"), values: ["alias": "c@example.com", "email": "Carol Clark"])
        #expect(problem?.hasPrefix("“Carol Clark” isn't one plain email address") == true)
    }

    /// A suspend, a random password or a sign-out for the admin this app is connected as is refused by the executor, as on every
    /// screen: as typed at the preview, and as an alias GAM resolves to it at the run, whether or not the directory has been
    /// read; and the spellings GAM rewrites to another address aren't taken at all (review 2026-10-28: `uid:alice@…` and
    /// `<alice@…>` were held and ran).
    @Test func theConnectedAdminIsNotLockedOut() async throws {
        try await connect(as: "alice@example.com", loadingTheDirectory: false)
        #expect(directory.users == nil)
        for id in ["build.suspend_user", "build.reset_password", "build.signout_user"] {
            await changes.preview(try command(id), values: ["email": "Alice@Example.com"])
            #expect(problem?.hasPrefix("Alice@Example.com is the admin this app is connected as") == true,
                    "\(id): \(String(describing: problem))")
            for alias in ["a.anders@example.com", "alice@alias.example.net"] {
                await changes.preview(try command(id), values: ["email": alias])
                await changes.confirm(try pending(), OperatorConfirmation(confirmed: true))
                #expect(problem?.hasPrefix("\(alias) is the account this app is connected as (alice@example.com)") == true,
                        "\(id) \(alias): \(String(describing: problem))")
            }
            for rewritten in ["uid:alice@example.com", "ID:alice@example.com", "<alice@example.com>", "x<alice@example.com>",
                              "Alice <alice@example.com>", "uid: alice@example.com"] {
                await changes.preview(try command(id), values: ["email": rewritten])
                #expect(problem?.contains("isn't one plain email address") == true, "\(id) \(rewritten): \(String(describing: problem))")
            }
        }
        #expect(calls().allSatisfy { $0.prefix(2) == ["info", "user"] }, "only reads ran: \(calls())")
        await changes.preview(try command("build.suspend_user"), values: ["email": "carol@example.com"])
        #expect(try pending().isDestructive)
    }

    /// Whose account it is is asked of GAM just before the run (the executor's check, by account ID), and a read Google
    /// refuses refuses the run, never a guess. An address GAM doesn't know is no one's: GAM itself says so at the write.
    @Test func theAccountIsCheckedBeforeTheRun() async throws {
        try await connect(as: "alice@example.com")
        await changes.preview(try command("build.suspend_user"), values: ["email": "carol@example.com"])
        let before = calls().count
        await changes.confirm(try pending(), OperatorConfirmation(confirmed: true))
        guard case .done = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(calls().dropFirst(before).map { Array($0.prefix(3)) }
                == [["info", "user", "carol@example.com"], ["update", "user", "carol@example.com"]])
        await changes.preview(try command("build.reset_password"), values: ["email": "INFOREFUSED@example.com"])
        await changes.confirm(try pending(), OperatorConfirmation(confirmed: true))
        #expect(problem?.hasPrefix("Couldn't check whose account INFOREFUSED@example.com is") == true, "\(String(describing: problem))")
        await changes.preview(try command("build.reset_password"), values: ["email": "nonexistent@example.com"])
        await changes.confirm(try pending(), OperatorConfirmation(confirmed: true))
        #expect(problem?.contains("nonexistent@example.com") == true, "\(String(describing: problem))")
    }

    /// A preview that comes back after a newer one was asked for is dropped: it never shows under the newer command's page.
    @Test func aSlowPreviewNeverShowsUnderAnotherCommand() async throws {
        try await connect()
        let first = Task { await changes.preview(try command("build.add_group_member"),
                                                 values: ["group": "sales@example.com", "member": "carol@example.com"]) }
        await Task.yield()
        await changes.preview(try command("build.create_alias"), values: ["alias": "c@example.com"])
        try await first.value
        #expect(problem == "Fill in User.")
        #expect(changes.subject == "build.create_alias")
    }

    /// A delegate is checked as Users checks one: its owner refused, one outside the directory said before the add.
    @Test func aDelegateIsCheckedAsUsersChecksOne() async throws {
        try await connect()
        let add = try command("build.add_delegate")
        await changes.preview(add, values: ["email": "alice@example.com", "delegate": "alice@example.com"])
        #expect(problem == "A mailbox can't be delegated to its own owner.")
        await changes.preview(add, values: ["email": "alice@example.com", "delegate": "a.anders@example.com"])
        #expect(problem == "a.anders@example.com is an alias of alice@example.com — enter the primary address.")
        await changes.preview(add, values: ["email": "alice@example.com", "delegate": "zed@example.com"])
        #expect(try pending().warning?.hasPrefix("zed@example.com isn't in the directory.") == true)
        await changes.preview(add, values: ["email": "alice@example.com", "delegate": "carol@example.com"])
        #expect(try pending().warning == nil)
    }

    /// A title or department left empty is said before GAM clears it, naming the one it would clear; one already empty isn't.
    @Test func aTitleOrDepartmentLeftEmptyIsSaid() async throws {
        try await connect()
        let set = try command("build.set_organization")
        await changes.preview(set, values: ["email": "alice@example.com", "title": "Head of IT"])
        #expect(try pending().warning == "GAM sets the title and department together: this clears alice@example.com's department. "
                + "Fill it in to keep it.")
        await changes.preview(set, values: ["email": "carol@example.com"])
        #expect(try pending().warning == nil, "Carol has neither")
        await changes.preview(set, values: ["email": "zed@example.com", "department": "Sales"])
        #expect(try pending().warning == "GAM sets the title and department together, and zed@example.com isn't in the directory as "
                + "read: if they have a title, this clears it.")
        await changes.preview(set, values: ["email": "alice@example.com", "title": "Head of IT", "department": "IT"])
        #expect(try pending().warning == nil)
    }
}
