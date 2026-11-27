import ChangeCore
import Foundation
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// A group's settings (roadmap 4.4), against the strict mock: GamGUI's `tests/test_group_settings.py`. sales@ posts from anyone,
/// asks to join, shows members to the domain, no outside members; locked@ is a group whose update Google refuses.
@MainActor
@Suite("Group settings", .serialized)
final class GroupSettingsTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-gs-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let access: UserAccess
    let model: GroupSettingsChanges
    let argvLog: URL
    let state: URL

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        argvLog = scratch.appending(path: "argv.log")
        state = scratch.appending(path: "state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": state.path]
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: scratch.appending(path: "audit.jsonl")), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
        model = GroupSettingsChanges(executor: executor, setup: setup, access: access)
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
    }

    private func updates() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.starts(with: ["update", "group"]) }
    }

    @Test func theSettingsReadInWords() async throws {
        try await connect()
        await model.load("sales@example.com")
        let settings = try #require(try model.settings(of: "sales@example.com")?.get())
        #expect(settings.map(\.key) == GroupSettings.table.map(\.key))
        #expect(settings.first { $0.key == "whocanpostmessage" }?.shown == "Anyone, outside the organization too")
        #expect(settings.first { $0.key == "allowexternalmembers" }?.value == "false")
    }

    @Test func onlyWhatChangesIsHeldAndWritten() async throws {
        try await connect()
        await model.preview("sales@example.com", wanted: ["whocanpostmessage": "anyone_can_post", "allowexternalmembers": "true",
                                                         "whocanjoin": "invited_can_join"])
        guard case .previewing(let pending) = model.state else { Issue.record("\(model.state)"); return }
        #expect(pending.changes.map(\.key) == ["whocanjoin", "allowexternalmembers"], "posting is unchanged")
        await model.confirm(pending, OperatorConfirmation(confirmed: true))
        #expect(updates() == [["update", "group", "sales@example.com", "whocanjoin", "invited_can_join", "allowexternalmembers", "true"]])
        guard case .done = model.state else { Issue.record("\(model.state)"); return }
        #expect(try model.settings(of: "sales@example.com")?.get().first { $0.key == "allowexternalmembers" }?.value == "true")
    }

    @Test func nothingToChangeOrAnUnknownValueHoldsNothing() async throws {
        try await connect()
        await model.preview("sales@example.com", wanted: ["whocanpostmessage": "anyone_can_post"])
        guard case .problem(let same) = model.state else { Issue.record("\(model.state)"); return }
        #expect(same == "Nothing to change: those are sales@example.com's settings now.")
        await model.preview("sales@example.com", wanted: ["whocanpostmessage": "everyone"])
        guard case .problem = model.state else { Issue.record("\(model.state)"); return }
        #expect(updates().isEmpty)
    }

    @Test func googlesRefusalIsSaidInItsWords() async throws {
        try await connect()
        await model.preview("locked@example.com", wanted: ["allowwebposting": "false", "isarchived": "false"])
        guard case .previewing(let pending) = model.state else { Issue.record("\(model.state)"); return }
        await model.confirm(pending, OperatorConfirmation(confirmed: true))
        guard case .problem(let why) = model.state else { Issue.record("\(model.state)"); return }
        #expect(why.hasPrefix("Google refused the change: Invalid Value"))
    }

    @Test func abuseAndPostmasterAreNeverRead() async throws {
        try await connect()
        await model.load("abuse@example.com")
        guard case .failure? = model.settings(of: "abuse@example.com") else { Issue.record("read"); return }
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.updateGroupSettings(group: "postmaster@example.com", changes: ["isarchived": "true"]) }
    }
}
