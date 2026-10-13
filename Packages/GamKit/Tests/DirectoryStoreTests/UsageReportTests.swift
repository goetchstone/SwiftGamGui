import Foundation
import Security
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// The usage report (GamGUI's `/reports/usage`): its parsing held to `Tests/Fixtures/usage_report.json`
/// (GamGUI's `_csv_from`, `parse_usage` and `usage_report`'s walk back), and its store against the strict mock:
/// GamGUI's argv byte for byte, the tenant rules the directory keeps, a refusal in words, output too large refused.
@MainActor
@Suite("Usage report", .serialized)
struct UsageReportTests {
    let fixture = JSONValue.parse(try! String(contentsOf: Fixtures.directory.appending(path: "usage_report.json"), encoding: .utf8))!
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-usage-\(UUID().uuidString)")
    let memory = MemoryStore()
    let vault: Vault
    let base: URL
    let argvLog: URL
    /// 2026-10-08 23:59 UTC: the report asks for 2026-10-06 first.
    let today = Date(timeIntervalSince1970: 1_791_503_940)

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        vault = Vault(store: memory)
        base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        argvLog = scratch.appending(path: "argv.log")
    }

    // MARK: parity

    @Test func theConstantsAreGamGUIs() {
        #expect(UsageReport.parameters == fixture["constants"]!["USAGE_PARAMS"]!.array!.map { $0.string! })
        #expect(UsageReport.lookback == fixture["constants"]!["max_lookback"]!.int)
        #expect(UsageReport.shown == 25)
    }

    @Test func progressBeforeTheCSVIsDroppedAsGamGUIDropsIt() {
        for pair in fixture["csv_from"]!.array! {
            let input = pair.array![0].string!, expected = pair.array![1].string!
            #expect(Array(UsageReport.csv(from: input).unicodeScalars) == Array(expected.unicodeScalars),
                    "\(input.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    @Test func rowsAreParsedAndOrderedAsGamGUIParsesThem() {
        for item in fixture["parse_usage"]!.array! {
            let records = item["rows"]!.array!.map { $0.object! }
            let rows = UsageReport.rows(records)
            let expected = item["usage"]!.array!
            #expect(rows.count == expected.count)
            for (row, want) in zip(rows, expected) {
                let label = want["email"]!.string!
                #expect(Array(row.email.utf8) == Array(want["email"]!.string!.utf8), "\(label)")
                #expect(row.quotaMB == want["quota_mb"]!.int && row.received == want["received"]!.int, "\(label)")
                #expect(row.sent == want["sent"]!.int && row.driveCreated == want["drive_created"]!.int, "\(label)")
                #expect(row.storageGB == want["storage_gb"]!.double, "\(label)")
                #expect(row.storage == want["storage"]!.string! + " GB", "\(label): the template's %.1f")
            }
        }
    }

    /// `usage_report`'s dates: today in UTC, less two days, then one more each time, six in all.
    @Test func theWalkBackAsksForGamGUIsDates() throws {
        for walk in fixture["walks"]!.array! where walk["answers"]!.string! == "empty" {
            let today = try #require(ISO8601DateFormatter().date(from: walk["today"]!.string!))
            let argv = UsageReport.dates(today: today).map {
                GamCommands.reportUsers(date: $0, parameters: UsageReport.parameters).argv
            }
            #expect(argv == walk["argv"]!.array!.map { $0.array!.map { $0.string! } })
        }
    }

    // MARK: the store against the mock

    /// The mock, each call's argv logged. `empty`: the dates whose report has no rows (GAM's header alone).
    /// `state`: the mock's state folder.
    private func runner(empty: [String] = [], state: URL? = nil, slow: Bool = false) throws -> AuthenticatedRunner {
        let script = scratch.appending(path: "mock-\(UUID().uuidString).sh")
        var body = "#!/bin/sh\ntrap 'exit 143' TERM\n"
        if slow { body += "if [ \"$1 $2\" = 'report users' ]; then sleep 2 >/dev/null 2>&1 & wait $!; fi\n" }
        for date in empty {
            body += "if [ \"$4\" = '\(date)' ]; then printf '%s\\0' \"$#\" \"$@\" >> '\(argvLog.path)'; echo 'email,date'; exit 0; fi\n"
        }
        if let state { body += "export GAM_MOCK_STATE='\(state.path)'\n" }
        body += "GAM_MOCK_ARGV_LOG='\(argvLog.path)' exec '\(Fixtures.mockGam.path)' \"$@\"\n"
        try Data(body.utf8).write(to: script)
        chmod(script.path, 0o755)
        return AuthenticatedRunner(runner: GamRunner(binary: script), vault: vault, runtimeDirectory: base)
    }

    private func app(_ runner: AuthenticatedRunner) -> (setup: SetupModel, usage: UsageStore) {
        let setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        let today = today
        return (setup, UsageStore(setup: setup, runner: runner, now: { today }))
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

    private func reports() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.first == "report" }
    }

    private func walk(_ answers: String) -> JSONValue {
        fixture["walks"]!.array!.first { $0["answers"]!.string! == answers && $0["today"]!.string!.hasPrefix("2026-10-08") }!
    }

    @Test func aLoadRunsGamGUIsReadAndShowsTheTopByStorage() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.usage.load()
        #expect(app.usage.problem == nil, "\(String(describing: app.usage.problem))")
        let expected = walk("third")["argv"]!.array!.prefix(1).map { $0.array!.map { Array($0.string!.utf8) } }
        #expect(reports().map { $0.map { Array($0.utf8) } } == Array(expected))
        let report = try #require(app.usage.report)
        #expect(report.rows.map(\.email) == ["bob@example.com", "alice@example.com", "carol@example.com"])
        #expect(report.rows.map(\.storage) == ["1024.0 GB", "594.6 GB", "2.0 GB"])
        #expect(report.requested == "2026-10-06")
        #expect(report.date == "2026-06-16", "the date GAM's rows are for: GAM walks back to data on its own")
        #expect(report.loadedAt == today)
    }

    /// GamGUI's walk back: a date whose report has no rows asks for the day before, at most six days.
    @Test func noRowsAsksForTheDayBefore() async throws {
        let app = app(try runner(empty: ["2026-10-06", "2026-10-05"]))
        try await connect("example.com", in: app.setup)
        await app.usage.load()
        let third = walk("third")
        #expect(reports() == third["argv"]!.array!.map { $0.array!.map { $0.string! } })
        #expect(app.usage.report?.requested == third["result"]!["date"]!.string)
        #expect(app.usage.report?.rows.map(\.email) == ["bob@example.com", "alice@example.com", "carol@example.com"])
    }

    @Test func sixDaysWithoutRowsIsNoReportYet() async throws {
        let empty = walk("empty")
        let dates = empty["argv"]!.array!.map { $0.array![3].string! }
        let app = app(try runner(empty: dates))
        try await connect("example.com", in: app.setup)
        await app.usage.load()
        #expect(reports() == empty["argv"]!.array!.map { $0.array!.map { $0.string! } })
        let report = try #require(app.usage.report)
        #expect(report.rows.isEmpty && report.date == "" && report.requested == "")
        #expect(app.usage.problem == nil, "no data yet isn't a failure (GamGUI: Google's reports lag a few days)")
    }

    /// The mock's `noreports` marker: Google refuses the report. The screen says why in words, GAM's line beside it,
    /// and asks for no earlier day (GamGUI's walk stops at a failure).
    @Test func aRefusedReportSaysWhy() async throws {
        let state = scratch.appending(path: "state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data().write(to: state.appending(path: "noreports"))
        let app = app(try runner(state: state))
        try await connect("example.com", in: app.setup)
        await app.usage.load()
        #expect(reports().count == 1, "the first answer was the refusal")
        let problem = try #require(app.usage.problem)
        #expect(problem.summary == GamError.Kind.permissionDenied.remediation)
        #expect(problem.detail?.contains("Access Forbidden") == true)
        #expect(problem.detail?.contains("Getting Reports") == false, "GAM's progress isn't the error")
        #expect(app.usage.report == nil)
    }

    @Test func anotherTenantNeverSeesTheReport() async throws {
        let app = app(try runner())
        try await connect("example.com", in: app.setup)
        await app.usage.load()
        #expect(app.usage.report != nil)
        try await connect("example.org", in: app.setup)
        #expect(app.usage.report == nil, "example.com's usage, shown as example.org's")
    }

    @Test func aTenantSwitchStopsTheOldLoad() async throws {
        let app = app(try runner(slow: true))
        try await connect("example.com", in: app.setup)
        let clock = ContinuousClock(), started = clock.now
        let usage = app.usage
        let old = Task { await usage.load() }
        var turns = 0
        while !usage.isLoading, turns < 100_000 {
            await Task.yield()
            turns += 1
        }
        try #require(usage.isLoading, "the load never started")
        try await connect("example.org", in: app.setup)
        #expect(!usage.isLoading)
        await old.value
        #expect(clock.now - started < .seconds(1.5), "the old load's gam was stopped, not waited for")
        #expect(usage.report == nil && usage.problem == nil)
    }

    @Test func nothingLoadsUntilADomainIsConnected() async throws {
        let app = app(try runner())
        await app.usage.load()
        #expect(app.usage.report == nil)
        #expect(app.usage.problem?.summary == "Connect a domain on Setup first.")
        #expect(reports().isEmpty)
    }

    /// Output cut at the runner's cap is refused: the top 25 of a partial list isn't the tenant's top 25.
    @Test func aCutReportIsRefused() throws {
        let argv = GamCommands.reportUsers(date: "2026-10-06", parameters: UsageReport.parameters).argv
        let cut = GamResult(exitCode: 0, stdout: "email,date\na@example.com,2026-10-04\n", stderr: "",
                            stdoutTruncated: true, stderrTruncated: false)
        #expect(throws: DirectoryStore.Truncated.self) { try UsageStore.records(from: cut, argv: argv) }
        #expect(UsageStore.problem(for: DirectoryStore.Truncated(), argv: argv).summary
                == "The usage report is larger than one call can return yet (GAM printed more than 8 MiB), so none of it is shown rather than part of it.")
    }
}
