import Foundation
import Security
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// The Calendars screen's and the person page's reads (C1b) against the strict mock with its argv log:
/// GamGUI's builders byte for byte, the tenant rules GroupMembers keeps, the last sixteen reads kept
/// (invariant 9), and output too large to trust refused. Ports GamGUI's `test_calendars_resources_search`,
/// `test_calendars_user_list`, `test_calendar_access_view`, `test_calendar_access_owner_not_removable` and
/// `test_calendars_detail_has_share_form_and_row_remove`'s row count.
@MainActor
@Suite("Calendar reads", .serialized)
struct CalendarReadsTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-calreads-\(UUID().uuidString)")
    let memory = MemoryStore()
    let vault: Vault
    let base: URL
    let argvLog: URL
    static let team = "c_team@group.calendar.google.com"

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        vault = Vault(store: memory)
        base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        argvLog = scratch.appending(path: "argv.log")
    }

    /// The mock, each call's argv logged. Given `slow`, a call whose first two words are that takes two seconds;
    /// like real GAM (one process), it ends on SIGTERM at once.
    private func runner(slow: String? = nil) throws -> AuthenticatedRunner {
        let script = scratch.appending(path: "mock-\(UUID().uuidString).sh")
        let delay = slow.map { "case \"$1 $2\" in \"\($0)\") sleep 2 >/dev/null 2>&1 & wait $! ;; esac\n" } ?? ""
        try Data(("#!/bin/sh\ntrap 'exit 143' TERM\n\(delay)"
                  + "GAM_MOCK_ARGV_LOG='\(argvLog.path)' exec '\(Fixtures.mockGam.path)' \"$@\"\n").utf8)
            .write(to: script)
        chmod(script.path, 0o755)
        return AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base)
    }

    private func app(_ runner: AuthenticatedRunner, keep: Int = CalendarReads.kept)
        -> (setup: SetupModel, directory: DirectoryStore, reads: CalendarReads) {
        let setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        return (setup, DirectoryStore(setup: setup, runner: runner), CalendarReads(setup: setup, runner: runner, keep: keep))
    }

    private func connect(_ domain: String, in setup: SetupModel) async throws {
        let folder = scratch.appending(path: "gamcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "admin@\#(domain)"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
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

    /// The calendar reads the mock ran.
    private func calendarCalls() -> [[String]] {
        calls().filter { $0.contains("calendars") || $0.contains("calendaracls") || $0.contains("resources") }
    }

    private func gamguiArgv(_ builder: String, _ kwargs: [String: String] = [:]) throws -> [String] {
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Fixtures.argvJSON)) as? [String: Any])
        if kwargs.isEmpty {
            let defaults = try #require(document["defaults"] as? [String: [String: Any]])
            return try #require(defaults[builder]?["argv"] as? [String])
        }
        let cases = try #require(document["cases"] as? [[String: Any]])
        let found = cases.first { $0["builder"] as? String == builder && $0["kwargs"] as? [String: String] == kwargs }
        return try #require(found?["argv"] as? [String])
    }

    private func bytes(_ argv: [String]) -> [[UInt8]] { argv.map { Array($0.utf8) } }

    // MARK: rooms

    /// GamGUI reads rooms when its list is asked for: connecting reads none, and they belong to their tenant.
    @Test func roomsLoadLazilyForTheirTenant() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.directory.load()
        #expect(calendarCalls().isEmpty, "connecting read calendars")
        #expect(app.reads.rooms() == nil)
        await app.reads.load(.rooms)
        #expect(calendarCalls().map(bytes) == [bytes(try gamguiArgv("print_resources"))])
        let rooms = try #require(app.reads.rooms())
        #expect(rooms.map(\.email) == ["aspen@resource.calendar.google.com", "birch@resource.calendar.google.com",
                                       "projector@resource.calendar.google.com"])
        #expect(rooms.map(\.label) == ["Aspen", "Birch Huddle, 2nd floor", "Projector"])
        #expect(rooms[1].details.utf8.elementsEqual("Huddle \"Pod\" \\ Small".utf8), "read back as GAM escaped it")
        try await connect("example.org", in: app.setup)
        #expect(app.reads.rooms() == nil && app.reads.rooms(matching: "") == nil, "example.com's rooms, shown as example.org's")
    }

    /// `test_calendars_resources_search`: GamGUI's filter over the rooms read.
    @Test func roomSearchIsGamGUIs() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.reads.load(.rooms)
        #expect(app.reads.rooms(matching: " ASPEN ")?.map(\.label) == ["Aspen"])
        #expect(app.reads.rooms(matching: "huddle")?.map(\.label) == ["Birch Huddle, 2nd floor"])
        #expect(app.reads.rooms(matching: "1003")?.map(\.label) == ["Projector"], "by ID")
        #expect(app.reads.rooms(matching: "equipment")?.isEmpty == true, "a type isn't searched")
        #expect(calendarCalls().count == 1, "searching reads nothing again")
    }

    // MARK: a person's calendars and a calendar's access

    /// `test_calendars_user_list`: a person's list, read as GamGUI reads it, and its rows' words.
    @Test func aPersonsCalendarsAreReadAsThePerson() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.reads.load(.calendars(of: "alice@example.com"))
        #expect(calendarCalls().map(bytes) == [bytes(try gamguiArgv("print_user_calendars", ["email": "alice@example.com"]))])
        let calendars = try #require(app.reads.calendars(of: "alice@example.com"))
        #expect(calendars.map(\.label) == ["alice@example.com", "Team Calendar", "Holidays in United States", "Aspen",
                                           "Rota \"B\" C:\\Shifts, Zo\u{EB}"])
        #expect(calendars.map(\.details) == ["primary · owner", "owner", "reader", "freeBusyReader", "writer"])
        #expect(app.reads.calendars(of: " ALICE@example.com ") != nil, "an address in another case is the same person")
        #expect(app.reads.calendars(of: "carol@example.com") == nil)
    }

    /// The screen reads a calendar's rules by GamGUI's admin form (`calendars.py:311-343`), and shows a Remove
    /// only on rules that aren't an owner's: Team Calendar's four.
    @Test func theScreenReadsAccessByGamGUIsAdminForm() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.reads.load(.access(calendar: Self.team))
        #expect(calendarCalls().map(bytes) == [bytes(try gamguiArgv("print_calendar_acls_cal", ["calendar_id": Self.team]))])
        let rules = try #require(app.reads.access(.access(calendar: Self.team)))
        #expect(rules.map(\.who) == [Self.team, "alice@example.com", "carol@example.com", "bob@example.com",
                                     "sales@example.com", "Everyone at example.com"])
        #expect(rules.map(\.roleLabel) == ["Owner", "Owner", "Make changes to events", "See all event details",
                                           "See all event details", "See free/busy only"])
        #expect(rules.filter { !$0.isOwner }.map(\.scopeToken)
                == ["carol@example.com", "bob@example.com", "group:sales@example.com", "domain:example.com"])
        #expect(app.reads.access(.primaryAccess(of: Self.team)) == nil, "the user form is another read")
    }

    /// `test_calendar_access_view` and `_owner_not_removable`: the person page reads their primary calendar by
    /// GamGUI's user form (`users.py:561-574`); one Remove per shared party, never the owner's.
    @Test func theTabReadsThePrimaryAsThePerson() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.reads.load(.primaryAccess(of: "alice@example.com"))
        #expect(calendarCalls().map(bytes)
                == [bytes(try gamguiArgv("print_calendar_acls", ["email": "alice@example.com", "calendar": "primary"]))])
        let rules = try #require(app.reads.access(.primaryAccess(of: "alice@example.com")))
        #expect(rules.map(\.who) == ["alice@example.com", "assistant@example.com", "Public (anyone)"])
        #expect(rules.map(\.roleLabel) == ["Owner", "See all event details", "See free/busy only"])
        #expect(rules.filter { !$0.isOwner }.count == 2)
    }

    /// GAM's "Getting … for …" line comes first on stderr; the person's Calendar being off is what's said.
    @Test func aPersonWithCalendarOffIsSaidSo() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        let state = scratch.appending(path: "state")
        try FileManager.default.createDirectory(at: state.appending(path: "nocalendar"), withIntermediateDirectories: true)
        try Data().write(to: state.appending(path: "nocalendar/carol@example.com"))
        app.reads.environment = ["GAM_MOCK_STATE": state.path]
        await app.reads.load(.calendars(of: "carol@example.com"))
        let problem = try #require(app.reads.problem(for: .calendars(of: "carol@example.com")))
        #expect(problem.summary == GamError.Kind.serviceNotEnabled.remediation)
        #expect(problem.detail?.contains("Calendar Service/App not enabled") == true)
        #expect(app.reads.calendars(of: "carol@example.com") == nil)
    }

    /// F3/Q4: no rules (exit 60, the header alone) reads as none, "No access rules returned."; any other
    /// failure is a problem with no rules shown.
    @Test func noRulesReadAsNoneAndAnUnknownCalendarAsAProblem() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        let state = scratch.appending(path: "state")
        try FileManager.default.createDirectory(at: state.appending(path: "acls"), withIntermediateDirectories: true)
        try Data().write(to: state.appending(path: "acls/\(Self.team)"))
        app.reads.environment = ["GAM_MOCK_STATE": state.path]
        await app.reads.load(.access(calendar: Self.team))
        #expect(app.reads.access(.access(calendar: Self.team))?.isEmpty == true)
        #expect(app.reads.problem(for: .access(calendar: Self.team)) == nil)
        await app.reads.load(.access(calendar: "nosuch@group.calendar.google.com"))
        let problem = try #require(app.reads.problem(for: .access(calendar: "nosuch@group.calendar.google.com")))
        #expect(problem.summary == GamError.Kind.notFound.remediation)
        #expect(problem.detail?.contains("Calendar: nosuch@group.calendar.google.com, Print Failed: Not Found") == true)
    }

    // MARK: the tenant, the bound, the order

    /// A switch hides what was read, and a read still running when the tenant changes is dropped when it ends.
    @Test func aSwitchHidesAndDropsReads() async throws {
        let app = app(try runner(slow: "calendars \(Self.team)"))
        try await connect("example.com", in: app.setup)
        await app.reads.load(.calendars(of: "alice@example.com"))
        let reads = app.reads
        let running = Task { await reads.load(.access(calendar: Self.team)) }
        while !reads.isReading(.access(calendar: Self.team)) { await Task.yield() }
        try await connect("example.org", in: app.setup)
        #expect(!reads.isReading(.access(calendar: Self.team)), "an old tenant's read shown as this one's")
        #expect(reads.calendars(of: "alice@example.com") == nil, "example.com's calendars, shown as example.org's")
        await running.value
        #expect(reads.access(.access(calendar: Self.team)) == nil && reads.problem(for: .access(calendar: Self.team)) == nil)
    }

    /// Output the runner cut at its cap is refused: a partial list would pass for the whole one.
    @Test func truncatedOutputIsRefused() throws {
        let argv = GamCommands.printCalendarACLs(calendarID: Self.team).argv
        let cut = GamResult(exitCode: 0, stdout: "calendarId,JSON\n", stderr: "", stdoutTruncated: true, stderrTruncated: false)
        #expect(throws: DirectoryStore.Truncated.self) { try CalendarReads.found(from: cut, for: .access(calendar: Self.team), argv: argv) }
        let emptyButCut = GamResult(exitCode: 60, stdout: "calendarId,JSON\n", stderr: "", stdoutTruncated: true, stderrTruncated: false)
        #expect(throws: DirectoryStore.Truncated.self) {
            try CalendarReads.found(from: emptyButCut, for: .access(calendar: Self.team), argv: argv)
        }
        #expect(CalendarReads.problem(for: DirectoryStore.Truncated(), read: .rooms, argv: argv).summary
                == "There are more rooms than one call can return yet (GAM printed more than 8 MiB), so none are shown rather than some.")
        // Exit 60 is "none" only for a calendar's rules; for a list it's a failure.
        let list = GamResult(exitCode: 60, stdout: "primaryEmail,calendarId,JSON\n", stderr: "", stdoutTruncated: false, stderrTruncated: false)
        #expect(throws: GamError.self) { try CalendarReads.found(from: list, for: .calendars(of: "a@example.com"), argv: argv) }
    }

    /// Only the last sixteen reads are kept (invariant 9), the oldest going first.
    @Test func onlyTheLastSixteenAreKept() async throws {
        #expect(CalendarReads.kept == 16)
        let app = app(try runner(), keep: 3)
        try await connect("example.com", in: app.setup)
        await app.reads.load(.rooms)
        await app.reads.load(.calendars(of: "alice@example.com"))
        await app.reads.load(.access(calendar: Self.team))
        #expect(app.reads.rooms() != nil)
        await app.reads.load(.primaryAccess(of: "alice@example.com"))
        #expect(app.reads.rooms() == nil, "past the bound")
        #expect(app.reads.calendars(of: "alice@example.com") != nil && app.reads.access(.access(calendar: Self.team)) != nil)
        #expect(app.reads.access(.primaryAccess(of: "alice@example.com")) != nil)
    }

    /// An older read that finishes after a newer one is in hand doesn't replace it.
    @Test func anOlderReadNeverReplacesANewer() async throws {
        let marker = scratch.appending(path: "first-call")
        let script = scratch.appending(path: "mock-first-slow.sh")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data(("#!/bin/sh\ntrap 'exit 143' TERM\ncase \"$1 $2\" in \"print resources\") "
                  + "if [ ! -e '\(marker.path)' ]; then : > '\(marker.path)'; sleep 2 >/dev/null 2>&1 & wait $!; fi ;; esac\n"
                  + "exec '\(Fixtures.mockGam.path)' \"$@\"\n").utf8).write(to: script)
        chmod(script.path, 0o755)
        let app = app(AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base))
        try await connect("example.com", in: app.setup)
        let reads = app.reads
        let older = Task { await reads.load(.rooms) }
        while !FileManager.default.fileExists(atPath: marker.path) { await Task.yield() }
        await reads.load(.rooms)
        let newer = try #require(reads.revision(of: .rooms))
        await older.value
        #expect(reads.revision(of: .rooms) == newer, "the older read replaced the newer one")
        #expect(reads.rooms() != nil)
    }

    /// A page left before its delay is up reads nothing, and isn't left reading.
    @Test func aDelayedReadLeftEarlyReadsNothing() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        let reads = app.reads
        let read = Task { await reads.load(.access(calendar: Self.team), after: .seconds(30)) }
        while !reads.isReading(.access(calendar: Self.team)) { await Task.yield() }
        read.cancel()
        await read.value
        #expect(!reads.isReading(.access(calendar: Self.team)))
        #expect(calendarCalls().isEmpty)
    }
}
