import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Audit runs end to end against the strict mock (plan F3, GamGUI's `tests/test_audit_runs.py`): a fixed list of reads, Stop
/// between steps, each step's table kept for the run, and each step leaving one read record (origin `audit_run`). A step that
/// failed, wrote no table, read nothing where something must be, or never ran is unknown, and so is every table that needs it:
/// never "none" (invariant 10).
@MainActor
@Suite("Audit runs", .serialized)
final class AuditRunnerTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-audit-runner-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let runner: AuditRunner
    let auditURL: URL
    let argvLog: URL
    let state: URL
    /// The mock's directory signed in last on 2026-10-20 (admin@), 2026-10-01 (dana@), 2026-06-18 (alice@) and 2026-01-01
    /// (carol@); bob@ is suspended.
    nonisolated static let now = ISO8601DateFormatter().date(from: "2026-11-19T00:00:00Z")!

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let gam = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: gam, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: gam, now: { AuditRunnerTests.now })
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        argvLog = scratch.appending(path: "argv.log")
        state = scratch.appending(path: "mock-state")
        runner = AuditRunner(setup: setup, runner: gam, audit: ReadAudit(log: AuditLog(url: auditURL)), now: { AuditRunnerTests.now })
        runner.environment = ["GAM_MOCK_STATE": state.path, "GAM_MOCK_ARGV_LOG": argvLog.path]
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
    }

    /// A marker in the mock's state folder (`licenses_silent`, `denied/x`).
    private func mark(_ name: String) throws {
        let url = state.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    /// The read records, oldest first.
    private var records: [JSONObject] { AuditLog.records(at: auditURL).reversed().filter { $0["action"] == .string("read") } }

    /// Every gam call the mock ran, as argv.
    private func calls() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var found: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            found.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return found
    }

    private func run(_ run: AuditRuns.Run, days: Int = 90) async throws -> AuditRuns.Outcome {
        #expect(runner.start(run, days: days) == nil)
        await runner.finish(run)
        guard case .finished(let outcome)? = runner.state(of: run) else {
            throw NotFinished(state: "\(String(describing: runner.state(of: run)))")
        }
        return outcome
    }

    struct NotFinished: Error { let state: String }

    // MARK: the runs

    /// Every step of every run leaves one read record: the run and step as its command, origin `audit_run`, no target, the
    /// domain and the rows; never the output. Nothing a run does is a write.
    @Test func everyStepOfEveryRunLeavesOneReadRecord() async throws {
        try await connect()
        for each in AuditRuns.all {
            let before = records.count
            let outcome = try await run(each)
            #expect(outcome.complete, "\(each.key)")
            let mine = Array(records.dropFirst(before))
            #expect(mine.map { $0["extra"]?["command"]?.string } == each.steps.map { each.command($0) }, "\(each.key)")
            for record in mine {
                #expect(record["ok"] == .bool(true) && record["target"] == .string(""), "\(each.key)")
                #expect(record["argv"]?.array?.first == .string("print"))
                #expect(record["extra"]?["origin"] == .string("audit_run") && record["extra"]?["domain"] == .string("example.com"))
                #expect((record["extra"]?["rows"]?.int ?? 0) > 0)
            }
        }
        #expect(calls().allSatisfy { $0.first == "print" }, "\(calls())")
        #expect(!(try String(contentsOf: auditURL, encoding: .utf8)).contains("Business Standard"), "never the output")
    }

    /// Inactive users: the directory read once, the window's bucket flagged, the connected admin's run's people listed. A window
    /// the run doesn't offer is refused before any read.
    @Test func theInactiveRunReadsTheDirectoryOnceForTheWindow() async throws {
        try await connect()
        let outcome = try await run(AuditRuns.inactiveUsers, days: 90)
        #expect(calls() == [AuditRuns.read(AuditRuns.directory).argv])
        #expect(outcome.days == 90 && outcome.reads.map(\.rows) == [5])
        let table = try #require(outcome.finding("inactive"))
        #expect(table.title == "Inactive 90+ days" && table.known && table.links)
        #expect(table.rows.map { $0[0] } == ["carol@example.com", "alice@example.com"])
        #expect(table.rows.map { $0[5] } == ["", "admin"], "alice is an admin; neither was made inside the window")
        #expect(records.last?["extra"] == .object(["command": .string("inactive_users/directory"), "origin": .string("audit_run"),
                                                   "rows": .number("5"), "domain": .string("example.com")]))
        for days in [0, 45, -90, 91] {
            #expect(runner.start(AuditRuns.inactiveUsers, days: days) == "Pick one of the windows the run offers.")
        }
        #expect(calls().count == 1)
    }

    /// License usage: both steps recorded and joined; each step's table kept for the run.
    @Test func theLicenseRunJoinsTheSeatsToTheDirectory() async throws {
        try await connect()
        let outcome = try await run(AuditRuns.licenseUsage)
        #expect(calls().map { Array($0.prefix(2)) } == [["print", "licenses"], ["print", "users"]])
        #expect(outcome.complete && outcome.tables.rows["licenses"]?.count == 7 && outcome.tables.users?.count == 5)
        #expect(outcome.finding("per_sku")?.summary == "7 seats across 2 licenses.")
        #expect(outcome.finding("on_suspended")?.rows.map { $0[0] } == ["bob@example.com", "bob@example.com"])
        #expect(outcome.finding("not_in_directory")?.rows == [["left@example.com", "Google Workspace Business Standard"]])
    }

    /// A refused read is unknown, never "no seats": GAM's remediation and its own line, and every table built on it unknown; the
    /// directory still read. The failed read is recorded with GAM's words and no row count.
    @Test func aRefusedLicenseReadIsUnknownNeverNoSeats() async throws {
        try await connect()
        try mark("nolicensing")
        let outcome = try await run(AuditRuns.licenseUsage)
        #expect(!outcome.complete)
        #expect(outcome.reads.map(\.state) == [.unknown, .read])
        #expect(outcome.reads[0].why.hasPrefix("A required API scope is not authorized") && outcome.reads[0].detail.contains("License Manager"))
        #expect(outcome.findings.allSatisfy { !$0.known && $0.rows.isEmpty })
        #expect(outcome.finding("on_suspended")?.why.hasPrefix("Not known: “Every license seat” couldn't be read.") == true)
        let failed = try #require(records.first)
        #expect(failed["ok"] == .bool(false) && failed["extra"]?["rows"] == nil)
        #expect(failed["extra"]?["error"]?.string?.contains("License Manager API") == true)
    }

    /// Titles alone: GAM passed over every product without a word, so the seats are unknown, not none, and that's recorded as
    /// what GAM did (0 rows). One product passed over reads as a clean run, so every table carries the caveat.
    @Test func gamsSilentSkipIsUnknownOrCaveated() async throws {
        try await connect()
        try mark("licenses_silent")
        var outcome = try await run(AuditRuns.licenseUsage)
        #expect(outcome.reads[0].state == .unknown && outcome.reads[0].why.hasPrefix("GAM listed no license seat at all"))
        #expect(records.first?["extra"]?["rows"] == .number("0"))
        #expect(outcome.findings.allSatisfy { !$0.known })
        try FileManager.default.removeItem(at: state.appending(path: "licenses_silent"))
        try mark("licenses_partial")
        outcome = try await run(AuditRuns.licenseUsage)
        #expect(outcome.complete, "nothing in GAM's answer tells it from a whole read")
        #expect(outcome.finding("per_sku")?.rows.map { $0[1] } == ["Google Workspace Business Standard"])
        #expect(outcome.findings.allSatisfy { $0.note.contains("passes over a product Google won't let it read without saying so") })
    }

    /// A directory read that stopped part way (exit 50 with the rows it had) is unknown and its partial table never used.
    @Test func aDirectoryThatStoppedShortIsNeverUsed() async throws {
        try await connect()
        try mark("directory_fails")
        let outcome = try await run(AuditRuns.licenseUsage)
        #expect(outcome.reads.map(\.state) == [.read, .unknown] && outcome.tables.users == nil)
        let perSKU = try #require(outcome.finding("per_sku"))
        #expect(perSKU.known && perSKU.rows.allSatisfy { Array($0.suffix(2)) == ["unknown", "unknown"] })
        #expect(outcome.finding("on_suspended")?.known == false && outcome.finding("not_in_directory")?.known == false)
        let inactive = try await run(AuditRuns.inactiveUsers)
        #expect(inactive.findings.count == 1 && inactive.findings[0].known == false && inactive.findings[0].summary.hasPrefix("Not known:"))
        #expect(calls().allSatisfy { $0.first == "print" })
    }

    /// Stop between steps: the step in flight finishes and is recorded; the rest are not run, and every table that needs them
    /// says unknown. A second Run while one goes is ignored.
    @Test func stopLeavesTheRestNotRun() async throws {
        try await connect()
        #expect(runner.start(AuditRuns.licenseUsage) == nil)
        // The first step is in flight once its title is shown.
        while case .running(let progress)? = runner.state(of: AuditRuns.licenseUsage), progress.current.isEmpty, progress.done == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(runner.start(AuditRuns.licenseUsage) == nil, "a second press joins the first")
        #expect(runner.stop(AuditRuns.licenseUsage))
        await runner.finish(AuditRuns.licenseUsage)
        guard case .finished(let outcome)? = runner.state(of: AuditRuns.licenseUsage) else {
            Issue.record("\(String(describing: runner.state(of: AuditRuns.licenseUsage)))")
            return
        }
        #expect(outcome.reads.map(\.state) == [.read, .notRun])
        #expect(outcome.reads[1].why == AuditRunner.stoppedBefore)
        #expect(outcome.finding("on_suspended")?.why == "Not known: the run was stopped before “The directory, suspended accounts included”.")
        #expect(calls().map { Array($0.prefix(2)) } == [["print", "licenses"]])
        #expect(records.map { $0["extra"]?["command"]?.string } == ["license_usage/licenses"])
        #expect(!runner.stop(AuditRuns.licenseUsage), "nothing going to stop")
    }

    /// A switch of the connected domain drops what was kept for the old one.
    @Test func aSwitchDropsTheKeptRuns() async throws {
        try await connect()
        _ = try await run(AuditRuns.inactiveUsers)
        #expect(runner.state(of: AuditRuns.inactiveUsers) != nil)
        try await connect("example.org")
        #expect(setup.active?.name == "example.org")
        #expect(runner.state(of: AuditRuns.inactiveUsers) == nil)
    }

    /// A step the log can't record isn't used: it says so, and the table built on it is unknown.
    @Test func aReadTheLogCantRecordIsntUsed() async throws {
        try await connect()
        let blocked = scratch.appending(path: "not-a-folder")
        try Data().write(to: blocked)
        let gam = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault,
                                      runtimeDirectory: try RuntimeDirectory.prepare(scratch.appending(path: "run2")))
        let unrecorded = AuditRunner(setup: setup, runner: gam, audit: ReadAudit(log: AuditLog(url: blocked.appending(path: "a.jsonl"))),
                                     now: { AuditRunnerTests.now })
        #expect(unrecorded.start(AuditRuns.inactiveUsers) == nil)
        await unrecorded.finish(AuditRuns.inactiveUsers)
        guard case .finished(let outcome)? = unrecorded.state(of: AuditRuns.inactiveUsers) else { Issue.record("not finished"); return }
        #expect(outcome.reads[0].state == .unknown && outcome.reads[0].why.contains("couldn't record it"))
        #expect(outcome.findings[0].known == false)
    }
}
