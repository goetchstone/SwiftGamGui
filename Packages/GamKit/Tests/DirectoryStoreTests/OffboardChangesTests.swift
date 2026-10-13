import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Security
import Setup
import Synchronization
import TestSupport
import Testing
import Vault

/// Offboarding Off1, the read-only plan: what GamGUI's 8-step offboarding would run for a leaver and a
/// manager, checked against a fresh directory, with the leaver's delegates read, and no way to run it.
/// carol@ leaves and alice@ (a super admin) takes over, against the strict mock. Ports GamGUI's preview
/// tests (`tests/test_users_web.py`, the `/lifecycle/offboard/preview` cases).
@MainActor
@Suite("Offboard changes", .serialized)
final class OffboardChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-offboard-\(UUID().uuidString)")
    let memory = MemoryStore()
    let setup: SetupModel
    let directory: DirectoryStore
    let access: UserAccess
    let changes: OffboardChanges
    let state: URL
    let argvLog: URL
    /// The clock the directory's age and the plan's dates read: 2026-06-23, mid-morning in New York.
    let clock = Clock(Date(timeIntervalSince1970: 1_782_225_000))

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let vault = Vault(store: memory)
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        let clock = clock
        directory = DirectoryStore(setup: setup, runner: runner, now: { clock.now })
        state = scratch.appending(path: "mock-state")
        argvLog = scratch.appending(path: "argv.log")
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": state.path, "GAM_MOCK_ARGV_LOG": argvLog.path]
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        changes = OffboardChanges(setup: setup, directory: directory, access: access, now: { clock.now }, calendar: newYork)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect(_ domain: String = "example.com", admin: String = "admin@example.com") async throws {
        let folder = scratch.appending(path: "config-\(domain)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "\#(admin)"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
        await directory.load()
    }

    private func form(_ leaver: String = "carol@example.com", _ manager: String = "alice@example.com",
                      subject: String = "s", message: String = "m", days: Int = 30, invitee: String = "",
                      done: Set<Offboarding.Step> = [], notApplicable: Set<Offboarding.Step> = []) -> OffboardChanges.Form {
        var form = OffboardChanges.Form()
        (form.leaver, form.manager, form.subject, form.message, form.days, form.invitee) = (leaver, manager, subject, message, days, invitee)
        (form.done, form.notApplicable) = (done, notApplicable)
        return form
    }

    private func plan(_ form: OffboardChanges.Form) async throws -> OffboardChanges.Plan {
        await changes.plan(form)
        guard case .planned(let plan) = changes.state else { throw NotPlanned(state: "\(changes.state)") }
        return plan
    }

    private func blocked(_ form: OffboardChanges.Form) async throws -> String {
        await changes.plan(form)
        guard case .blocked(let blocked) = changes.state else { throw NotPlanned(state: "\(changes.state)") }
        return blocked.reason
    }

    private func marker(_ path: String, _ text: String = "") throws {
        let file = state.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    /// The `print delegates` reads the mock ran.
    private func delegateReads() -> Int {
        guard let data = try? Data(contentsOf: argvLog) else { return 0 }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { $0 == "delegates" }.count
    }

    private func lines(_ plan: OffboardChanges.Plan) -> [String] { plan.steps.map(\.commandLine) }

    // MARK: the checks (test_users_web.py)

    /// `test_offboard_blocks_an_address_the_directory_does_not_confirm`: a typo'd manager meant a
    /// half-offboarded account. Refused, with no plan to show.
    @Test(arguments: [("nobody@example.com", "alice@example.com", "nobody@example.com isn't in the directory"),
                      ("carol@example.com", "alcie@example.com", "alcie@example.com isn't in the directory"),
                      ("a.anders@example.com", "carol@example.com", "a.anders@example.com is an alias of alice@example.com"),
                      ("carol@example.com", "Carol@Example.com", "are the same account")])
    func anAddressTheDirectoryDoesNotConfirmIsBlocked(_ leaver: String, _ manager: String, _ expected: String) async throws {
        try await connect()
        let reason = try await blocked(form(leaver, manager))
        #expect(reason.contains(expected), "\(reason)")
    }

    /// `test_offboard_blocks_when_the_directory_cannot_be_read`, and GamGUI's plan U12b: a list past its five
    /// minutes is read again first, and a failed read blocks; the old list is never the fallback.
    @Test func aDirectoryThatCantBeReadBlocks() async throws {
        try await connect()
        let loaded = try #require(directory.loadedAt)
        clock.advance(299)
        _ = try await plan(form())
        #expect(directory.loadedAt == loaded, "within five minutes the list is used as it is")
        clock.advance(2)
        _ = try await plan(form())
        #expect(directory.loadedAt == loaded.addingTimeInterval(301), "past five minutes it is read again first")
        clock.advance(301)
        memory.failNext(.read, with: errSecInteractionNotAllowed)
        let reason = try await blocked(form())
        #expect(reason == "Couldn't read the directory to check the addresses — Your Mac is locked. Unlock it and try again.")
        #expect(directory.users != nil, "the old list is still there, and wasn't used")
    }

    /// `test_offboard_acts_on_the_directory_primary_address`: whatever case and spaces were typed.
    @Test func theStepsActOnThePrimaryAddress() async throws {
        try await connect()
        let plan = try await plan(form(" CAROL@example.com ", "Alice@Example.com"))
        #expect(lines(plan).first == "gam update user carol@example.com password random changepassword off")
        #expect(lines(plan).contains("gam user carol@example.com add delegate alice@example.com"))
        #expect(plan.leaver.primaryEmail == "carol@example.com" && plan.manager.primaryEmail == "alice@example.com")
    }

    /// `test_offboard_preview_warns_but_does_not_block`.
    @Test(arguments: [("alice@example.com", "carol@example.com", "alice@example.com is a super admin"),
                      ("carol@example.com", "bob@example.com", "The manager bob@example.com is suspended"),
                      ("bob@example.com", "carol@example.com", "bob@example.com is already suspended")])
    func aWarningDoesNotBlock(_ leaver: String, _ manager: String, _ expected: String) async throws {
        try await connect()
        let plan = try await plan(form(leaver, manager))
        #expect(plan.warnings.contains { $0.contains(expected) }, "\(plan.warnings)")
        #expect(plan.steps.count == 8)
    }

    /// `test_lifecycle_offboard_preview_shows_each_exact_command`: before the first live run the operator
    /// reads the exact gam command of every step, quoted so a value with spaces is visibly one argument.
    @Test func thePlanShowsEachExactCommand() async throws {
        try await connect()
        let plan = try await plan(form(subject: "Away now"))
        let shown = lines(plan)
        for line in ["gam update user carol@example.com password random changepassword off",
                     "gam user carol@example.com deprovision signout",
                     "gam user carol@example.com forward off",
                     "gam user carol@example.com add delegate alice@example.com",
                     "gam user carol@example.com vacation on subject 'Away now' message m html",
                     "gam create datatransfer carol@example.com drive,calendar alice@example.com all",
                     "gam all users delete calendaracls primary carol@example.com",
                     "gam user alice@example.com add event primary summary 'Offboarding carol@example.com: confirm"] {
            #expect(shown.contains { $0.hasPrefix(line) }, "\(line)")
        }
        #expect(shown.count == 8 && plan.header == "Offboarding carol@example.com — 8 steps")
        #expect(plan.rows.contains { $0.summary.contains("stopped and reported failed after 60 min") })
        // The reminder is dated from the operator's day: 2026-06-23 in New York, plus 30.
        #expect(shown.last?.contains(" start allday 2026-07-23 end allday 2026-07-24 ") == true)
        #expect(plan.whatStopsWhat.hasPrefix("If “Reset password” fails, nothing after it runs."))
        #expect(plan.notes.count == 2)
    }

    /// GamGUI's `test_lifecycle_autoreply_substitutes_employee_and_manager`: both names from the directory.
    @Test func theAutoReplyUsesTheDirectorysNames() async throws {
        try await connect()
        let plan = try await plan(form("alice@example.com", "carol@example.com", subject: "{employee} has left",
                                       message: "Please contact {manager}."))
        #expect(plan.autoreply == OffboardChanges.Autoreply(subject: "Alice Anders has left",
                                                             message: "Please contact Carol Clark (carol@example.com)."))
        #expect(lines(plan).contains { $0.contains("subject 'Alice Anders has left' message 'Please contact Carol Clark (carol@example.com).'") })
    }

    /// `test_offboard_preview_runs_the_default_text_for_an_emptied_field`: the block shows the default
    /// subject for an empty field, so the command sends it.
    @Test func anEmptiedFieldGivesTheDefaultText() async throws {
        try await connect()
        let plan = try await plan(form(subject: "", message: ""))
        #expect(lines(plan).contains { $0.contains("vacation on subject 'Carol Clark is no longer with the company'") })
        #expect(plan.autoreply?.message.hasPrefix("Thank you for your email. Carol Clark is no longer with the company.") == true)
    }

    /// GamGUI's Run refused a form edited after its preview; here an edited form is simply a new plan, and
    /// the screen knows which form a plan belongs to.
    @Test func anEditedFormGivesANewPlan() async throws {
        try await connect()
        let first = try await plan(form(subject: "Away"))
        let second = try await plan(form(subject: "Gone", days: 7))
        #expect(first.form != second.form && second.form == form(subject: "Gone", days: 7))
        #expect(lines(second).contains { $0.contains("subject Gone") } && !lines(second).contains { $0.contains("subject Away") })
        #expect(second.rows.last?.label == "7-day reminder for alice@example.com")
    }

    /// `test_offboard_preview_warns_when_the_manager_is_already_a_delegate`: GAM fails re-adding an
    /// existing delegate, which would stop the routine. Gmail compares addresses case-insensitively.
    @Test func theManagerAlreadyADelegateIsWarned() async throws {
        try await connect()
        try marker("delegates/carol@example.com", "helpdesk@example.com\nAlice@example.com\n")
        let plan = try await plan(form())
        #expect(plan.warnings.contains { $0.hasPrefix("alice@example.com already has delegate access to carol@example.com's mailbox") })
        let ticked = try await self.plan(form(done: [.delegate]))
        #expect(!ticked.warnings.contains { $0.contains("already has delegate access") })
    }

    /// `test_offboard_preview_warns_when_the_leavers_delegates_cannot_be_read`: the read uses the same Gmail
    /// access as the delegate step. A warning, not a block: the read may have failed for a passing reason.
    @Test func offboardPreviewWarnsWhenTheLeaversDelegatesCantBeRead() async throws {
        try await connect()
        try marker("nogmail/carol@example.com")
        let plan = try await plan(form())
        let warning = try #require(plan.warnings.first { $0.hasPrefix("Couldn't read carol@example.com's mail delegates") })
        #expect(warning.contains("Gmail Service/App not enabled") && warning.contains("will likely fail"))
        #expect(plan.steps.count == 8, "still a plan")
        let ticked = try await self.plan(form(done: [.delegate]))
        #expect(!ticked.warnings.contains { $0.contains("Couldn't read") })
    }

    /// `test_leaving_the_delegate_out_skips_its_read_and_warning`: it would warn about a step that won't run.
    @Test func leavingTheDelegateOutSkipsItsRead() async throws {
        try await connect()
        try marker("nogmail/carol@example.com")
        _ = try await plan(form())
        #expect(delegateReads() == 1)
        let plan = try await plan(form(notApplicable: [.delegate]))
        #expect(delegateReads() == 1 && plan.warnings.isEmpty)
    }

    /// `test_offboard_refuses_the_connected_admin`: revoking its access deletes the app's own token mid-run.
    @Test func theConnectedAdminIsRefused() async throws {
        try await connect(admin: "carol@example.com")
        let reason = try await blocked(form())
        #expect(reason.contains("GamGUI is connected as carol@example.com"))
    }

    /// GamGUI's route refuses these before reading anything: both addresses, a step ticked both ways,
    /// nothing left to run. And the invitee must be one address.
    @Test func theFormsOwnRefusalsComeFirst() async throws {
        try await connect()
        #expect(try await blocked(form("carol@example.com", "  ")) == "Enter both the departing user and the manager email.")
        #expect(try await blocked(form(done: [.transfer], notApplicable: [.transfer]))
                == "“Transfer Drive & Calendar” is ticked both as already done and as doesn't apply — pick one.")
        #expect(try await blocked(form(done: [.password, .revoke, .forward], notApplicable: Set(Offboarding.optionalSteps)))
                .contains("there is nothing to run"))
        #expect(try await blocked(form(invitee: "it@example.com, hr@example.com")).hasPrefix("The invitee"))
        #expect(delegateReads() == 0, "nothing was read")
        let invited = try await plan(form(invitee: " it@example.com "))
        #expect(lines(invited).last?.hasSuffix(" attendee it@example.com sendupdates all") == true)
    }

    /// GamGUI's `_days`: at least one.
    @Test func daysAreAtLeastOne() async throws {
        try await connect()
        let plan = try await plan(form(days: 0))
        #expect(plan.rows.last?.label == "1-day reminder for alice@example.com")
    }

    /// `test_a_rerun_mixing_done_and_left_out_runs_only_the_rest`: ticked steps are shown struck through with
    /// no command, left-out ones with what leaving them out costs; only the rest are writes, each needing
    /// only the steps that run before it (a ticked one counts as succeeded).
    @Test func aRerunMixingDoneAndLeftOutPlansOnlyTheRest() async throws {
        try await connect()
        let plan = try await plan(form(done: [.password, .revoke], notApplicable: [.delegate]))
        #expect(plan.header == "Offboarding carol@example.com — 5 of 8 steps (2 ticked as already done, 1 left out)")
        #expect(plan.steps.map { Array($0.commandLine.split(separator: " ").prefix(5)).joined(separator: " ") } == [
            "gam user carol@example.com forward off", "gam user carol@example.com vacation on",
            "gam create datatransfer carol@example.com drive,calendar", "gam all users delete calendaracls",
            "gam user alice@example.com add event"])
        #expect(plan.steps.map(\.requires) == [[], [], [], [], [2]], "only the transfer, among the steps that run")
        let rows = Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.key, $0.status) })
        #expect(rows[.password] == .alreadyDone && rows[.revoke] == .alreadyDone)
        #expect(rows[.delegate] == .leftOut(cost: "Nobody is given access to the leaver's mailbox."))
        #expect(!plan.whatStopsWhat.contains("“Set delegate” fails"))
    }

    /// What Off2 will hold: one write per step that runs, about the leaver, the sweep alone with the
    /// domain-wide timeout, each at least as risky as its action.
    @Test func theWritesAreWhatOff2WillHold() async throws {
        try await connect()
        let plan = try await plan(form())
        #expect(plan.steps.map(\.action) == [.resetPassword, .deprovisionUser, .forwardOff, .addDelegate, .setVacation,
                                             .createDataTransfer, .removeAllCalendarACLs, .addCalendarEvent])
        #expect(plan.steps.allSatisfy { $0.about["offboard"] == "carol@example.com" })
        #expect(plan.steps.map(\.target) == Array(repeating: "carol@example.com", count: 7) + ["alice@example.com"])
        #expect(plan.steps.map(\.requires) == [[], [0], [0], [0], [0, 3], [0, 3], [0], [0, 3, 5]])
        #expect(plan.steps.filter { $0.timeout == GamRunner.domainWideTimeout }.map(\.action) == [.removeAllCalendarACLs])
        #expect(plan.steps.first { $0.action == .createDataTransfer }?.risk == .destructive)
    }

    /// The live "senders will receive" block, from the directory as loaded: no read while typing.
    @Test func theLiveAutoReplyBlockReadsNothing() async throws {
        try await connect()
        let block = try #require(changes.autoreply(for: form(subject: "", message: "")))
        #expect(block.subject == "Carol Clark is no longer with the company")
        #expect(block.message.contains("please reach out to Alice Anders (alice@example.com)"))
        #expect(changes.autoreply(for: form(notApplicable: [.vacation])) == nil, "no auto-reply: left out")
        #expect(changes.autoreply(for: form("", "", subject: ""))?.subject == "[departing user] is no longer with the company")
        #expect(delegateReads() == 0)
    }

    /// A plan belongs to the tenant it was made on (GamGUI failure-log 2026-09-25).
    @Test func aTenantSwitchDropsThePlan() async throws {
        try await connect()
        _ = try await plan(form())
        try await connect("example.org", admin: "admin@example.org")
        #expect(setup.active == Domain("example.org"))
        if case .planned = changes.state { Issue.record("a plan made on example.com is shown for \(String(describing: setup.active))") }
    }

    // MARK: Off1 can't write

    /// Off1 is read-only by construction: `OffboardChanges` holds no executor and never previews or runs,
    /// and the screen reaches no write either (no Run button, no confirm sheet). A source scan, as
    /// `WriteRouteTests` holds the write routes.
    @Test func offboardingCantWrite() throws {
        func code(_ path: String) throws -> [String] {
            try String(contentsOf: Fixtures.repoRoot.appending(path: path), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        }
        let model = try code("Packages/GamKit/Sources/Directory/OffboardChanges.swift")
        #expect(model.contains { $0.contains("final class OffboardChanges") }, "the scan sees the model")
        for token in ["Executor", "executor", "preview(", "run(", "HeldPreview", "OperatorConfirmation", "WriteTicket",
                      "AuthenticatedRunner", "GamRunner("] {
            #expect(!model.contains { $0.contains(token) }, "OffboardChanges names \(token)")
        }
        let view = try code("App/OffboardView.swift")
        #expect(view.contains { $0.contains("struct OffboardView") }, "the scan sees the screen")
        for token in ["Executor", "executor", "preview(", ".run(", "HeldPreview", "OperatorConfirmation", "confirmed:",
                      ".confirm(", "ChangePreviewSheet", "UserChanges", "userChanges"] {
            #expect(!view.contains { $0.contains(token) }, "OffboardView names \(token)")
        }
    }
}

struct NotPlanned: Error {
    let state: String
}

/// A clock the test moves: the directory's age and the plan's dates read it.
final class Clock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}
