import ChangeCore
import Foundation
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Close Out (roadmap 4.5), against the strict mock: GamGUI's `tests/test_closeout.py` screen cases. The mock's alice is in
/// sales@ and staff@, Super Admin (9170001), in /Staff, with the alias a.anders@ and a Business Standard seat; the connected
/// admin is admin@.
@MainActor
@Suite("Close Out changes", .serialized)
final class CloseOutChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-closeout-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let access: UserAccess
    let runner: AuthenticatedRunner
    let executor: Executor
    let argvLog: URL
    let state: URL
    let changes: CloseOutChanges
    static let alice = "alice@example.com"
    static let seat = "Google-Apps|1010020028"

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
        executor = Executor(runner: runner, audit: AuditLog(url: scratch.appending(path: "audit.jsonl")),
                            currentActor: { @MainActor in setup.connectedAdmin }, adminAccountID: { @MainActor in setup.connectedAdminID },
                            tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
        changes = CloseOutChanges(executor: executor, setup: setup, directory: directory, access: access, runner: runner)
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
        return calls.filter { ["update", "delete", "create"].contains($0.first ?? "") }
    }

    private func found() throws -> CloseOut.Found {
        guard case .checked(let found) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return found
    }

    private func pending() throws -> CloseOutChanges.Pending {
        guard case .previewing(let pending) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return pending
    }

    private func problem() -> String? {
        if case .problem(let words) = changes.state { words } else { nil }
    }

    private func marker(_ path: String, _ text: String = "") throws {
        let file = state.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func asked(_ change: (inout CloseOut.Asked) -> Void) -> CloseOut.Asked {
        var asked = CloseOut.Asked()
        change(&asked)
        return asked
    }

    @Test func theCheckListsWhatIsLeftAndWritesNothing() async throws {
        try await connect()
        await changes.check(Self.alice)
        let found = try found()
        #expect(found.refusal == nil && found.unread.isEmpty)
        #expect(found.groups == ["sales@example.com", "staff@example.com"] && found.roles?.map(\.id) == ["9170001"])
        #expect(found.seats?.map(\.key) == [Self.seat] && found.aliases == ["a.anders@example.com"] && found.orgUnit == "/Staff")
        #expect(found.archived == false && found.units?.contains("/Students") == true)
        #expect(writes().isEmpty)
    }

    @Test func aPendingOrUnreadTransferOffersNothing() async throws {
        try await connect()
        try marker("datatransfers/\(Self.alice)", "id,oldOwnerUserEmail,newOwnerUserEmail,overallTransferStatusCode,application\n"
                   + "t1,alice@example.com,bob@example.com,inProgress,Drive and Docs\n")
        await changes.check(Self.alice)
        #expect(try found().refusal?.contains("hasn't finished") == true)
        await changes.preview(Self.alice, asked { $0.groups = ["sales@example.com"] }, manager: "")
        #expect(problem()?.contains("hasn't finished") == true)
        try FileManager.default.removeItem(at: state.appending(path: "datatransfers/\(Self.alice)"))
        try marker("notransfers")
        await changes.check(Self.alice)
        #expect(try found().refusal?.contains("Couldn't check whether a data transfer") == true)
        #expect(writes().isEmpty)
    }

    @Test func anAliasIsRefusedForItsPrimary() async throws {
        try await connect()
        await changes.check("a.anders@example.com")
        #expect(problem()?.contains("is an alias of alice@example.com") == true)
    }

    /// The admin this app signs in as is never closed out, by account ID.
    @Test func theConnectedAdminIsNeverClosedOut() async throws {
        try await connect()
        await changes.check("admin@example.com")
        #expect(problem() != nil, "\(changes.state)")
        await changes.preview("admin@example.com", asked { $0.state = .suspend }, manager: "")
        #expect(problem() != nil)
        #expect(writes().isEmpty)
    }

    @Test func thePreviewHoldsThePickedStepsAndWritesNothing() async throws {
        try await connect()
        await changes.preview(Self.alice, asked {
            $0.groups = ["staff@example.com"]
            $0.roles = ["9170001"]
            $0.state = .suspend
        }, manager: "")
        let pending = try pending()
        #expect(pending.preview.title == "Closing out alice@example.com" && pending.steps.count == 3)
        #expect(pending.preview.typedAddress == Self.alice, "the leaver's address is typed")
        #expect(pending.preview.steps.map(\.shownArgv).contains(["delete", "admin", "9170001"]))
        #expect(writes().isEmpty)
    }

    @Test func aPickTheReadNoLongerHasIsRefusedAndNothingPickedHoldsNothing() async throws {
        try await connect()
        await changes.preview(Self.alice, asked { $0.groups = ["it@example.com"] }, manager: "")
        #expect(problem()?.contains("changed since the check (it@example.com") == true)
        await changes.preview(Self.alice, CloseOut.Asked(), manager: "")
        #expect(problem()?.contains("Nothing is picked") == true)
        await changes.preview(Self.alice, asked { $0.aliases = ["a.anders@example.com"] }, manager: "nobody@example.com")
        #expect(problem()?.contains("isn't an account here") == true)
        #expect(writes().isEmpty)
    }

    @Test func theRunWritesExactlyTheHeldStepsOnce() async throws {
        try await connect()
        await changes.preview(Self.alice, asked {
            $0.groups = ["staff@example.com"]
            $0.roles = ["9170001"]
            $0.orgUnit = "/Students"
            $0.state = .suspend
            $0.aliases = ["a.anders@example.com"]
        }, manager: "bob@example.com")
        let pending = try pending()
        await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedAddresses: [Self.alice]))
        guard case .done(let done) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(!done.partial, "\(done.failures)")
        #expect(writes() == [["update", "group", "staff@example.com", "remove", Self.alice], ["delete", "admin", "9170001"],
                             ["update", "org", "/Students", "move", "user", Self.alice], ["update", "user", Self.alice, "suspended", "on"],
                             ["update", "alias", "a.anders@example.com", "user", "bob@example.com"]])
        await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedAddresses: [Self.alice]))
        #expect(writes().count == 5, "a preview runs once")
    }

    @Test func theRunNeedsTheLeaverTyped() async throws {
        try await connect()
        await changes.preview(Self.alice, asked { $0.groups = ["staff@example.com"] }, manager: "")
        await changes.confirm(try pending(), OperatorConfirmation(confirmed: true))
        #expect(problem() != nil && writes().isEmpty)
    }

    /// A refused step is reported and the rest still run: the role deleted elsewhere since the preview.
    @Test func aRefusedStepIsReportedAndTheRestStillRun() async throws {
        try await connect()
        await changes.preview(Self.alice, asked {
            $0.roles = ["9170001"]
            $0.state = .suspend
        }, manager: "")
        let pending = try pending()
        try marker("admins_deleted", "9170001\n")
        await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedAddresses: [Self.alice]))
        guard case .done(let done) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(done.partial && done.failures.count == 1 && done.failures[0].hasPrefix("Remove the admin role Super Admin"))
        #expect(writes().contains(["update", "user", Self.alice, "suspended", "on"]))
    }

    /// GamGUI's `test_an_alias_gone_from_them_by_the_step_is_never_moved`: the check before the move reads it as theirs.
    @Test func anAliasNoLongerTheirsIsNeverMoved() async throws {
        try await connect()
        await changes.preview(Self.alice, asked { $0.aliases = ["a.anders@example.com"] }, manager: "bob@example.com")
        let pending = try pending()
        let step = WriteStep(try GamCommands.moveAlias(alias: "a.anders@example.com", to: "bob@example.com"), target: "carol@example.com",
                             summary: "", risk: .destructive, keepFirst: .aliasOf(email: "carol@example.com", alias: "a.anders@example.com"))
        let held = try await executor.preview([step]).get()
        let outcome = await executor.run(held, confirmation: OperatorConfirmation(confirmed: true))
        guard case .failed(let message, _)? = outcome.steps.first else { Issue.record("\(outcome.steps)"); return }
        #expect(message.contains("isn't carol@example.com's alias any more"))
        _ = pending
        #expect(writes().isEmpty)
    }

    @Test func aFailedAliasMoveSaysTheAliasMayBeOnNobody() async throws {
        try await connect()
        await changes.preview(Self.alice, asked { $0.aliases = ["a.anders@example.com"] }, manager: "bob@example.com")
        let pending = try pending()
        let failed = CloseOutChanges.done(pending, [.failed(message: "Add Failed: Invalid alias", kind: .unknown)], note: "")
        #expect(failed.failures.first?.contains("a.anders@example.com may now be on nobody") == true)
        // Refused by the check before it: nothing moved, and it doesn't say so.
        let checked = CloseOutChanges.done(pending, [.failed(message: "a.anders@example.com isn't alice@example.com's alias any more, "
                                                             + "so it wasn't moved.", kind: nil)], note: "")
        #expect(checked.failures.first?.contains("on nobody") == false)
    }
}
