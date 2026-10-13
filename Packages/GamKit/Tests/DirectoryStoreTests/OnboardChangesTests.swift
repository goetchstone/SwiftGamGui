@testable import ChangeCore
import Foundation
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Onboarding O1: one hire, previewed, confirmed and run through ChangeCore, end to end against the strict
/// mock with its argv log and kept state. Ports GamGUI's onboarding tests (`tests/test_onboarding.py`) and
/// the incidents behind them: a run that executed what nobody previewed (failure-log 2026-09-23), a
/// one-time password stranded by a later failure or left in a feed (2026-09-22), and the new account Google
/// wasn't ready for (2026-09-30).
@MainActor
@Suite("Onboard changes", .serialized)
final class OnboardChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-onboard-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let executor: Executor
    let argvLog: URL
    let auditURL: URL
    let state: URL
    let offset = Clock()
    let confirmed = OperatorConfirmation(confirmed: true)

    /// A clock tests move (time asleep counts on `ContinuousClock`).
    final class Clock: @unchecked Sendable {
        let start = ContinuousClock.now
        var moved: Duration = .zero
        var now: ContinuousClock.Instant { start + moved }
    }

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        state = scratch.appending(path: "mock-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let setup = setup
        executor = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The model, with zero waits (five rounds, as GamGUI's), a seeded password and the test's clock.
    private func model(waits: [Duration] = Array(repeating: .zero, count: 5), timeout: Duration = GamRunner.defaultTimeout,
                       executor: Executor? = nil) -> OnboardChanges {
        let clock = offset
        return OnboardChanges(executor: executor ?? self.executor, setup: setup, directory: directory, waits: waits,
                              makePassword: { var seeded = Seeded(state: 42); return TemporaryPassword.generate(using: &seeded) },
                              now: { clock.now }, timeout: timeout)
    }

    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// The password the seeded generator makes.
    private var password: String {
        var seeded = Seeded(state: 42)
        return TemporaryPassword.generate(using: &seeded).shownOnTheSheet
    }

    private func connect(admin: String = "alice@example.com") async throws {
        let folder = scratch.appending(path: "config")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "\#(admin)"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
        await directory.load()
    }

    private func lag(_ calls: Int) throws {
        try Data("\(calls)\n".utf8).write(to: state.appending(path: "new_account_lag"))
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

    /// The writes among them (`ran()` also has the access check and the directory's reads).
    private func writes() -> [[String]] {
        ran().filter { argv in
            !(argv.first == "print" || argv.first == "info" || argv.contains("check") || argv.first == "version"
              || (argv.count > 2 && (argv[2] == "print" || argv[2] == "show")))
        }
    }

    private var audit: String { (try? String(contentsOf: auditURL, encoding: .utf8)) ?? "" }

    private let sales = RoleTemplate(name: "Sales", steps: ["Set up the CRM login", "Order a laptop"], signature: "Classic",
                                     orgUnit: "/Sales", groups: ["sales@example.com"], calendars: ["c_allhands@group.calendar.google.com"])
    private var classic: String { Signature.seeds.first { $0.name == "Classic" }!.body }
    private let jordan = Hire(name: "Jordan Lee", email: "jordan@example.com", createAccount: true)

    private func pending(_ changes: OnboardChanges) throws -> OnboardChanges.Pending {
        try #require(changes.pending, "no preview: \(changes.problem ?? "")")
    }

    private func preview(_ changes: OnboardChanges, _ hire: Hire? = nil, role: RoleTemplate? = nil) async throws -> OnboardChanges.Pending {
        await changes.preview(hire: hire ?? jordan, role: role ?? sales, signatureTemplate: classic)
        return try pending(changes)
    }

    private func results(_ changes: OnboardChanges) -> [RunOutcome.Step?] { changes.run?.results ?? [] }

    // MARK: the plan is GamGUI's

    struct Fixture: Decodable {
        struct Provision: Decodable {
            struct Role: Decodable {
                let name: String, steps: [String], signature: String, org_unit: String, groups: [String], calendars: [String]
            }
            struct HireRow: Decodable {
                let name: String, email: String, assignee: String, create_account: Bool, first: String, last: String
            }
            let role: Role, hire: HireRow, create_ok: Bool, calls: [[String]], credential_org_unit: String?
        }
        let provision: [Provision]
    }

    /// GamGUI's `provision_hire`, through a recording connector (the fixture): the same argv in the same order,
    /// with its gates. The password and the list's id are the two elements a plan can't know in advance.
    @Test func thePlanIsGamGUIsOrderAndGates() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Fixtures.directory.appending(path: "onboarding.json")))
        let templates = Dictionary(uniqueKeysWithValues: Signature.seeds.map { ($0.name, $0.body) })
            .merging(["Empty": "", "Optional": "[[{title}]]", "Tokens": "{first}|{last}|{name}|{email}|{ou}|{phone}"]) { $1 }
        #expect(fixture.provision.count > 30)
        for item in fixture.provision {
            let role = RoleTemplate(name: item.role.name, steps: item.role.steps, signature: item.role.signature,
                                    orgUnit: item.role.org_unit, groups: item.role.groups, calendars: item.role.calendars)
            let hire = Hire(name: item.hire.name, email: item.hire.email, assignee: item.hire.assignee,
                            createAccount: item.hire.create_account, first: item.hire.first, last: item.hire.last)
            var seeded = Seeded(state: 1)
            let password = hire.createAccount ? TemporaryPassword.generate(using: &seeded) : nil
            let (plan, steps) = OnboardChanges.plan(hire: hire, role: role, signatureTemplate: templates[role.signature], password: password)
            var argv = steps.map(\.write.argv)
            if let password {
                #expect(argv[0][8] == password.shownOnTheSheet, "the password, in one element")
                #expect(argv[0].count { $0 == password.shownOnTheSheet } == 1)
                argv[0][8] = "PASSWORD"
                #expect(plan.orgUnit == item.credential_org_unit || !item.create_ok)
            }
            argv = argv.map { $0.count > 4 && $0[3] == "task" ? $0.enumerated().map { $0.offset == 4 ? "TASKLIST_ID" : $0.element } : $0 }
            let label = "\(role.name) for \(hire.name.debugDescription)/\(hire.email)"
            if item.create_ok {
                #expect(argv.map { $0.map { Array($0.utf8) } } == item.calls.map { $0.map { Array($0.utf8) } }, "\(label)")
            } else {
                // The create failed: GamGUI ran nothing after it; here every later step requires it.
                #expect(argv.first == item.calls.first && item.calls.count == 1, "\(label)")
                #expect(steps.dropFirst().allSatisfy { $0.requires.contains(0) }, "\(label)")
            }
            // The gates: what waits for a new account, and on which step.
            for (index, step) in steps.enumerated() where hire.createAccount && index > 0 {
                #expect(step.requires.contains(0))
                let waits = switch step.action {
                case .setSignature, .subscribeCalendar: true
                case .createTaskList, .createTask: PythonText.lower(plan.assignee) == PythonText.lower(plan.email)
                default: false
                }
                #expect((step.newAccountFrom == 0) == waits, "\(label): step \(index) \(step.action)")
            }
            #expect(steps.allSatisfy { hire.createAccount || ($0.requires.isEmpty || $0.action == .createTask) && $0.newAccountFrom == nil })
            #expect(plan.rows.map(\.shownArgv) == steps.map(\.shownArgv))
        }
    }

    // MARK: a confirm runs what the preview held, once

    /// GamGUI's test_run_executes_only_the_previewed_hire (failure-log 2026-09-23, "nobody had previewed"):
    /// "Create" ticked after a tasks-only preview, the email retyped, the assignee retyped. The new preview
    /// replaces the old, and confirming the old runs nothing and audits nothing.
    @Test func aConfirmRunsOnlyWhatThePreviewHeld() async throws {
        try await connect()
        let changes = model()
        let tasksOnly = try await preview(changes, Hire(name: "Jordan Lee", email: "carol@example.com", assignee: "carol@example.com"))
        let edited = try await preview(changes, Hire(name: "Jordan Lee", email: "jordan@example.com", assignee: "alice@example.com",
                                                     createAccount: true))
        #expect(await executor.isHeld(tasksOnly.id) == false, "the replaced preview is dropped")
        await changes.confirm(tasksOnly, confirmed)
        #expect(writes().isEmpty && audit.isEmpty)
        #expect(changes.run == nil)
        await changes.confirm(edited, confirmed)
        #expect(writes().map { $0.prefix(3).joined(separator: " ") }.first == "create user jordan@example.com")
        #expect(writes().count == edited.plan.rows.count)
    }

    /// GamGUI's test_run_uses_the_role_as_previewed: the role edited after the preview changes nothing; a
    /// confirm takes no role, only the held preview.
    @Test func theRoleIsTheOneAsPreviewed() async throws {
        try await connect()
        let changes = model()
        let pending = try await preview(changes, Hire(name: "Sam Rivers", email: "carol@example.com"),
                                        role: RoleTemplate(name: "Sales", steps: ["Badge"]))
        await changes.confirm(pending, confirmed)
        #expect(writes().map { $0.last } == ["returnidonly", "Badge"])
    }

    /// GamGUI's test_run_is_single_use.
    @Test func aConfirmIsSingleUse() async throws {
        try await connect()
        let changes = model()
        let pending = try await preview(changes, Hire(name: "Sam Rivers", email: "carol@example.com"),
                                        role: RoleTemplate(name: "Sales", steps: ["Badge"]))
        await changes.confirm(pending, confirmed)
        let count = writes().count
        await changes.confirm(pending, confirmed)
        #expect(writes().count == count && count == 2)
        #expect(await executor.run(pending.preview, confirmation: confirmed).refusal
                == "That preview has expired or was already run — preview again.")
    }

    /// GamGUI's test_run_refuses_account_without_confirmation: onboarding always needs the Confirm click.
    @Test func aBareConfirmRunsNothing() async throws {
        try await connect()
        let changes = model()
        let pending = try await preview(changes)
        await changes.confirm(pending, OperatorConfirmation())
        #expect(changes.problem == "This change needs confirmation — preview it, then confirm.")
        #expect(changes.run == nil)
        #expect(writes().isEmpty && audit.isEmpty)
        #expect(changes.card == nil)
    }

    // MARK: the one-time password

    /// GamGUI's test_run_creates_account_and_returns_sheet and test_create_user_redacts_password: the card
    /// shows the password the account was made with; the audit, the rows and the preview never do.
    @Test func aCreatedAccountShowsTheCardAndNeverAuditsThePassword() async throws {
        try await connect()
        let changes = model()
        let pending = try await preview(changes)
        #expect(pending.summary == "One new hire: 7 steps" && pending.confirmLabel == "Create Account and Onboard")
        #expect(!pending.plan.rows.flatMap(\.shownArgv).contains(password))
        await changes.confirm(pending, confirmed)
        let card = try #require(changes.card)
        #expect(card.password.shownOnTheSheet == password && !card.unsure)
        #expect(card.name == "Jordan Lee" && card.email == "jordan@example.com" && card.orgUnit == "/Sales")
        #expect(card.signature == .applied("Classic"))
        #expect(writes().first?[8] == password, "the account was made with it")
        #expect(audit.contains("createUser") && !audit.contains(password))
        #expect(changes.run?.results.allSatisfy { $0?.isSucceeded == true } == true)
        #expect(changes.run?.tallies == ["Added jordan@example.com to 1 of 1 group.", "Subscribed to 1 of 1 shared calendar.",
                                         "Created 2 of 2 tasks in jordan@example.com's Google Tasks — “Onboard Jordan Lee — Sales”."])
        #expect(changes.accountsCreated == 1)
    }

    /// GamGUI's test_run_keeps_credentials_when_tasklist_fails: a later failure never strands the password.
    @Test func theCardSurvivesALaterFailure() async throws {
        try await connect()
        let changes = model()
        let pending = try await preview(changes, Hire(name: "Ada Byte", email: "ada@example.com", assignee: "nobody@example.com",
                                                      createAccount: true), role: RoleTemplate(name: "Sales", steps: ["POS"], orgUnit: "/Sales"))
        await changes.confirm(pending, confirmed)
        #expect(changes.card?.password.shownOnTheSheet == password)
        guard case .failed(_, let kind)? = results(changes)[1] else { Issue.record("\(results(changes))"); return }
        #expect(kind == .notFound)
    }

    /// An irreversible write never discards the one-shot secret it produced (failure-log 2026-09-22,
    /// "stranded"): a create that didn't finish may have made the account, so the card shows, marked unsure.
    @Test func aTimedOutCreateStillShowsTheCardMarkedUnsure() async throws {
        try await connect()
        let changes = model(timeout: .nanoseconds(1))
        await changes.confirm(try await preview(changes), confirmed)
        let card = try #require(changes.card)
        #expect(card.unsure && card.password.shownOnTheSheet == password)
        #expect(results(changes).dropFirst().allSatisfy { if case .skipped? = $0 { true } else { false } })
    }

    /// GamGUI's test_run_account_duplicate_fails_gracefully, with GAM's own wording (F1, D7): nothing else
    /// runs, no card, and the preview had warned from the directory.
    @Test func aDuplicateCreateRunsNothingElseAndSaysWhy() async throws {
        try await connect()
        let changes = model()
        let pending = try await preview(changes, Hire(name: "Carol Clark", email: "carol@example.com", createAccount: true))
        #expect(pending.plan.warnings.contains("carol@example.com is already in the directory: Google will refuse to create it."))
        await changes.confirm(pending, confirmed)
        #expect(writes().count == 1)
        #expect(changes.card == nil)
        let problem = try #require(changes.run?.accountProblem)
        #expect(problem.summary == "Couldn't create the account: An account, alias or group already uses carol@example.com.")
        #expect(problem.detail.contains("Create Failed: Duplicate, User: carol@example.com"))
        let alias = try await preview(changes, Hire(name: "A Anders", email: "a.anders@example.com", createAccount: true))
        #expect(alias.plan.warnings.contains("a.anders@example.com is an alias of alice@example.com: Google will refuse to create it."))
    }

    /// GamGUI's test_run_account_failure_error_partial_never_shows_password; and F2's words for an org unit
    /// that doesn't exist.
    @Test func aFailedCreateNeverShowsThePassword() async throws {
        try await connect()
        let changes = model()
        await changes.confirm(try await preview(changes, role: RoleTemplate(name: "Night", steps: ["A"], orgUnit: "Missing/Night")),
                              confirmed)
        #expect(changes.card == nil)
        #expect(changes.run?.accountProblem?.summary == "Couldn't create the account: The role\u{2019}s org unit "
                + "\u{201C}/Missing/Night\u{201D} doesn\u{2019}t exist in Google.")
        #expect(!"\(String(describing: changes.run))".contains(password))
        #expect(instances(of: TemporaryPassword.self, in: changes) == 0)
    }

    /// GamGUI's test_a_single_hire_refused_for_want_of_a_license_says_so.
    @Test func noLicenseSaysSo() async throws {
        try await connect()
        let changes = model()
        await changes.confirm(try await preview(changes, Hire(name: "Jo Lee", email: "jo-userlimit@example.com", createAccount: true)),
                              confirmed)
        #expect(changes.run?.accountProblem?.summary == "Couldn't create the account: " + GamError.Kind.licenseLimit.remediation)
        #expect(changes.card == nil && writes().count == 1)
    }

    /// The card goes at Done, or fifteen minutes after it appeared (GamGUI's `_CREDS_TTL`; time asleep counts).
    @Test func theCardIsDroppedAtDoneOrAfterFifteenMinutes() async throws {
        try await connect()
        let changes = model()
        await changes.confirm(try await preview(changes, role: RoleTemplate(name: "Sales", steps: ["A"])), confirmed)
        #expect(changes.card != nil)
        changes.doneWithCard()
        #expect(changes.card == nil && instances(of: TemporaryPassword.self, in: changes) == 0)

        changes.startAnother()
        await changes.confirm(try await preview(changes, Hire(name: "Sam Rivers", email: "sam@example.com", createAccount: true),
                                                role: RoleTemplate(name: "Sales", steps: ["A"])), confirmed)
        let card = try #require(changes.card)
        offset.moved = OnboardChanges.cardLifetime
        #expect(changes.card != nil, "fifteen minutes to the second")
        offset.moved = OnboardChanges.cardLifetime + .seconds(1)
        #expect(changes.card == nil)
        changes.dropCard(ifExpired: card.id)
        #expect(instances(of: TemporaryPassword.self, in: changes) == 0, "dropped, not just hidden")
    }

    /// A new account's card would replace one not yet handed over, whose password exists nowhere else: a new
    /// create waits for Done. A run that creates nothing can go ahead.
    @Test func aNewCreateWaitsForTheLastCardToBeHandedOver() async throws {
        try await connect()
        let changes = model()
        await changes.confirm(try await preview(changes, role: RoleTemplate(name: "Sales", steps: ["A"])), confirmed)
        let card = try #require(changes.card)
        changes.startAnother()
        await changes.preview(hire: Hire(name: "Sam Rivers", email: "sam@example.com", createAccount: true),
                              role: RoleTemplate(name: "Sales", steps: ["A"]), signatureTemplate: nil)
        #expect(changes.problem == "Print or copy the sign-in details for jordan@example.com, then click Done, before creating another account.")
        #expect(changes.pending == nil && changes.card?.id == card.id)
        _ = try await preview(changes, Hire(name: "Carol Clark", email: "carol@example.com"), role: RoleTemplate(name: "Sales", steps: ["A"]))
        changes.doneWithCard()
        _ = try await preview(changes, Hire(name: "Sam Rivers", email: "sam@example.com", createAccount: true),
                              role: RoleTemplate(name: "Sales", steps: ["A"]))
    }

    /// Failure-log 2026-09-22 ("feed"): nothing but the card holds the password. While it's held for the card
    /// it's there once; no held preview stays behind in the model after the run.
    @Test func noStateButTheCardHoldsThePassword() async throws {
        try await connect()
        let changes = model()
        let pending = try await preview(changes)
        #expect(instances(of: TemporaryPassword.self, in: changes) == 1, "the pending holds it for the card")
        await changes.confirm(pending, confirmed)
        #expect(instances(of: TemporaryPassword.self, in: changes) == 1, "the card")
        #expect(instances(of: HeldPreview.self, in: changes) == 0)
        for text in [String(describing: changes.run as Any), String(describing: changes.finishing as Any),
                     changes.run?.tallies.joined() ?? "", changes.problem ?? "",
                     changes.interruptible.map { $0.what + " " + $0.consequence } ?? ""] {
            #expect(!text.contains(password))
        }
        // Quitting with the card up asks first: its password is shown nowhere else (security review, 2026-10-13).
        #expect(changes.interruptible != nil)
        changes.doneWithCard()
        #expect(instances(of: TemporaryPassword.self, in: changes) == 0)
        #expect(changes.interruptible?.what.contains("sign-in card") != true)
    }

    /// How many values of `type` the model holds, anywhere in its stored state (its mirror, recursively).
    private func instances<T>(of type: T.Type, in changes: OnboardChanges) -> Int {
        func count(_ value: Any, depth: Int) -> Int {
            guard depth < 12 else { return 0 }
            if value is T { return 1 }
            return Mirror(reflecting: value).children.reduce(0) { $0 + count($1.value, depth: depth + 1) }
        }
        return Mirror(reflecting: changes).children
            .filter { !["setup", "directory", "executor", "makePassword", "now", "_$observationRegistrar"].contains($0.label ?? "") }
            .reduce(0) { $0 + count($1.value, depth: 0) }
    }

    // MARK: the rest of the hire

    /// GamGUI's test_provision_hire_skips_signature_for_existing_account.
    @Test func theSignatureIsOnlyForAnAccountThisRunCreates() async throws {
        try await connect()
        let changes = model()
        let existing = try await preview(changes, Hire(name: "Carol Clark", email: "carol@example.com"))
        #expect(!existing.plan.rows.contains { if case .signature = $0.kind { true } else { false } })
        #expect(existing.plan.rows.first?.kind == .group("sales@example.com"))
        let created = try await preview(changes)
        #expect(created.plan.rows.map(\.kind).prefix(2) == [.account, .signature(template: "Classic")])
    }

    /// GamGUI's test_run_adds_groups_and_subscribes_calendars and test_run_reports_failed_group_and_calendar_non_fatal.
    @Test func groupsAndCalendarsAreBestEffort() async throws {
        try await connect()
        let changes = model()
        let role = RoleTemplate(name: "Sales", steps: ["A"], groups: ["sales@example.com", "missing@example.com"],
                                calendars: ["c_allhands@group.calendar.google.com", "missing@group.calendar.google.com"])
        await changes.confirm(try await preview(changes, Hire(name: "Carol Clark", email: "carol@example.com"), role: role), confirmed)
        let run = try #require(changes.run)
        #expect(run.results.map { $0?.isSucceeded } == [true, false, true, false, true, true])
        #expect(run.tallies == ["Added carol@example.com to 1 of 2 groups.", "Subscribed to 1 of 2 shared calendars.",
                                "Created 1 of 1 task in carol@example.com's Google Tasks — “Onboard Carol Clark — Sales”."])
        #expect(changes.failedSteps.map(\.index) == [1, 3])
    }

    /// GamGUI's test_run_reports_actual_task_count: the mock fails a task on any list but its own, so
    /// "Created 3 of 3" means three were made.
    @Test func theTaskCountIsReal() async throws {
        try await connect()
        let changes = model()
        await changes.confirm(try await preview(changes, Hire(name: "Jo", email: "carol@example.com", assignee: "alice@example.com"),
                                                role: RoleTemplate(name: "Cashier", steps: ["A", "B", "C"])), confirmed)
        #expect(changes.run?.tallies.last == "Created 3 of 3 tasks in alice@example.com's Google Tasks — “Onboard Jo — Cashier”.")
        let lists = writes().filter { $0.count > 4 && $0[3] == "task" }.map { $0[4] }
        #expect(Set(lists).count == 1 && lists.count == 3)
    }

    // MARK: the new account's wait

    /// GamGUI's test_a_new_accounts_signature_and_calendar_wait_for_google_then_apply: they wait, then the
    /// retries apply them, each attempt audited in pairs. The card says the signature waited, then applied.
    @Test func aNewAccountsSignatureAndCalendarWaitThenApply() async throws {
        try await connect()
        try lag(3)
        let changes = model()
        let role = RoleTemplate(name: "Sales", steps: ["A"], signature: "Classic", calendars: ["c_allhands@group.calendar.google.com"])
        await changes.confirm(try await preview(changes, Hire(name: "Jordan Lee", email: "jordan@example.com", assignee: "alice@example.com",
                                                              createAccount: true), role: role), confirmed)
        #expect(results(changes).map { $0?.isWaiting } == [false, true, true, false, false])
        #expect(changes.finishing?.email == "jordan@example.com" && changes.finishing?.waiting == 2)
        #expect(changes.isBusy && changes.interruptible?.what.contains("waiting for Google") == true)
        await changes.waitForFinishing()
        #expect(changes.finishing?.phase == .done)
        #expect(results(changes).allSatisfy { $0?.isSucceeded == true })
        #expect(changes.card?.signature == .applied("Classic"))
        let signature = AuditLog.records(at: auditURL).reversed().filter { $0["action"]?.string == "setSignature" }
        #expect(signature.map { $0["extra"]?.object?["phase"]?.string } == ["begin", "end", "begin", "end", "begin", "end"])
        #expect(signature.map { $0["extra"]?.object?["attempt"]?.int } == [nil, nil, 2, 2, 3, 3])
    }

    /// GamGUI's test_finishing_gives_up_after_its_last_round_and_says_what_to_do: GAM's last error with it.
    @Test func finishingGivesUpWithGamsLastError() async throws {
        try await connect()
        try lag(100)
        let changes = model()
        let role = RoleTemplate(name: "Sales", steps: ["A"], calendars: ["c_allhands@group.calendar.google.com"])
        await changes.confirm(try await preview(changes, Hire(name: "Jordan Lee", email: "jordan@example.com", assignee: "alice@example.com",
                                                              createAccount: true), role: role), confirmed)
        await changes.waitForFinishing()
        #expect(changes.finishing?.phase == .gaveUp && changes.finishing?.round == 5)
        let notDone = try #require(changes.run?.notDone[1])
        #expect(notDone.reason == Onboarding.notReadyReason)
        #expect(notDone.detail == "GAM failed (service_not_enabled, exit=73): User: jordan@example.com, Calendar Service/App not enabled")
        #expect(writes().filter { $0.count > 3 && $0[3] == "calendars" }.count == 6, "the run and five rounds")
        #expect(changes.failedSteps.map(\.index) == [1])
    }

    /// GamGUI's test_an_existing_account_is_never_parked: the same refusal on an account the run didn't
    /// create is a failure at once.
    @Test func anExistingAccountIsNeverParked() async throws {
        try await connect()
        try FileManager.default.createDirectory(at: state.appending(path: "provisioning"), withIntermediateDirectories: true)
        try Data("5".utf8).write(to: state.appending(path: "provisioning/carol@example.com"))
        let changes = model()
        let role = RoleTemplate(name: "Sales", steps: ["A"], calendars: ["c_allhands@group.calendar.google.com"])
        await changes.confirm(try await preview(changes, Hire(name: "Carol Clark", email: "carol@example.com"), role: role), confirmed)
        guard case .failed(_, let kind)? = results(changes)[0] else { Issue.record("\(results(changes))"); return }
        #expect(kind == .serviceNotEnabled)
        #expect(changes.finishing == nil)
    }

    /// GamGUI's test_the_new_hires_own_task_list_waits_too: left blank, the assignee is the account just made.
    @Test func theHiresOwnTaskListWaitsToo() async throws {
        try await connect()
        try lag(1)
        let changes = model()
        await changes.confirm(try await preview(changes, Hire(name: "Ada Byte", email: "ada@example.com", createAccount: true),
                                                role: RoleTemplate(name: "Sales", steps: ["A", "B"])), confirmed)
        #expect(results(changes).map { $0?.isWaiting } == [false, true, true, true])
        await changes.waitForFinishing()
        #expect(results(changes).allSatisfy { $0?.isSucceeded == true }, "\(results(changes))")
        let other = model()
        let elsewhere = try await preview(other, Hire(name: "Bo Byte", email: "bo@example.com", assignee: "alice@example.com", createAccount: true),
                                          role: RoleTemplate(name: "Sales", steps: ["A"]))
        #expect(elsewhere.preview.steps.map(\.newAccountFrom) == [nil, nil, nil], "someone else's list doesn't wait")
    }

    /// GamGUI's test_stop_ends_the_wait_for_google_at_once: Stop ends a wait mid-sleep, and the retry is gone.
    @Test func stopEndsTheWaitAtOnce() async throws {
        try await connect()
        try lag(100)
        let changes = model(waits: [.seconds(3600)])
        await changes.confirm(try await preview(changes, role: RoleTemplate(name: "Sales", steps: ["A"], signature: "Classic")), confirmed)
        #expect(changes.finishing?.phase == .waiting)
        let before = writes().count
        let started = ContinuousClock.now
        changes.stopFinishing()
        await changes.waitForFinishing()
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(changes.finishing?.phase == .stopped)
        #expect(changes.run?.notDone.values.allSatisfy { $0.reason == Onboarding.stoppedReason } == true)
        #expect(changes.run?.notDone.count == 3)
        #expect(changes.card?.signature == .notApplied("Classic"))
        #expect(writes().count == before)
        #expect(!changes.isBusy)
        #expect(await executor.parkedRuns == 0, "the executor holds nothing for a retry, the password with it")
    }

    /// Done or the last round leave nothing held for a retry either.
    @Test func aFinishedWaitLeavesNothingHeld() async throws {
        try await connect()
        try lag(100)
        let changes = model(waits: [.zero, .zero])
        await changes.confirm(try await preview(changes, role: RoleTemplate(name: "Sales", steps: ["A"], signature: "Classic")), confirmed)
        #expect(await executor.parkedRuns == 1)
        await changes.waitForFinishing()
        #expect(changes.finishing?.phase == .gaveUp && changes.finishing?.round == 2)
        #expect(await executor.parkedRuns == 0, "the rounds this model didn't use are dropped, not left to expire")
    }

    // MARK: refused at preview, in GamGUI's words

    /// GamGUI's test_run_single_word_name_requires_last.
    @Test func aSingleWordNameNeedsALastName() async throws {
        try await connect()
        let changes = model()
        await changes.preview(hire: Hire(name: "Ada", email: "ada@example.com", createAccount: true), role: sales, signatureTemplate: classic)
        #expect(changes.problem == "Enter the new hire's first and last name to create the account.")
        #expect(changes.pending == nil)
        await changes.preview(hire: Hire(name: "Ada", email: "ada@example.com", createAccount: true,
                                         first: String(repeating: "A", count: 61), last: "Byte"), role: sales, signatureTemplate: classic)
        #expect(changes.problem == "Google takes a first or last name of at most 60 characters.")
    }

    /// GamGUI's test_preview_rejects_invalid_email and test_run_rejects_invalid_email; the assignee, GAM's
    /// `oauthuser` keyword and a comma (GAM splits a `<UserList>` on it).
    @Test func invalidAddressesAreRefusedAtPreview() async throws {
        try await connect()
        let changes = model()
        for (hire, message) in [
            (Hire(name: "A B", email: "not-an-email"), "That does not look like a valid email address for the new hire."),
            (Hire(name: "A B", email: "a,b@example.com"), "That does not look like a valid email address for the new hire."),
            (Hire(name: "A B", email: "ab@example.com", assignee: "oauthuser"), "The assignee does not look like a valid email address."),
            (Hire(name: "A B", email: "ab@example.com", assignee: "x@example.com,y@example.com"),
             "The assignee does not look like a valid email address."),
            (Hire(name: "A B"), "Enter the assignee (who does the setup) or the new hire's email."),
            (Hire(name: "A B", createAccount: true), "Enter the new hire's email to create the account."),
        ] {
            await changes.preview(hire: hire, role: sales, signatureTemplate: classic)
            #expect(changes.problem == message, "\(hire)")
            #expect(changes.pending == nil)
        }
        #expect(writes().isEmpty)
    }

    @Test func aRoleWithoutStepsCantPreview() async throws {
        try await connect()
        let changes = model()
        await changes.preview(hire: jordan, role: RoleTemplate(name: "Empty", steps: []), signatureTemplate: nil)
        #expect(changes.problem == "That role has no steps yet — add some in Role templates.")
    }

    /// D6: the signature is looked up and rendered at preview, and held; a template that's gone is left out
    /// and said before the confirm (GamGUI said "not applied" only after the run).
    @Test func aMissingSignatureTemplateIsLeftOutAndSaid() async throws {
        try await connect()
        let changes = model()
        await changes.preview(hire: jordan, role: RoleTemplate(name: "Sales", steps: ["A"], signature: "Gone"), signatureTemplate: nil)
        let pending = try pending(changes)
        #expect(!pending.plan.rows.contains { if case .signature = $0.kind { true } else { false } })
        #expect(pending.plan.warnings.contains("The role's signature “Gone” isn't saved on Signatures, so no signature is set."))
        await changes.preview(hire: jordan, role: RoleTemplate(name: "Sales", steps: ["A"], signature: "Word"), signatureTemplate: "  file ")
        #expect(try self.pending(changes).plan.warnings.first?.contains("GAM reads as a file") == true)
    }

    // MARK: retrying what failed (D8)

    /// "Retry the N that failed" is a new preview of exactly those steps, from the plan held: the same
    /// signature, tasks on the list that exists; it needs the Confirm click, then runs just those.
    @Test func retryIsANewPreviewOfExactlyTheFailed() async throws {
        try await connect()
        try lag(100)
        let changes = model(waits: [.zero])
        let role = RoleTemplate(name: "Sales", steps: ["A"], signature: "Classic", groups: ["missing@example.com"])
        await changes.confirm(try await preview(changes, Hire(name: "Jordan Lee", email: "jordan@example.com", assignee: "alice@example.com",
                                                              createAccount: true), role: role), confirmed)
        await changes.waitForFinishing()
        #expect(changes.failedSteps.map(\.kind) == [.signature(template: "Classic"), .group("missing@example.com")])
        try FileManager.default.removeItem(at: state.appending(path: "provisioning/jordan@example.com"))
        await changes.previewRetry()
        let retry = try pending(changes)
        #expect(retry.isRetry && retry.summary == "Retry 2 steps for jordan@example.com" && retry.confirmLabel == "Retry 2 Steps")
        #expect(retry.preview.steps.map(\.write.argv) == [
            GamCommands.setSignature(email: "jordan@example.com", signature: Onboarding.signatureHTML(
                template: classic, email: "jordan@example.com", first: "Jordan", last: "Lee")!).argv,
            GamCommands.addGroupMember(group: "missing@example.com", member: "jordan@example.com").argv])
        #expect(retry.preview.steps.allSatisfy { $0.newAccountFrom == nil && $0.requires.isEmpty })
        let before = writes().count
        await changes.confirm(retry, OperatorConfirmation())
        #expect(changes.problem == "This change needs confirmation — preview it, then confirm." && writes().count == before)
        #expect(changes.failedSteps.count == 2, "the run it retries from is still shown")
        await changes.previewRetry()
        await changes.confirm(try pending(changes), confirmed)
        #expect(writes().count == before + 2)
        #expect(changes.run?.results.map { $0?.isSucceeded } == [true, false])

        // A list that never ran comes back whole: the list, then every task on it.
        let plan = OnboardChanges.plan(hire: Hire(name: "Jo", email: "carol@example.com", assignee: "alice@example.com"),
                                       role: RoleTemplate(name: "Sales", steps: ["A", "B"]), signatureTemplate: nil, password: nil).plan
        let failedList: [RunOutcome.Step?] = [.failed(message: "x", kind: .unknown), .skipped(reason: "Step 1 didn't succeed."),
                                              .skipped(reason: "Step 1 didn't succeed.")]
        let again = OnboardChanges.retryPlan(plan, results: failedList, failed: [0, 1, 2])
        #expect(again.steps.map(\.action) == [.createTaskList, .createTask, .createTask])
        #expect(again.steps[2].requires == [0])
        // Tasks that failed on a list that exists go on it, by the id it printed.
        let onList: [RunOutcome.Step?] = [.succeeded(output: "MockTasklist_9\n"), .succeeded(output: ""), .failed(message: "x", kind: .unknown)]
        let tasks = OnboardChanges.retryPlan(plan, results: onList, failed: [2])
        #expect(tasks.steps.map(\.write.argv) == [["user", "alice@example.com", "create", "task", "MockTasklist_9", "title", "B"]])
    }
}
