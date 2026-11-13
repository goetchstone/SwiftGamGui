import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Calendars C2a: sharing a calendar with one person and taking access away, previewed, confirmed and run
/// through ChangeCore, end to end against the strict mock with its argv log. Ports GamGUI's calendar route
/// tests (`tests/test_users_web.py`) and the incidents behind its confirm rules (failure-log 2026-09-23 and
/// 2026-09-25: a confirm that ran what the form said then, a preview held on one tenant for another).
@MainActor
@Suite("Calendar changes", .serialized)
final class CalendarChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-calchanges-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let base: URL
    let runner: AuthenticatedRunner
    let setup: SetupModel
    let directory: DirectoryStore
    let groups: GroupStore
    let reads: CalendarReads
    let argvLog: URL
    let auditURL: URL
    let state: URL
    let confirmed = OperatorConfirmation(confirmed: true)
    static let team = "c_team@group.calendar.google.com"

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        argvLog = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        state = scratch.appending(path: "mock-state")
        runner = AuthenticatedRunner(runner: GamRunner(binary: try Self.logging(Fixtures.mockGam, to: argvLog, in: scratch)),
                                     vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        groups = GroupStore(setup: setup, runner: runner)
        reads = CalendarReads(setup: setup, runner: runner)
        reads.environment = ["GAM_MOCK_STATE": state.path]
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A script running `mock` with every call's argv logged (`prefix` before it: a failure to fake).
    static func logging(_ mock: URL, to log: URL, in folder: URL, prefix: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "mock-\(UUID().uuidString).sh")
        try Data(("#!/bin/sh\n\(prefix)GAM_MOCK_ARGV_LOG='\(log.path)' exec '\(mock.path)' \"$@\"\n").utf8).write(to: script)
        chmod(script.path, 0o755)
        return script
    }

    /// The executor and the screen's changes, on `lookups` for the group check (the mock by default).
    private func changes(lookups: AuthenticatedRunner? = nil, writer: AuthenticatedRunner? = nil) -> CalendarChanges {
        let setup = setup
        let executor = Executor(runner: writer ?? runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_FIXTURES": Fixtures.mockGamData.path, "GAM_MOCK_STATE": state.path])
        let changes = CalendarChanges(executor: executor, setup: setup, directory: directory, groups: groups, reads: reads,
                                      runner: lookups ?? runner)
        changes.environment = ["GAM_MOCK_STATE": state.path]
        return changes
    }

    /// Imports `domain` with an `oauth2.txt` naming `admin`, checks access, and loads its directory.
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

    private func calls() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls
    }

    /// The calendar writes the mock ran: rule changes and subscribes.
    private func writes() -> [[String]] {
        calls().filter { argv in
            (argv.contains("calendaracls") && !argv.contains("print")) || (argv.count > 3 && argv[2] == "add" && argv[3] == "calendars")
                || (argv.count > 3 && argv[2] == "remove" && argv[3] == "calendars") || (argv.count > 3 && argv[2] == "delete" && argv[3] == "events")
        }
    }

    /// The event reads the mock ran.
    private func eventReads() -> [[String]] { calls().filter { $0.count > 3 && $0[2] == "print" && $0[3] == "events" } }

    /// Accounts the mock's directory doesn't hold that it can act as (`known_user`: an account `create user` made).
    private func makeUsers(_ addresses: [String]) throws {
        let folder = state.appending(path: "created")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for address in addresses { try Data().write(to: folder.appending(path: address)) }
    }

    /// The mock's rules for `calendar` replaced (as a write would leave them), one record per line as GAM prints them.
    private func setRules(_ calendar: String, _ records: [String]) throws {
        let folder = state.appending(path: "acls")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data((records.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: calendar))
    }

    private func lookups() -> [[String]] { calls().filter { $0.starts(with: ["print", "group-members"]) } }

    /// The mock's data owner of `calendar` (as a `transfer ownership` would leave it).
    private func setDataOwner(_ calendar: String, _ owner: String) throws {
        let folder = state.appending(path: "calendar_owner")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(owner.utf8).write(to: folder.appending(path: calendar))
    }

    /// A lookups runner whose reads matching `test` (shell, on the argv) answer `stderr` and exit `code` once `flag` exists.
    private func failing(_ test: String, once flag: URL, stderr: String, code: Int32 = 50) throws -> AuthenticatedRunner {
        let script = try Self.logging(Fixtures.mockGam, to: argvLog, in: scratch, prefix: """
            if [ -e '\(flag.path)' ] && \(test); then printf '%s\\n' '\(stderr)' >&2; exit \(code); fi

            """)
        return AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base)
    }

    private func bytes(_ calls: [[String]]) -> [[[UInt8]]] { calls.map { $0.map { Array($0.utf8) } } }

    private func pending(_ changes: CalendarChanges) throws -> CalendarChanges.Pending {
        guard case .previewing(let pending) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return pending
    }

    private func problem(_ changes: CalendarChanges) throws -> CalendarChanges.Problem {
        guard case .problem(let problem) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return problem
    }

    private func done(_ changes: CalendarChanges) throws -> CalendarChanges.Done {
        guard case .done(let done) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return done
    }

    private func rule(_ who: String, on calendar: String = team) async throws -> CalendarACL {
        await reads.load(.access(calendar: calendar))
        return try #require(reads.access(.access(calendar: calendar))?.first { $0.scopeToken == who })
    }

    // MARK: sharing

    /// `test_calendar_share_subscribes_the_person` (`test_users_web.py:1027-1036`): the rule, then the subscribe
    /// as the person, GamGUI's argv pair exactly; GamGUI's message.
    @Test func sharingWithAPersonAddsTheRuleThenSubscribes() async throws {
        try await connect()
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: " dana@example.com ", role: "reader")
        let pending = try pending(changes)
        #expect(pending.title == "Share Team Calendar with dana@example.com" && pending.confirmLabel == "Share")
        #expect(pending.preview.steps.map(\.shownArgv) == [GamCommands.addCalendarACL(calendarID: Self.team, scope: "dana@example.com").argv,
                                                          GamCommands.subscribeCalendar(email: "dana@example.com", calendarID: Self.team).argv])
        #expect(pending.preview.steps.map(\.target) == [Self.team, "dana@example.com"])
        #expect(pending.preview.steps[1].requires == [0])
        #expect(pending.preview.steps.map(\.summary) == ["Let dana@example.com see all event details on Team Calendar.",
                                                         "Add Team Calendar to dana@example.com's calendar list."])
        #expect(!pending.preview.needsConfirmClick, "LOW and two targets: the sheet's click is all it asks (D4)")
        #expect(pending.warnings.isEmpty)
        await changes.confirm(pending, confirmed)
        #expect(try done(changes) == CalendarChanges.Done(
            message: "Shared with dana@example.com — it will now appear in their Google Calendar.", partial: false))
        #expect(bytes(writes()) == bytes([["calendars", Self.team, "add", "calendaracls", "reader", "dana@example.com"],
                                          ["user", "dana@example.com", "add", "calendars", Self.team, "selected", "true"]]))
        #expect(changes.finished == 1)
        let audit = AuditLog.records(at: auditURL)
        #expect(audit.compactMap { $0["action"]?.string }.filter { $0 != "" }.count == 4, "begin and end of each step")
        #expect(audit.contains { $0["extra"]?.object?["scope"]?.string == "dana@example.com" })
        #expect(audit.contains { $0["extra"]?.object?["calendar"]?.string == Self.team })
    }

    /// `test_calendar_share_partial_when_subscribe_fails` (`:1345-1350`): the rule is in, the subscribe failed.
    @Test func aFailedSubscribeIsAPartialShare() async throws {
        try await connect()
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "SUBFAIL@example.com", role: "reader")
        await changes.confirm(try pending(changes), confirmed)
        #expect(try done(changes) == CalendarChanges.Done(
            message: "Shared with SUBFAIL@example.com, but couldn't auto-add it to their calendar list — they can add it manually in Google Calendar.",
            partial: true))
        #expect(writes().count == 2)
        #expect(changes.finished == 1)
    }

    /// A rule GAM couldn't add is GamGUI's failure, and the subscribe that needed it is skipped.
    @Test func aFailedGrantSkipsTheSubscribe() async throws {
        try await connect()
        let changes = changes()
        await changes.previewShare(calendarID: "nosuch@group.calendar.google.com", name: "Gone", target: "dana@example.com", role: "reader")
        await changes.confirm(try pending(changes), confirmed)
        let problem = try problem(changes)
        #expect(problem.summary == "Couldn't share the calendar with dana@example.com. \(GamError.Kind.notFound.remediation)")
        #expect(problem.detail?.contains("Add Failed: Not Found") == true)
        #expect(writes().count == 1, "the subscribe was skipped")
        #expect(changes.finished == 0)
    }

    /// `test_calendar_share_refuses_a_role_outside_the_grammar` (`:842-849`): the builder's check, before any gam.
    @Test func aRoleOutsideTheGrammarNeverReachesGam() async throws {
        try await connect()
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "dana@example.com", role: "admin")
        #expect(try problem(changes).summary.hasPrefix("Couldn't share calendar: invalid calendar role"))
        #expect(writes().isEmpty && lookups().isEmpty)
        // The picker's words are GAM's: each of the four is accepted.
        for (role, _) in CalendarSharing.pickerRoles {
            await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "dana@example.com", role: role.rawValue)
            #expect(try pending(changes).preview.steps.first?.shownArgv[4] == role.rawValue)
        }
    }

    /// `test_calendar_share_requires_target` (`:833-836, 1340-1342`).
    @Test func anEmptyTargetIsRefused() async throws {
        try await connect()
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: " \u{3000}", role: "reader")
        #expect(try problem(changes).summary == "Enter a person or group to share with.")
        #expect(writes().isEmpty && lookups().isEmpty)
    }

    /// F5/D5: a comma list, a keyword or a scope prefix would be read by GAM as something else; never sent.
    @Test func aCommaListOrKeywordNeverReachesGam() async throws {
        try await connect()
        let changes = changes()
        for target in ["dana@example.com,erin@example.com", "file", "domain", "default", "dana", "user:dana@example.com",
                       "group:", "group:sales@example.com,it@example.com", "group:group:sales@example.com", "group:sales"] {
            await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: target, role: "reader")
            #expect(try problem(changes).summary == CalendarSharing.calendarTargetProblem(target), "\(target)")
        }
        #expect(CalendarSharing.calendarTargetProblem("dana") == "\u{201C}dana\u{201D} isn't one address: enter one person's or group's full "
            + "address, like name@example.com.")
        #expect(writes().isEmpty && lookups().isEmpty)
    }

    /// `test_calendar_share_known_user_skips_group_lookup` (`:1108-1114`): an active account is a person, full stop.
    @Test func aKnownUserIsNeverTreatedAsAGroup() async throws {
        try await connect()
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "Carol@Example.com", role: "reader")
        #expect(try pending(changes).preview.steps.count == 2)
        #expect(lookups().isEmpty, "a known account was looked up as a group")
        // Not in the directory: GamGUI's lookup, and "Does not exist" makes it a person (external included).
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "guest@example.net", role: "reader")
        #expect(try pending(changes).preview.steps.count == 2)
        #expect(bytes(lookups()) == bytes([GamCommands.printGroupMembers(group: "guest@example.net").argv]))
    }

    /// `test_calendars_share_group_fans_out_to_members` and `…_bare_group_address_also_fans_out` (`:1070-1095`): a group
    /// is resolved first, then shared, then the calendar is added to each member's list. Its members are read now and held;
    /// only active people get a step (a group inside it, a suspended account and the customer row are counted, not run),
    /// and the rule's scope is `group:` (GAM reads a bare address as a person's rule, `normalizeRuleId`).
    @Test func sharingWithAGroupAddsItForEachActiveMember() async throws {
        try await connect()
        let changes = changes()
        let ops = "c_ops@group.calendar.google.com"
        await changes.previewShare(calendarID: ops, name: "Operations", target: "staff@example.com", role: "reader")
        let pending = try pending(changes)
        #expect(pending.kind == .shareGroup && pending.title == "Share Operations with staff@example.com")
        #expect(bytes(pending.preview.steps.map(\.shownArgv)) == bytes([
            GamCommands.addCalendarACL(calendarID: ops, scope: "group:staff@example.com").argv,
            GamCommands.subscribeCalendar(email: "alice@example.com", calendarID: ops).argv]))
        #expect(pending.preview.steps[1].requires == [0]
            && pending.preview.title == "Share Operations with staff@example.com and add it to 1 member's calendar")
        guard case .group(let members, let leftOut) = pending.detail else { throw NotPreviewing(state: "\(pending.detail)") }
        #expect(members == ["alice@example.com"] && leftOut == 2)
        #expect(bytes(lookups()) == bytes([GamCommands.printGroupMembers(group: "staff@example.com").argv]))
        #expect(pending.preview.needsConfirmClick, "a group share is always confirmed from its step")
        await changes.confirm(pending, OperatorConfirmation())
        #expect(writes().isEmpty, "a bare confirm")
        await changes.previewShare(calendarID: ops, name: "Operations", target: "staff@example.com", role: "reader")
        await changes.confirm(try self.pending(changes), confirmed)
        #expect(try done(changes) == CalendarChanges.Done(
            message: "Shared with staff@example.com. It now appears in 1 of 1 member's Google Calendars.", partial: false))
        #expect(bytes(writes()) == bytes([["calendars", ops, "add", "calendaracls", "reader", "group:staff@example.com"],
                                          ["user", "alice@example.com", "add", "calendars", ops, "selected", "true"]]))
        #expect(reads.access(.access(calendar: ops))?.contains { $0.scopeToken == "group:staff@example.com" } == true)
        // Known from the group list it is still read, for its members; a member who already has it is GamGUI's failure.
        await groups.load()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "SALES@example.com", role: "reader")
        #expect(lookups().count == 3, "staff twice, then sales")
        await changes.confirm(try self.pending(changes), confirmed)
        let partial = try done(changes)
        #expect(partial.partial && partial.failedCount == 1 && partial.failures.count == 1)
        #expect(partial.message == "Shared with SALES@example.com. It now appears in 0 of 1 member's Google Calendars. "
            + "Couldn't add it for 1 — they can add it manually.")
        #expect(partial.failures[0].hasPrefix("alice@example.com — "))
    }

    /// `test_calendars_share_to_a_large_group_asks_first_with_the_member_count` (`:1097-1118`): at the guard's bulk
    /// threshold the confirm names the count with a sample, and the count must be typed; the confirm runs exactly the
    /// members the preview resolved, in GAM's order.
    @Test func aLargeGroupNeedsItsCountTyped() async throws {
        try await connect()
        let allhands = (1...12).map { String(format: "member%02d@example.com", $0) }
        try makeUsers(allhands)
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "allhands@example.com", role: "reader")
        let pending = try pending(changes)
        #expect(pending.members == allhands && pending.preview.steps.count == 13)
        #expect(pending.preview.decision.requiresTypedCount && pending.preview.decision.requiresConfirmation)
        #expect(writes().isEmpty)
        await changes.confirm(pending, confirmed)
        #expect(changes.typedProblem == "Type 13, the number of changes, to confirm." && writes().isEmpty)
        #expect(try self.pending(changes).id == pending.id, "the sheet stays, its preview unspent")
        await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedCount: "13"))
        #expect(try done(changes).message == "Shared with allhands@example.com. It now appears in 12 of 12 members' Google Calendars.")
        let ran = writes()
        #expect(bytes([ran[0]]) == bytes([["calendars", Self.team, "add", "calendaracls", "reader", "group:allhands@example.com"]]))
        #expect(ran.dropFirst().map { $0[1] } == allhands)
        #expect(changes.progress == nil)
    }

    /// `test_calendars_share_empty_group_says_so` (`:1135-1140`): the group is shared; there is no one to add it for.
    @Test func anEmptyGroupIsSharedWithTheGroupOnly() async throws {
        try await connect()
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "empty-group@example.com", role: "reader")
        let pending = try pending(changes)
        #expect(pending.preview.steps.count == 1 && pending.members.isEmpty)
        await changes.confirm(pending, confirmed)
        #expect(try done(changes).message == "Shared with empty-group@example.com, but that group has no members to add it for.")
        #expect(writes().count == 1)
    }

    /// `test_stop_ends_the_calendar_fan_out` (`test_jobs_tray.py:83-90`): Stop ends the fan-out after the subscribe in
    /// flight; the rest never run, and the result says how far it got.
    @Test func stopEndsAGroupShareAfterTheSubscribeInFlight() async throws {
        try await connect()
        let allhands = (1...12).map { String(format: "member%02d@example.com", $0) }
        try makeUsers(allhands)
        let slow = try Self.logging(Fixtures.mockGam, to: argvLog, in: scratch, prefix: "[ \"$3 $4\" = \"add calendars\" ] && sleep 0.3\n")
        let changes = changes(writer: AuthenticatedRunner(runner: GamRunner(binary: slow), vault: vault, runtimeDirectory: base))
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "allhands@example.com", role: "reader")
        let pending = try pending(changes)
        let run = Task { await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedCount: "13")) }
        while (changes.progress?.done ?? 0) < 1 { try await Task.sleep(for: .milliseconds(20)) }
        await changes.stop()
        await run.value
        let stopped = try done(changes)
        let subscribes = writes().count - 1
        #expect(subscribes >= 1 && subscribes < 12, "\(subscribes) ran")
        #expect(stopped.partial && stopped.message == "Stopped by you \u{2014} \(12 - subscribes) not attempted. Added to \(subscribes) of 12 "
            + "members' calendars before stopping.")
        #expect(stopped.failedCount == 0 && stopped.failures.isEmpty, "a member never tried isn't a failure")
    }

    /// GamGUI's `stop_reason` in `_run_subscribe`: a failure every later member would share (a scope not granted, the
    /// sign-in expired) stops the fan-out there; the rest aren't attempted, and aren't told to add it by hand. The live
    /// count never counts them as failed.
    @Test func anAccountWideFailureStopsAGroupShare() async throws {
        try await connect()
        let allhands = (1...12).map { String(format: "member%02d@example.com", $0) }
        try makeUsers(allhands)
        let failing = try Self.logging(Fixtures.mockGam, to: argvLog, in: scratch, prefix: """
            if [ "$3 $4" = "add calendars" ] && [ "$2" = member03@example.com ]; then echo 'ERROR: 403: Request had insufficient authentication scopes' >&2; exit 50; fi

            """)
        let changes = changes(writer: AuthenticatedRunner(runner: GamRunner(binary: failing), vault: vault, runtimeDirectory: base))
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "allhands@example.com", role: "reader")
        let pending = try pending(changes)
        var seen: [CalendarChanges.Progress] = []
        let run = Task { await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedCount: "13")) }
        while true {
            if let progress = changes.progress { seen.append(progress) }
            if case .done = changes.state { break }
            if case .problem = changes.state { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await run.value
        let stopped = try done(changes)
        #expect(stopped.message == "Stopped: \(GamError.Kind.scopeMissing.remediation) The remaining 9 were not attempted. "
            + "Added to 2 of 12 members' calendars before stopping.")
        #expect(stopped.partial && stopped.failedCount == 1 && stopped.failures == ["member03@example.com \u{2014} "
            + GamError.Kind.scopeMissing.remediation])
        #expect(writes().count == 3, "the rule, then two subscribes (the refused one is answered before the mock logs it)")
        #expect(seen.allSatisfy { $0.failed <= 1 }, "\(seen)")
    }

    /// `test_run_subscribe_caps_its_failed_sample` (`test_users_web.py:1216-1232`): every failure is counted, only the first
    /// `failuresKept` are kept to name (invariant 9).
    @Test func aGroupSharesFailuresAreCapped() async throws {
        try await connect()
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "staff@example.com", role: "reader")
        let held = try pending(changes)
        let count = CalendarChanges.failuresKept + 7
        let members = (0..<count).map { "u\($0)@example.com" }
        let pending = CalendarChanges.Pending(preview: held.preview, kind: .shareGroup, title: held.title, confirmLabel: "Share",
                                              calendarID: Self.team, calendarName: "Team Calendar", who: "staff@example.com",
                                              warnings: [], detail: .group(members: members, leftOut: 0))
        let steps: [RunOutcome.Step] = [.succeeded(output: "")]
            + Array(repeating: .failed(message: "Add Failed: Not Found", kind: .notFound), count: count)
        let done = CalendarChanges.groupDone(pending, steps, note: "")
        #expect(done.failedCount == count && done.failures.count == CalendarChanges.failuresKept)
        #expect(done.failures.first == "u0@example.com \u{2014} \(GamError.Kind.notFound.remediation)")
        #expect(done.message == "Shared with staff@example.com. It now appears in 0 of \(count) members' Google Calendars. "
            + "Couldn't add it for \(count) \u{2014} they can add it manually.")
    }

    /// `test_calendars_share_group_fans_out_to_members` and `test_calendars_share_empty_group_says_so` (`:1070-1082`,
    /// `:1135-1140`): `group:` and one address, GAM's `<CalendarACLScope>`, is a group, never looked up as a person; its
    /// members are read and each gets a step. One GAM says isn't a group is refused (GamGUI shared it, subscribing nobody).
    @Test func anExplicitGroupPrefixSharesWithTheGroup() async throws {
        try await connect()
        let changes = changes()
        let ops = "c_ops@group.calendar.google.com"
        await changes.previewShare(calendarID: ops, name: "Operations", target: " Group:staff@example.com ", role: "reader")
        let pending = try pending(changes)
        #expect(pending.kind == .shareGroup && pending.who == "staff@example.com" && pending.members == ["alice@example.com"])
        #expect(bytes(pending.preview.steps.map(\.shownArgv)) == bytes([
            GamCommands.addCalendarACL(calendarID: ops, scope: "group:staff@example.com").argv,
            GamCommands.subscribeCalendar(email: "alice@example.com", calendarID: ops).argv]))
        #expect(bytes(lookups()) == bytes([GamCommands.printGroupMembers(group: "staff@example.com").argv]))
        await changes.confirm(pending, confirmed)
        #expect(try done(changes).message == "Shared with staff@example.com. It now appears in 1 of 1 member's Google Calendars.")
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "group:empty-group@example.com", role: "reader")
        #expect(try self.pending(changes).members.isEmpty)
        changes.dismiss()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "group:dana@example.com", role: "reader")
        #expect(try problem(changes).summary == "dana@example.com isn't a group here.")
        #expect(writes().count == 2)
    }

    /// A preview whose group read ends after the form changed (or a newer preview began) holds nothing the sheet shows:
    /// the confirm can't open on a target the form no longer names.
    @Test func aPreviewOutdatedWhileReadingIsDropped() async throws {
        try await connect()
        let reading = scratch.appending(path: "reading")
        let slow = try Self.logging(Fixtures.mockGam, to: argvLog, in: scratch,
                                    prefix: "[ \"$1 $2\" = \"print group-members\" ] && : > '\(reading.path)' && sleep 0.3\n")
        let changes = changes(lookups: AuthenticatedRunner(runner: GamRunner(binary: slow), vault: vault, runtimeDirectory: base))
        let group = Task { await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "staff@example.com", role: "reader") }
        while !FileManager.default.fileExists(atPath: reading.path) { try await Task.sleep(for: .milliseconds(10)) }
        changes.edited()
        await group.value
        guard case .idle = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        // A newer preview: the slower, older one never replaces it.
        try FileManager.default.removeItem(at: reading)
        let older = Task { await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "staff@example.com", role: "reader") }
        while !FileManager.default.fileExists(atPath: reading.path) { try await Task.sleep(for: .milliseconds(10)) }
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "dana@example.com", role: "reader")
        let newer = try pending(changes)
        await older.value
        #expect(try pending(changes).id == newer.id && newer.who == "dana@example.com")
        #expect(writes().isEmpty)
    }

    /// D6: a lookup that fails for any reason but "Does not exist" says so; GamGUI guessed "person" (calendars.py:79-85).
    @Test func aFailedGroupLookupIsAProblemNotAGuess() async throws {
        try await connect()
        let failing = try Self.logging(Fixtures.mockGam, to: argvLog, in: scratch, prefix:
            "case \"$1 $2\" in \"print group-members\") echo 'ERROR: 403: Request had insufficient authentication scopes' >&2; exit 50 ;; esac\n")
        let changes = changes(lookups: AuthenticatedRunner(runner: GamRunner(binary: failing), vault: vault, runtimeDirectory: base))
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "guest@example.net", role: "reader")
        let problem = try problem(changes)
        #expect(problem.summary.hasPrefix("Couldn't check whether guest@example.net is a group"))
        #expect(problem.detail?.contains("insufficient authentication scopes") == true)
        #expect(writes().isEmpty)
    }

    /// D7/F4: the account GAM acts as for the calendar is refused before any gam: the admin for a secondary
    /// calendar, the person for their own primary.
    @Test func sharingWithTheActingAccountIsRefusedBeforeGam() async throws {
        try await connect(admin: "Admin@Example.com")
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "admin@example.com", role: "reader")
        #expect(try problem(changes).summary == CalendarSharing.ownAccessRefusal)
        await changes.previewShare(calendarID: "alice@example.com", name: "alice@example.com", target: "ALICE@example.com", role: "reader")
        #expect(try problem(changes).summary == CalendarSharing.ownAccessRefusal)
        await changes.previewUnshare(calendarID: "alice@example.com", name: "alice@example.com",
                                     rule: CalendarACL(record: ["id": .string("user:alice@example.com"), "role": .string("reader")]))
        #expect(try problem(changes).summary == CalendarSharing.ownAccessRefusal)
        #expect(writes().isEmpty && lookups().isEmpty)
        // The admin is anyone on alice's primary, which GAM changes as alice.
        await changes.previewShare(calendarID: "alice@example.com", name: "alice@example.com", target: "admin@example.com", role: "reader")
        #expect(try pending(changes).preview.steps.count == 2)
    }

    /// D7: Google's own refusal (the acting account's own access) is said in this screen's words, not offboarding's
    /// ("expected for the departing user's own calendar"). The screen's own check catches every case the mock
    /// models, and the admin is always known while a domain is connected (Off2's review), so the words are held
    /// here: they're what the operator reads if Google acts as an account the check didn't foresee.
    @Test func googlesOwnAccessRefusalIsSaidInThisScreensWords() {
        #expect(CalendarChanges.remediation(.ownACL) == CalendarSharing.ownAccessRefusal)
        #expect(!CalendarSharing.ownAccessRefusal.contains("departing"))
        #expect(CalendarChanges.remediation(.notFound) == GamError.Kind.notFound.remediation)
        #expect(CalendarChanges.remediation(nil).isEmpty)
    }

    /// D5: a target who already has a rule is warned what changes; an owner grant is warned what owners can do.
    @Test func aChangedRuleIsWarnedBeforeItIsOverwritten() async throws {
        try await connect()
        await reads.load(.access(calendar: Self.team))
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "bob@example.com", role: "writer")
        #expect(try pending(changes).warnings
                == ["bob@example.com already has access (See all event details): sharing changes it to Make changes to events."])
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "alice@example.com", role: "reader")
        #expect(try pending(changes).warnings == ["alice@example.com already has access (Owner): sharing changes it to "
            + "See all event details. This takes away their ownership."])
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "dana@example.com", role: "owner")
        #expect(try pending(changes).warnings == ["Owners can change sharing and delete the calendar."])
        #expect(try pending(changes).confirmLabel == "Share")
    }

    // MARK: unsharing

    /// `test_calendars_unshare_by_scope_token` (`:1353-1357`): GAM's delete takes the rule's token, whatever its
    /// kind; one step, GamGUI's message.
    @Test func unshareUsesTheScopeToken() async throws {
        try await connect()
        let changes = changes()
        let tokens = ["bob@example.com", "group:sales@example.com", "domain:example.com"]
        for token in tokens {
            await changes.previewUnshare(calendarID: Self.team, name: "Team Calendar", rule: try await rule(token))
            let pending = try pending(changes)
            #expect(pending.preview.steps.map(\.shownArgv) == [GamCommands.deleteCalendarACL(calendarID: Self.team, scope: token).argv])
            await changes.confirm(pending, confirmed)
        }
        let publicRule = try await rule("default", on: "alice@example.com")
        await changes.previewUnshare(calendarID: "alice@example.com", name: "alice@example.com", rule: publicRule)
        let pending = try pending(changes)
        #expect(pending.title == "Remove Public (anyone)'s access to alice@example.com")
        await changes.confirm(pending, confirmed)
        #expect(try done(changes) == CalendarChanges.Done(message: "Removed access for default.", partial: false))
        #expect(bytes(writes()) == bytes(tokens.map { ["calendars", Self.team, "delete", "calendaracls", $0] }
                                          + [["calendars", "alice@example.com", "delete", "calendaracls", "default"]]))
        #expect(changes.finished == 4)
    }

    /// GamGUI's in-page confirm (`_calendar_detail.html:22`): a removal runs only from its confirm step.
    @Test func unshareNeedsTheConfirmClick() async throws {
        try await connect()
        let changes = changes()
        await changes.previewUnshare(calendarID: Self.team, name: "Team Calendar", rule: try await rule("bob@example.com"))
        let pending = try pending(changes)
        #expect(pending.preview.needsConfirmClick && pending.confirmLabel == "Remove")
        await changes.confirm(pending, OperatorConfirmation())
        #expect(try problem(changes).summary == "This change needs confirmation — preview it, then confirm.")
        #expect(writes().isEmpty)
    }

    /// GamGUI shows no Remove on an owner's rule (`_calendar_detail.html:18`); asked anyway, nothing is previewed.
    @Test func anOwnerRuleCantBeRemoved() async throws {
        try await connect()
        let changes = changes()
        await changes.previewUnshare(calendarID: Self.team, name: "Team Calendar", rule: try await rule("alice@example.com"))
        #expect(try problem(changes).summary == "alice@example.com owns Team Calendar: an owner's access isn't removed here.")
        #expect(writes().isEmpty)
    }

    // MARK: the confirm

    /// GamGUI failure-log 2026-09-23 ("stale Apply"): a confirm runs the preview it was given exactly as held, and
    /// only while it's the one the screen shows. An edited share, a replay or a bare confirm of a removal writes
    /// nothing.
    @Test func confirmRunsWhatThePreviewHeld() async throws {
        try await connect()
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "dana@example.com", role: "reader")
        let first = try pending(changes)
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "dana@example.com", role: "writer")
        let edited = try pending(changes)
        await changes.confirm(first, confirmed)
        #expect(writes().isEmpty, "the role was changed after the first preview")
        await changes.confirm(edited, confirmed)
        #expect(bytes(writes()) == bytes([["calendars", Self.team, "add", "calendaracls", "writer", "dana@example.com"],
                                          ["user", "dana@example.com", "add", "calendars", Self.team, "selected", "true"]]))
        await changes.confirm(edited, confirmed)
        #expect(writes().count == 2, "a replayed confirm")
        await changes.previewUnshare(calendarID: Self.team, name: "Team Calendar", rule: try await rule("bob@example.com"))
        await changes.confirm(try pending(changes), OperatorConfirmation())
        #expect(writes().count == 2, "a bare confirm")
    }

    /// GamGUI failure-log 2026-09-25: a preview held on one tenant never runs on another.
    @Test func aPreviewAfterATenantSwitchIsRefused() async throws {
        try await connect()
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "dana@example.com", role: "reader")
        let held = try pending(changes)
        try await connect("example.org", admin: "admin@example.org")
        await changes.confirm(held, confirmed)
        #expect(try problem(changes).summary.hasPrefix("The active domain changed after the preview"))
        #expect(writes().isEmpty)
    }

    /// After a change, the calendar's access is read again, so the page shows the rule as it now is.
    @Test func afterAChangeTheAccessIsReadAgain() async throws {
        try await connect()
        await reads.load(.access(calendar: Self.team))
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "dana@example.com", role: "reader")
        await changes.confirm(try pending(changes), confirmed)
        #expect(reads.access(.access(calendar: Self.team))?.contains { $0.scopeToken == "dana@example.com" } == true)
        await changes.previewUnshare(calendarID: Self.team, name: "Team Calendar", rule: try await rule("bob@example.com"))
        await changes.confirm(try pending(changes), confirmed)
        #expect(reads.access(.access(calendar: Self.team))?.contains { $0.scopeToken == "bob@example.com" } == false)
        #expect(changes.concerns(Self.team) && !changes.concerns("alice@example.com"))
    }

    /// A count typed that isn't the guard's is said on the sheet and runs nothing: the preview isn't spent (the executor
    /// spends one it refuses), and a second wrong try is said again; typing clears it. Then the right count runs it.
    @Test func aWrongCountKeepsTheGroupSharesPreview() async throws {
        try await connect()
        let allhands = (1...12).map { String(format: "member%02d@example.com", $0) }
        try makeUsers(allhands)
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "allhands@example.com", role: "reader")
        let pending = try pending(changes)
        #expect(pending.preview.decision.requiresTypedCount && pending.preview.decision.affectedCount == 13)
        for typed in ["12", " 13x", "1 3"] {
            await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedCount: typed))
            #expect(changes.typedProblem == "Type 13, the number of changes, to confirm.", "\(typed)")
            #expect(try self.pending(changes).id == pending.id, "the sheet stays")
        }
        #expect(changes.typedRefusals == 3, "each refusal is said again")
        #expect(writes().isEmpty)
        changes.typingChanged()
        #expect(changes.typedProblem == nil)
        await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedCount: " 13 "))
        #expect(try done(changes).message.hasPrefix("Shared with allhands@example.com."), "the same preview, not spent")
        #expect(writes().count == 13)
    }

    // MARK: deleting a calendar

    /// `test_calendars_delete_preview_shows_owner_and_confirm`, `…_requires_exact_case_confirm` and
    /// `…_applies_with_confirm` (`:1005-1024`): acting as the owner the app resolved, after DELETE typed in capitals;
    /// then gone from the person's list the screen read, and its access read dropped.
    @Test func aCalendarIsDeletedActingAsItsActiveOwnerAfterDeleteIsTyped() async throws {
        try await connect()
        await reads.load(.calendars(of: "bob@example.com"))
        let changes = changes()
        await changes.previewDeleteCalendar(calendarID: Self.team, name: "Team Calendar")
        let pending = try pending(changes)
        #expect(pending.kind == .deleteCalendar && pending.isDestructive && pending.confirmLabel == "Delete Calendar")
        #expect(bytes(pending.preview.steps.map(\.shownArgv)) == bytes([["user", "alice@example.com", "remove", "calendars", Self.team]]))
        guard case .deleteCalendar(let owner, let rules) = pending.detail else { throw NotPreviewing(state: "\(pending.detail)") }
        #expect(owner == "alice@example.com" && rules == 6)
        #expect(pending.preview.typedExactWord == "DELETE", "the executor holds the word, not only this screen")
        await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedWord: "delete"))
        #expect(changes.typedProblem == "Type DELETE (in capitals) to confirm." && writes().isEmpty)
        #expect(try self.pending(changes).id == pending.id, "the sheet stays")
        await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedWord: "Delete"))
        #expect(changes.typedRefusals == 2, "a repeated wrong word is said again")
        changes.typingChanged()
        #expect(changes.typedProblem == nil)
        await changes.confirm(pending, OperatorConfirmation(typedWord: "DELETE"))
        #expect(try problem(changes).summary == "This change needs confirmation — preview it, then confirm.")
        #expect(writes().isEmpty)
        await changes.previewDeleteCalendar(calendarID: Self.team, name: "Team Calendar")
        await changes.confirm(try self.pending(changes), OperatorConfirmation(confirmed: true, typedWord: " DELETE "))
        #expect(try done(changes) == CalendarChanges.Done(message: "Calendar deleted: “Team Calendar”.", partial: false,
                                                          deletedCalendar: Self.team))
        #expect(bytes(writes()) == bytes([["user", "alice@example.com", "remove", "calendars", Self.team]]))
        #expect(reads.access(.access(calendar: Self.team)) == nil)
        #expect(reads.calendars(of: "bob@example.com")?.map(\.calendarID) == ["bob@example.com"])
        let audit = AuditLog.records(at: auditURL)
        #expect(audit.contains { $0["extra"]?.object?["owner"]?.string == "alice@example.com" })
    }

    /// `test_calendars_delete_refuses_primary` and `…_resource_and_holiday` (`:1026-1037`): only a secondary calendar,
    /// refused before any gam.
    @Test func onlyASecondaryCalendarCanBeDeleted() async throws {
        try await connect()
        let changes = changes()
        for calendar in ["alice@example.com", "aspen@resource.calendar.google.com", "en.usa#holiday@group.v.calendar.google.com"] {
            await changes.previewDeleteCalendar(calendarID: calendar, name: calendar)
            #expect(try problem(changes).summary == CalendarDeletion.notSecondary, "\(calendar)")
        }
        #expect(calls().allSatisfy { !$0.contains("calendaracls") && !$0.contains("remove") })
    }

    /// `test_calendars_delete_refuses_when_owner_suspended` (`:1039-1043`) and a calendar Google names no owner for. The
    /// owner is the data owner (`print settings`'s `dataOwner`), read now: a suspended one is refused, never a co-owner instead.
    @Test func aCalendarWithoutAnActiveOwnerIsRefused() async throws {
        try await connect()
        let orphan = "c_orphan@group.calendar.google.com"
        try setRules(orphan, [
            #"{"id": "user:c_orphan@group.calendar.google.com", "role": "owner", "scope": {"type": "user", "value": "c_orphan@group.calendar.google.com"}}"#,
            #"{"id": "user:bob@example.com", "role": "owner", "scope": {"type": "user", "value": "bob@example.com"}}"#])
        try setDataOwner(orphan, "bob@example.com")
        let changes = changes()
        await changes.previewDeleteCalendar(calendarID: orphan, name: "Orphan")
        #expect(try problem(changes).summary == "bob@example.com, the calendar's owner, is suspended or no longer exists — transfer "
            + "ownership to an active user, then delete.")
        #expect(calls().contains(GamCommands.printCalendarSettings(calendarID: orphan).argv))
        await changes.previewDeleteCalendar(calendarID: "c_allhands@group.calendar.google.com", name: "All Hands")
        #expect(try problem(changes).summary.hasPrefix("Couldn't find an owner account to act as"))
        #expect(writes().isEmpty)
    }

    /// A deliberate difference from GamGUI's `_owner_candidates`, which acted as the first active `owner` rule: Google gives a
    /// secondary calendar one data owner, and only they can delete it. A co-owner, first in the rules and active, is never
    /// acted as: the delete acts as the data owner, or, while the data owner is suspended, is refused.
    @Test func theDeleteActsAsTheDataOwnerNotACoOwner() async throws {
        try await connect()
        try setRules(Self.team, [
            #"{"id": "user:c_team@group.calendar.google.com", "role": "owner", "scope": {"type": "user", "value": "c_team@group.calendar.google.com"}}"#,
            #"{"id": "user:carol@example.com", "role": "owner", "scope": {"type": "user", "value": "carol@example.com"}}"#,
            #"{"id": "user:alice@example.com", "role": "owner", "scope": {"type": "user", "value": "alice@example.com"}}"#])
        let changes = changes()
        await changes.previewDeleteCalendar(calendarID: Self.team, name: "Team Calendar")
        let pending = try pending(changes)
        #expect(bytes(pending.preview.steps.map(\.shownArgv)) == bytes([["user", "alice@example.com", "remove", "calendars", Self.team]]),
                "the data owner, though carol is first among the owner rules")
        try setDataOwner(Self.team, "bob@example.com")
        await changes.previewDeleteCalendar(calendarID: Self.team, name: "Team Calendar")
        #expect(try problem(changes).summary.hasPrefix("bob@example.com, the calendar's owner, is suspended or no longer exists"))
        #expect(writes().isEmpty)
    }

    /// GamGUI's delete resolves the owner again (`_resolve_delete_owner` in `/delete`): the data owner read again, one changed
    /// since the preview is refused, and nothing is deleted.
    @Test func theRunChecksTheOwnerAgain() async throws {
        try await connect()
        let changes = changes()
        await changes.previewDeleteCalendar(calendarID: Self.team, name: "Team Calendar")
        let held = try pending(changes)
        try setDataOwner(Self.team, "carol@example.com")
        await changes.confirm(held, OperatorConfirmation(confirmed: true, typedWord: "DELETE"))
        #expect(try problem(changes).summary == "alice@example.com is no longer this calendar's owner — preview the delete again.")
        #expect(writes().isEmpty)
    }

    /// The run's owner read failing is said in fixed words, never an error's type name: a calendar gone since the preview,
    /// or GAM refusing the read (its remediation).
    @Test func theRunsOwnerReadFailingIsSaidInWords() async throws {
        try await connect()
        let flag = scratch.appending(path: "fail-settings")
        let changes = changes(lookups: try failing(#"[ "$3 $4" = "print settings" ]"#, once: flag,
                                                   stderr: "Calendar: \(Self.team), Print Failed: Forbidden"))
        await changes.previewDeleteCalendar(calendarID: Self.team, name: "Team Calendar")
        try Data().write(to: flag)
        await changes.confirm(try pending(changes), OperatorConfirmation(confirmed: true, typedWord: "DELETE"))
        #expect(try problem(changes).summary == "What the preview showed couldn't be checked again (Couldn't check who owns the "
            + "calendar before deleting it. \(GamError.Kind.permissionDenied.remediation)) — preview again.")
        try FileManager.default.removeItem(at: flag)
        await changes.previewDeleteCalendar(calendarID: Self.team, name: "Team Calendar")
        let held = try pending(changes)
        let removed = state.appending(path: "calendars_removed")
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        try Data().write(to: removed.appending(path: Self.team))
        await changes.confirm(held, OperatorConfirmation(confirmed: true, typedWord: "DELETE"))
        #expect(try problem(changes).summary == "That calendar no longer exists — nothing was deleted.")
        #expect(writes().isEmpty)
    }

    /// GamGUI's `_resolve_delete_owner` at the delete also wants the owner active (`_active_emails`): one suspended since
    /// the preview is read now (`info user`) and refused, never impersonated.
    @Test func theRunChecksTheOwnerIsStillActive() async throws {
        try await connect()
        let changes = changes()
        await changes.previewDeleteCalendar(calendarID: Self.team, name: "Team Calendar")
        let held = try pending(changes)
        let folder = state.appending(path: "suspended")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "alice@example.com"))
        await changes.confirm(held, OperatorConfirmation(confirmed: true, typedWord: "DELETE"))
        #expect(try problem(changes).summary == "alice@example.com is suspended or no longer exists — preview the delete again.")
        #expect(writes().isEmpty)
        #expect(calls().contains { $0.starts(with: ["info", "user", "alice@example.com"]) })
    }

    /// The word is the executor's to check: a run of the held preview with only a Confirm click deletes nothing.
    @Test func theExecutorRefusesACalendarDeleteWithoutTheWord() async throws {
        try await connect()
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_FIXTURES": Fixtures.mockGamData.path, "GAM_MOCK_STATE": state.path])
        let changes = CalendarChanges(executor: executor, setup: setup, directory: directory, groups: groups, reads: reads, runner: runner)
        changes.environment = ["GAM_MOCK_STATE": state.path]
        await changes.previewDeleteCalendar(calendarID: Self.team, name: "Team Calendar")
        let held = try pending(changes)
        let outcome = await executor.run(held.preview, confirmation: confirmed)
        #expect(outcome.refusal == "Type DELETE (exactly) to run this.")
        #expect(writes().isEmpty)
    }

    // MARK: events

    /// `test_calendars_event_search_requires_filter` and `…_flags_recurring` (`:949-958`): never an unbounded scan; a
    /// title, or days, finds the events; none is "No matching events.", not a failure (GAM's exit 60).
    @Test func anEventSearchNeedsATitleOrDays() async throws {
        try await connect()
        let changes = changes()
        let search = changes.events
        search.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        await search.search(calendarID: Self.team, .init(text: "  ", after: "", before: ""))
        guard case .needsFilter = search.state(for: Self.team) else { throw NotPreviewing(state: "\(search.state)") }
        #expect(eventReads().isEmpty)
        await search.search(calendarID: Self.team, .init(text: "stand"))
        guard case .found(_, let found, let capped) = search.state(for: Self.team) else { throw NotPreviewing(state: "\(search.state)") }
        #expect(found.map(\.summary) == ["Weekly Standup"] && found[0].isRecurring && !capped)
        #expect(bytes(eventReads()) == bytes([GamCommands.printEvents(calendarID: Self.team, query: "stand").argv]))
        await search.search(calendarID: Self.team, .init(text: "", after: "2026-07-01", before: "2026-07-20"))
        guard case .found(_, let days, _) = search.state(for: Self.team) else { throw NotPreviewing(state: "\(search.state)") }
        #expect(days.map(\.eventID) == ["0a1b2c3d4e5f6g7h8i9j", "q3planning0v1u2t3s4r"])
        await search.search(calendarID: Self.team, .init(text: "no such meeting"))
        guard case .found(_, let none, _) = search.state(for: Self.team) else { throw NotPreviewing(state: "\(search.state)") }
        #expect(none.isEmpty)
        guard case .idle = search.state(for: "c_ops@group.calendar.google.com") else { throw NotPreviewing(state: "another calendar") }
    }

    /// `test_calendars_event_delete_preview_warns_on_recurring` and `…_delete_applies` (`:960-978`): the event read again
    /// now, a destructive confirm, then GamGUI's delete with `doit` and no updates sent; it leaves the results.
    @Test func anEventIsReadAgainThenDeletedFromItsConfirm() async throws {
        try await connect()
        let changes = changes()
        let standup = "4j3k2m1n0p9q8r7s6t5u"
        await changes.events.search(calendarID: Self.team, .init(text: "stand"))
        await changes.previewDeleteEvent(calendarID: Self.team, name: "Team Calendar", eventID: standup)
        let pending = try pending(changes)
        #expect(bytes(eventReads().suffix(1)) == bytes([GamCommands.getEvent(calendarID: Self.team, eventID: standup).argv]))
        #expect(pending.kind == .deleteEvent && pending.isDestructive && pending.preview.needsConfirmClick)
        #expect(pending.warnings == ["Recurring event — deleting removes the entire series (all occurrences)."])
        #expect(bytes(pending.preview.steps.map(\.shownArgv)) == bytes([
            ["calendars", Self.team, "delete", "events", "eventid", standup, "doit", "sendupdates", "none"]]))
        await changes.confirm(pending, OperatorConfirmation())
        #expect(writes().isEmpty, "a bare confirm")
        await changes.previewDeleteEvent(calendarID: Self.team, name: "Team Calendar", eventID: standup)
        await changes.confirm(try self.pending(changes), confirmed)
        #expect(try done(changes).message == "Event deleted.")
        #expect(writes().count == 1)
        guard case .found(_, let left, _) = changes.events.state(for: Self.team) else { throw NotPreviewing(state: "search") }
        #expect(left.isEmpty)
        // Gone now: Google's get returns it cancelled, said in GamGUI's words; and an ID it never had (Not Found).
        await changes.previewDeleteEvent(calendarID: Self.team, name: "Team Calendar", eventID: standup)
        #expect(try problem(changes).summary == "That event no longer exists.")
        await changes.previewDeleteEvent(calendarID: Self.team, name: "Team Calendar", eventID: "0000000000")
        #expect(try problem(changes).summary == "That event no longer exists.")
        #expect(writes().count == 1)
    }

    /// A series loses every occurrence (GamGUI's warning); an instance (Google's `recurringEventId` set) is deleted by its
    /// own ID, which cancels that occurrence only: a listed difference from GamGUI, which warned of the series for both.
    @Test func onlyASeriesWarnsThatEveryOccurrenceGoes() {
        func event(_ fields: JSONObject) -> CalendarEvent {
            CalendarEvent(record: (["id": .string("e1"), "summary": .string("Weekly Standup")] as JSONObject).merging(fields))
        }
        let series = event(["recurrence": .array([.string("RRULE:FREQ=WEEKLY;BYDAY=MO")])])
        let instance = event(["recurringEventId": .string("4j3k2m1n0p9q8r7s6t5u")])
        #expect(CalendarChanges.deleteWarnings(series) == ["Recurring event \u{2014} deleting removes the entire series (all occurrences)."])
        #expect(CalendarChanges.deleteWarnings(instance)
            == ["One occurrence of a recurring event \u{2014} deleting removes only this occurrence; the rest of the series stays."])
        #expect(CalendarChanges.deleteWarnings(event([:])).isEmpty)
    }

    /// The run reads the event again first: one deleted after the preview (Google's get returns it `cancelled`) is refused,
    /// not deleted twice.
    @Test func anEventDeletedSinceThePreviewIsRefused() async throws {
        try await connect()
        let changes = changes()
        let allHands = "0a1b2c3d4e5f6g7h8i9j"
        await changes.previewDeleteEvent(calendarID: Self.team, name: "Team Calendar", eventID: allHands)
        let held = try pending(changes)
        #expect(held.warnings.isEmpty)
        let folder = state.appending(path: "events_deleted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("\(allHands)\n".utf8).write(to: folder.appending(path: Self.team))
        await changes.confirm(held, confirmed)
        #expect(try problem(changes).summary == "That event no longer exists.")
        #expect(writes().isEmpty)
    }

    /// The run's re-read failing says so in its own words, not the preview's "so nothing was previewed".
    @Test func theRunsEventReadFailingIsSaidInItsOwnWords() async throws {
        try await connect()
        let allHands = "0a1b2c3d4e5f6g7h8i9j"
        let flag = scratch.appending(path: "fail-event")
        let changes = changes(lookups: try failing(#"[ "$5" = eventid ]"#, once: flag,
                                                   stderr: "Calendar: \(Self.team), Event: \(allHands), Print Failed: Forbidden"))
        await changes.previewDeleteEvent(calendarID: Self.team, name: "Team Calendar", eventID: allHands)
        let held = try pending(changes)
        try Data().write(to: flag)
        await changes.confirm(held, confirmed)
        #expect(try problem(changes).summary == "What the preview showed couldn't be checked again (Couldn't re-read the event "
            + "before deleting it. \(GamError.Kind.permissionDenied.remediation)) — preview again.")
        #expect(writes().isEmpty)
    }

    /// What the sheet said (a series loses every occurrence, an instance one, a single event itself) must still hold at the
    /// run: an event that became a series, or stopped being one, since the preview is refused.
    @Test func anEventThatChangedSinceThePreviewIsRefused() async throws {
        try await connect()
        let allHands = "0a1b2c3d4e5f6g7h8i9j"
        let flag = scratch.appending(path: "now-a-series")
        let line = try String(contentsOf: Fixtures.mockGamData.appending(path: "calendar_events/\(Self.team).json"), encoding: .utf8)
            .split(separator: "\n").map(String.init).first { $0.contains(allHands) }!
        let series = line.replacingOccurrences(of: #", "start""#, with: #", "recurrence": ["RRULE:FREQ=YEARLY"], "start""#)
        let csv = scratch.appending(path: "series.csv")
        try Data(("calendarId,id,JSON\n\(Self.team),\(allHands),\"" + series.replacingOccurrences(of: "\"", with: "\"\"") + "\"\n").utf8)
            .write(to: csv)
        let script = try Self.logging(Fixtures.mockGam, to: argvLog, in: scratch, prefix: """
            if [ -e '\(flag.path)' ] && [ "$5" = eventid ]; then echo 'Getting Events for \(Self.team)' >&2; cat '\(csv.path)'; exit 0; fi

            """)
        let changes = changes(lookups: AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base))
        await changes.previewDeleteEvent(calendarID: Self.team, name: "Team Calendar", eventID: allHands)
        let held = try pending(changes)
        #expect(held.warnings.isEmpty)
        try Data().write(to: flag)
        await changes.confirm(held, confirmed)
        #expect(try problem(changes).summary == CalendarChanges.eventChanged)
        #expect(writes().isEmpty)
    }

    /// The days searched are the operator's: each sent as the instant it begins in their zone, with its offset (GAM reads a
    /// bare day as midnight UTC), and Google keeps an event ending after the first and starting before the second. An
    /// afternoon meeting is found on its own day, in New York and in Auckland, where it is the next day. A listed difference
    /// from GamGUI, which sent the bare day.
    @Test func eventDaysAreTheOperatorsOwn() async throws {
        try await connect()
        let changes = changes()
        let search = changes.events
        search.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        await search.search(calendarID: Self.team, .init(text: "", after: "2026-07-14", before: "2026-07-15"))
        guard case .found(_, let ny, _) = search.state(for: Self.team) else { throw NotPreviewing(state: "\(search.state)") }
        #expect(ny.map(\.eventID) == ["q3planning0v1u2t3s4r"])
        #expect(bytes(eventReads().suffix(1)) == bytes([GamCommands.printEvents(calendarID: Self.team, after: "2026-07-14T00:00:00-04:00",
                                                                              before: "2026-07-15T00:00:00-04:00").argv]))
        search.timeZone = try #require(TimeZone(identifier: "Pacific/Auckland"))
        await search.search(calendarID: Self.team, .init(text: "", after: "2026-07-15", before: "2026-07-16"))
        guard case .found(_, let nz, _) = search.state(for: Self.team) else { throw NotPreviewing(state: "\(search.state)") }
        #expect(nz.map(\.eventID) == ["q3planning0v1u2t3s4r"], "2-3pm in New York is the next morning in Auckland")
        await search.search(calendarID: Self.team, .init(text: "", after: "2026-07-14", before: "2026-07-15"))
        guard case .found(_, let none, _) = search.state(for: Self.team) else { throw NotPreviewing(state: "\(search.state)") }
        #expect(none.isEmpty)
    }

    @Test func aDayIsTheInstantItBegins() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York")), utc = try #require(TimeZone(identifier: "UTC"))
        #expect(CalendarEventSearch.instant("2026-07-14", in: newYork) == "2026-07-14T00:00:00-04:00")
        #expect(CalendarEventSearch.instant("2026-01-14", in: newYork) == "2026-01-14T00:00:00-05:00")
        #expect(CalendarEventSearch.instant("2026-07-14", in: utc) == "2026-07-14T00:00:00+00:00")
        for odd in ["", "2026-02-31", "2026-7-14", "today", "2026-07-14T00:00:00Z"] {
            #expect(CalendarEventSearch.instant(odd, in: newYork) == odd, "\(odd)")
        }
    }
}
