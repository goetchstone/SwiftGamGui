import Foundation
@testable import GamEngine
import TestSupport
import Testing

/// Offboarding Off1's pure core: GamGUI's routine (`core/lifecycle.py`) and its preview's checks and words
/// (`web/routes/lifecycle.py`), held byte for byte to Tests/Fixtures/offboarding.json, generated from frozen
/// GamGUI by scripts/gen_fixtures.py. The named tests port GamGUI's `tests/test_lifecycle.py`,
/// `tests/test_offboard_safety.py` and the preview's cases in `tests/test_users_web.py`.
@Suite("Offboarding")
struct OffboardingTests {
    struct Args: Decodable {
        let user: String, manager: String, subject: String, message: String, days: Int, today: String
        let notify: String, employee_name: String, manager_contact: String, not_applicable: [String]
    }
    struct PlannedStep: Decodable {
        let key: String, label: String, summary: String, requires: [String], commands: [[String]], command_lines: [String]
    }
    struct Routine: Decodable { let args: Args, steps: [PlannedStep]?, error: String?, message: String? }
    struct Requires: Decodable { let key: String, not_applicable: [String], requires: [String] }
    struct Fill: Decodable { let text: String, employee: String, manager: String, out: String }
    struct Line: Decodable { let argv: [String], line: String }
    struct Check: Decodable {
        let user: String, manager: String, connected_admin: String, errors: [String], warnings: [String]
        let leaver: String?, manager_found: String?
    }
    struct Name: Decodable { let email: String, name: String, contact: String }
    struct Compose: Decodable {
        let user: String, manager: String, subject_in: String, message_in: String, subject: String, message: String
    }
    struct Delegates: Decodable {
        let list: [String]?, exit: Int32?, stderr: String?
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            struct Failure: Decodable { let exit: Int32, stderr: String }
            let list = try? value.decode([String].self)
            let failure = list == nil ? try value.decode(Failure.self) : nil
            self.list = list
            exit = failure?.exit
            stderr = failure?.stderr
        }
    }
    struct Warning: Decodable { let user: String, manager: String, delegates: Delegates, warning: String }
    struct Constants: Decodable {
        let step_names: [String: String], requires: [String: [String]], optional_steps: [String]
        let not_applicable_cost: [String: String], default_subject: String, default_message: String
        let transfer_services: String, transfer_privacy: String
    }
    struct Document: Decodable {
        let constants: Constants, steps: [Routine], effective_requires: [Requires], fill_autoreply: [Fill]
        let command_line: [Line], check_addresses: [Check], names: [Name], compose_autoreply: [Compose]
        let delegate_warning: [Warning]
    }

    static let data = try! Data(contentsOf: Fixtures.offboardingJSON)
    let document = try! JSONDecoder().decode(Document.self, from: data)
    /// The fixture's directory, read into users as GamGUI's GAMUser.from_json reads it (gam_models.json).
    static let directory: [GamUser] = JSONValue.parse(String(decoding: data, as: UTF8.self))!.object!["users"]!.array!
        .map { GamUser(record: $0.object!) }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    private func bytes(_ texts: [String]) -> [[UInt8]] { texts.map(bytes) }
    private func steps(_ keys: [String]) -> Set<Offboarding.Step> { Set(keys.map { Offboarding.Step(rawValue: $0)! }) }

    /// The mock's directory, as the preview's checks read it: carol@ leaves, alice@ (a super admin, alias
    /// a.anders@) takes over, bob@ is suspended.
    static var mock: [GamUser] { Array(directory.prefix(4)) }

    static let today = Offboarding.Day(iso: "2026-06-23")!

    private func plan(_ user: String = "leaver@e.com", _ manager: String = "mgr@e.com", subject: String = "s",
                      message: String = "m", days: Int = 30, notify: String = "", employeeName: String = "",
                      managerContact: String = "", notApplicable: Set<Offboarding.Step> = [],
                      adding: Set<Offboarding.Step> = [], ownedCalendars: [UserCalendar] = [],
                      forwardingFilters: [Offboarding.MailFilter] = []) throws -> [Offboarding.Planned] {
        try Offboarding.steps(user: user, manager: manager, subject: subject, message: message, days: days, today: Self.today,
                              notify: notify, employeeName: employeeName, managerContact: managerContact,
                              notApplicable: notApplicable, adding: adding, ownedCalendars: ownedCalendars,
                              forwardingFilters: forwardingFilters)
    }

    private func calendar(_ id: String, _ summary: String) -> UserCalendar {
        UserCalendar(record: ["id": .string(id), "summary": .string(summary)])
    }

    // MARK: held to the fixture

    @Test func theConstantsAreGamGUIs() {
        let constants = document.constants
        #expect(Set(Offboarding.Step.gamgui.map(\.rawValue)) == Set(constants.requires.keys))
        #expect(Offboarding.Step.allCases.filter(Offboarding.Step.gamgui.contains) == Offboarding.Step.gamgui, "GamGUI's order")
        #expect(Offboarding.Step.allCases.filter { !Offboarding.Step.gamgui.contains($0) } == Offboarding.Step.addable)
        for step in Offboarding.Step.gamgui {
            #expect(bytes(step.name) == bytes(constants.step_names[step.rawValue]!), "\(step)")
            #expect(Offboarding.requires(step).map(\.rawValue) == constants.requires[step.rawValue]!, "\(step)")
            #expect(step.leftOutCost.map(bytes) == constants.not_applicable_cost[step.rawValue].map(bytes), "\(step)")
        }
        #expect(Offboarding.optionalSteps.map(\.rawValue) == constants.optional_steps)
        #expect(bytes(Offboarding.defaultSubject) == bytes(constants.default_subject))
        #expect(bytes(Offboarding.defaultMessage) == bytes(constants.default_message))
        #expect(Offboarding.transferServices == constants.transfer_services)
        #expect(Offboarding.transferPrivacy.rawValue == constants.transfer_privacy)
    }

    @Test func everyRoutineIsGamGUIs() throws {
        #expect(document.steps.count > 300)
        #expect(document.steps.contains { $0.error == "ValueError" } && document.steps.contains { $0.error == "OverflowError" })
        for routine in document.steps {
            let args = routine.args
            let today = try #require(Offboarding.Day(iso: args.today), "\(args.today)")
            let made = Result {
                try Offboarding.steps(user: args.user, manager: args.manager, subject: args.subject, message: args.message,
                                      days: args.days, today: today, notify: args.notify, employeeName: args.employee_name,
                                      managerContact: args.manager_contact, notApplicable: steps(args.not_applicable))
            }
            switch (made, routine.steps) {
            case (.success(let made), let want?):
                #expect(made.map(\.key.rawValue) == want.map(\.key), "\(args)")
                for (step, want) in zip(made, want) {
                    #expect(bytes(step.label) == bytes(want.label), "\(want.key) \(args)")
                    #expect(bytes(step.summary) == bytes(want.summary), "\(want.key) \(args)")
                    #expect(step.requires.map(\.rawValue) == want.requires, "\(want.key) \(args)")
                    #expect(want.commands.count == 1, "one command, one result per step")
                    #expect(bytes(step.write.argv) == bytes(want.commands[0]), "\(want.key) \(args)")
                    #expect(bytes(GamCommandLine.text(step.write.argv)) == bytes(want.command_lines[0]), "\(want.key) \(args)")
                }
            case (.failure(let error), nil):
                switch error as? Offboarding.Invalid {
                case .notOptional(let message)?:
                    #expect(routine.error == "ValueError" && message == routine.message, "\(args)")
                case .outOfRange?:
                    #expect(routine.error == "OverflowError", "\(args)")
                case .notAddable?, nil:
                    Issue.record("\(error) for \(args)")
                }
            case (.success, nil):
                Issue.record("GamGUI refused \(args) (\(routine.message ?? ""))")
            case (.failure(let error), _?):
                Issue.record("\(error) for \(args)")
            }
        }
    }

    @Test func effectiveRequiresIsGamGUIsForEveryLeftOutSet() {
        #expect(document.effective_requires.count == 8 * 256)
        for item in document.effective_requires {
            let made = Offboarding.effectiveRequires(Offboarding.Step(rawValue: item.key)!, notApplicable: steps(item.not_applicable))
            #expect(made.map(\.rawValue) == item.requires, "\(item.key) without \(item.not_applicable)")
        }
    }

    @Test func fillAutoreplyIsGamGUIs() {
        for item in document.fill_autoreply {
            #expect(bytes(Offboarding.fillAutoreply(item.text, employee: item.employee, manager: item.manager)) == bytes(item.out),
                    "\(item.text.debugDescription)")
        }
    }

    @Test func commandLineIsGamGUIs() {
        #expect(document.command_line.count > 800)
        for item in document.command_line {
            #expect(bytes(GamCommandLine.text(item.argv)) == bytes(item.line), "\(item.argv)")
        }
    }

    @Test func checkAddressesIsGamGUIs() {
        #expect(document.check_addresses.count > 900)
        for item in document.check_addresses {
            let check = Offboarding.checkAddresses(Self.directory, user: item.user, manager: item.manager,
                                                   connectedAdmin: item.connected_admin)
            let label = "\(item.user) → \(item.manager) as \(item.connected_admin)"
            #expect(bytes(check.errors) == bytes(item.errors), "\(label)")
            #expect(bytes(check.warnings) == bytes(item.warnings), "\(label)")
            #expect(check.user?.primaryEmail == item.leaver && check.manager?.primaryEmail == item.manager_found, "\(label)")
        }
    }

    @Test func displayNamesAreGamGUIs() {
        for item in document.names {
            #expect(bytes(Offboarding.displayName(of: item.email, in: Self.directory)) == bytes(item.name), "\(item.email)")
            #expect(bytes(Offboarding.managerContact(item.email, in: Self.directory)) == bytes(item.contact), "\(item.email)")
        }
    }

    @Test func theAutoreplyBlockIsGamGUIs() {
        for item in document.compose_autoreply {
            let block = Offboarding.composeAutoreply(user: item.user, manager: item.manager, subject: item.subject_in,
                                                     message: item.message_in, directory: Self.directory)
            #expect(bytes(block.subject) == bytes(item.subject) && bytes(block.message) == bytes(item.message),
                    "\(item.user) → \(item.manager)")
        }
    }

    @Test func theDelegateWarningIsGamGUIs() {
        #expect(document.delegate_warning.contains { $0.warning.isEmpty } && document.delegate_warning.contains { !$0.warning.isEmpty })
        for item in document.delegate_warning {
            let delegates: Result<[String], Offboarding.Unread> = if let list = item.delegates.list {
                .success(list)
            } else {
                .failure(Offboarding.Unread(GamError(exitCode: item.delegates.exit, stderr: item.delegates.stderr ?? "").message))
            }
            let warning = Offboarding.delegateWarning(user: item.user, manager: item.manager, delegates: delegates)
            #expect(bytes(warning ?? "") == bytes(item.warning), "\(item.delegates.list ?? [item.delegates.stderr ?? ""])")
        }
    }

    // MARK: ported from GamGUI's tests/test_lifecycle.py

    /// `test_offboard_steps_order_and_due_date`: Drive and Calendar are one transfer step (a second
    /// same-user transfer 409s while the first runs).
    @Test func offboardStepsOrderAndDueDate() throws {
        let steps = try plan(subject: "Subj", message: "Msg")
        #expect(steps.map(\.key) == [.password, .revoke, .forward, .delegate, .vacation, .transfer, .calacls, .reminder])
        #expect(steps.first { $0.key == .transfer }?.label == "Transfer Drive & Calendar ownership")
        #expect(steps.last!.label.contains("30-day"))
        #expect(steps.last!.summary.contains("2026-07-23"), "2026-06-23 + 30 days")
    }

    /// `test_the_default_offboarding_is_pinned_byte_for_byte`: every option at its default sends these
    /// eight commands, with these dependencies, in this order.
    @Test func theDefaultOffboardingIsPinnedByteForByte() throws {
        let steps = try plan("leaver@example.com", "mgr@example.com", subject: "{employee} has left", message: "Line one.\nAsk {manager}",
                             notify: "it@example.com", employeeName: "Lee Ver", managerContact: "Mo Gr (mgr@example.com)")
        let pinned: [(Offboarding.Step, [Offboarding.Step], [String])] = [
            (.password, [], ["update", "user", "leaver@example.com", "password", "random", "changepassword", "off"]),
            (.revoke, [.password], ["user", "leaver@example.com", "deprovision", "signout"]),
            (.forward, [.password], ["user", "leaver@example.com", "forward", "off"]),
            (.delegate, [.password], ["user", "leaver@example.com", "add", "delegate", "mgr@example.com"]),
            (.vacation, [.password, .delegate], [
                "user", "leaver@example.com", "vacation", "on", "subject", "Lee Ver has left",
                "message", "Line one.<br/>Ask Mo Gr (mgr@example.com)", "html", "contactsonly", "false",
                "domainonly", "false", "start", "Started", "end", "NotSpecified"]),
            (.transfer, [.password, .delegate], ["create", "datatransfer", "leaver@example.com", "drive,calendar", "mgr@example.com", "all"]),
            (.calacls, [.password], ["all", "users", "delete", "calendaracls", "primary", "leaver@example.com"]),
            (.reminder, [.password, .delegate, .transfer], [
                "user", "mgr@example.com", "add", "event", "primary",
                "summary", "Offboarding leaver@example.com: confirm with IT whether to delete the account",
                "start", "allday", "2026-07-23", "end", "allday", "2026-07-24",
                "description", "leaver@example.com was offboarded on 2026-06-23 (password reset; data + calendars "
                    + "transferred to mgr@example.com). When you're sure it's safe, tell IT to delete the account.",
                "attendee", "it@example.com", "sendupdates", "all"]),
        ]
        #expect(steps.count == pinned.count)
        for (step, (key, requires, argv)) in zip(steps, pinned) {
            #expect(step.key == key && step.requires == requires, "\(key)")
            #expect(bytes(step.write.argv) == bytes(argv), "\(key)")
        }
        // `drive,calendar` is ONE element, then the privacy level.
        let transfer = try #require(steps.first { $0.key == .transfer })
        #expect(transfer.write.argv[3] == "drive,calendar" && transfer.write.argv.count == 6 && transfer.write.argv[5] == "all")
    }

    /// `test_a_step_left_out_is_routed_around_never_counted_as_succeeded`.
    @Test func aStepLeftOutIsRoutedAroundNeverCountedAsSucceeded() {
        for step in Offboarding.Step.allCases {
            #expect(Offboarding.effectiveRequires(step) == Offboarding.requires(step), "nothing left out: unchanged")
        }
        // No delegate: the auto-reply and the transfer need only the reset, and the reminder the transfer.
        #expect(Offboarding.effectiveRequires(.vacation, notApplicable: [.delegate]) == [.password])
        #expect(Offboarding.effectiveRequires(.transfer, notApplicable: [.delegate]) == [.password])
        #expect(Offboarding.effectiveRequires(.reminder, notApplicable: [.delegate]) == [.password, .transfer])
        // No transfer: the reminder still needs the delegate, through which the manager was first reached.
        #expect(Offboarding.effectiveRequires(.reminder, notApplicable: [.transfer]) == [.password, .delegate])
        #expect(Offboarding.effectiveRequires(.reminder, notApplicable: [.delegate, .transfer]) == [.password])
    }

    /// `test_the_minimum_lock_cannot_be_left_out`.
    @Test(arguments: [Offboarding.Step.password, .revoke, .forward])
    func theMinimumLockCannotBeLeftOut(_ lock: Offboarding.Step) {
        #expect(throws: Offboarding.Invalid.notOptional(
            "only delegate, vacation, transfer, calacls, reminder can be left out; the reset, the sign-out and forwarding off always run")) {
            try plan("l@e.com", "m@e.com", notApplicable: [lock])
        }
        #expect(lock.leftOutCost == nil && !Offboarding.optionalSteps.contains(lock))
    }

    /// `test_the_reminder_does_not_claim_a_transfer_that_was_left_out`.
    @Test func theReminderDoesNotClaimATransferThatWasLeftOut() throws {
        let reminder = try #require(try plan("l@e.com", "m@e.com", notApplicable: [.transfer]).last)
        let line = reminder.write.argv.joined(separator: " ")
        #expect(line.contains("nothing transferred") && !line.contains("data + calendars transferred"))
    }

    /// `test_offboard_step_dependencies_are_the_documented_ones`: the runbook's "When a step fails" table.
    @Test func offboardStepDependenciesAreTheDocumentedOnes() throws {
        let made = Dictionary(uniqueKeysWithValues: try plan().map { ($0.key, $0.requires) })
        #expect(made == [.password: [], .revoke: [.password], .forward: [.password], .delegate: [.password],
                         .vacation: [.password, .delegate], .transfer: [.password, .delegate], .calacls: [.password],
                         .reminder: [.password, .delegate, .transfer]])
    }

    /// `test_offboard_reminder_invites_notify_target`: by email, since GAM's `add event` sends no invitation
    /// unless told to.
    @Test func offboardReminderInvitesNotifyTarget() throws {
        let reminder = try #require(try plan(notify: "it@e.com").last)
        #expect(reminder.write.argv[1] == "mgr@e.com")
        #expect(reminder.summary.contains("invites it@e.com"))
        #expect(Array(reminder.write.argv.suffix(4)) == ["attendee", "it@e.com", "sendupdates", "all"])
    }

    /// `test_offboard_autoreply_substitutes_employee_and_manager`.
    @Test func offboardAutoreplySubstitutesEmployeeAndManager() throws {
        let vacation = try #require(try plan("jane@e.com", "bob@e.com", subject: Offboarding.defaultSubject,
                                             message: Offboarding.defaultMessage, employeeName: "Jane Doe")
            .first { $0.key == .vacation })
        let argv = vacation.write.argv
        #expect(argv[1] == "jane@e.com")
        let subject = argv[argv.firstIndex(of: "subject")! + 1], message = argv[argv.firstIndex(of: "message")! + 1]
        #expect(subject.contains("Jane Doe") && message.contains("Jane Doe") && message.contains("bob@e.com"))
        #expect(!message.contains("{employee}") && !message.contains("{manager}"))
        #expect(vacation.summary.contains("Jane Doe") && vacation.summary.contains("bob@e.com"), "the preview shows it filled")
    }

    /// `test_offboard_autoreply_is_sent_as_the_text_the_preview_shows`: the message as HTML (each line
    /// break a `<br/>`, typed markup escaped, a backslash `&#92;`), the summary as the text.
    @Test func offboardAutoreplyIsSentAsTheTextThePreviewShows() throws {
        let vacation = try #require(try plan(subject: "Subj", message: "Line one.\r\n\r\nAsk {manager} <IT> & co.\nC:\\new",
                                             managerContact: "Mo Gr (mgr@e.com)").first { $0.key == .vacation })
        let argv = vacation.write.argv, at = argv.firstIndex(of: "message")!
        #expect(argv[at + 1] == "Line one.<br/><br/>Ask Mo Gr (mgr@e.com) &lt;IT&gt; &amp; co.<br/>C:&#92;new")
        #expect(argv[at + 2] == "html")
        #expect(bytes(vacation.summary).firstRange(of: bytes("Line one.\r\n\r\nAsk Mo Gr (mgr@e.com) <IT> & co.")) != nil)
    }

    /// `test_command_line_shows_argument_bounds_and_masks_secrets`: shell-quoted so each element's bounds
    /// show, an apostrophe readable, GAM's own `password random` as it runs, a typed password masked.
    @Test func commandLineShowsArgumentBoundsAndMasksSecrets() {
        let argv = GamCommands.setVacation(email: "a@example.com", subject: "Jane has left", message: "It's \"done\"\nbye").argv
        let line = GamCommandLine.text(argv)
        #expect(line.hasPrefix("gam user a@example.com vacation on subject 'Jane has left' message "))
        #expect(Array(Self.shellWords(line).dropFirst()) == argv, "each element's bounds survive")
        #expect(line.contains("It's") && !line.contains("'\"'\"'"), "an apostrophe stays readable")
        #expect(GamCommandLine.text(GamCommands.resetPassword(email: "a@example.com").argv)
                == "gam update user a@example.com password random changepassword off")
        let typed = GamCommandLine.text(GamCommands.createUser(email: "n@example.com", firstName: "N", lastName: "U",
                                                               password: "S3cret pw!", notify: "b@example.com").argv)
        #expect(!typed.contains("S3cret") && typed.components(separatedBy: ArgvRedaction.mask).count - 1 == 2)
    }

    /// `test_the_connected_admin_cannot_be_offboarded`: revoking the account the app is connected as
    /// deletes its own OAuth token mid-run.
    @Test func theConnectedAdminCannotBeOffboarded() {
        let directory = Self.users(#"{"primaryEmail": "admin@example.com", "isAdmin": true}"#, #"{"primaryEmail": "mgr@example.com"}"#)
        let check = Offboarding.checkAddresses(directory, user: "Admin@example.com", manager: "mgr@example.com",
                                               connectedAdmin: "admin@example.com")
        #expect(check.errors.first?.contains("GamGUI is connected as admin@example.com") == true)
        #expect(Offboarding.checkAddresses(directory, user: "admin@example.com", manager: "mgr@example.com").errors.isEmpty)
    }

    // MARK: the preview's address checks (test_users_web.py, on the mock's directory)

    /// `test_offboard_blocks_an_address_the_directory_does_not_confirm`: a typo'd manager meant a
    /// half-offboarded account.
    @Test(arguments: [("nobody@example.com", "alice@example.com", "nobody@example.com isn't in the directory"),
                      ("carol@example.com", "alcie@example.com", "alcie@example.com isn't in the directory"),
                      ("a.anders@example.com", "carol@example.com", "a.anders@example.com is an alias of alice@example.com"),
                      ("carol@example.com", "Carol@Example.com", "are the same account")])
    func anAddressTheDirectoryDoesNotConfirmIsBlocked(_ user: String, _ manager: String, _ expected: String) {
        let check = Offboarding.checkAddresses(Self.mock, user: user, manager: manager)
        #expect(check.errors.joined(separator: " ").contains(expected))
    }

    /// `test_offboard_preview_warns_but_does_not_block`.
    @Test(arguments: [("alice@example.com", "carol@example.com", "alice@example.com is a super admin"),
                      ("carol@example.com", "bob@example.com", "The manager bob@example.com is suspended"),
                      ("bob@example.com", "carol@example.com", "bob@example.com is already suspended")])
    func aWarningDoesNotBlock(_ user: String, _ manager: String, _ expected: String) {
        let check = Offboarding.checkAddresses(Self.mock, user: user, manager: manager)
        #expect(check.errors.isEmpty && check.warnings.joined(separator: " ").contains(expected))
    }

    /// `test_offboard_acts_on_the_directory_primary_address`: whatever case was typed.
    @Test func theChecksFindThePrimaryAddresses() {
        let check = Offboarding.checkAddresses(Self.mock, user: "CAROL@example.com", manager: "Alice@Example.com")
        #expect(check.errors.isEmpty && check.user?.primaryEmail == "carol@example.com"
                && check.manager?.primaryEmail == "alice@example.com")
    }

    // MARK: the form's own refusals (routes/lifecycle.py's preview)

    /// `test_nothing_left_to_run_says_why` and `test_a_step_cannot_be_both_already_done_and_left_out`.
    @Test func everyStepTickedLeavesNothingToRunAndBothWaysIsRefused() {
        #expect(Offboarding.tickProblem(done: [.password, .revoke, .forward], notApplicable: Set(Offboarding.optionalSteps))
                == "Every step is ticked as already done or left out — there is nothing to run.")
        #expect(Offboarding.tickProblem(done: Set(Offboarding.Step.allCases), notApplicable: [])?.contains("nothing to run") == true)
        #expect(Offboarding.tickProblem(done: [.transfer, .delegate], notApplicable: [.transfer, .delegate])
                == "“Set delegate” is ticked both as already done and as doesn't apply — pick one.", "the first in run order")
        #expect(Offboarding.tickProblem(done: [.password], notApplicable: [.delegate]) == nil)
    }

    // MARK: test_offboard_safety.py

    /// `test_domain_wide_calls_get_the_long_timeout`: `all users …` walks every user in one gam process;
    /// under the default a sweep of a few hundred users was killed partway. Every other step keeps it.
    @Test func onlyTheSweepGetsTheDomainWideTimeout() throws {
        let steps = try plan()
        #expect(steps.filter { $0.timeout == GamRunner.domainWideTimeout }.map(\.key) == [.calacls])
        #expect(steps.filter { $0.key != .calacls }.allSatisfy { $0.timeout == GamRunner.defaultTimeout })
        #expect(GamRunner.domainWideTimeout > GamRunner.defaultTimeout)
        #expect(try #require(steps.first { $0.key == .calacls }).summary.contains("stopped and reported failed after 60 min"))
    }

    // MARK: the preview's words

    /// The header: "8 steps", or how many of the eight run and why the rest don't (GamGUI's
    /// `test_a_rerun_mixing_done_and_left_out_runs_only_the_rest`, `…_rerun_runs_only_the_steps_not_ticked_done`).
    @Test func theHeaderCountsWhatRuns() {
        #expect(Offboarding.header(user: "carol@example.com", done: [], notApplicable: []) == "Offboarding carol@example.com — 8 steps")
        #expect(Offboarding.header(user: "c@example.com", done: [.password, .revoke], notApplicable: [.delegate])
                == "Offboarding c@example.com — 5 of 8 steps (2 ticked as already done, 1 left out)")
        #expect(Offboarding.header(user: "c@example.com", done: [.password, .revoke, .forward, .delegate, .vacation, .calacls],
                                   notApplicable: []) == "Offboarding c@example.com — 2 of 8 steps (6 ticked as already done)")
        #expect(Offboarding.header(user: "c@example.com", done: [], notApplicable: [.reminder])
                == "Offboarding c@example.com — 7 of 8 steps (1 left out)")
    }

    /// `test_lifecycle_page_intro_names_every_step_in_run_order`: the intro once left out the two steps
    /// that lock the leaver out.
    @Test func theIntroNamesEveryStepInRunOrder() throws {
        let intro = Offboarding.intro()
        let positions = try Offboarding.Step.gamgui.map { try #require(intro.range(of: $0.name)?.lowerBound, "\($0.name)") }
        #expect(positions == positions.sorted())
        #expect(Offboarding.Step.addable.allSatisfy { !intro.contains($0.name) })
        let added = Offboarding.intro(adding: Set(Offboarding.Step.addable))
        let all = try Offboarding.Step.allCases.map { try #require(added.range(of: $0.name)?.lowerBound, "\($0.name)") }
        #expect(all == all.sorted())
    }

    /// What stops what, worked out from the dependencies rather than written beside them (GamGUI's sentence
    /// went stale twice: it named the delegate as stopping the routine after the sweep stopped depending on
    /// it, and never named forwarding). Said only for the steps that run.
    @Test func whatStopsWhatFollowsTheDependencies() {
        let all = Offboarding.whatStopsWhat(done: [], notApplicable: [])
        #expect(all == "If “Reset password” fails, nothing after it runs. "
                + "If “Set delegate” fails, “Auto-reply”, “Transfer Drive & Calendar” and “Manager reminder” don't run. "
                + "If “Transfer Drive & Calendar” fails, “Manager reminder” doesn't run. "
                + "If “Revoke access & sign out”, “Turn off forwarding”, “Auto-reply”, “Remove from everyone's calendars” "
                + "or “Manager reminder” fails, it is reported as failed and the rest still runs.")
        // `test_offboarding_without_a_delegate_or_reminder_runs_what_its_preview_showed`: no delegate sentence.
        let without = Offboarding.whatStopsWhat(done: [], notApplicable: [.delegate, .reminder])
        #expect(!without.contains("“Set delegate” fails") && !without.contains("Manager reminder"))
        #expect(without.contains("If “Reset password” fails, nothing after it runs."))
        // A step ticked as done can't fail; what it would have stopped still runs.
        let rerun = Offboarding.whatStopsWhat(done: [.password, .revoke, .forward, .delegate], notApplicable: [])
        #expect(!rerun.contains("“Reset password” fails") && !rerun.contains("“Set delegate” fails"))
        #expect(rerun.contains("If “Transfer Drive & Calendar” fails, “Manager reminder” doesn't run."))
    }

    // MARK: added steps (native: docs/plans/2026-10-13-offboarding-options.md)

    /// An added step runs in its place, needs only the reset, and leaves GamGUI's eight exactly as they are.
    @Test func addedStepsRunInTheirPlacesAndChangeNothingElse() throws {
        let owned = [calendar("c_ops@group.calendar.google.com", "Operations"), calendar("c_old@group.calendar.google.com", "Old")]
        let filters = [Offboarding.MailFilter(id: "F1", forward: "home@example.org"), Offboarding.MailFilter(id: "F2", forward: "home@example.org"),
                       Offboarding.MailFilter(id: "F3", forward: "accounts@example.com")]
        let added = try plan("carol@example.com", "alice@example.com", adding: Set(Offboarding.Step.addable), ownedCalendars: owned,
                             forwardingFilters: filters)
        #expect(added.map(\.key) == [.password, .clearRecovery, .revoke, .forward, .forwardingFilters, .delegate, .vacation, .transfer,
                                     .secondaryCalendars, .calacls, .reminder, .hideFromDirectory])
        let filterStep = try #require(added.first { $0.key == .forwardingFilters })
        #expect(filterStep.write.argv == ["user", "carol@example.com", "delete", "filters", "F1,F2,F3"])
        #expect(filterStep.summary.hasPrefix("Delete carol@example.com's 3 Gmail filters that forward mail (to home@example.org, "
                                             + "accounts@example.com)."))
        let handOver = try #require(added.first { $0.key == .secondaryCalendars })
        #expect(handOver.write.argv == ["calendars", "c_ops@group.calendar.google.com,c_old@group.calendar.google.com", "transfer",
                                        "ownership", "alice@example.com"])
        #expect(handOver.summary.hasPrefix("Make alice@example.com the owner of carol@example.com's secondary calendars (“Operations”, “Old”)"))
        let recovery = try #require(added.first { $0.key == .clearRecovery })
        #expect(recovery.write.argv == ["update", "user", "carol@example.com", "recoveryemail", "", "recoveryphone", ""])
        #expect(recovery.summary.contains("recovery email and recovery phone") && recovery.label == "Clear recovery email & phone")
        let hide = try #require(added.first { $0.key == .hideFromDirectory })
        #expect(hide.write.argv == ["update", "user", "carol@example.com", "gal", "off"] && hide.label == "Hide from the directory")
        for step in added where Offboarding.Step.addable.contains(step.key) {
            #expect(step.requires == [.password] && step.timeout == GamRunner.defaultTimeout, "\(step.key)")
        }
        let plain = try plan("carol@example.com", "alice@example.com")
        #expect(plain.count == 8)
        let kept = added.filter { Offboarding.Step.gamgui.contains($0.key) }
        for (a, b) in zip(kept, plain) {
            #expect(a.key == b.key && a.write.argv == b.write.argv && a.summary == b.summary && a.requires == b.requires)
        }
        // Left-out steps route around as before; an added step can't be left out, nor a GamGUI step added.
        #expect(try plan(notApplicable: [.delegate], adding: [.clearRecovery]).first { $0.key == .vacation }?.requires == [.password])
        #expect(throws: Offboarding.Invalid.notAddable(
            "only clear_recovery, forwarding_filters, secondary_calendars, hide_from_directory can be added")) {
            try plan(adding: [.calacls])
        }
        #expect(throws: Offboarding.Invalid.notAddable("secondary_calendars needs the calendars to hand over")) {
            try plan(adding: [.secondaryCalendars])
        }
        #expect(throws: Offboarding.Invalid.notAddable("forwarding_filters needs the filters to remove")) {
            try plan(adding: [.forwardingFilters])
        }
        let record = GamOutput.records(#"User,id,JSON"# + "\n" + #"c@example.com,F9,"{""id"": ""F9"", ""action"": {""forward"": ""x@example.org""}}""#)
        #expect(record.map(Offboarding.MailFilter.init(record:)) == [Offboarding.MailFilter(id: "F9", forward: "x@example.org")])
        #expect(throws: Offboarding.Invalid.self) { try plan(notApplicable: [.clearRecovery]) }
    }

    @Test func theWordsCountTheAddedSteps() {
        let adding: Set<Offboarding.Step> = [.clearRecovery, .hideFromDirectory]
        #expect(Offboarding.header(user: "c@example.com", done: [], notApplicable: [], adding: adding) == "Offboarding c@example.com — 10 steps")
        #expect(Offboarding.header(user: "c@example.com", done: [.password, .clearRecovery], notApplicable: [.reminder], adding: adding)
                == "Offboarding c@example.com — 7 of 10 steps (2 ticked as already done, 1 left out)")
        #expect(Offboarding.header(user: "c@example.com", done: [.clearRecovery], notApplicable: [])
                == "Offboarding c@example.com — 8 steps", "a step not added doesn't count, ticked or not")
        let words = Offboarding.whatStopsWhat(done: [], notApplicable: [], adding: adding)
        #expect(words.hasPrefix("If “Reset password” fails, nothing after it runs."))
        #expect(words.contains("If “Clear recovery email & phone”, “Revoke access & sign out”")
                && words.contains("or “Hide from the directory” fails, it is reported as failed and the rest still runs."))
        #expect(Offboarding.tickProblem(done: Set(Offboarding.Step.gamgui), notApplicable: [], adding: [.hideFromDirectory]) == nil,
                "an added step is still to run")
        #expect(Offboarding.tickProblem(done: Set(Offboarding.Step.gamgui).union([.hideFromDirectory]), notApplicable: [],
                                        adding: [.hideFromDirectory])?.contains("nothing to run") == true)
    }

    @Test func aTemplateAddsOnlyTheAddableSteps() {
        let template = Offboarding.Template(leftOut: [.calacls], added: [.hideFromDirectory, .clearRecovery])
        #expect(template.problem == nil)
        #expect(template.runs == [.password, .clearRecovery, .revoke, .forward, .delegate, .vacation, .transfer, .reminder,
                                  .hideFromDirectory])
        #expect(Offboarding.Template(added: [.calacls]).problem?.contains("one of GamGUI's steps") == true)
        #expect(Offboarding.Template(leftOut: [.clearRecovery]).problem?.contains("runs only when added") == true)
        #expect(Offboarding.Step.addable.allSatisfy { $0.addedNote != nil && $0.leftOutCost == nil })
        #expect(Offboarding.Step.gamgui.allSatisfy { $0.addedNote == nil })
    }

    /// The reads' warnings: what the delete would lose, and what a hold stops, said whatever the steps; a failed read
    /// is said, never taken as "none".
    @Test func theCalendarAndVaultWarningsSayWhatWasFound() {
        let user = "carol@example.com"
        #expect(Offboarding.secondaryCalendarsWarning(user: user, calendars: .success([])) == nil)
        let one = UserCalendar(record: ["id": .string("c_team@group.calendar.google.com"), "summary": .string("Team")])
        #expect(Offboarding.secondaryCalendarsWarning(user: user, calendars: .success([one]))
                == "carol@example.com owns 1 secondary calendar: “Team”. The Drive & Calendar transfer doesn't move it, and Google "
                + "deletes it with the account: add “Hand over secondary calendars”, or hand it over before the account is deleted.")
        let seven = (1...7).map { UserCalendar(record: ["id": .string("c\($0)@group.calendar.google.com"), "summary": .string("")]) }
        let many = Offboarding.secondaryCalendarsWarning(user: user, calendars: .success(seven)) ?? ""
        #expect(many.contains("owns 7 secondary calendars: “c1@group.calendar.google.com”") && many.contains("and 2 more")
                && !many.contains("c6@"))
        #expect(Offboarding.secondaryCalendarsWarning(user: user, calendars: .failure(.init("Calendar Service/App not enabled")))
                == "Couldn't check whether carol@example.com owns secondary calendars (Calendar Service/App not enabled). Google "
                + "deletes the secondary calendars a deleted account owns: check before the account is deleted.")

        #expect(Offboarding.vaultHoldsWarning(user: user, holds: .success([]), transferRuns: true) == nil)
        let holds = [Offboarding.VaultHold(matter: "Smith v. Example", hold: "Mail"),
                     Offboarding.VaultHold(matter: "Audit", hold: "Sales OU", orgUnit: "/Sales")]
        #expect(Offboarding.vaultHoldsWarning(user: user, holds: .success(holds), transferRuns: true)
                == "carol@example.com is under 2 Vault holds: “Mail” in “Smith v. Example”, “Sales OU” in “Audit” (through the org "
                + "unit /Sales). Google doesn't transfer held data, so the Drive & Calendar transfer may move nothing, and the "
                + "account can't be deleted while it's held.")
        #expect(Offboarding.vaultHoldsWarning(user: user, holds: .success([holds[0]]), transferRuns: false)?
                    .hasPrefix("carol@example.com is under a Vault hold: “Mail” in “Smith v. Example”. Google doesn't transfer held data, and") == true)
        #expect(Offboarding.vaultHoldsWarning(user: user, holds: .failure(.init("Forbidden")), transferRuns: true)
                == "Couldn't check carol@example.com for Vault holds (Forbidden). A hold stops the Drive & Calendar transfer and the "
                + "account's deletion: check in Google Vault.")
        let row = GamOutput.records("User,matterId,matterName,holdId,name,orgUnitId,orgUnitPath\n"
                                    + "carol@example.com,m1,Audit,h1,Sales OU,ou1,/Sales\n")
        #expect(row.map(Offboarding.VaultHold.init(record:)) == [holds[1]])
    }

    /// The notes under the steps: the account stays active, and when to delete it.
    @Test func theNotesFollowWhatRuns() {
        let notes = Offboarding.notes(days: 30, notApplicable: [])
        #expect(notes.contains { $0.contains("stays active") && $0.contains("30-day reminder") })
        #expect(notes.contains { $0.contains("Don't delete the account until") })
        let none = Offboarding.notes(days: 30, notApplicable: [.transfer, .reminder])
        #expect(none.contains { $0.contains("no reminder is set") } && !none.contains { $0.contains("Don't delete the account until") })
    }

    /// GamGUI's dates are Python's: proleptic Gregorian, years 1 to 9999, `YYYY-MM-DD`.
    @Test func daysArePythonsDates() throws {
        #expect(try Offboarding.Day(iso: "2024-02-28")!.adding(days: 1).iso == "2024-02-29")
        #expect(try Offboarding.Day(iso: "1900-02-28")!.adding(days: 1).iso == "1900-03-01")
        #expect(try Offboarding.Day(iso: "0001-01-01")!.adding(days: 0).iso == "0001-01-01")
        #expect(throws: Offboarding.Invalid.outOfRange) { try Offboarding.Day(iso: "9999-12-31")!.adding(days: 1) }
        #expect(throws: Offboarding.Invalid.outOfRange) { try Offboarding.Day(iso: "0001-01-01")!.adding(days: -1) }
        #expect(throws: Offboarding.Invalid.outOfRange) { try Offboarding.Day(iso: "2026-06-23")!.adding(days: .max) }
        for bad in ["2026-02-30", "2026-13-01", "0000-01-01", "2026-6-23", "2026-06-23 ", "\u{0662}026-06-23", ""] {
            #expect(Offboarding.Day(iso: bad) == nil, "\(bad)")
        }
        // The operator's calendar day, in a Gregorian calendar whatever the Mac's own calendar is.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "America/New_York")!
        let instant = Date(timeIntervalSince1970: 1_782_180_000)   // 2026-06-23T02:00:00Z, the 22nd in New York
        #expect(Offboarding.Day(instant, in: buddhist).iso == "2026-06-22")
    }

    // MARK: helpers

    static func users(_ records: String...) -> [GamUser] {
        records.map { GamUser(record: JSONValue.parse($0)!.object!) }
    }

    /// A POSIX shell's words, for the bounds check (`shlex.split`): single quotes literal, double quotes
    /// with `\` before `\`, `"`, `$` or a backtick.
    static func shellWords(_ line: String) -> [String] {
        var words: [String] = [], word = "", inWord = false
        var scalars = Array(line.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            switch scalar {
            case " ":
                if inWord { words.append(word); word = ""; inWord = false }
            case "'":
                inWord = true
                while let next = scalars.popFirst(), next != "'" { word.unicodeScalars.append(next) }
            case "\"":
                inWord = true
                while let next = scalars.popFirst(), next != "\"" {
                    if next == "\\", let escaped = scalars.first, "\\\"$`".unicodeScalars.contains(escaped) {
                        word.unicodeScalars.append(scalars.removeFirst())
                    } else {
                        word.unicodeScalars.append(next)
                    }
                }
            default:
                inWord = true
                word.unicodeScalars.append(scalar)
            }
        }
        if inWord { words.append(word) }
        return words
    }
}
