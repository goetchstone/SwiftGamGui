import ChangeCore
import Foundation
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Licenses (roadmap 4.3), against the strict mock: GamGUI's `tests/test_licenses.py` and `test_suspended_licenses.py`. The
/// mock's seats: everyone holds Business Standard; bob (suspended) also holds Google Vault - Former Employee; the domain
/// subscribes to Business Plus too, with no seat assigned.
@MainActor
@Suite("Licenses", .serialized)
final class LicenseChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-lic-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let access: UserAccess
    let executor: Executor
    let argvLog: URL
    let state: URL

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
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

    private func writes() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.count > 3 && $0[0] == "user" && $0[3] == "license" }
    }

    private func user(_ email: String) throws -> GamUser { try #require(directory.users?.first { $0.primaryEmail == email }) }

    private func pendingTransfer(_ email: String) throws {
        let folder = state.appending(path: "datatransfers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("id,requestTime,oldOwnerUserEmail,newOwnerUserEmail,overallTransferStatusCode,application,applicationId,status\nT9,2026-11-01T09:00:00Z,\(email),mgr@example.com,inProgress,Drive and Docs,1,inProgress\n".utf8)
            .write(to: folder.appending(path: email))
    }

    @Test func nameAndChoicesAreGamGUIs() throws {
        #expect(try GamCommands.licenseSKU(productID: "Google-Apps", skuID: "1010020028") == "nv:Google-Apps:1010020028")
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.licenseSKU(productID: "a:b", skuID: "1") }
        let std = Licenses.Seat(user: "a@x.com", productID: "Google-Apps", product: "Google Workspace", skuID: "1", sku: "Standard")
        let plus = Licenses.Seat(user: "b@x.com", productID: "Google-Apps", product: "Google Workspace", skuID: "2", sku: "Plus")
        let vault = Licenses.Seat(user: "b@x.com", productID: "Google-Vault", product: "Google Vault", skuID: "V", sku: "Vault")
        let choices = Licenses.choices([std, plus, vault], for: "A@x.com")
        #expect(choices.held.map(\.seat) == [std] && choices.held[0].changes == [plus] && choices.adds == [vault])
    }

    @Test func onePersonsSeatsChangeAsHeld() async throws {
        try await connect()
        let changes = LicenseChanges(executor: executor, setup: setup, access: access)
        let alice = try user("alice@example.com")
        await changes.load(alice.primaryEmail)
        let choices = try #require(try changes.choices(for: alice.primaryEmail)?.get())
        let standard = try #require(choices.held.first?.seat)
        let vault = try #require(choices.adds.first { $0.productID == "Google-Vault" })
        await changes.preview(.add(vault), for: alice)
        guard case .previewing(let add) = changes.state else { Issue.record("\(changes.state)"); return }
        await changes.confirm(add, OperatorConfirmation(confirmed: true))
        #expect(writes() == [["user", "alice@example.com", "add", "license", "nv:Google-Vault:Google-Vault-Former-Employee"]])
        await changes.preview(.remove(standard), for: alice)
        guard case .previewing(let remove) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(remove.typedAddress == "alice@example.com" && remove.notes.contains(Licenses.mightLoseData))
        await changes.confirm(remove, OperatorConfirmation(confirmed: true))
        #expect(writes().count == 1, "the address wasn't typed")
        await changes.preview(.remove(standard), for: alice)
        guard case .previewing(let again) = changes.state else { Issue.record("\(changes.state)"); return }
        await changes.confirm(again, OperatorConfirmation(confirmed: true, typedAddresses: ["alice@example.com"]))
        #expect(writes().last == ["user", "alice@example.com", "delete", "license", "nv:Google-Apps:1010020028"])
    }

    @Test func aRemovalWaitsForAnUnfinishedTransfer() async throws {
        try await connect()
        try pendingTransfer("carol@example.com")
        let changes = LicenseChanges(executor: executor, setup: setup, access: access)
        let carol = try user("carol@example.com")
        let seat = Licenses.Seat(user: "carol@example.com", productID: "Google-Apps", product: "Google Workspace", skuID: "1010020028",
                                 sku: "Google Workspace Business Standard")
        await changes.preview(.remove(seat), for: carol)
        guard case .problem(let why) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(why.hasPrefix("A data transfer from carol@example.com hasn't finished"))
        #expect(writes().isEmpty)
    }

    @Test func suspendedAccountsLoseTheirSeatsAsHeld() async throws {
        try await connect()
        let many = SuspendedLicenses(executor: executor, setup: setup, directory: directory, access: access)
        await many.preview()
        guard case .previewing(let pending) = many.state else { Issue.record("\(many.state)"); return }
        #expect(pending.seats.map(\.email) == ["bob@example.com", "bob@example.com"] && pending.kept.isEmpty)
        await many.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(writes().map(\.last) == ["nv:Google-Vault:Google-Vault-Former-Employee", "nv:Google-Apps:1010020028"], "by product name")
        guard case .done(let words) = many.state else { Issue.record("\(many.state)"); return }
        #expect(words == "Removed 2 of 2 licenses.")
    }

    @Test func aSuspendedAccountWithATransferRunningKeepsItsSeats() async throws {
        try await connect()
        try pendingTransfer("bob@example.com")
        let many = SuspendedLicenses(executor: executor, setup: setup, directory: directory, access: access)
        await many.preview()
        guard case .problem(let why) = many.state else { Issue.record("\(many.state)"); return }
        #expect(why.contains("bob@example.com hasn't finished") && writes().isEmpty)
    }
}

