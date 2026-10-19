import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Security
import Setup
import TestSupport
import Testing
import Vault

/// The compromised-account response against the strict mock: carol@ was taken over. Check Account reads and changes
/// nothing; the plan is the lock and the picks as one held preview; the run is exactly those commands, then the account
/// is read again.
@MainActor
@Suite("Compromised changes", .serialized)
final class CompromisedChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-compromised-\(UUID().uuidString)")
    let memory = MemoryStore()
    let setup: SetupModel
    let access: UserAccess
    let changes: CompromisedChanges
    let state: URL
    let argvLog: URL
    let auditURL: URL

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let vault = Vault(store: memory)
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        state = scratch.appending(path: "mock-state")
        argvLog = scratch.appending(path: "argv.log")
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": state.path, "GAM_MOCK_ARGV_LOG": argvLog.path]
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        let tenantSetup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), actor: "admin@example.com",
                                tenant: { @MainActor [weak tenantSetup] in tenantSetup.flatMap { s in s.active.map { ($0, s.generation) } } },
                                extraEnvironment: ["GAM_MOCK_STATE": state.path, "GAM_MOCK_ARGV_LOG": argvLog.path])
        changes = CompromisedChanges(executor: executor, setup: setup, access: access)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect(admin: String = "admin@example.com") async throws {
        let folder = scratch.appending(path: "config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "\#(admin)"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
    }

    private func checked(_ person: String = "carol@example.com") async throws -> CompromisedChanges.Check {
        await changes.check(person)
        return try #require(changes.check, "\(changes.checkState)")
    }

    private func plan(_ form: CompromisedChanges.Form) async throws -> CompromisedChanges.Plan {
        await changes.plan(form)
        guard case .planned(let plan) = changes.planState else { throw NotPlanned(state: "\(changes.planState)") }
        return plan
    }

    private func blocked(_ form: CompromisedChanges.Form) async -> String? {
        await changes.plan(form)
        guard case .blocked(let blocked) = changes.planState else { return nil }
        return blocked.reason
    }

    private func form(_ person: String = "carol@example.com") -> CompromisedChanges.Form {
        var form = CompromisedChanges.Form()
        form.person = person
        return form
    }

    /// Every argv the mock ran, in order.
    private func ran() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls
    }

    private func writes() -> [String] {
        ran().filter { !["print", "info", "show"].contains($0.first ?? "") && !($0.count > 2 && ["print", "info", "show"].contains($0[2])) }
            .map { GamCommandLine.text($0, masked: ArgvRedaction.redact($0)) }
    }

    @Test func theCheckReadsEverythingAndChangesNothing() async throws {
        try await connect()
        let check = try await checked()
        #expect(writes().isEmpty)
        #expect(check.user.primaryEmail == "carol@example.com" && !check.isConnectedAdmin)
        #expect(check.account.recoveryPhone == "+15555550123")
        #expect(try check.filters.get().map(\.id) == ["ANe1Bmj001", "ANe1Bmj002", "ANe1Bmj003"])
        #expect(try check.forwarding.get()?.enabled == true)
        #expect(try check.forwardingAddresses.get().count == 2)
        #expect(try check.delegates.get() == ["helpdesk@example.com"])
        #expect(try check.sendAs.get().map(\.address) == ["carol@example.com", "billing.desk@example.net"])
        #expect(try check.adminRoles.get().isEmpty)
        #expect(check.findings.first?.hasPrefix("Forwarding is on, to carol.home@example.org") == true, "\(check.findings)")
        #expect(check.isFor("CAROL@example.com ") && !check.isFor("alice@example.com"))
    }

    /// One read failing is said beside its list; the rest are still read. Gmail off fails every Gmail read, never the
    /// account or its admin roles.
    @Test func aFailedReadIsSaidNotTakenAsNone() async throws {
        try await connect()
        try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
        try Data().write(to: state.appending(path: "nogmail/carol@example.com"))
        let check = try await checked()
        for result in [check.filters.map { _ in () }, check.forwarding.map { _ in () }, check.delegates.map { _ in () },
                       check.sendAs.map { _ in () }, check.forwardingAddresses.map { _ in () }] {
            guard case .failure(let problem) = result else { Issue.record("a Gmail read passed with Gmail off"); continue }
            #expect(problem.summary.contains("Gmail"), "\(problem.summary)")
        }
        #expect((try? check.adminRoles.get()) != nil)
        await changes.check("stranger@example.com")
        guard case .failed(_, let reason) = changes.checkState else { Issue.record("\(changes.checkState)"); return }
        #expect(reason.hasPrefix("Couldn't read stranger@example.com"))
    }

    /// The confirm runs exactly the held commands, once each, in order; then the account is read again, and what the
    /// run removed is gone from it.
    @Test func theRunExecutesExactlyThePreviewAndTheCheckAgainShowsIt() async throws {
        try await connect()
        _ = try await checked()
        var form = form()
        form.done = [.password]
        form.filters = ["ANe1Bmj003"]
        form.delegates = ["helpdesk@example.com"]
        form.sendAs = ["billing.desk@example.net"]
        let plan = try await plan(form)
        #expect(plan.header == "Securing carol@example.com — 7 of 8 steps (1 ticked as already done)")
        #expect(plan.steps.map(\.commandLine) == [
            "gam user carol@example.com deprovision signout",
            "gam user carol@example.com forward off",
            "gam user carol@example.com delete filters ANe1Bmj003",
            "gam user carol@example.com delete delegate helpdesk@example.com",
            "gam user carol@example.com delete sendas billing.desk@example.net",
            "gam user carol@example.com imap off",
            "gam user carol@example.com pop off",
        ])
        #expect(plan.steps.allSatisfy { $0.requires.isEmpty }, "the reset is ticked: nothing stops anything else")
        #expect(plan.steps[4].risk == .destructive && plan.preview?.typedAddress == "carol@example.com")
        await changes.confirm(plan, OperatorConfirmation(confirmed: true, typedAddresses: ["carol@example.com"]))
        let run = try #require(changes.run)
        #expect(run.isComplete && changes.problem == nil, "\(run.results) \(changes.problem ?? "")")
        #expect(run.summary == "Securing carol@example.com complete — 7 of 7 steps succeeded.")
        #expect(writes() == plan.steps.map(\.commandLine))
        let again = try #require(changes.check)
        #expect(try again.forwarding.get()?.enabled == false)
        #expect(try again.filters.get().map(\.id) == ["ANe1Bmj001", "ANe1Bmj002"])
        #expect(try again.delegates.get().isEmpty)
        #expect(try again.sendAs.get().map(\.address) == ["carol@example.com"])
        let records = AuditLog.records(at: auditURL)
        #expect(records.filter { $0["extra"]?.object?["compromised"]?.string == "carol@example.com" }.count >= 7)
    }

    /// The rest of a run is that person's: its "already done" lock steps never carry to the next person checked, who
    /// would then lose their sign-out (review 2026-10-19). The rest itself plans only what's left.
    @Test func theRestIsThePersonsOwn() async throws {
        try await connect()
        _ = try await checked()
        var first = form()
        first.done = [.password]
        let plan = try await plan(first)
        await changes.confirm(plan, OperatorConfirmation(confirmed: true, typedAddresses: ["carol@example.com"]))
        var rest = try #require(changes.run).rest
        #expect(rest.restOf == "carol@example.com" && rest.done.isSuperset(of: [.revoke, .forward]))
        #expect(await blocked(rest) == "Every step is ticked as already done: there is nothing to run.")
        _ = try await checked("dana@example.com")
        rest.person = "dana@example.com"
        #expect(await blocked(rest)?.hasPrefix("Steps are ticked as already done from another person's run") == true)
        var dana = form("dana@example.com")
        dana.done = [.password]
        #expect(try await self.plan(dana).steps.first?.commandLine == "gam user dana@example.com deprovision signout")
    }

    /// The reset, when it runs, gates every other step; a typed address that isn't the person's runs nothing.
    @Test func theResetGatesTheRestAndTheAddressMustBeTyped() async throws {
        try await connect()
        _ = try await checked()
        let plan = try await plan(form())
        #expect(plan.steps.first?.commandLine == "gam update user carol@example.com password random changepassword off")
        #expect(plan.steps.dropFirst().allSatisfy { $0.requires == [0] })
        await changes.confirm(plan, OperatorConfirmation(confirmed: true, typedAddresses: ["alice@example.com"]))
        #expect(changes.run == nil && changes.problem != nil)
        #expect(writes().isEmpty)
    }

    /// Never the admin this app is connected as: the sign-out would delete the app's own token mid-run.
    @Test func theConnectedAdminCantBeSecuredFromHere() async throws {
        try await connect(admin: "carol@example.com")
        let check = try await checked()
        #expect(check.isConnectedAdmin)
        #expect(await blocked(form())?.hasPrefix("This app is connected as carol@example.com") == true)
    }

    /// A plan needs a check of the same person; a pick the check didn't list is never planned.
    @Test func aPlanNeedsTheCheckAndOnlyItsPicks() async throws {
        try await connect()
        #expect(await blocked(form())?.hasPrefix("Check the account first") == true)
        _ = try await checked()
        #expect(await blocked(form("alice@example.com"))?.hasPrefix("Check the account first") == true)
        var odd = form()
        odd.filters = ["NOTREAD"]
        odd.delegates = ["stranger@example.com"]
        odd.sendAs = ["carol@example.com"]   // the primary is never removed
        let plan = try await plan(odd)
        #expect(!plan.steps.contains { [.deleteFilters, .removeDelegate, .deleteSendAs].contains($0.action) })
    }

    /// Checked again at the run: an account suspended since the check runs nothing ("preview again").
    @Test func anAccountChangedSinceTheCheckRunsNothing() async throws {
        try await connect()
        _ = try await checked()
        var form = form()
        form.done = [.password]
        let plan = try await plan(form)
        try FileManager.default.createDirectory(at: state.appending(path: "suspended"), withIntermediateDirectories: true)
        try Data().write(to: state.appending(path: "suspended/carol@example.com"))
        await changes.confirm(plan, OperatorConfirmation(confirmed: true, typedAddresses: ["carol@example.com"]))
        #expect(changes.run == nil && changes.problem != nil, "\(changes.problem ?? "")")
        #expect(writes().isEmpty)
    }
}
