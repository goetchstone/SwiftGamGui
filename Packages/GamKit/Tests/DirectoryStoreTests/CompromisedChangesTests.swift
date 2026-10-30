import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Security
import Setup
import Stores
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
                                adminAccountID: { @MainActor [weak tenantSetup] in tenantSetup?.connectedAdminID },
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
        try Fixtures.oauth2(admin: admin).write(to: folder.appending(path: "oauth2.txt"))
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
        ran().filter { !["print", "info", "show", "report"].contains($0.first ?? "") && !($0.count > 2 && ["print", "info", "show"].contains($0[2])) }
            .map { GamCommandLine.text($0, masked: ArgvRedaction.redact($0)) }
    }

    @Test func theCheckReadsEverythingAndChangesNothing() async throws {
        try await connect()
        let check = try await checked()
        #expect(try check.devices.get().count == 2)
        #expect(try check.apps.get().map(\.name) == ["Mail Sync Pro", "Google Chrome"], "the broadest first")
        #expect(check.findings.contains { $0.hasPrefix("2 apps have access to carol@example.com's account (broad: Mail Sync Pro). The sign-out revokes them all") })
        #expect(check.findings.contains { $0.hasPrefix("2 phones or tablets sync carol@example.com's account") })
        #expect(try check.computers.get().map(\.model) == ["Virtual Machine", "MacBook Pro"], "her own, never the prefix's other account's")
        #expect(try check.scripts.get().map(\.name) == ["Inbox Helper", "Untitled project", "Timesheet export"], "the latest changed first")
        #expect(check.findings.contains { $0.hasPrefix("2 computers are signed in with carol@example.com's account, 1 of them a virtual machine") })
        #expect(writes().isEmpty)
        #expect(check.user.primaryEmail == "carol@example.com" && !check.isConnectedAdmin)
        #expect(check.account.recoveryPhone == "+15555550123")
        #expect(try check.filters.get().map(\.id) == ["ANe1Bmj001", "ANe1Bmj002", "ANe1Bmj003"])
        #expect(try check.forwarding.get()?.enabled == true)
        #expect(try check.forwardingAddresses.get().count == 2)
        #expect(try check.delegates.get() == ["helpdesk@example.com"])
        #expect(try check.sendAs.get().map(\.address) == ["carol@example.com", "billing.desk@example.net"])
        #expect(try check.adminRoles.get().isEmpty)
        // What goes out on its own first, then what keeps going out.
        #expect(check.findings.first?.hasPrefix("1 email is scheduled to send from carol@example.com") == true, "\(check.findings)")
        #expect(check.findings.dropFirst().first?.hasPrefix("Forwarding is on, to carol.home@example.org") == true, "\(check.findings)")
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
                       check.sendAs.map { _ in () }, check.forwardingAddresses.map { _ in () }, check.scheduled.map { _ in () }] {
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

    /// A computer the attacker signed in on, blocked or the account taken off it from the plan: each its own previewed step
    /// by the person's sign-in on it, removal destructive; the run blocks the virtual machine, and the check again shows it
    /// blocked, so its pick drops. A computer not picked, or already blocked, runs nothing.
    @Test func aComputerIsBlockedOrRemovedFromThePlan() async throws {
        try await connect()
        let check = try await checked()
        #expect(try check.computers.get().map(\.deviceUser) == ["devices/0vmcarol01/deviceUsers/u1", "devices/0maccarol01/deviceUsers/u2"])
        var form = form()
        form.switchedOn = []
        form.computers = ["devices/0vmcarol01/deviceUsers/u1": .block, "devices/0maccarol01/deviceUsers/u2": .delete]
        let both = try await plan(form)
        #expect(both.steps.map(\.commandLine) == ["gam block deviceuser devices/0vmcarol01/deviceUsers/u1",
                                                  "gam delete deviceuser devices/0maccarol01/deviceUsers/u2"])
        #expect(both.steps[1].risk == .destructive)
        form.computers = ["devices/0vmcarol01/deviceUsers/u1": .block]
        let plan = try await plan(form)
        #expect(plan.steps.first?.summary.hasPrefix("Block carol@example.com's sign-in on Virtual Machine, Windows 10.0.19045") == true)
        await changes.confirm(plan, OperatorConfirmation(confirmed: true, typedAddresses: ["carol@example.com"]))
        let run = try #require(changes.run)
        #expect(run.isComplete && changes.problem == nil, "\(run.results) \(changes.problem ?? "")")
        #expect(writes() == ["gam block deviceuser devices/0vmcarol01/deviceUsers/u1"])
        let again = try #require(changes.check)
        #expect(try again.computers.get().first { $0.id == "devices/0vmcarol01" }?.state == "blocked")
        form.keepPicks(in: again)
        #expect(form.computers.isEmpty, "blocked now: nothing more to do")
    }

    /// A to-do item's "Do It Here" picks only its own fix, the lock steps off: the computer by the Devices log's ID, else
    /// the one first signed in within two minutes of the registration; nothing when neither matches.
    @Test func doItHerePicksOnlyItsOwnFix() async throws {
        try await connect()
        let check = try await checked()
        var form = form()
        let byID = form.pickOnly(computer: "0vmcarol01", registeredAt: nil, in: check)
        #expect(byID)
        #expect(form.switchedOn.isEmpty && form.computers == ["devices/0vmcarol01/deviceUsers/u1": .block])
        let joined = try Date("2026-10-19T14:13:30Z", strategy: .iso8601)
        form = self.form()
        let unknownID = form.pickOnly(computer: "an-id-the-api-doesnt-use", registeredAt: joined, in: check)
        #expect(unknownID)
        #expect(form.computers == ["devices/0vmcarol01/deviceUsers/u1": .block])
        form = self.form()
        let tooLate = form.pickOnly(computer: "", registeredAt: joined.addingTimeInterval(600), in: check)
        #expect(!tooLate)
        #expect(form.switchedOn.isEmpty && form.computers.isEmpty, "nothing matched: nothing picked")
        form.pickOnlyClearRecovery()
        #expect(form.switchedOn == [.clearRecovery])
        let plan = try await plan(form)
        #expect(plan.steps.allSatisfy { $0.summary.localizedCaseInsensitiveContains("recovery") }, "\(plan.steps.map(\.summary))")
        // Blocked now: named by its ID, it picks nothing, never the person's own Mac that signed in near that time.
        var block = self.form()
        block.switchedOn = []
        block.computers = ["devices/0vmcarol01/deviceUsers/u1": .block]
        await changes.confirm(try await self.plan(block), OperatorConfirmation(confirmed: true, typedAddresses: ["carol@example.com"]))
        let again = try #require(changes.check)
        var after = self.form()
        let macSignedIn = try Date("2025-02-03T15:05:30Z", strategy: .iso8601)
        let named = after.pickOnly(computer: "0vmcarol01", registeredAt: macSignedIn, in: again)
        #expect(!named && after.computers.isEmpty)
        let byTime = after.pickOnly(computer: "", registeredAt: macSignedIn, in: again)
        #expect(byTime && after.computers == ["devices/0maccarol01/deviceUsers/u2": .block], "with no ID, the time decides")
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

    /// Users' "Secure Account…" hands over only an address: the screen starts a new form for it and checks it, nothing
    /// ticked, and the plan is the screen's own, the reset first and the address to type (no second write path).
    @Test func secureAccountFromAPersonsPageIsTheScreensOwnFlow() async throws {
        try await connect()
        let form = CompromisedChanges.Form(person: "dana@example.com")
        #expect(form.done.isEmpty && form.restOf.isEmpty && form.switchedOn == Compromised.Step.onByDefault)
        #expect(form.filters.isEmpty && form.delegates.isEmpty && form.sendAs.isEmpty)
        _ = try await checked("dana@example.com")
        let plan = try await plan(form)
        #expect(plan.steps.first?.commandLine == "gam update user dana@example.com password random changepassword off")
        #expect(plan.preview?.typedAddress == "dana@example.com" && writes().isEmpty)
    }

    /// A person's mailbox searched from their page: reads only, kept per person on this tenant.
    @Test func aMailboxSearchIsThePersonsOwn() async throws {
        try await connect()
        let searches = MailboxSearches(setup: setup, access: access)
        await searches.search("carol@example.com", query: MailboxSearch.defaultQuery)
        guard case .found(let query, let result)? = searches.state(for: "carol@example.com") else {
            Issue.record("\(String(describing: searches.state(for: "carol@example.com")))"); return
        }
        let found = try result.get()
        #expect(query == "in:sent newer_than:3d" && found.first?.bcc.count == 7)
        #expect(searches.state(for: "alice@example.com") == nil && writes().isEmpty)
    }

    /// Apps Script through the real read: someone with none reads as none (GAM's 60 with its own "Got 0"); a refusal GAM
    /// prints no word for is a failure, never "none".
    @Test func scriptsOfSomeoneWithNoneAreNoneAndARefusalIsSaid() async throws {
        try await connect()
        #expect(try await checked("dana@example.com").scripts.get().isEmpty)
        try FileManager.default.createDirectory(at: state.appending(path: "quiet"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "quiet/carol@example.com").path, contents: Data())
        guard case .failure(let problem) = try await checked().scripts else { Issue.record("not refused"); return }
        #expect(problem.summary.contains("exit=60"), "\(problem.summary)")
    }

    /// A domain whose service account can't read devices: the computers say how to grant the scope, and the rest of the check
    /// reads as before; nothing is taken for "no computer".
    @Test func computersWithoutTheScopeSayHowToGrantIt() async throws {
        try await connect()
        try FileManager.default.createDirectory(at: state.appending(path: "noscope"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "noscope/devices").path, contents: Data())
        let check = try await checked()
        guard case .failure(let problem) = check.computers else { Issue.record("\(check.computers)"); return }
        #expect(problem.summary.contains("exit=73") && problem.summary.hasSuffix(Compromised.Computer.delegationNote), "\(problem.summary)")
        #expect(try check.devices.get().count == 2 && !check.findings.contains { $0.contains("computer") })
        #expect(writes().isEmpty)
    }

    /// Every account's connected apps, read for Reports: AI assistants and agents first, never a suspended account's grants,
    /// counted and said in words, kept for the tenant; a refusal is GAM's words.
    @Test func everyAccountsConnectedAppsAreRead() async throws {
        try await connect()
        let reads = ConnectedAppsRead(setup: setup, access: access)
        await reads.read()
        guard case .read(.success(let apps), _)? = reads.state else { Issue.record("\(String(describing: reads.state))"); return }
        #expect(apps.map(\.name) == ["ChatGPT", "Read AI Notetaker", "Mail Sync Pro", "Zoom", "macOS"])
        #expect(apps.first { $0.name == "Zoom" }?.users == ["alice@example.com", "dana@example.com"], "bob@ is suspended")
        #expect(ConnectedApps.Summary(apps).sentences == [
            "3 people have given 5 apps access.",
            "2 apps look like an AI assistant or agent by name, granted by 1 person; none with broad access.",
            "1 app has broad access, to all of Gmail or reading and changing mail.",
            "3 apps were granted by one person only, among them 2 that look like AI and 1 with broad access.",
            "At most 2 people granted any one app.",
        ])
        try FileManager.default.createDirectory(at: state.appending(path: "denied"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "denied/tokens").path, contents: Data())
        await reads.read()
        guard case .read(.failure(let problem), _)? = reads.state else { Issue.record("not refused"); return }
        #expect(problem.summary.contains("exit=12"), "\(problem.summary)")
        #expect(writes().isEmpty)
    }

    /// A person's Chrome profiles read from their page: reads only, kept per person on this tenant, a failure in GAM's words.
    @Test func aPersonsChromeProfilesAreTheirOwn() async throws {
        try await connect()
        let reads = ChromeProfileReads(setup: setup, access: access)
        await reads.read("carol@example.com")
        guard case .read(.success(let profiles))? = reads.state(for: "carol@example.com") else {
            Issue.record("\(String(describing: reads.state(for: "carol@example.com")))"); return
        }
        #expect(profiles.map(\.device) == ["CAROL-MBP", "OptiPlex 7010"] && reads.state(for: "dana@example.com") == nil)
        try FileManager.default.createDirectory(at: state.appending(path: "noscope"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "noscope/chromemanagement").path, contents: Data())
        await reads.read("dana@example.com")
        guard case .read(.failure(let problem))? = reads.state(for: "dana@example.com") else { Issue.record("not refused"); return }
        #expect(problem.summary.contains("Chrome Management API") && problem.summary.contains("exit=15"), "\(problem.summary)")
        #expect(problem.summary.hasSuffix(ChromeProfiles.scopeNote), "the scope's fix, said for a missing scope")
        #expect(writes().isEmpty)
    }

    /// Chrome's log for several accounts reads each one both ways (by the profile's account, and GAM's own device match,
    /// which finds a Chromebook's sign-in), each event once, newest first together; one read that can't be made fails the
    /// log, never a part passed as the whole.
    @Test func chromesLogIsEachAccountsBothWays() async throws {
        try await connect()
        let logs = IncidentLogs(setup: setup, access: access)
        await logs.pull(IncidentLogs.Query(applications: [.chrome], users: ["carol@example.com", "dana@example.com"], hours: 72, ip: ""))
        let rows = try #require(logs.pull?.logs.first).rows.get()
        #expect(rows.map(\.event) == ["UNSAFE_SITE_VISIT", "PASSWORD_BREACH", "CHROME_OS_LOGIN_FAILURE_EVENT", "PASSWORD_REUSE",
                                     "LOGIN_EVENT"], "the breach both reads found, once")
        #expect(rows.map(\.who) == ["dana@example.com", "dana@example.com", "dana@example.com", "carol@example.com", "carol@example.com"])
        let read = try String(contentsOf: argvLog, encoding: .utf8)
        #expect(read.contains("PROFILE_USER_NAME==carol@example.com") && read.contains("PROFILE_USER_NAME==dana@example.com"))
        #expect(read.contains("chrome\u{0}user\u{0}carol@example.com\u{0}start") && read.contains("chrome\u{0}user\u{0}dana@example.com\u{0}start"))
        try FileManager.default.createDirectory(at: state.appending(path: "nolog"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "nolog/chrome").path, contents: Data())
        await logs.pull(IncidentLogs.Query(applications: [.chrome], users: ["carol@example.com", "dana@example.com"], hours: 72, ip: ""))
        guard case .failure(let problem)? = logs.pull?.logs.first?.rows else { Issue.record("a failed read passed"); return }
        #expect(problem.summary.hasPrefix("carol@example.com: "), "\(problem.summary)")
        #expect(writes().isEmpty)
    }

    /// A log at the cap is read on further back over the same window until it's whole: every account's sign-ins, three at
    /// a time, come back all ten, none twice, newest first, and not capped; named accounts each go on by themselves.
    @Test func aCappedLogIsReadFurtherBack() async throws {
        try await connect()
        // The mock's events are on fixed dates: a pull just after them, so the window's fixed start is before them all.
        let logs = IncidentLogs(setup: setup, access: access, cap: 3, clock: { Date(timeIntervalSince1970: 1_792_454_400) })
        await logs.pull(IncidentLogs.Query(applications: [.login], users: [], hours: 72, ip: ""))
        let every = try #require(logs.pull?.logs.first)
        let rows = try every.rows.get()
        #expect(rows.count == 10 && Set(rows.map(\.identity)).count == 10 && !every.capped, "\(rows.map(\.time))")
        #expect(rows.map(\.time) == rows.map(\.time).sorted(by: >))
        await logs.pull(IncidentLogs.Query(applications: [.login], users: ["carol@example.com", "dana@example.com"], hours: 72, ip: ""))
        let named = try #require(logs.pull?.logs.first)
        #expect(try named.rows.get().filter { $0.who == "carol@example.com" }.count == 7 && !named.capped)
        #expect(try named.rows.get().filter { $0.who == "dana@example.com" }.count == 1)
        #expect(writes().isEmpty)
    }

    /// Reading further back stays bounded (invariant 9): at most `ActivityLogs.pages` reads, from one fixed start, then
    /// capped. A later read that fails keeps what came back, said as capped; a first read that fails is the failure.
    @Test func readingFurtherBackStaysBounded() async throws {
        let base = Date(timeIntervalSince1970: 1_792_400_000)
        // Forty sign-ins a minute apart, newest first, as GAM prints them.
        let events = (0..<40).map { base.addingTimeInterval(Double(-60 * $0)) }
        func page(before end: String) -> [ActivityLogs.Row] {
            let kept = events.filter { end.isEmpty || IncidentLogs.time($0) < end }.prefix(3)
            return ActivityLogs.rows("name,actor.email,id.time,id.uniqueQualifier\n" + kept.map {
                "login_success,carol@example.com,\(IncidentLogs.time($0)),q\(Int($0.timeIntervalSince1970))"
            }.joined(separator: "\n"), application: .login)
        }
        let window = (start: IncidentLogs.time(base.addingTimeInterval(-72 * 3_600)), end: IncidentLogs.time(base))
        var reads = 0, starts: Set<String> = []
        let (rows, capped) = await IncidentLogs.paged(users: [], window: window, cap: 3) { _, start, end in
            reads += 1
            starts.insert(start)
            return .success(page(before: end))
        }
        // Each read after the first repeats the one it ended on, and brings two more.
        #expect(reads == ActivityLogs.pages && capped && starts == [window.start])
        #expect(try rows.get().count == 3 + (ActivityLogs.pages - 1) * 2)
        reads = 0
        let (kept, cut) = await IncidentLogs.paged(users: [], window: window, cap: 3) { _, _, end in
            reads += 1
            return reads == 1 ? .success(page(before: end)) : .failure(UserAccess.Problem(summary: "timed out"))
        }
        #expect(try kept.get().count == 3 && cut)
        let (failed, _) = await IncidentLogs.paged(users: [], window: window, cap: 3) { _, _, _ in
            .failure(UserAccess.Problem(summary: "timed out"))
        }
        guard case .failure = failed else { Issue.record("a failed read passed"); return }
        // One account read by an alias: every row is that read's, though each names the primary address. Several accounts,
        // one of them by an alias: the primary's rows at the cap can't be gone on with, so the log is capped.
        let (_, byAlias) = await IncidentLogs.paged(users: ["carol.alias@example.com"], window: window, cap: 3) { _, _, end in
            .success(page(before: end))
        }
        #expect(byAlias)
        let (_, mixed) = await IncidentLogs.paged(users: ["carol.alias@example.com", "dana@example.com"], window: window, cap: 3) { _, _, end in
            .success(page(before: end))
        }
        #expect(mixed)
    }

    /// A log read whole, oldest first (as asked for): one read of the window, and at the cap, a day at a
    /// time from its start, each day read back until it's whole; every event once. Bounded: past its reads it stops at a
    /// day's start, the older days whole, and says when it was read through.
    @Test func aLogIsReadWholeOldestFirst() async throws {
        let start = Date(timeIntervalSince1970: 1_792_400_400), end = start.addingTimeInterval(3 * 86_400)
        // An event every 20 minutes for three days, newest first, as GAM gives them; the window kept as Google keeps it.
        let events = stride(from: end.addingTimeInterval(-600), to: start, by: -1_200).map { $0 }
        var starts: [String] = []
        func read(_ from: String, _ to: String) -> Result<[ActivityLogs.Row], UserAccess.Problem> {
            starts.append(from)
            let kept = events.filter { IncidentLogs.time($0) >= from && IncidentLogs.time($0) < to }.prefix(50)
            return .success(ActivityLogs.rows("name,actor.email,id.time,id.uniqueQualifier\n" + kept.map {
                "login_success,carol@example.com,\(IncidentLogs.time($0)),q\(Int($0.timeIntervalSince1970))"
            }.joined(separator: "\n"), application: .login))
        }
        var heard: [Date] = [], counts: [Int] = []
        let whole = await IncidentLogs.complete(users: [], start: start, end: end, cap: 50) { heard.append($0) } read: { _, from, to in
            read(from, to)
        } reading: { counts.append($0) }
        let rows = try whole.rows.get()
        #expect(whole.through == nil && rows.count == events.count && Set(rows.map(\.identity)).count == events.count)
        // Heard after every read, each event once: the first read at the cap counts none (its days are read again).
        #expect(counts.count == starts.count && counts.first == 0 && counts.last == events.count && counts == counts.sorted())
        #expect(rows.map(\.time) == rows.map(\.time).sorted(by: >), "shown newest first")
        let dayStarts = Array(starts.dropFirst()).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        #expect(dayStarts == [0, 1, 2].map { IncidentLogs.time(start.addingTimeInterval(Double($0) * 86_400)) }, "the oldest day first")
        #expect(heard == [1, 2, 3].map { start.addingTimeInterval(Double($0) * 86_400) })

        starts = []
        let bounded = await IncidentLogs.complete(users: [], start: start, end: end, cap: 50, budget: 4) { _ in } read: { _, from, to in
            read(from, to)
        }
        let dayTwo = start.addingTimeInterval(86_400)
        #expect(bounded.through == dayTwo, "the first day whole, the second not")
        let kept = try bounded.rows.get()
        #expect(kept.filter { ($0.date ?? .distantFuture) < dayTwo }.count == 72 && starts.count == 4)
    }

    /// Pull Incident Logs reads and changes nothing: the person's logs, then every account's by the address on their
    /// flagged sign-in, where another account signed in from it too; each log in the query's order, and as a CSV. An
    /// address that isn't one is refused in words, in every log.
    @Test func incidentLogsFindTheSameAttackerElsewhere() async throws {
        try await connect()
        let logs = IncidentLogs(setup: setup, access: access)
        await logs.pull(IncidentLogs.Query(applications: ActivityLogs.incidentDefault, users: ["carol@example.com"], hours: 72, ip: ""))
        let person = try #require(logs.pull)
        #expect(person.ended && person.logs.map(\.application) == ActivityLogs.incidentDefault)
        #expect(try person.logs[0].rows.get().count == 7 && !person.logs[0].capped)
        // The admin log read both ways: what was done to her (the lock), and what she did as an admin (nothing).
        let admin = try #require(person.logs.first { $0.application == .admin }).rows.get()
        #expect(admin.map(\.event) == ["RESET_SIGNIN_COOKIES", "REVOKE_3LO_TOKEN", "DELETE_2SV_SCRATCH_CODES", "CHANGE_PASSWORD"]
                && admin.allSatisfy { $0.who == "alice@example.com" && $0.details.first == "to carol@example.com" })
        let address = try #require(person.addresses.first)
        await logs.pull(IncidentLogs.Query(applications: [.login, .userAccounts], users: [], hours: 72, ip: address))
        let domain = try #require(logs.pull)
        #expect(Set(try domain.logs[0].rows.get().map(\.who)) == ["carol@example.com", "dana@example.com"])
        #expect(try domain.logs[1].rows.get().map(\.event) == ["recovery_phone_edit"])
        // The Devices log has no address: by one it would be empty, so its registrations are read instead, for the reader to
        // tie to the sign-ins by time.
        await logs.pull(IncidentLogs.Query(applications: [.mobile], users: [], hours: 72, ip: address))
        let devices = try #require(logs.pull?.logs.first).rows.get()
        #expect(devices.map(\.who) == ["carol@example.com", "alice@example.com"]
                && devices.allSatisfy { $0.event == "DEVICE_REGISTER_UNREGISTER_EVENT" })
        #expect(writes().isEmpty)
        let csv = IncidentLogs.csv(domain.logs[0])
        #expect(csv.hasPrefix("log,time,actor,event,ip_address,flagged,via,parameters\r\nlogin,") && csv.contains("198.51.100.23"))
        await logs.pull(IncidentLogs.Query(applications: [.login], users: [], hours: 72, ip: "198.51.100"))
        guard case .failure(let problem)? = logs.pull?.logs.first?.rows else { Issue.record("not refused"); return }
        #expect(problem.summary.contains("isn't one IP address"))
        #expect(IncidentLogs.Query.accounts(" carol@example.com, dana@example.com\nalice@example.com CAROL@example.com")
                == ["carol@example.com", "dana@example.com", "alice@example.com"])
        // Six months asked: Gmail reads its 30 days, and says so; the others the whole window.
        await logs.pull(IncidentLogs.Query(applications: [.login, .gmail], users: ["carol@example.com"], hours: 4_320, ip: ""))
        let long = try #require(logs.pull)
        #expect(long.logs.map(\.hours) == [4_320, 720] && (try? long.logs[1].rows.get()) != nil)
    }

    /// Export All writes every log that was read, and only those, into a new private folder with a note of what was
    /// pulled; a second export never reuses the first's folder, and a folder that can't be written leaves nothing.
    @Test func exportAllSavesEveryReadLogInANewPrivateFolder() async throws {
        try await connect()
        let logs = IncidentLogs(setup: setup, access: access)
        await logs.pull(IncidentLogs.Query(applications: [.login, .userAccounts], users: ["carol@example.com"], hours: 72, ip: ""))
        let read = try #require(logs.pull)
        await logs.pull(IncidentLogs.Query(applications: [.token], users: [], hours: 72, ip: "198.51.100"))
        let refused = try #require(logs.pull?.logs.first)
        let pull = IncidentLogs.Pull(query: read.query, logs: read.logs + [refused], ended: true)
        let parent = scratch.appending(path: "exports")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        let utc = try #require(TimeZone(identifier: "UTC"))

        let first = try IncidentLogs.exportAll(pull, into: parent, at: now, timeZone: utc)
        #expect(first.folder.lastPathComponent == "Incident logs 2026-10-20 1240")
        #expect(first.written == [.login, .userAccounts] && first.unread == [.token])
        let files = try FileManager.default.contentsOfDirectory(atPath: first.folder.path).sorted()
        #expect(files == ["about.txt", "login-log.csv", "useraccounts-log.csv"], "no CSV for the log that wasn't read")
        #expect(try String(contentsOf: first.folder.appending(path: "login-log.csv"), encoding: .utf8) == IncidentLogs.csv(read.logs[0]))
        let about = try String(contentsOf: first.folder.appending(path: "about.txt"), encoding: .utf8)
        #expect(about.contains("Accounts: carol@example.com."), "\(about)")
        #expect(about.contains("From IP address: any.") && about.contains("Over the last 3 days."))
        #expect(about.contains("Not exported, not read: the "))
        let mode = try FileManager.default.attributesOfItem(atPath: first.folder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)

        let second = try IncidentLogs.exportAll(pull, into: parent, at: now, timeZone: utc)
        #expect(second.folder.lastPathComponent == "Incident logs 2026-10-20 1240 (2)")
        #expect(throws: (any Error).self) { try IncidentLogs.exportAll(pull, into: parent.appending(path: "missing"), at: now, timeZone: utc) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).count == 2)
        #expect(writes().isEmpty)
    }

    /// An incident's saved evidence reads back as what was pulled: the mock's logs exported, then read from their files, are
    /// the same events (when, who, the event, the address, flagged, who acted, every parameter), in the same order; a second
    /// export of the same events counts each once; the export is known as this domain's.
    @Test func savedEvidenceReadsBackAsThePull() async throws {
        try await connect()
        let logs = IncidentLogs(setup: setup, access: access)
        await logs.pull(IncidentLogs.Query(applications: ActivityLogs.incidentDefault + [.chrome, .drive],
                                           users: ["carol@example.com", "dana@example.com"], hours: 72, ip: ""))
        let pull = try #require(logs.pull)
        let parent = scratch.appending(path: "evidence")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let utc = try #require(TimeZone(identifier: "UTC"))
        let first = try IncidentLogs.exportAll(pull, into: parent, at: Date(timeIntervalSince1970: 1_792_500_000), timeZone: utc)
        let second = try IncidentLogs.exportAll(pull, into: parent, at: Date(timeIntervalSince1970: 1_792_500_060), timeZone: utc)
        func export(_ folder: URL) throws -> ActivityLogs.Export {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            let logs = try names.compactMap { name -> (application: ActivityLogs.Application, csv: String)? in
                guard name.hasSuffix("-log.csv"), let application = ActivityLogs.Application(rawValue: String(name.dropLast(8))) else { return nil }
                return (application, try String(contentsOf: folder.appending(path: name), encoding: .utf8))
            }
            return ActivityLogs.Export(name: folder.lastPathComponent, about: try String(contentsOf: folder.appending(path: "about.txt"), encoding: .utf8),
                                       logs: logs)
        }
        let once = await IncidentLogs.evidence([try export(first.folder)])
        #expect(once.unreadable.isEmpty && once.pull.fromEvidence && once.pull.ended)
        #expect(once.pull.query.users == ["carol@example.com", "dana@example.com"] && once.pull.query.hours == 72 && once.pull.query.ip.isEmpty)
        func shape(_ row: ActivityLogs.Row) -> [String] {
            [row.application.rawValue, row.time, row.who, row.event, row.ip, String(row.flagged), row.agent, row.app]
                + row.parameters.map { "\($0.name)=\($0.value)" }
        }
        var compared = 0
        for log in pull.logs {
            guard let original = try? log.rows.get() else { continue }
            let saved = try #require(once.pull.logs.first { $0.application == log.application }, "\(log.application)").rows.get()
            #expect(saved.map(shape) == original.map(shape), "\(log.application)")
            compared += original.count
        }
        #expect(compared > 20, "the mock's events, every log")
        #expect(pull.logs.contains { ((try? $0.rows.get()) ?? []).contains { !$0.agent.isEmpty || !$0.app.isEmpty } }, "who acted is covered")
        let twice = await IncidentLogs.evidence([try export(first.folder), try export(second.folder)])
        #expect(twice.pull.logs.map { (try? $0.rows.get().count) ?? -1 } == once.pull.logs.map { (try? $0.rows.get().count) ?? -1 })
        #expect(IncidentLogs.export(try export(first.folder), isFrom: "example.com"))
        #expect(!IncidentLogs.export(try export(first.folder), isFrom: "example.org"))
        #expect(writes().isEmpty)
    }

    /// A pull made while an incident is open is added to the evidence shown in memory, never by reading every saved pull
    /// back (failure log 2026-10-23): what Export All wrote is what the store reads back, the newer export reads back last
    /// (by name, "(2)" within the same minute), and the evidence with it added is the read-back's, event for event, with
    /// the same window, accounts and caps.
    @Test func aPullAddedToAnIncidentIsWhatReadingItBackGives() async throws {
        try await connect()
        let logs = IncidentLogs(setup: setup, access: access)
        await logs.pull(IncidentLogs.Query(applications: [.login, .token, .admin], users: [], hours: 72, ip: ""))
        let wide = try #require(logs.pull)
        await logs.pull(IncidentLogs.Query(applications: [.login, .gmail], users: ["carol@example.com"], hours: 72, ip: ""))
        let narrow = try #require(logs.pull)
        var store = try IncidentStore(root: scratch.appending(path: "incidents"))
        let record = try store.create(domain: "example.com", title: "Account takeover", opened: Date(), openedBy: "Pat", reported: "")
        let folder = try store.evidenceFolder(of: record.id)
        let utc = try #require(TimeZone(identifier: "UTC")), at = Date(timeIntervalSince1970: 1_792_500_000)
        let first = try IncidentLogs.exportAll(wide, into: folder, at: at, timeZone: utc).export
        let second = try IncidentLogs.exportAll(narrow, into: folder, at: at, timeZone: utc).export
        let saved = store.exports(of: record.id)
        #expect(saved.unreadable.isEmpty && saved.exports.map(\.name) == [first.name, second.name])
        for (written, read) in zip([first, second], saved.exports) {
            #expect(written.name == read.name && written.about == read.about)
            #expect(Dictionary(written.logs.map { ($0.application, $0.csv) }) { a, _ in a }
                    == Dictionary(read.logs.map { ($0.application, $0.csv) }) { a, _ in a })
        }
        #expect(IncidentStore.readsBackLast(second, after: [first.name], saved: 1))
        let readBack = await IncidentLogs.evidence(saved.exports).pull
        let added = IncidentLogs.adding(second, to: await IncidentLogs.evidence([first]).pull)
        let inMemory = try #require(added.together)
        #expect(added.readable && inMemory.fromEvidence && inMemory.ended)
        #expect(inMemory.query == readBack.query && inMemory.logs.map(\.application) == readBack.logs.map(\.application))
        for (mine, theirs) in zip(inMemory.logs, readBack.logs) {
            #expect(mine.hours == theirs.hours && mine.capped == theirs.capped && mine.through == theirs.through)
            #expect(try mine.rows.get() == theirs.rows.get(), "\(mine.application)")
        }
        #expect(try inMemory.logs[0].rows.get().count >= wide.logs[0].rows.get().count, "the wider read's sign-ins all kept")
        #expect(writes().isEmpty)
    }

    /// With an incident open, a pull is saved before it ends (`keep`): the hook gets what was read while the pull still
    /// reads, and what it gives back is the pull, read by the log reader once; nil (not saved) shows the read as it is.
    /// Each log's progress ends done, with its events and the reads it took.
    @Test func aPullIsKeptBeforeItEnds() async throws {
        try await connect()
        let logs = IncidentLogs(setup: setup, access: access)
        var handed: [IncidentLogs.Query] = [], stillReading: [Bool] = []
        logs.keep = { read in
            handed.append(read.query)
            stillReading.append(logs.isPulling && logs.isKeeping && read.ended)
            return await IncidentLogs.evidence([]).pull
        }
        let query = IncidentLogs.Query(applications: [.login, .token], users: [], hours: 72, ip: "")
        await logs.pull(query)
        #expect(handed == [query] && stillReading == [true])
        #expect(logs.pull?.fromEvidence == true && logs.pull?.ended == true && !logs.isKeeping)
        let login = try #require(logs.progress[.login])
        #expect(login.state == .done && !login.failed && login.events > 0 && login.reads >= 1)
        logs.keep = { _ in nil }
        await logs.pull(query)
        #expect(logs.pull?.fromEvidence == false && logs.pull?.logs.map(\.application) == [.login, .token])
        #expect(writes().isEmpty)
    }

    /// Pull Again for the accounts that matter adds to what's shown: a narrower read never takes away what the wider one
    /// found, and an event both read is there once.
    @Test func pullingAgainAddsToWhatsShown() async throws {
        try await connect()
        let logs = IncidentLogs(setup: setup, access: access)
        await logs.pull(IncidentLogs.Query(applications: [.login, .token], users: [], hours: 72, ip: ""))
        let wide = try #require(logs.pull)
        await logs.pull(adding: IncidentLogs.Query(applications: [.login, .gmail], users: ["carol@example.com"], hours: 72, ip: ""))
        let together = try #require(logs.pull)
        #expect(together.ended && !together.fromEvidence && together.query.users.isEmpty, "every account, as the wider read was")
        #expect(together.logs.map(\.application) == [.login, .token, .gmail])
        let login = try together.logs[0].rows.get(), before = try wide.logs[0].rows.get()
        #expect(login.count == before.count && Set(login.map(\.identity)) == Set(before.map(\.identity)), "carol@'s sign-ins once")
        #expect(try together.logs[1].rows.get().count == wide.logs[1].rows.get().count)
        #expect(writes().isEmpty)
    }

    /// A read cut off at the runner's cap is a failure in words, never rows that pass as all there is (review 2026-10-19).
    @Test func aCutOffReadIsNeverTakenAsWhole() {
        let cut = GamResult(exitCode: 0, stdout: "name,actor.email\nlogin_success,dana@exa", stderr: "", stdoutTruncated: true,
                            stderrTruncated: false)
        guard case .failure(let problem) = UserAccess.outcome(cut, argv: ["report", "login"], parse: { ActivityLogs.rows($0, application: .login) })
        else { Issue.record("a cut-off read passed"); return }
        #expect(problem.summary.hasPrefix("GAM printed more than 8 MiB"))
        let whole = GamResult(exitCode: 0, stdout: "name\n", stderr: "", stdoutTruncated: false, stderrTruncated: false)
        #expect((try? UserAccess.outcome(whole, argv: [], parse: { ActivityLogs.rows($0, application: .login) }).get())?.isEmpty == true)
    }

    /// The check lists the drafts; those whose subject matches are deleted in one step through the executor, exactly as
    /// held, and the check again lists what's left. All of them is the same step over every listed ID; a subject that
    /// matches nothing plans nothing.
    @Test func draftsByTheirSubjectAreDeletedAndTheCheckAgainShowsWhatsLeft() async throws {
        try await connect()
        let check = try await checked()
        let drafts = try check.drafts.get()
        #expect(drafts.count == 3 && check.findings.contains { $0.hasPrefix("carol@example.com has 3 drafts") })
        var form = form()
        form.done = [.password]
        form.discardDrafts = .all
        let all = try await plan(form)
        #expect(all.steps.contains { $0.commandLine == "gam user carol@example.com delete messages ids "
                                     + "19a0c0ffee000011,19a0c0ffee000012,19a0c0ffee000013" })
        form.discardDrafts = .subjectContaining("nothing like it")
        #expect(await blocked(form)?.hasPrefix("No draft's subject contains “nothing like it”") == true)
        form.discardDrafts = .subjectContaining(" Q4 INVOICES")
        let plan = try await plan(form)
        let step = try #require(plan.steps.first { $0.action == .deleteMessages })
        #expect(step.commandLine == "gam user carol@example.com delete messages ids 19a0c0ffee000011,19a0c0ffee000012")
        #expect(step.risk == .destructive && step.requires.isEmpty && plan.preview?.typedAddress == "carol@example.com")
        #expect(step.timeout == Compromised.Draft.timeout)
        await changes.confirm(plan, OperatorConfirmation(confirmed: true, typedAddresses: ["carol@example.com"]))
        #expect(changes.run?.isComplete == true, "\(String(describing: changes.run?.results))")
        #expect(writes().contains(step.commandLine))
        let again = try #require(changes.check)
        #expect(try again.drafts.get().map(\.id) == ["19a0c0ffee000013"])
        #expect(changes.run?.rest.discardDrafts == CompromisedChanges.Form.Discard.none)
    }

    /// The check lists the emails scheduled to send, with whom they go to, and says so first; deleting them is one step
    /// through the executor, exactly as held, destructive and confirmed by the typed address; the check again lists none.
    /// One no longer scheduled at the confirm stops the run before anything runs.
    @Test func scheduledSendsAreDeletedInOneStepAndTheCheckAgainListsNone() async throws {
        try await connect()
        let check = try await checked()
        #expect(check.scheduledSends.map(\.id) == ["19a0c0ffee000014"])
        #expect(check.findings.first { $0.contains("scheduled") }
                == "1 email is scheduled to send from carol@example.com, to 4 recipients: Gmail sends it at its time on its own, "
                    + "with nobody signed in. Delete it unless carol@example.com scheduled it.")
        var form = form()
        form.done = [.password]
        form.switchedOn = []
        form.deleteScheduled = true
        let first = try await plan(form)
        #expect(first.steps.count == 1)
        let step = try #require(first.steps.first)
        #expect(step.commandLine == "gam user carol@example.com delete messages ids 19a0c0ffee000014")
        #expect(step.action == .deleteMessages && step.risk == .destructive && first.preview?.typedAddress == "carol@example.com")
        // Gone from Scheduled between the check and the confirm (sent, it may be the Sent copy under the same ID): nothing runs.
        let gone = state.appending(path: "deleted/19a0c0ffee000014")
        try FileManager.default.createDirectory(at: gone.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: gone)
        await changes.confirm(first, OperatorConfirmation(confirmed: true, typedAddresses: ["carol@example.com"]))
        #expect(changes.problem?.hasPrefix("What the preview showed has changed since") == true
                && changes.problem?.contains("The account has been checked again") == true, "\(String(describing: changes.problem))")
        #expect(!writes().contains(step.commandLine) && changes.run == nil)
        #expect(changes.check?.id != check.id && changes.check?.scheduledSends.isEmpty == true, "checked again: nothing scheduled now")
        try FileManager.default.removeItem(at: gone)
        _ = try await checked()
        let plan = try await self.plan(form)
        await changes.confirm(plan, OperatorConfirmation(confirmed: true, typedAddresses: ["carol@example.com"]))
        #expect(changes.run?.isComplete == true, "\(String(describing: changes.run?.results))")
        #expect(writes().contains(step.commandLine))
        let again = try #require(changes.check)
        #expect(try again.scheduled.get().isEmpty && !again.findings.contains { $0.contains("scheduled") })
        #expect(changes.run?.rest.deleteScheduled == false)
        var kept = form
        kept.keepPicks(in: again)
        #expect(!kept.deleteScheduled, "nothing listed, nothing to delete")
    }

    /// An attacker's auto-reply sends their message to everyone who writes: the check reads it, says it, and "Turn off the
    /// auto-reply" is one step of the plan, run through the executor; the check again reads it off. Off, it plans nothing.
    @Test func anAutoReplyIsReadSaidAndTurnedOff() async throws {
        try await connect()
        #expect(try await checked().autoReply.get().enabled == false, "carol@'s own is off")
        let stored = state.appending(path: "vacation/carol@example.com")
        try FileManager.default.createDirectory(at: stored, withIntermediateDirectories: true)
        try Data("True".utf8).write(to: stored.appending(path: "enabled"))
        try Data("Invoice ready".utf8).write(to: stored.appending(path: "subject"))
        // The attacker's own text says it's off: GAM prints the message last, so it's the message, never the setting.
        try Data("Pay here: https://login-check.example.net\nEnabled: False".utf8).write(to: stored.appending(path: "message"))
        let check = try await checked()
        #expect(try check.autoReply.get().subject == "Invoice ready" && check.autoReply.get().enabled)
        #expect(check.findings.contains { $0.hasPrefix("An auto-reply is on (“Invoice ready”)") })
        var form = form()
        form.switchedOn = []
        form.autoReplyOff = true
        let plan = try await plan(form)
        #expect(plan.steps.map(\.commandLine) == ["gam user carol@example.com vacation off"], "one step alone")
        await changes.confirm(plan, OperatorConfirmation(confirmed: true, typedAddresses: ["carol@example.com"]))
        #expect(changes.run?.isComplete == true, "\(String(describing: changes.run?.results))")
        #expect(try #require(changes.check).autoReply.get().enabled == false)
        #expect(changes.run?.rest.autoReplyOff == false)
        form.autoReplyOff = false
        #expect(await blocked(form)?.hasPrefix("No step is switched on") == true)
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
