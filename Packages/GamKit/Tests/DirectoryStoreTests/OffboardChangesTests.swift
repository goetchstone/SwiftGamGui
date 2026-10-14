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
    let auditURL: URL
    let executor: Executor
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
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        let tenantSetup = setup
        executor = Executor(runner: runner, audit: AuditLog(url: auditURL), actor: "admin@example.com",
                            tenant: { @MainActor [weak tenantSetup] in tenantSetup.flatMap { s in s.active.map { ($0, s.generation) } } },
                            extraEnvironment: ["GAM_MOCK_STATE": state.path, "GAM_MOCK_ARGV_LOG": argvLog.path])
        changes = OffboardChanges(executor: executor, setup: setup, directory: directory, access: access, now: { clock.now },
                                  calendar: newYork)
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
        #expect(delegateReads() == 1 && !plan.warnings.contains { $0.contains("delegate") }, "\(plan.warnings)")
    }

    // MARK: native reads and added steps (docs/plans/2026-10-13-offboarding-options.md)

    /// The secondary calendars the leaver owns (hidden ones too) and the Vault holds on them are said before the run,
    /// whatever the steps: the transfer doesn't move the calendars and the delete loses them; a hold stops both. A
    /// refused read is said, never taken as none.
    @Test func ownedCalendarsAndVaultHoldsAreSaid() async throws {
        try await connect()
        let carol = try await plan(form())
        #expect(carol.warnings.contains { $0.hasPrefix("carol@example.com owns 2 secondary calendars: “Operations”, “Old projects”.") },
                "\(carol.warnings)")
        #expect(!carol.warnings.contains { $0.contains("Vault") })
        let dana = try await plan(form("dana@example.com"))
        #expect(dana.warnings.contains("dana@example.com is under a Vault hold: “Mail and Drive” in “Contract audit”. Google doesn't "
                                       + "transfer held data, so the Drive & Calendar transfer may move nothing, and the account can't "
                                       + "be deleted while it's held."), "\(dana.warnings)")
        #expect(!dana.warnings.contains { $0.contains("secondary calendar") })
        try marker("novault")
        try marker("nocalendar/carol@example.com")
        let refused = try await plan(form(notApplicable: [.transfer]))
        #expect(refused.warnings.contains { $0.hasPrefix("Couldn't check carol@example.com for Vault holds (") && $0.hasSuffix(
            "A hold stops the account's deletion: check in Google Vault.") }, "\(refused.warnings)")
        #expect(refused.warnings.contains { $0.hasPrefix("Couldn't check whether carol@example.com owns secondary calendars (") })
    }

    /// "Hand over secondary calendars": one command over the calendars the preview read (hidden ones too), in place of
    /// the warning; run, the rest reads again and finds none, so it isn't planned; with none, or a failed read, it
    /// isn't planned and the warning stays.
    @Test func secondaryCalendarsAreHandedOverInOneCommand() async throws {
        try await connect()
        var form = form(notApplicable: [.calacls])
        form.added = [.secondaryCalendars]
        let plan = try await plan(form)
        #expect(plan.rows.map(\.key) == [.password, .revoke, .forward, .delegate, .vacation, .transfer, .secondaryCalendars, .calacls,
                                         .reminder])
        #expect(lines(plan).contains("gam calendars c_ops@group.calendar.google.com,c_archive@group.calendar.google.com transfer "
                                     + "ownership alice@example.com"), "\(lines(plan))")
        #expect(!plan.warnings.contains { $0.contains("secondary calendar") }, "the step replaces the warning")
        clock.advance(10)
        await changes.confirm(plan, typed("carol@example.com"))
        let run = try #require(changes.run)
        #expect(run.isComplete, "\(run.results)")
        #expect(try await blocked(run.rest) == "Every step is ticked as already done or left out — there is nothing to run.")
        let again = try await self.plan(form)
        #expect(!again.rows.contains { $0.key == .secondaryCalendars } && !again.warnings.contains { $0.contains("secondary calendar") },
                "carol owns none now: read again, nothing to hand over")
        // Someone who owns none: not planned, nothing said; a failed read: not planned, said.
        // (Then the admin-can't-see case, and the tick: `aCalendarTheAdminCantSeeFailsAndTheRestPlansIt`.)
        var dana = self.form("dana@example.com")
        dana.added = [.secondaryCalendars]
        #expect(!(try await self.plan(dana)).rows.contains { $0.key == .secondaryCalendars })
        try marker("nocalendar/dana@example.com")
        let unread = try await self.plan(dana)
        #expect(!unread.rows.contains { $0.key == .secondaryCalendars }
                && unread.warnings.contains { $0.hasPrefix("Couldn't check whether dana@example.com owns secondary calendars") })
    }

    /// GAM gets each calendar with the admin's own access first: one the admin can't see fails "Not Found", the rest
    /// are handed over, and Preview the Rest reads again and plans only that one. Ticked as done while it's still
    /// owned, the warning comes back.
    @Test func aCalendarTheAdminCantSeeFailsAndTheRestPlansIt() async throws {
        try await connect()
        try marker("adminhidden/c_archive@group.calendar.google.com")
        var form = form(notApplicable: [.calacls])
        form.added = [.secondaryCalendars]
        let plan = try await plan(form)
        clock.advance(10)
        await changes.confirm(plan, typed("carol@example.com"))
        let run = try #require(changes.run)
        #expect(!run.isComplete && run.summary.contains("failed: Hand over secondary calendars"), "\(run.summary)")
        let rest = try await self.plan(run.rest)
        #expect(lines(rest) == ["gam calendars c_archive@group.calendar.google.com transfer ownership alice@example.com"])
        var ticked = run.rest
        ticked.done.insert(.secondaryCalendars)
        let blocked = try await blocked(ticked)
        #expect(blocked == "Every step is ticked as already done or left out — there is nothing to run.")
        ticked.done.remove(.reminder)
        #expect(try await self.plan(ticked).warnings.contains { $0.hasPrefix("carol@example.com owns 1 secondary calendar: “Old projects”") })
    }

    /// Added steps run in their places and the first step's audit names them; a routine of ten or more steps with a
    /// destructive one needs `confirm` typed beside the leaver's address (the guard's rule for a destructive bulk run).
    @Test func addedStepsRunAndALongRoutineNeedsConfirmTyped() async throws {
        try await connect()
        var form = form()
        form.added = [.clearRecovery, .hideFromDirectory]
        let plan = try await plan(form)
        #expect(plan.header == "Offboarding carol@example.com — 10 steps")
        #expect(plan.rows.map(\.key) == [.password, .clearRecovery, .revoke, .forward, .delegate, .vacation, .transfer, .calacls,
                                         .reminder, .hideFromDirectory])
        // Masked, as GamGUI masks these keywords' values, though they're empty: the step's words say what it does.
        #expect(lines(plan)[1] == "gam update user carol@example.com recoveryemail '***redacted***' recoveryphone '***redacted***'")
        #expect(lines(plan).last?.hasSuffix("update user carol@example.com gal off") == true)
        #expect(plan.steps[1].requires == [0] && plan.steps.last?.requires == [0])
        #expect(plan.steps[0].about["added"] == "clear_recovery,hide_from_directory" && plan.steps[1].about["added"] == nil)
        #expect(plan.preview?.decision.requiresTypedConfirmation == true)
        await changes.confirm(plan, typed("carol@example.com"))
        #expect(changes.problem == "Type confirm to run this destructive bulk change." && changes.run == nil && writes().isEmpty)
        let again = try await self.plan(form)
        clock.advance(10)
        await changes.confirm(again, OperatorConfirmation(confirmed: true, typedWord: "confirm", typedAddresses: ["carol@example.com"]))
        let run = try #require(changes.run)
        #expect(run.isComplete, "\(run.results)")
        #expect(writes() == lines(again))
        #expect(writes()[1].contains("recoveryemail '***redacted***' recoveryphone") && writes().last?.hasSuffix("gal off") == true)
        // Without them, GamGUI's eight stay under the guard's bulk line: no word to type.
        #expect(try await self.plan(self.form()).preview?.decision.requiresTypedConfirmation == false)
    }

    /// `test_offboard_refuses_the_connected_admin`: revoking its access deletes the app's own token mid-run.
    @Test func theConnectedAdminIsRefused() async throws {
        try await connect(admin: "carol@example.com")
        let reason = try await blocked(form())
        #expect(reason.contains("GamGUI is connected as carol@example.com"))
        // Off2's review: a failed check of another domain once made the admin unknown, and this check then passed.
        try await connect("example.org", admin: "partialdwd@example.org")
        #expect(setup.active == Domain("example.com"))
        #expect(try await blocked(form()).contains("GamGUI is connected as carol@example.com"))
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

    /// A template only fills the form: the operator's Hand-over plans the seven steps of their routine, each
    /// command the one GamGUI's eight-step plan runs for that step, and the sweep left out with its cost.
    /// A step taken off, by its switch or by a template, drops its "already done" tick: it would come back with the
    /// step, unseen.
    @Test func takingAnAddedStepOffDropsItsTick() {
        var form = OffboardChanges.Form()
        form.added = [.clearRecovery, .hideFromDirectory]
        form.done = [.password, .clearRecovery, .hideFromDirectory]
        form.added.remove(.clearRecovery)
        #expect(form.done == [.password, .hideFromDirectory])
        form.apply(Offboarding.Template())
        #expect(form.added.isEmpty && form.done == [.password])
    }

    @Test func aTemplateFillsTheFormAndThePlanIsTheFormsOwn() async throws {
        try await connect()
        var fromTemplate = form(subject: "{employee} left", message: "Ask {manager}.", days: 9, done: [.password])
        let handOver = try #require(Offboarding.starterTemplates.first { $0.name == "Hand-over" }).template
        fromTemplate.apply(handOver)
        #expect(fromTemplate.leaver == "carol@example.com" && fromTemplate.manager == "alice@example.com")
        #expect(fromTemplate.done == [.password], "the ticks are this leaver's, and stay")
        #expect(fromTemplate.template == handOver)
        let byHand = form(subject: Offboarding.defaultSubject, message: Offboarding.defaultMessage, days: 30,
                          done: [.password], notApplicable: [.calacls])
        #expect(fromTemplate == byHand)

        let handOverPlan = try await plan(form(subject: Offboarding.defaultSubject, message: Offboarding.defaultMessage,
                                               notApplicable: handOver.leftOut))
        let everyStep = try await plan(form(subject: Offboarding.defaultSubject, message: Offboarding.defaultMessage))
        #expect(handOverPlan.header == "Offboarding carol@example.com — 7 of 8 steps (1 left out)")
        #expect(handOverPlan.steps.map(\.action) == [.resetPassword, .deprovisionUser, .forwardOff, .addDelegate, .setVacation,
                                                     .createDataTransfer, .addCalendarEvent])
        let reminder = { (plan: OffboardChanges.Plan) in plan.steps.last!.commandLine }
        #expect(handOverPlan.steps.dropLast().map(\.commandLine)
                == everyStep.steps.filter { $0.action != .removeAllCalendarACLs }.dropLast().map(\.commandLine))
        #expect(reminder(handOverPlan) == reminder(everyStep), "the reminder doesn't need the sweep")
        #expect(handOverPlan.rows.first { $0.key == .calacls }?.status == .leftOut(cost: Offboarding.Step.calacls.leftOutCost!))
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

    // MARK: the run (Off2; GamGUI's test_users_web.py run cases)

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

    /// What the mock wrote: everything but the reads (`print`, `info`, `show`).
    private func writes() -> [String] {
        ran().filter { !["print", "info", "show"].contains($0.first ?? "") && !($0.count > 2 && ["print", "info", "show"].contains($0[2])) }
            .map { GamCommandLine.text($0, masked: ArgvRedaction.redact($0)) }
    }

    private func typed(_ addresses: String...) -> OperatorConfirmation {
        OperatorConfirmation(confirmed: true, typedAddresses: addresses)
    }

    private var records: [JSONObject] { AuditLog.records(at: auditURL).reversed() }

    /// `test_offboard_run_executes_the_previewed_commands`: the confirm runs the preview's commands, each once, in
    /// order, and nothing else; the sweep's notices are tolerated and audited so; the directory is read again.
    @Test func theRunExecutesExactlyThePreviewedCommands() async throws {
        try await connect()
        let plan = try await plan(form())
        #expect(plan.preview != nil)
        clock.advance(10)
        await changes.confirm(plan, typed("carol@example.com"))
        let run = try #require(changes.run)
        #expect(changes.problem == nil, "\(changes.problem ?? "")")
        #expect(run.ended && run.isComplete, "\(run.results)")
        #expect(run.summary == "Offboarding complete — 8 of 8 steps succeeded.")
        #expect(writes() == lines(plan), "exactly the held commands, once each")
        let sweep = try #require(records.last { $0["action"]?.string == "removeAllCalendarACLs" })
        #expect(sweep["ok"]?.bool == true && sweep["extra"]?.object?["tolerated"]?.bool == true)
        #expect(records.filter { $0["extra"]?.object?["phase"]?.string == "end" }.allSatisfy { $0["extra"]?.object?["offboard"]?.string == "carol@example.com" })
        #expect(directory.loadedAt == clock.now, "the directory read again after the run")
        #expect(!run.mayStillBeSignedIn)
        #expect(run.next.hasPrefix("The manager now has a calendar reminder."))
        if case .planned = changes.state { Issue.record("the spent plan is still shown") }
    }

    /// The offboarding plan's D: no write without the leaver's address typed, whatever the screen sends.
    @Test func aRunNeedsTheLeaversAddressTyped() async throws {
        try await connect()
        for confirmation in [OperatorConfirmation(confirmed: true), typed("alice@example.com")] {
            let plan = try await plan(form())
            await changes.confirm(plan, confirmation)
            #expect(changes.problem == "Type carol@example.com to run this.")
            #expect(changes.run == nil)
        }
        #expect(writes().isEmpty)
    }

    /// `test_offboard_run_refuses_an_edited_form`: once the form changes under a plan, its preview is dropped and a
    /// confirm runs nothing, even after the form is changed back.
    @Test func anEditedFormDiscardsThePreview() async throws {
        try await connect()
        let plan = try await plan(form())
        let id = try #require(plan.preview?.id)
        changes.formChanged(form(days: 9))
        for _ in 0..<100 where await executor.isHeld(id) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await executor.isHeld(id) == false)
        guard case .planned(let shown) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(shown.preview == nil && shown.form == plan.form, "still shown, only shown")
        await changes.confirm(plan, typed("carol@example.com"))
        await changes.confirm(shown, typed("carol@example.com"))
        #expect(writes().isEmpty && changes.run == nil)
        #expect(changes.problem == nil, "a plan no longer shown is never sent to the executor")
    }

    /// `test_offboard_manager_already_a_delegate…` end to end (:1842): the delegate fails with GAM's line and stops the
    /// hand-over (auto-reply, transfer, reminder), the sweep still runs; the panel isn't complete, and Preview the
    /// Rest ticks exactly what succeeded.
    @Test func aFailedDelegateStopsOnlyTheHandOver() async throws {
        try await connect()
        try marker("delegates/carol@example.com", "alice@example.com\n")
        let plan = try await plan(form())
        #expect(plan.warnings.contains { $0.contains("already has delegate access") })
        await changes.confirm(plan, typed("carol@example.com"))
        let run = try #require(changes.run)
        let byKey = Dictionary(uniqueKeysWithValues: zip(plan.runningRows.map(\.key), run.results))
        guard case .failed(let message, _)? = byKey[.delegate] else { Issue.record("\(run.results)"); return }
        #expect(message.contains("Delegate already exists."))
        for key in [Offboarding.Step.vacation, .transfer, .reminder] {
            #expect(byKey[key] == .skipped(reason: "Step 4 didn't succeed."), "\(key)")
        }
        #expect(byKey[.calacls]??.isSucceeded == true, "the sweep doesn't need the delegate")
        #expect(!run.isComplete)
        #expect(run.summary == "Offboarding incomplete — 4 of 8 steps succeeded; failed: Set delegate; not run: Set auto-responder, "
            + "Transfer Drive & Calendar ownership, 30-day reminder for alice@example.com.")
        #expect(run.next.contains("Don't delete the account until the Drive & Calendar transfer"))
        #expect(run.rest.done == [.password, .revoke, .forward, .calacls])
        // The rest is what's left, as a new preview.
        let rest = try await self.plan(run.rest)
        #expect(rest.steps.map(\.action) == [.addDelegate, .setVacation, .createDataTransfer, .addCalendarEvent])
    }

    /// The run checks again that both accounts are what the preview showed (stricter than GamGUI's list re-check):
    /// another primary address (an alias, a rename), a suspension or an admin role since then refuses it.
    @Test func theAccountsMustBeUnchangedSinceThePreview() {
        func user(_ email: String, suspended: Bool = false, admin: Bool = false, delegated: Bool = false) -> GamUser {
            GamUser(record: ["primaryEmail": .string(email), "suspended": .bool(suspended), "isAdmin": .bool(admin),
                             "isDelegatedAdmin": .bool(delegated)])
        }
        let carol = user("carol@example.com")
        #expect(OffboardChanges.unchanged(user("Carol@Example.com"), since: carol))
        #expect(!OffboardChanges.unchanged(user("alice@example.com"), since: carol))
        #expect(!OffboardChanges.unchanged(user("carol@example.com", suspended: true), since: carol))
        #expect(!OffboardChanges.unchanged(user("carol@example.com", admin: true), since: carol))
        #expect(!OffboardChanges.unchanged(user("carol@example.com", delegated: true), since: carol))
    }

    /// Off2's review: the run reads both accounts again and refuses, with nothing written, when either changed
    /// since the plan: here suspended elsewhere (the Admin console) between the plan and the confirm.
    @Test func anAccountChangedSinceThePlanRefusesTheRun() async throws {
        try await connect()
        for changed in ["carol@example.com", "alice@example.com"] {
            let plan = try await plan(form())
            try marker("suspended/\(changed)")
            await changes.confirm(plan, typed("carol@example.com"))
            #expect(changes.problem == "What the preview showed has changed since — preview again.", "\(changed)")
            #expect(changes.run == nil)
            try FileManager.default.removeItem(at: state.appending(path: "suspended/\(changed)"))
        }
        #expect(writes().isEmpty)
    }

    /// The preview is the routine's: confirmed with a click and the leaver typed, only `requires` stopping a step.
    @Test func thePreviewIsTheRoutines() async throws {
        try await connect()
        let preview = try #require(try await plan(form()).preview)
        #expect(!preview.stopsAtAccountWideFailure)
        #expect(preview.typedAddress == "carol@example.com")
        #expect(preview.needsConfirmClick)
    }

    /// Off2's review: the rest of a run can be the manager's reminder alone, which acts on nobody's account but the
    /// manager's calendar: no address to type, and it runs (GamGUI runs it too).
    @Test func theReminderAloneRunsWithoutAnAddressToType() async throws {
        try await connect()
        let plan = try await plan(form(done: Set(Offboarding.Step.allCases).subtracting([.reminder])))
        #expect(plan.preview?.typedAddress == nil)
        await changes.confirm(plan, OperatorConfirmation(confirmed: true))
        #expect(changes.problem == nil, "\(changes.problem ?? "")")
        #expect(changes.run?.isComplete == true)
        #expect(writes() == lines(plan) && writes().count == 1)
    }

    /// One offboarding at a time: no new plan while a run goes on.
    @Test func noNewPlanWhileOneRuns() async throws {
        try await connect()
        let plan = try await plan(form())
        let running = Task { await changes.confirm(plan, typed("carol@example.com")) }
        while !changes.isRunning { await Task.yield() }
        await changes.plan(form(days: 9))
        #expect(changes.problem == "An offboarding is running: wait for it to finish, then preview again.")
        await running.value
        #expect(changes.run?.isComplete == true)
    }

    /// Steps left out are said in the run's first audit record (GamGUI's `offboard_plan`), and only the sweep tolerates.
    @Test func theHeldStepsSayWhatWasLeftOut() async throws {
        try await connect()
        let plan = try await plan(form(notApplicable: [.calacls, .reminder]))
        #expect(plan.steps.first?.about["not_applicable"] == "calacls,reminder")
        #expect(plan.steps.dropFirst().allSatisfy { $0.about["not_applicable"] == nil })
        let full = try await self.plan(form())
        #expect(full.steps.filter { !$0.tolerating.isEmpty }.map(\.action) == [.removeAllCalendarACLs])
        #expect(full.steps.first?.about["not_applicable"] == nil)
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
