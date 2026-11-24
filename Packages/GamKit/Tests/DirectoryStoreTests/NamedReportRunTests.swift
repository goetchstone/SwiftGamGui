import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import Stores
import TestSupport
import Testing
import Vault

/// Named reports run on Reports (plan F7a, GamGUI #178's `tests/test_named_report_runs.py`), end to end on the strict mock: each
/// F2 named report is a one-step run of its catalog read built bare, recorded as a `read` of origin `named_report` whose
/// `command` is the report's key; each read's failing, silent and partial exits are unknown, never "none" (invariant 10); a
/// scheduled one is kept and compared like an audit run, without the columns that move on their own; and a schedule for a key
/// nothing here runs any more is never due, and can be cleared.
@MainActor
@Suite("Named reports run on Reports", .serialized)
final class NamedReportRunTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-named-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let runner: AuditRunner
    let schedules: RunSchedules
    let store: AuditScheduleStore
    let auditURL: URL
    let argvLog: URL
    let state: URL
    nonisolated static let now = ISO8601DateFormatter().date(from: "2026-11-19T00:00:00Z")!
    nonisolated static let catalog = try! CommandCatalog(json: Data(contentsOf: Fixtures.catalogJSON))

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let gam = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: gam, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        argvLog = scratch.appending(path: "argv.log")
        state = scratch.appending(path: "mock-state")
        store = AuditScheduleStore(root: scratch.appending(path: "data/schedules"))
        runner = AuditRunner(setup: setup, runner: gam, audit: ReadAudit(log: AuditLog(url: auditURL)), now: { NamedReportRunTests.now })
        runner.environment = ["GAM_MOCK_STATE": state.path, "GAM_MOCK_ARGV_LOG": argvLog.path]
        runner.schedules = store
        runner.clock = .init(timeZone: .gmt)
        schedules = RunSchedules(setup: setup, store: store, clock: .init(timeZone: .gmt), now: { NamedReportRunTests.now })
        schedules.catalog = { .success(NamedReportRunTests.catalog) }
        runner.ended = { [schedules] run in await schedules.runEnded(run) }
        schedules.keepChanged = { [runner] run in runner.keepChanged(run) }
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect() async throws {
        let folder = scratch.appending(path: "config")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: "admin@example.com").write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
        await schedules.refresh()
    }

    private func mark(_ name: String) throws {
        let url = state.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func unmark(_ name: String) throws { try FileManager.default.removeItem(at: state.appending(path: name)) }

    private var records: [JSONObject] { AuditLog.records(at: auditURL).reversed().filter { $0["action"] == .string("read") } }

    /// How much the mock has logged: it grows with every call.
    private func logged() -> Int { (try? Data(contentsOf: argvLog))?.count ?? 0 }

    private func named(_ key: String) throws -> AuditRuns.Run { try #require(schedules.run(key), "\(key) runs here") }

    private func run(_ key: String) async throws -> AuditRuns.Outcome {
        let run = try named(key)
        #expect(runner.start(run) == nil)
        await runner.finish(run)
        guard case .finished(let outcome)? = runner.state(of: run) else { throw NotFinished() }
        return outcome
    }

    struct NotFinished: Error {}

    /// Every named report runs here once the catalog is read, as its bare catalog read, reads once, and leaves one read record of
    /// origin `named_report`, its command the report's key, never the output.
    @Test(arguments: NamedReport.all.map(\.key))
    func eachRunsItsBareReadOnceAndLeavesOneNamedReportRecord(_ key: String) async throws {
        try await connect()
        #expect(schedules.namedRuns?.map(\.key) == NamedReport.all.map(\.key))
        let before = records.count
        let outcome = try await run(key)
        let read = try #require(AuditRuns.read(outcome.run.steps[0]))
        #expect(records.count == before + 1)
        let record = try #require(records.last)
        #expect(record["ok"] == .bool(true) && record["argv"] == .array(read.argv.map(JSONValue.string)) && record["target"] == .string(""))
        #expect(record["extra"]?["origin"] == .string("named_report") && record["extra"]?["command"] == .string(key))
        #expect(record["extra"]?["domain"] == .string("example.com") && (record["extra"]?["rows"]?.int ?? 0) > 0)
        let table = try #require(outcome.findings.first)
        #expect(outcome.findings.count == 1 && outcome.answered && table.known && table.rows.count == record["extra"]?["rows"]?.int)
        #expect(table.columns.contains(outcome.run.steps[0].keyColumn), "\(table.columns)")
        #expect(AuditRuns.exportRows(table)?.first == table.columns, "the table's CSV is the whole read")
    }

    /// A read that failed, or wrote nothing where something must be, is unknown, never "none": the table has no rows and says
    /// why; a table that came back but can't be an answer is recorded as it was (rows 0) while the step is unknown.
    @Test(arguments: [
        ("licenses", "nolicensing", "", false),
        ("licenses", "licenses_silent", "GAM listed no license seat at all", true),
        ("shared_drives", "drive_token_silent", "didn't say there were none", false),
        ("shared_drive_acls", "drive_token_silent", "didn't say there were none", false),
        ("shared_drive_acls", "nodrives", "says that too when Google refused every drive", true),
        ("shared_drive_organizers", "drive_token_silent", "didn't say there were none", false),
        ("shared_drive_organizers", "nodrives", "says that too when Google refused every drive", true),
        ("org_units", "orgs_failed", "", false),
        ("mobile_devices", "denied/mobile", "", false),
        ("alerts", "alerts_token_silent", "GAM ended without writing the table", false),
        ("alerts", "denied/alerts", "", false),
        ("data_transfers", "denied/datatransfers", "", false),
        ("data_transfers", "denied/transferapps", "", false),
    ])
    func aFailedOrSilentReadIsUnknownNeverNone(_ key: String, _ marker: String, _ words: String, _ recordedOK: Bool) async throws {
        try await connect()
        try mark(marker)
        let outcome = try await run(key)
        let table = try #require(outcome.findings.first)
        #expect(!outcome.answered && !table.known && table.rows.isEmpty, "\(key) \(marker)")
        #expect(words.isEmpty || outcome.reads[0].why.contains(words), "\(key) \(marker): \(outcome.reads[0].why)")
        let record = try #require(records.last)
        #expect(record["extra"]?["origin"] == .string("named_report") && record["ok"] == .bool(recordedOK), "\(key) \(marker)")
        #expect(record["extra"]?["rows"]?.int == (recordedOK ? 0 : nil), "\(key) \(marker)")
    }

    /// None is an answer where GAM says none its own way.
    @Test(arguments: [("shared_drives", "nodrives"), ("org_units", "no_org_units"), ("mobile_devices", "no_mobile"),
                      ("alerts", "no_alerts"), ("data_transfers", "no_transfers")])
    func noneIsAnAnswerWhereGAMSaysNoneItsOwnWay(_ key: String, _ marker: String) async throws {
        try await connect()
        try mark(marker)
        let outcome = try await run(key)
        #expect(outcome.answered && outcome.findings.first?.known == true && outcome.findings.first?.rows.isEmpty == true, "\(key)")
        #expect(records.last?["extra"]?["rows"]?.int == 0)
    }

    /// A group whose members Google refused is named, and the table is partial: never compared, and its CSV says so.
    @Test func aGroupWhoseMembersWereRefusedIsNamedAndTheTableIsPartial() async throws {
        try await connect()
        try mark("members_gone/it@example.com")
        await schedules.save(try named("group_members"), cadence: .weekly, keep: "")
        let outcome = try await run("group_members")
        let table = try #require(outcome.findings.first)
        #expect(outcome.reads[0].state == .partial && outcome.reads[0].unread == ["it@example.com"])
        #expect(table.known && table.partial && table.note.contains("it@example.com"))
        #expect(!table.rows.contains { $0.first == "it@example.com" } && table.rows.contains { $0.first == "sales@example.com" })
        #expect(records.last?["extra"]?["partial"] == .bool(true))
        #expect(outcome.changes[AuditRuns.namedTable]?.why == AuditSchedules.partUnknownNow)
        #expect(AuditRuns.exportRows(table)?.first?.first?.hasPrefix("Part of this table is unknown.") == true)
    }

    /// A scheduled named report is due, then kept and counted; an alert only edited is no change (its times are left out, and
    /// said), one closed is.
    @Test func aScheduledNamedReportIsKeptAndComparedWithoutTheColumnsThatMove() async throws {
        try await connect()
        let alerts = try named("alerts")
        let before = logged()
        await schedules.save(alerts, cadence: .weekly, keep: "3")
        #expect(schedules.scheduled().map(\.run.key) == ["alerts"] && schedules.due(alerts)?.due == true)
        #expect(logged() == before, "a schedule runs nothing")
        let first = try await run("alerts")
        #expect(first.keptNote == "Kept on this Mac, as one of the last 3 runs it keeps." && schedules.due(alerts)?.due == false)
        try mark("alerts_edited")
        let edited = try #require(try await run("alerts").changes[AuditRuns.namedTable])
        #expect(edited.compared && edited.new.isEmpty && edited.gone.isEmpty)
        #expect(edited.leftOut == ["metadata.updateTime", "updateTime"] && !edited.columns.contains("updateTime"))
        try unmark("alerts_edited")
        try mark("alerts_closed")
        let closed = try #require(try await run("alerts").changes[AuditRuns.namedTable])
        #expect(closed.new.count == 1 && closed.gone.count == 1)
        #expect(schedules.kept["alerts"]?.runs.count == 3)
    }

    /// A schedule, or runs kept, under a key nothing here runs any more is never due and is listed apart; it can be unscheduled
    /// (its kept runs deleted) or its kept runs deleted, and never given a cadence through a run here.
    @Test func aScheduleThatCantRunAnyMoreIsNeverDueAndCanBeCleared() async throws {
        try await connect()
        let domain = try #require(setup.active)
        try store.setSchedule(domain, run: "old_report", cadence: .weekly, keep: 2, now: Self.now.timeIntervalSince1970)
        let table = AuditSchedules.Table(key: "table", title: "Old", columns: ["a"], rows: [["1"]], known: true, partial: false)
        _ = store.afterRun(domain, run: "old_report", tables: [table], days: 0, answered: true, when: Self.now.timeIntervalSince1970,
                           clock: .init(timeZone: .gmt))
        try store.setSchedule(domain, run: "gone_report", cadence: .daily, keep: 2, now: Self.now.timeIntervalSince1970)
        _ = store.afterRun(domain, run: "gone_report", tables: [table], days: 0, answered: true, when: Self.now.timeIntervalSince1970,
                           clock: .init(timeZone: .gmt))
        try store.setSchedule(domain, run: "gone_report", cadence: nil, keep: 2, now: Self.now.timeIntervalSince1970)
        _ = store.afterRun(domain, run: "gone_report", tables: [table], days: 0, answered: true, when: Self.now.timeIntervalSince1970,
                           clock: .init(timeZone: .gmt))
        await schedules.refresh()
        #expect(schedules.scheduled().isEmpty, "never due")
        #expect(schedules.stranded.map(\.key) == ["old_report"], "unscheduled runs keep nothing, so none of gone_report is left")
        #expect(schedules.stranded.first?.schedule?.cadence == .weekly && schedules.stranded.first?.kept == 1)
        await schedules.clear("license_usage", deleteOnly: false)
        #expect(try store.schedules(domain).keys.sorted() == ["old_report"], "a key a run here has is never cleared this way")
        await schedules.clear("old_report", deleteOnly: false)
        #expect(schedules.notices["old_report"]?.text == "Not scheduled. 1 kept run was deleted from this Mac.")
        #expect(try store.schedules(domain).isEmpty && schedules.stranded.isEmpty)

        // Kept runs alone: listed, and deleted.
        try store.setSchedule(domain, run: "kept_only", cadence: .weekly, keep: 2, now: Self.now.timeIntervalSince1970)
        _ = store.afterRun(domain, run: "kept_only", tables: [table], days: 0, answered: true, when: Self.now.timeIntervalSince1970,
                           clock: .init(timeZone: .gmt))
        var every = try #require(JSONValue.parse(String(contentsOf: store.root.appending(path: AuditScheduleStore.fileName), encoding: .utf8))?.object)
        every["domains"] = .object([:])
        try Data((JSONValue.dumps(.object(every)) + "\n").utf8).write(to: store.root.appending(path: AuditScheduleStore.fileName))
        await schedules.refresh()
        #expect(schedules.stranded.map(\.key) == ["kept_only"] && schedules.stranded.first?.schedule == nil)
        await schedules.clear("kept_only", deleteOnly: true)
        #expect(schedules.notices["kept_only"]?.text == "Deleted 1 kept run from this Mac." && schedules.stranded.isEmpty)
    }

    /// The catalog unread: no named report runs here, nothing is called stranded, and a named schedule says why it's unknown.
    @Test func aCatalogThatCantBeReadLeavesNamedSchedulesUnknown() async throws {
        schedules.catalog = { .failure(.init("It's missing.")) }
        try await connect()
        try store.setSchedule(try #require(setup.active), run: "alerts", cadence: .weekly, keep: 2, now: Self.now.timeIntervalSince1970)
        await schedules.refresh()
        #expect(schedules.namedRuns == nil && schedules.stranded.isEmpty && schedules.scheduled().isEmpty)
        #expect(schedules.namedUnknown?.hasPrefix("GAM's command catalog couldn't be read") == true)
    }
}
