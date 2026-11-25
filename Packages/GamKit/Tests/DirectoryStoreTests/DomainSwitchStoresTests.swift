@testable import ChangeCore
import Foundation
import Jobs
@testable import Directory
@testable import GamEngine
import Setup
import Synchronization
import TestSupport
import Testing
import Vault

/// Plan F6: a switch to another domain (Setup's own Check access, as the toolbar's menu runs it) leaves nothing of the old
/// domain showing or runnable on the new one: every per-domain store hides what it read there, every change model drops the
/// preview, result or problem it showed, and the executor drops the previews held there (as `AppServices` wires it).
/// GamGUI's `test_a_switch_drops_every_runs_retry_and_the_report_export_waiting` and the stores' own switch tests, at once.
@MainActor
@Suite("Domain switch: the stores", .serialized)
final class DomainSwitchStoresTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-switch-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let runner: AuthenticatedRunner
    let setup: SetupModel
    let executor: Executor
    let confirmed = OperatorConfirmation(confirmed: true)

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        let setup = setup
        executor = Executor(runner: runner, audit: AuditLog(url: scratch.appending(path: "audit/audit.jsonl")),
                            currentActor: { @MainActor in setup.connectedAdmin },
                            adminAccountID: { @MainActor in setup.connectedAdminID },
                            tenant: { @MainActor in setup.active.map { ($0, setup.generation) } },
                            extraEnvironment: ["GAM_MOCK_FIXTURES": Fixtures.mockGamData.path])
        // As AppServices: a switch drops what the executor held for the old tenant.
        let executor = executor
        setup.onTenantChange { Task { await executor.dropOtherTenants() } }
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func store(_ domain: String, admin: String) async throws {
        let folder = scratch.appending(path: "config-\(domain)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: admin).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
    }

    @Test func nothingOfTheOldDomainShowsOrRunsOnTheNewOne() async throws {
        try await store("example.com", admin: "admin@example.com")
        try await store("example.org", admin: "admin@example.org")
        #expect(await setup.checkAccess(Domain("example.com")!) == .connected)

        // The old domain's reads, each kept by its store.
        let directory = DirectoryStore(setup: setup, runner: runner)
        let groups = GroupStore(setup: setup, runner: runner)
        let usage = UsageStore(setup: setup, runner: runner)
        let access = UserAccess(setup: setup, runner: runner)
        let members = GroupMembers(setup: setup, runner: runner)
        let apps = ConnectedAppsRead(setup: setup, access: access)
        let classroom = ClassroomReads(setup: setup, access: access)
        let compromised = CompromisedChanges(executor: executor, setup: setup, access: access)
        await directory.load()
        await groups.load()
        await usage.load()
        await access.load("alice@example.com")
        await members.load("sales@example.com")
        await apps.read()
        await classroom.loadIndex()
        await compromised.check("carol@example.com")
        #expect(directory.users != nil && groups.groups != nil && usage.report != nil)
        #expect(access.lists(for: "alice@example.com") != nil && members.members(of: "sales@example.com") != nil)
        #expect(apps.state != nil && classroom.indexState != nil)
        guard case .checked = compromised.checkState else { Issue.record("\(compromised.checkState)"); return }

        // The old domain's previews and results, each shown by its change model.
        let userChanges = UserChanges(executor: executor, directory: directory)
        let groupChanges = GroupChanges(executor: executor, setup: setup, members: members)
        let builderChanges = BuilderChanges(executor: executor, setup: setup, directory: directory)
        let alice = try #require(directory.users?.first { $0.primaryEmail == "alice@example.com" })
        await userChanges.previewSuspend(alice, suspend: true)
        guard case .previewing(let heldUser) = userChanges.state else { Issue.record("\(userChanges.state)"); return }
        let sales = try #require(groups.groups?.first { $0.email == "sales@example.com" })
        await groupChanges.previewAdd("carol@example.com", to: sales, role: .member)
        guard case .previewing(let heldGroup) = groupChanges.state else { Issue.record("\(groupChanges.state)"); return }
        let add = try #require(CuratedCommand.all.first { $0.id == "build.add_group_member" })
        await builderChanges.preview(add, values: ["group": "sales@example.com", "member": "dana@example.com", "role": "member"])
        guard case .previewing(let heldBuilder) = builderChanges.state else { Issue.record("\(builderChanges.state)"); return }
        #expect(await executor.heldCount == 3)

        // The switch, by Setup's own check.
        #expect(await setup.checkAccess(Domain("example.org")!) == .connected)
        #expect(setup.active == Domain("example.org")! && setup.generation == 2)

        // Nothing read on example.com shows.
        #expect(directory.users == nil && groups.groups == nil && usage.report == nil)
        #expect(access.lists(for: "alice@example.com") == nil && members.members(of: "sales@example.com") == nil)
        #expect(apps.state == nil && classroom.indexState == nil)
        guard case .idle = compromised.checkState else { Issue.record("\(compromised.checkState)"); return }
        // No preview shows, and none held there runs here: each is dropped, its confirm refused.
        for state in ["\(userChanges.state)", "\(groupChanges.state)", "\(builderChanges.state)"] { #expect(state == "idle") }
        try await yieldWhile(every: .milliseconds(10)) { await executor.heldCount > 0 }
        #expect(await executor.heldCount == 0)
        for held in [heldUser.preview, heldGroup.preview, heldBuilder.preview] {
            #expect(await executor.run(held, confirmation: confirmed).refusal == "That preview has expired or was already run — preview again.")
        }
    }

    /// Review of plan F6: a temporary password's details show on the old domain's person page, which a switch closes, so a
    /// switch with nothing running hid a password already set before it was handed over. It's warned of first.
    @Test func aTemporaryPasswordNotHandedOverIsWarnedOf() async throws {
        try await store("example.com", admin: "admin@example.com")
        try await store("example.org", admin: "admin@example.org")
        #expect(await setup.checkAccess(Domain("example.com")!) == .connected)
        let directory = DirectoryStore(setup: setup, runner: runner)
        await directory.load()
        let users = UserChanges(executor: executor, directory: directory)
        setup.runningRuns = { [users] in SwitchStops.running(jobs: JobBoard(), onboarding: nil, users: users) }
        let carol = try #require(directory.users?.first { $0.primaryEmail == "carol@example.com" })
        await users.previewTemporaryPassword(carol)
        guard case .previewing(let pending) = users.state else { Issue.record("\(users.state)"); return }
        await users.confirm(pending, confirmed)
        #expect(users.signIn != nil)
        #expect(await setup.checkAccess(Domain("example.org")!) == .warned)
        #expect(setup.switchWarning?.runs.map(\.title)
                == ["carol@example.com's temporary password, not handed over yet: switching closes it before Done"])
        users.doneWithSignIn()
        #expect(await setup.checkAccess(Domain("example.org")!) == .connected, "handed over: nothing to warn of")
    }

    /// A run a switch lands in: it stops before its next step in GamGUI's words, and its result, the old domain's, isn't shown
    /// on the new one (the jobs tray and Audit keep it), so nor is anything it would offer to run again.
    @Test func aRunASwitchLandsInIsNotShownOnTheNewDomain() async throws {
        try await store("example.com", admin: "admin@example.com")
        try await store("example.org", admin: "admin@example.org")
        #expect(await setup.checkAccess(Domain("example.com")!) == .connected)
        let groups = GroupStore(setup: setup, runner: runner)
        let members = GroupMembers(setup: setup, runner: runner)
        let changes = GroupChanges(executor: executor, setup: setup, members: members)
        await groups.load()
        let sales = try #require(groups.groups?.first { $0.email == "sales@example.com" })
        await changes.previewAdd("carol@example.com, dana@example.com", to: sales, role: .member)
        guard case .previewing(let pending) = changes.state else { Issue.record("\(changes.state)"); return }
        let setup = setup, steps = Mutex(0)
        await executor.setBeforeEachStep {
            if steps.withLock({ $0 += 1; return $0 }) == 2 { _ = await setup.checkAccess(Domain("example.org")!) }
        }
        await changes.confirm(pending, confirmed)
        #expect(setup.active == Domain("example.org")!)
        guard case .idle = changes.state else { Issue.record("\(changes.state)"); return }
    }
}
