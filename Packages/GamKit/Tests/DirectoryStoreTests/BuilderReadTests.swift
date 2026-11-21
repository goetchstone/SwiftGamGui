import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// A Builder read run end to end against the strict mock (`UserAccess.catalogRead`): the vendored catalog's command, its argv
/// from the one door, run on the tenant it was started on, its output read as the screen shows it; and GAM's own words when GAM
/// refuses one; and each read recorded once it ended (plan F1), never its output. The mock models only the shapes this app's own
/// screens send, so of the catalog's reads it answers `version` alone: the rest are refused as GAM refuses what it doesn't know,
/// never answered in a guessed shape. Whether GAM accepts each read is the live check's (docs/live-verification.md, B1).
@MainActor
@Suite("Builder reads", .serialized)
final class BuilderReadTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-builder-reads-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let access: UserAccess
    let catalog = try! CommandCatalog(json: Data(contentsOf: Fixtures.catalogJSON))
    let auditURL: URL
    let audit: ReadAudit

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        access = UserAccess(setup: setup, runner: runner)
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        audit = ReadAudit(log: AuditLog(url: auditURL))
    }

    /// The log's records, oldest first.
    private var records: [JSONObject] { AuditLog.records(at: auditURL).reversed() }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect(_ domain: String = "example.com") async throws -> Domain {
        let folder = scratch.appending(path: "config-\(domain)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "admin@\#(domain)"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
        return try #require(setup.active)
    }

    private func command(_ prefix: String) throws -> CommandCatalog.Command {
        try #require(catalog.commands.first { $0.runnable && ($0.syntax == prefix || $0.syntax.hasPrefix(prefix + " ")) })
    }

    /// A read that ran is recorded as one: the command, whom it was about (none: GamGUI's "(command)"), the domain, where it was
    /// started, and no row count, since it prints words, not a table. Never the output.
    @Test func aReadRunsAndItsOutputIsShown() async throws {
        let domain = try await connect()
        let command = try command("gam version")
        let version = try GamCommands.catalogRead(command, values: [:])
        let shown = try await access.catalogRead(version, command: command.id, target: command.target([:]), in: domain,
                                                 recordingTo: audit).get()
        #expect(shown.argv == ["version"] && !shown.isTable && shown.text.hasPrefix("GAM \(GamVersion.expected)"))
        #expect(shown.tableRows == nil)
        let record = try #require(records.last)
        #expect(records.count == 1)
        #expect(record["action"] == .string("read") && record["target"] == .string("(command)") && record["ok"] == .bool(true))
        #expect(record["argv"] == .array([.string("version")]))
        #expect(record["extra"] == .object(["command": .string(command.id), "origin": .string("builder"),
                                            "domain": .string("example.com")]))
        #expect(!(try String(contentsOf: auditURL, encoding: .utf8)).contains(GamVersion.expected), "never the output")
    }

    /// GAM's own words when it refuses a read, never an empty table; and none at all without a domain connected. The failed read
    /// is recorded with those words and no row count.
    @Test func aRefusedReadSaysWhy() async throws {
        let domain = try await connect()
        let command = try command("gam print users")
        let users = try GamCommands.catalogRead(command, values: [:])
        #expect(users.argv == ["print", "users"])
        guard case .failure(let problem) = await access.catalogRead(users, command: command.id, target: "(command)", in: domain,
                                                                    recordingTo: audit) else {
            Issue.record("the mock models no bare print users: it must refuse it")
            return
        }
        #expect(!problem.summary.isEmpty)
        let extra = try #require(records.last?["extra"]?.object)
        #expect(records.last?["ok"] == .bool(false) && extra["error"] == .string(problem.summary) && extra["rows"] == nil)
    }

    /// A read whose task is cancelled before GAM finished is recorded as interrupted, in the read's own words. No screen cancels
    /// a Builder read today (this is for a Stop); a read the app quits during leaves no record, since the app exits first.
    @Test func aCancelledReadTaskIsRecordedAsInterrupted() async throws {
        let domain = try await connect()
        let command = try command("gam version")
        let version = try GamCommands.catalogRead(command, values: [:])
        let access = access, audit = audit
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await access.catalogRead(version, command: command.id, target: "(command)", in: domain, recordingTo: audit)
        }
        #expect(await task.value == .failure(UserAccess.interrupted))
        #expect(records.last?["ok"] == .bool(false))
        #expect(records.last?["extra"]?.object?["error"] == .string(ReadAudit.interrupted))
    }

    /// A read the audit log can't record isn't shown, as GamGUI's isn't: it says so.
    @Test func aReadTheLogCantRecordIsntShown() async throws {
        let domain = try await connect()
        let command = try command("gam version")
        let version = try GamCommands.catalogRead(command, values: [:])
        let blocked = scratch.appending(path: "not-a-folder")
        try Data().write(to: blocked)
        let unwritable = ReadAudit(log: AuditLog(url: blocked.appending(path: "audit.jsonl")))
        guard case .failure(let problem) = await access.catalogRead(version, command: command.id, target: "(command)", in: domain,
                                                                    recordingTo: unwritable) else {
            Issue.record("shown without its record")
            return
        }
        #expect(problem.summary.hasPrefix("The read ended, but the audit log couldn't record it"))
    }
}
