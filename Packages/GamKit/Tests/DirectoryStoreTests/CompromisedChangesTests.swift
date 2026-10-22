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

    /// Every account's connected apps, read from Incident: AI assistants and agents first, never a suspended account's grants,
    /// kept for the tenant; a refusal is GAM's words.
    @Test func everyAccountsConnectedAppsAreRead() async throws {
        try await connect()
        let reads = ConnectedAppsRead(setup: setup, access: access)
        await reads.read()
        guard case .read(.success(let apps), _)? = reads.state else { Issue.record("\(String(describing: reads.state))"); return }
        #expect(apps.map(\.name) == ["ChatGPT", "Read AI Notetaker", "Mail Sync Pro", "Zoom", "macOS"])
        #expect(apps.first { $0.name == "Zoom" }?.users == ["alice@example.com", "dana@example.com"], "bob@ is suspended")
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

    /// Pull Incident Logs reads and changes nothing: the person's logs, then every account's by the address on their
    /// flagged sign-in, where another account signed in from it too; each log in the query's order, and as a CSV. An
    /// address that isn't one is refused in words, in every log.
    @Test func incidentLogsFindTheSameAttackerElsewhere() async throws {
        try await connect()
        let logs = IncidentLogs(setup: setup, access: access)
        await logs.pull(IncidentLogs.Query(applications: ActivityLogs.incidentDefault, users: ["carol@example.com"], hours: 72, ip: ""))
        let person = try #require(logs.pull)
        #expect(person.ended && person.logs.map(\.application) == ActivityLogs.incidentDefault)
        #expect(try person.logs[0].rows.get().count == 5 && !person.logs[0].capped)
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
