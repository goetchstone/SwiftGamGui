import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import Stores
import TestSupport
import Testing
import Vault

/// Scheduled audit runs end to end against the strict mock (plan F7a, GamGUI's `tests/test_schedules.py`, its web half): a
/// schedule says a run is due and runs nothing; the operator's run is recorded as ever, kept and counted; the next run says what
/// changed; a run that failed or stopped short is never kept and stays due; a schedule's keep belongs to one domain; and
/// Setup's Remove deletes a domain's.
@MainActor
@Suite("Scheduled audit runs", .serialized)
final class ScheduledRunTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-scheduled-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let runner: AuditRunner
    let schedules: RunSchedules
    let store: AuditScheduleStore
    let auditURL: URL
    let argvLog: URL
    let state: URL
    nonisolated static let now = ISO8601DateFormatter().date(from: "2026-11-19T00:00:00Z")!

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let gam = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: gam, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        argvLog = scratch.appending(path: "argv.log")
        state = scratch.appending(path: "mock-state")
        store = AuditScheduleStore(root: scratch.appending(path: "data/schedules"))
        runner = AuditRunner(setup: setup, runner: gam, audit: ReadAudit(log: AuditLog(url: auditURL)), now: { ScheduledRunTests.now })
        runner.environment = ["GAM_MOCK_STATE": state.path, "GAM_MOCK_ARGV_LOG": argvLog.path]
        runner.schedules = store
        runner.clock = .init(timeZone: .gmt)
        schedules = RunSchedules(setup: setup, store: store, clock: .init(timeZone: .gmt), now: { ScheduledRunTests.now })
        // As the app wires them.
        runner.ended = { [schedules] run in await schedules.runEnded(run) }
        schedules.keepChanged = { [runner] run in runner.keepChanged(run) }
        setup.removing = { [schedules] domain in await schedules.forget(domain) }
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect(_ domain: String = "example.com") async throws {
        let folder = scratch.appending(path: "config-\(domain)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: "admin@\(domain)").write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
        await schedules.refresh()
    }

    private func mark(_ name: String) throws {
        let url = state.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private var records: [JSONObject] { AuditLog.records(at: auditURL).reversed().filter { $0["action"] == .string("read") } }

    private func calls() -> Int {
        guard let data = try? Data(contentsOf: argvLog) else { return 0 }
        return data.split(separator: 0, omittingEmptySubsequences: false).count
    }

    private func run(_ run: AuditRuns.Run = AuditRuns.licenseUsage, days: Int = 90) async throws -> AuditRuns.Outcome {
        #expect(runner.start(run, days: days) == nil)
        await runner.finish(run)
        guard case .finished(let outcome)? = runner.state(of: run) else { throw NotFinished() }
        return outcome
    }

    struct NotFinished: Error {}

    /// A schedule says the run is due, on Home's list and its pane, and runs nothing: no GAM, no read record.
    @Test func aScheduledRunSaysItsDueAndNothingRuns() async throws {
        try await connect()
        let before = calls(), recorded = records.count
        await schedules.save(AuditRuns.licenseUsage, cadence: .weekly, keep: "")
        #expect(schedules.notices["license_usage"] == .init(text: "Saved: weekly, keeping the last 5 runs.", problem: false))
        let due = try #require(schedules.due(AuditRuns.licenseUsage))
        #expect(due.due && due.line == "License usage is due. Weekly; no run of it has read every step since it was scheduled.")
        #expect(schedules.scheduled().map(\.run) == [AuditRuns.licenseUsage])
        #expect(calls() == before && records.count == recorded && runner.state(of: AuditRuns.licenseUsage) == nil)
    }

    /// The operator's run is recorded as ever (origin `audit_run`), kept and counted: no longer due; the next says no change
    /// since the first, and the kept runs list both.
    @Test func runningItKeepsItCountsItAndRecordsItsReadsAsEver() async throws {
        try await connect()
        await schedules.save(AuditRuns.licenseUsage, cadence: .weekly, keep: "3")
        let first = try await run()
        #expect(first.keptNote == "Kept on this Mac, as one of the last 3 runs it keeps." && !first.keptProblem)
        #expect(first.changes["per_sku"]?.why == AuditSchedules.nothingBefore)
        #expect(records.suffix(2).allSatisfy { $0["extra"]?["origin"] == .string("audit_run") })
        #expect(schedules.due(AuditRuns.licenseUsage) == .init(due: false, headline: "Weekly, next due Thu 26 Nov 2026"))
        let second = try await run()
        let change = try #require(second.changes["per_sku"])
        #expect(change.compared && change.new.isEmpty && change.gone.isEmpty && change.since == Self.now.timeIntervalSince1970)
        #expect(schedules.kept["license_usage"]?.runs.count == 2)
    }

    /// A run with a step that failed is never kept, compares nothing, and stays due; so does one stopped short.
    @Test func aRunWithAStepThatFailedOrStoppedIsNotKeptAndStaysDue() async throws {
        try await connect()
        await schedules.save(AuditRuns.licenseUsage, cadence: .weekly, keep: "")
        try mark("licenses_silent")
        let failed = try await run()
        #expect(failed.keptProblem && failed.keptNote == "Not kept, and it doesn't count as its scheduled run: a step has no answer.")
        #expect(failed.changes.values.allSatisfy { $0.why == AuditSchedules.notAnswered })
        try FileManager.default.removeItem(at: state.appending(path: "licenses_silent"))
        runner.afterEachStep = { [runner] _ in runner.stop(AuditRuns.licenseUsage) }
        let stopped = try await run()
        runner.afterEachStep = nil
        #expect(!stopped.answered && stopped.keptProblem)
        #expect(try schedules.due(AuditRuns.licenseUsage)?.due == true && store.runs(Domain("example.com")!, run: "license_usage").isEmpty)
    }

    /// A run that isn't scheduled writes nothing to disk.
    @Test func anUnscheduledRunWritesNothingToDisk() async throws {
        try await connect()
        let outcome = try await run()
        #expect(outcome.keptNote.isEmpty && outcome.changes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.root.path))
    }

    /// Lowering the count prunes, unscheduling deletes what it kept, Delete keeps the schedule; each says so, and what the pane
    /// said of the run's keep goes.
    @Test func lowerUnscheduleAndDeleteSayWhatTheyDid() async throws {
        try await connect()
        await schedules.save(AuditRuns.licenseUsage, cadence: .monthly, keep: "5")
        for _ in 0..<3 { _ = try await run() }
        await schedules.save(AuditRuns.licenseUsage, cadence: .monthly, keep: "1")
        #expect(schedules.notices["license_usage"]?.text == "Saved: monthly, keeping the last 1 run. 2 kept runs were deleted from this Mac.")
        guard case .finished(let outcome)? = runner.state(of: AuditRuns.licenseUsage) else { throw NotFinished() }
        #expect(outcome.keptNote.isEmpty, "the keep it spoke of has changed")
        await schedules.deleteKept(AuditRuns.licenseUsage)
        #expect(schedules.notices["license_usage"]?.text == "Deleted 1 kept run from this Mac." && schedules.schedule(of: AuditRuns.licenseUsage) != nil)
        await schedules.deleteKept(AuditRuns.licenseUsage)
        #expect(schedules.notices["license_usage"]?.text == "Nothing was kept.")
        _ = try await run()
        await schedules.save(AuditRuns.licenseUsage, cadence: nil, keep: "")
        #expect(schedules.notices["license_usage"]?.text == "Not scheduled. 1 kept run was deleted from this Mac.")
        #expect(schedules.schedule(of: AuditRuns.licenseUsage) == nil && schedules.kept["license_usage"]?.runs.isEmpty == true)
    }

    /// A count the form can't mean is refused and nothing saved; blank is the default.
    @Test func aCountTheFormCantMeanIsRefusedAndNothingSaved() async throws {
        try await connect()
        for text in ["0", "13", "x", "2.5", "-1", "+3", "1_0"] {
            await schedules.save(AuditRuns.licenseUsage, cadence: .daily, keep: text)
            #expect(schedules.notices["license_usage"] == .init(text: "Keep a whole number of runs, from 1 to 12.", problem: true), "\(text)")
        }
        #expect(schedules.schedule(of: AuditRuns.licenseUsage) == nil && !FileManager.default.fileExists(atPath: store.root.path))
        #expect(RunSchedules.keepCount(" 7 ") == 7 && RunSchedules.keepCount("") == AuditSchedules.keepDefault && RunSchedules.keepCount("12") == 12)
    }

    /// Each domain has its own schedules and kept runs: a switch shows the other's, and a run there never compares with this one's.
    @Test func eachDomainHasItsOwnSchedulesAndKeptRuns() async throws {
        try await connect()
        await schedules.save(AuditRuns.licenseUsage, cadence: .weekly, keep: "")
        _ = try await run()
        try await connect("example.org")
        #expect(schedules.schedule(of: AuditRuns.licenseUsage) == nil && schedules.scheduled().isEmpty)
        await schedules.save(AuditRuns.licenseUsage, cadence: .daily, keep: "2")
        let there = try await run()
        #expect(there.changes["per_sku"]?.why == AuditSchedules.nothingBefore || there.keptProblem, "never compared across domains")
        #expect(try store.runs(Domain("example.com")!, run: "license_usage").count == 1)
        #expect(try store.schedules(Domain("example.com")!)["license_usage"]?.cadence == .weekly)
    }

    /// Removing a domain on Setup deletes its schedules and the runs they kept, and says so; another domain's stay.
    @Test func removingADomainOnSetupDeletesItsSchedulesAndKeptRuns() async throws {
        try await connect("example.org")
        await schedules.save(AuditRuns.licenseUsage, cadence: .weekly, keep: "")
        try await connect()
        await schedules.save(AuditRuns.licenseUsage, cadence: .weekly, keep: "")
        _ = try await run()
        await setup.remove(Domain("example.com")!)
        #expect(setup.activity == .done("Removed example.com's credentials from this Mac. Its 1 schedule and 1 kept run on this Mac were deleted."))
        #expect(try store.schedules(Domain("example.com")!).isEmpty && store.runs(Domain("example.com")!, run: "license_usage").isEmpty)
        #expect(try store.schedules(Domain("example.org")!).count == 1)
    }
}
