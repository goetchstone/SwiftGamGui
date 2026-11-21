import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Inactive users' Suspend these… end to end against the strict mock (GamGUI's `tests/test_audit_runs.py` and its Reports
/// suspend tests): the directory read again at preview, the window's people held in address order, the connected admin left
/// out, one previewed write run once through the executor, and the cached directory patched.
@MainActor
@Suite("Inactive suspend", .serialized)
final class InactiveSuspendTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-inactive-suspend-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let suspend: InactiveSuspend
    let writeAuditURL: URL
    let argvLog: URL
    let state: URL
    nonisolated static let now = AuditRunnerTests.now

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let gam = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: gam, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: gam, now: { InactiveSuspendTests.now })
        writeAuditURL = scratch.appending(path: "audit/writes.jsonl")
        argvLog = scratch.appending(path: "argv.log")
        state = scratch.appending(path: "mock-state")
        let setup = setup
        let executor = Executor(runner: gam, audit: AuditLog(url: writeAuditURL), currentActor: { @MainActor in setup.connectedAdmin },
                                adminAccountID: { @MainActor in setup.connectedAdminID },
                                tenant: { @MainActor in setup.active.map { ($0, setup.generation) } },
                                extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                                                   "GAM_MOCK_STATE": state.path])
        suspend = InactiveSuspend(executor: executor, setup: setup, directory: directory, now: { InactiveSuspendTests.now })
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
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

    /// A second domain, connected: a switch.
    private func connectOther() async throws {
        let folder = scratch.appending(path: "config-other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: "admin@example.org").write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.org")
        await setup.checkAccess(Domain("example.org")!)
        #expect(setup.active?.name == "example.org")
    }

    /// Every gam call the mock ran, as argv.
    private func calls() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var found: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            found.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return found
    }

    struct NotPreviewing: Error { let state: String }

    private func pending() throws -> InactiveSuspend.Pending {
        guard case .previewing(let pending) = suspend.state else { throw NotPreviewing(state: "\(suspend.state)") }
        return pending
    }

    /// The preview reads the directory again and holds the window's people in address order; Confirm suspends exactly them,
    /// once, through the executor, and the cached directory shows it.
    @Test func suspendTheseHoldsTheWindowsPeopleAndRunsThemOnce() async throws {
        try await connect()
        await directory.load()
        let loaded = try #require(directory.revision)
        await suspend.preview(days: 90)
        let pending = try pending()
        #expect(directory.revision != loaded, "read again")
        #expect(pending.targets.map(\.email) == ["alice@example.com", "carol@example.com"] && pending.leftOut.isEmpty)
        #expect(pending.days == 90 && pending.new == 0 && !pending.needsWord && !pending.needsCount)
        #expect(pending.preview.steps.map(\.shownArgv) == [["update", "user", "alice@example.com", "suspended", "on"],
                                                         ["update", "user", "carol@example.com", "suspended", "on"]])
        #expect(pending.preview.decision.maxRisk == .destructive)
        await suspend.confirm(pending, OperatorConfirmation(confirmed: true))
        guard case .done(let words) = suspend.state else { Issue.record("\(suspend.state)"); return }
        #expect(words.hasPrefix("Suspended 2 of 2 accounts."))
        #expect(calls().filter { $0.first == "update" } == pending.preview.steps.map(\.shownArgv))
        #expect(directory.users?.filter(\.suspended).map(\.primaryEmail).sorted() == ["alice@example.com", "bob@example.com", "carol@example.com"])
        await suspend.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(calls().filter { $0.first == "update" }.count == 2, "a preview runs once")
    }

    /// The admin this app signs in as is left out of the people held, and a window the run doesn't offer is refused before any
    /// read. A Confirm without the click isn't one.
    /// What Suspend these… shows belongs to the tenant and the run it was asked from: a switch hides another tenant's preview and
    /// outcome (and a held preview from it never shows, so it can't be confirmed from here), and a newer run's table never shows an
    /// older run's outcome.
    @Test func whatItShowsBelongsToOneTenantAndOneRun() async throws {
        try await connect()
        let older = Date(timeIntervalSince1970: 1), newer = Date(timeIntervalSince1970: 2)
        await suspend.preview(days: 90, about: older)
        let pending = try pending()
        guard case .previewing = suspend.state(about: older) else { Issue.record("\(suspend.state)"); return }
        guard case .idle = suspend.state(about: newer) else { Issue.record("a newer run shows the older preview"); return }
        await suspend.preview(days: 365, about: older)
        guard case .done(let words) = suspend.state(about: older), words.hasSuffix("Nothing to suspend.") else {
            Issue.record("\(suspend.state)"); return
        }
        try await connectOther()
        guard case .idle = suspend.state, case .idle = suspend.state(about: older) else {
            Issue.record("another tenant's outcome shows: \(suspend.state)"); return
        }
        await suspend.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(calls().allSatisfy { $0.first == "print" }, "nothing held for another tenant runs from here")
    }

    @Test func suspendTheseLeavesTheConnectedAdminOut() async throws {
        try await connect()
        await suspend.preview(days: 45)
        guard case .problem(let words) = suspend.state else { Issue.record("\(suspend.state)"); return }
        #expect(words.hasPrefix("Pick one of the windows") && calls().isEmpty)
        let later = InactiveSuspend(executor: nil, setup: setup, directory: directory)
        await later.preview(days: 30)
        guard case .problem = later.state else { Issue.record("\(later.state)"); return }
        await suspend.preview(days: 30)
        let pending = try pending()
        // 30 days before 2026-11-19: admin@ signed in on 2026-10-20 08:00, inside it; dana@ on 2026-10-01, outside.
        #expect(pending.targets.map(\.email) == ["alice@example.com", "carol@example.com", "dana@example.com"])
        let late = InactiveSuspend(executor: try executor(), setup: setup, directory: directory,
                                   now: { ISO8601DateFormatter().date(from: "2027-06-01T00:00:00Z")! })
        await late.preview(days: 30)
        guard case .previewing(let everyone) = late.state else { Issue.record("\(late.state)"); return }
        #expect(everyone.leftOut == ["admin@example.com"] && !everyone.targets.map(\.email).contains("admin@example.com"))
        #expect(everyone.new == 0)
        await suspend.confirm(pending, OperatorConfirmation())
        guard case .problem(let refused) = suspend.state else { Issue.record("\(suspend.state)"); return }
        #expect(refused.contains("confirm") && calls().allSatisfy { $0.first == "print" })
    }

    private func executor() throws -> Executor {
        let gam = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault,
                                      runtimeDirectory: try RuntimeDirectory.prepare(scratch.appending(path: "run3")))
        let setup = setup
        return Executor(runner: gam, audit: AuditLog(url: writeAuditURL), currentActor: { @MainActor in setup.connectedAdmin },
                        adminAccountID: { @MainActor in setup.connectedAdminID },
                        tenant: { @MainActor in setup.active.map { ($0, setup.generation) } },
                        extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                                           "GAM_MOCK_STATE": state.path])
    }
}
