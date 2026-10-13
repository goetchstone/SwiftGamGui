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
    private func changes(lookups: AuthenticatedRunner? = nil) -> CalendarChanges {
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
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
        }
    }

    private func lookups() -> [[String]] { calls().filter { $0.starts(with: ["print", "group-members"]) } }

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
        for target in ["dana@example.com,erin@example.com", "file", "domain", "default", "group:sales@example.com", "dana"] {
            await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: target, role: "reader")
            #expect(try problem(changes).summary == CalendarSharing.shareTargetProblem(target), "\(target)")
        }
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

    /// D8: sharing with a group fans out to its members, one change each: that waits for background jobs (C4).
    @Test func aGroupIsRefusedUntilJobs() async throws {
        try await connect()
        let changes = changes()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "sales@example.com", role: "reader")
        let refusal = "“sales@example.com” is a group: sharing with a group adds it for each member, one change each. "
            + "That comes with background jobs; use GamGUI's Calendars for now."
        #expect(try problem(changes).summary == refusal)
        #expect(lookups().count == 1, "looked up, as GamGUI does")
        // Known from the group list, it isn't looked up again; an empty group is a group too.
        await groups.load()
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "STAFF@example.com", role: "reader")
        #expect(try problem(changes).summary.hasPrefix("“STAFF@example.com” is a group"))
        #expect(lookups().count == 1)
        await changes.previewShare(calendarID: Self.team, name: "Team Calendar", target: "empty-group@example.com", role: "reader")
        #expect(try problem(changes).summary.hasPrefix("“empty-group@example.com” is a group"))
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
}
