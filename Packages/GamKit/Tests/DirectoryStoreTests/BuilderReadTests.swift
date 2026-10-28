import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// A Builder read run end to end against the strict mock (`UserAccess.catalogRead`): the vendored catalog's command, its argv
/// from the one door, run on the tenant it was started on, its output read as the screen shows it; and GAM's own words when GAM
/// refuses one. The mock models only the shapes this app's own screens send, so of the catalog's reads it answers `version`
/// alone: the rest are refused as GAM refuses what it doesn't know, never answered in a guessed shape. Whether GAM accepts each
/// read is the live check's (docs/live-verification.md, B1).
@MainActor
@Suite("Builder reads", .serialized)
final class BuilderReadTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-builder-reads-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let access: UserAccess
    let catalog = try! CommandCatalog(json: Data(contentsOf: Fixtures.catalogJSON))

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        access = UserAccess(setup: setup, runner: runner)
    }

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
        try #require(catalog.commands.first { $0.runnable && $0.syntax.hasPrefix(prefix + " ") })
    }

    @Test func aReadRunsAndItsOutputIsShown() async throws {
        let domain = try await connect()
        let version = try GamCommands.catalogRead(try command("gam version"), values: [:])
        let shown = try await access.catalogRead(version, in: domain).get()
        #expect(shown.argv == ["version"] && !shown.isTable && shown.text.hasPrefix("GAM \(GamVersion.expected)"))
    }

    /// GAM's own words when it refuses a read, never an empty table; and none at all without a domain connected.
    @Test func aRefusedReadSaysWhy() async throws {
        let domain = try await connect()
        let users = try GamCommands.catalogRead(try command("gam print users"), values: [:])
        #expect(users.argv == ["print", "users"])
        guard case .failure(let problem) = await access.catalogRead(users, in: domain) else {
            Issue.record("the mock models no bare print users: it must refuse it")
            return
        }
        #expect(!problem.summary.isEmpty)
    }
}
