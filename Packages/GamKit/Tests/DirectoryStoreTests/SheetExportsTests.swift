import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Export to a Google Sheet… end to end against the strict mock (GamGUI's `tests/test_sheet_export.py` and its domain-menu
/// tests): the scope check, the preview holding the read's exact argv and GAM's todrive options, one run through the executor
/// from that preview only, the outcome read from the upload's own lines, and the audit record. Nothing here has run against a
/// real tenant: the first live export waits on the operator's yes.
@MainActor
@Suite("Sheet exports", .serialized)
final class SheetExportsTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-sheet-exports-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let access: UserAccess
    let exports: SheetExports
    let executor: Executor
    let writeAuditURL: URL
    let argvLog: URL
    let state: URL
    static let admin = "admin@example.com"
    static let title = "example.com - List mailbox delegates"
    static let read = GamCommands.printDelegates(email: "alice@example.com")

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let gam = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: gam, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        writeAuditURL = scratch.appending(path: "audit/writes.jsonl")
        argvLog = scratch.appending(path: "argv.log")
        state = scratch.appending(path: "mock-state")
        let environment = ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path, "GAM_MOCK_STATE": state.path]
        let setup = setup
        executor = Executor(runner: gam, audit: AuditLog(url: writeAuditURL), currentActor: { @MainActor in setup.connectedAdmin },
                                adminAccountID: { @MainActor in setup.connectedAdminID },
                                tenant: { @MainActor in setup.active.map { ($0, setup.generation) } }, extraEnvironment: environment)
        access = UserAccess(setup: setup, runner: gam)
        access.environment = environment
        exports = SheetExports(executor: executor, setup: setup, access: access)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect(_ domain: String = "example.com", admin: String = SheetExportsTests.admin) async throws {
        let folder = scratch.appending(path: "config-\(domain)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "123456789"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: admin).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
        #expect(setup.active?.name == domain)
    }

    /// The simulated tenant hasn't authorized these delegated scopes (the mock's GAM_MOCK_STATE/dwd_missing).
    private func refuse(_ scopes: String...) throws {
        try Data(scopes.map { $0 + "\n" }.joined().utf8).write(to: state.appending(path: "dwd_missing"))
    }

    private func mark(_ name: String) throws {
        try Data().write(to: state.appending(path: name))
    }

    /// The files the mock's uploads made: their titles.
    private func made() -> [String] {
        let text = (try? String(contentsOf: state.appending(path: "drive_files"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { String($0.split(separator: "\t")[1]) }
    }

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

    private func exportCalls() -> [[String]] { calls().filter { $0.contains("todrive") } }

    private func records() -> [JSONObject] { AuditLog.records(at: writeAuditURL).reversed() }

    struct NotPreviewing: Error { let state: String }

    private func pending() throws -> SheetExports.Pending {
        guard case .previewing(let pending) = exports.state else { throw NotPreviewing(state: "\(exports.state)") }
        return pending
    }

    private func done() throws -> SheetExports.Done {
        guard case .done(let done) = exports.state else { throw NotPreviewing(state: "\(exports.state)") }
        return done
    }

    private func preview(_ read: GamRead = SheetExportsTests.read) async {
        await exports.preview(read: read, command: "build.print_delegates", commandName: "List mailbox delegates", rows: 2)
    }

    /// The preview says what runs, whose Drive, and the scope check; it runs only reads (the check), and holds the exact argv.
    @Test func thePreviewHoldsTheReadThenTheTodriveOptions() async throws {
        try await connect()
        await preview()
        let pending = try pending()
        #expect(pending.commandLine == "gam user alice@example.com print delegates todrive tdtitle '\(Self.title)' tdnobrowser true tdnoemail true")
        #expect(pending.owner == Self.admin && pending.name == Self.title && pending.rows == 2 && pending.canExport)
        #expect(pending.scopes.map(\.allowed) == [true, true] && pending.scopeWords.isEmpty && pending.delegationLink == nil)
        let held = try #require(pending.preview)
        #expect(held.steps.map(\.shownArgv) == [Self.read.argv + GamCommands.todriveArgs(title: Self.title)])
        #expect(held.steps.first?.action == .exportToSheet && held.steps.first?.target == Self.admin && held.needsConfirmClick)
        #expect(exportCalls().isEmpty && made().isEmpty, "the check is a read: nothing made yet")
        #expect(calls().contains { $0.contains("serviceaccount") })
    }

    /// Confirmed, it runs exactly what it held, once: one Sheet, its link read from GAM's own line, the record naming the admin,
    /// the command and the link. A second confirm of the same preview runs nothing.
    @Test func theExportMakesOneSheetAndShowsItsLink() async throws {
        try await connect()
        await preview()
        let pending = try pending()
        await exports.confirm(pending, OperatorConfirmation(confirmed: true))
        let done = try done()
        #expect(done.outcome.made == .yes && done.outcome.url.hasPrefix("https://docs.google.com/spreadsheets/d/1MockSheet"))
        #expect(done.outcome.said == "Exported to a new Google Sheet in \(Self.admin)'s Drive, shared with nobody.")
        #expect(done.detail.isEmpty && done.unrecorded.isEmpty && made() == [Self.title])
        #expect(exportCalls() == [Self.read.argv + GamCommands.todriveArgs(title: Self.title)])
        let end = try #require(records().last)
        #expect(end["action"]?.string == "export_to_sheet" && end["target"]?.string == Self.admin && end["ok"] == .bool(true))
        let extra = try #require(end["extra"]?.object)
        #expect(extra["phase"]?.string == "end" && extra["url"]?.string == done.outcome.url)
        #expect(extra["command"]?.string == "build.print_delegates" && extra["domain"]?.string == "example.com")
        #expect(!String(describing: end).contains("delegateAddress"), "never the rows")
        #expect(records().map { $0["extra"]?.object?["phase"]?.string } == ["begin", "end"])
        // The preview is spent: the sheet is gone, and the same preview held again by hand runs nothing.
        await exports.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(exportCalls().count == 1 && made().count == 1)
    }

    /// The executor decides whether the confirmation is enough: a preview that asked for a click runs nothing without it.
    @Test func anExportWithoutItsClickRunsNothing() async throws {
        try await connect()
        await preview()
        await exports.confirm(try pending(), OperatorConfirmation(confirmed: false))
        guard case .problem(let words) = exports.state else { Issue.record("\(exports.state)"); return }
        #expect(words.hasSuffix("Nothing ran.") && exportCalls().isEmpty && made().isEmpty && records().isEmpty)
    }

    /// A scope the service account is known to lack: nothing held, no Export, and Setup's link with every scope.
    @Test func aRefusedScopeOffersNoExportAndSetupsLink() async throws {
        try await connect()
        try refuse(SheetExport.sheetsScope)
        await preview()
        let pending = try pending()
        #expect(!pending.canExport && pending.preview == nil)
        #expect(pending.scopes.map(\.allowed) == [true, false] && pending.scopeWords.contains("stop before finishing it as a Sheet"))
        let link = try #require(pending.delegationLink?.absoluteString)
        #expect(link.hasPrefix(DelegationScopes.adminConsoleURL) && link.contains("auth/spreadsheets") && link.contains("auth/calendar"))
        #expect(link.contains("clientIdToAdd=123456789"))
        await exports.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(exportCalls().isEmpty && made().isEmpty)
    }

    /// A check that can't be made (here: no admin named in the token, so GAM's own admin is unknown) is said as unknown, and
    /// Export is still offered.
    @Test func anUncheckedScopeIsSaidAndExportStillOffered() async throws {
        try await connect()
        let unknown = await access.sheetExportScopes(admin: "", in: Domain("example.com")!)
        #expect(unknown == nil)
        #expect(SheetExport.scopeState(unknown).contains("couldn't be checked"))
        let checked = await access.sheetExportScopes(admin: Self.admin, in: Domain("example.com")!)
        #expect(checked == [SheetExport.driveScope: true, SheetExport.sheetsScope: true])
    }

    /// The Sheets scope taken away after the preview checked it: GAM makes the file, then stops before its link. Said as made.
    @Test func aFileMadeWithoutItsLinkIsSaid() async throws {
        try await connect()
        await preview()
        let pending = try pending()
        try refuse(SheetExport.sheetsScope)
        await exports.confirm(pending, OperatorConfirmation(confirmed: true))
        let done = try done()
        #expect(done.outcome.made == .yes && done.outcome.url.isEmpty && done.outcome.said.contains("made the file"))
        #expect(done.outcome.todo.hasPrefix("Find the file in that Drive") && made().count == 1)
        let end = try #require(records().last?["extra"]?.object)
        #expect(end["upload"]?.string == "sheets_refused" && end["url"] == nil)
    }

    @Test func aFullDriveMakesNothingAndSaysSo() async throws {
        try await connect()
        await preview()
        let pending = try pending()
        try mark("drive_full")
        await exports.confirm(pending, OperatorConfirmation(confirmed: true))
        let done = try done()
        #expect(done.outcome.made == .no && done.detail.contains("Drive Folder: root, Create Failed:") && made().isEmpty)
        #expect(records().last?["extra"]?.object?["upload"]?.string == "create_failed")
    }

    /// printShowDelegates for an account that isn't there: its token refused (a soft error), GAM writes the titles and uploads
    /// them, prints the link and exits 50. A Sheet of headers, said as made but maybe short, never as nothing.
    @Test func aReadOfAnAccountThatIsntThereUploadsItsHeaders() async throws {
        try await connect()
        await preview(GamCommands.printDelegates(email: "missing@example.com"))
        await exports.confirm(try pending(), OperatorConfirmation(confirmed: true))
        let done = try done()
        #expect(done.outcome.made == .yes && !done.outcome.url.isEmpty && done.outcome.said.contains("only its headers"))
        #expect(done.outcome.said.contains("invalid_grant") && made().count == 1)
        let end = try #require(records().last)
        #expect(end["ok"] == .bool(false) && end["extra"]?.object?["url"]?.string == done.outcome.url)
    }

    /// A read carrying todrive in any spelling GAM reads is refused at the preview, before any read, and by the Builder's read
    /// door, before GAM runs and unrecorded (it ran nothing). A curated search's value is one element GAM reads as a query,
    /// but it's refused all the same, as GamGUI's `catalog_read` refuses it: the stricter side.
    @Test func aReadCarryingTodriveIsRefusedEverywhere() async throws {
        try await connect()
        let readLog = scratch.appending(path: "audit/reads.jsonl")
        let find = try #require(CuratedCommand.all.first { $0.id == "build.find_users" })
        for spelling in ["todrive", "To_Drive", " TODRIVE "] {
            guard case .read(let carrying) = try find.built(["query": spelling]) else { Issue.record("not a read"); continue }
            await preview(carrying)
            guard case .problem(let words) = exports.state else { Issue.record("\(exports.state)"); continue }
            #expect(words.contains("already says todrive"), "\(spelling)")
            let shown = await access.catalogRead(carrying, command: find.id, target: "", in: Domain("example.com")!,
                                                 recordingTo: ReadAudit(log: AuditLog(url: readLog)))
            guard case .failure(let problem) = shown else { Issue.record("it ran: \(spelling)"); continue }
            #expect(problem == UserAccess.carriesToDrive, "\(spelling)")
        }
        #expect(!calls().contains { $0.starts(with: ["print", "users"]) }, "no read ran")
        #expect(AuditLog.records(at: readLog).isEmpty && exportCalls().isEmpty && made().isEmpty)
        // The catalog's door refuses the typed word itself.
        #expect(throws: GamCommands.Invalid.self) {
            try GamCommands.catalogRead(Self.catalogCommand(), values: ["a0": "alice@example.com", "a1": "To_Drive"])
        }
    }

    /// A catalog command for the refusal test: a promoted read whose second value sits where GAM reads options.
    static func catalogCommand() throws -> CommandCatalog.Command {
        let json = #"{"version": "7.52.04", "commands": [{"id": "t1", "category": "Users", "raw_syntax": "gam user <UserItem> print delegates <String>", "verb": "print", "risk": 0}]}"#
        return try #require(try CommandCatalog(json: Data(json.utf8)).commands.first)
    }

    /// A switch drops a held export, so the old domain's read never runs on the new one, nor makes a Sheet in the new admin's
    /// Drive; the executor refuses the old preview anyway.
    @Test func aSwitchDropsAHeldExport() async throws {
        try await connect()
        await preview()
        let pending = try pending()
        try await connect("example.org", admin: "admin@example.org")
        guard case .idle = exports.state else { Issue.record("\(exports.state)"); return }
        await exports.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(exportCalls().isEmpty && made().isEmpty && records().isEmpty)
    }

    /// Cancel drops the held preview from the executor: it can't be run later.
    @Test func cancelDropsTheHeldPreview() async throws {
        try await connect()
        await preview()
        let held = try #require(try pending().preview)
        exports.dismiss()
        try await Task.sleep(for: .milliseconds(50))
        guard case .idle = exports.state else { Issue.record("\(exports.state)"); return }
        #expect(!(await executor.isHeld(held.id)))
    }
}
