import ChangeCore
import Foundation
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// No 2SV / No recovery → a reminder email (roadmap 3.3), against the strict mock: GamGUI's `tests/test_remind_buckets.py`.
/// The mock's active accounts without 2SV are carol and dana.
@MainActor
@Suite("Bucket reminders", .serialized)
final class BucketRemindersTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-remind-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let model: BucketReminders
    let argvLog: URL

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: scratch.appending(path: "audit.jsonl")), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": scratch.appending(path: "state").path])
        model = BucketReminders(executor: executor, setup: setup, directory: directory)
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
        await directory.load()
    }

    private func sent() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.first == "sendemail" }
    }

    private func pending() throws -> BucketReminders.Pending {
        guard case .previewing(let pending) = model.state else { throw NotPreviewing(state: "\(model.state)") }
        return pending
    }

    /// `test_the_text_is_the_operators_own_words_escaped_with_its_line_breaks`.
    @Test func theTextIsTheOperatorsOwnWordsEscaped() {
        #expect(BucketReminders.html("Hi <b>x</b> & co\nline two\n") == "Hi &lt;b&gt;x&lt;/b&gt; &amp; co<br>line two")
        #expect(BucketReminders.html("it's \"quoted\"") == "it&#x27;s &quot;quoted&quot;")
    }

    /// `test_the_preview_reads_again_lists_the_bucket_and_sends_nothing` and `test_send_emails_each_person_the_held_text`.
    @Test func thePreviewHoldsTheBucketAndTheConfirmSendsItOnce() async throws {
        try await connect()
        await model.preview(key: "no_2sv", subject: " Turn on 2SV ", message: "Hello <b>you</b>,\nplease turn it on.")
        let held = try pending()
        #expect(held.people.map(\.primaryEmail) == ["carol@example.com", "dana@example.com"] && sent().isEmpty)
        await model.confirm(held, OperatorConfirmation(confirmed: true))
        await model.confirm(held, OperatorConfirmation(confirmed: true))
        let mails = sent()
        #expect(mails.map { $0[2] } == ["carol@example.com", "dana@example.com"], "once each, as held")
        #expect(Array(mails[0][3...]) == ["subject", "Turn on 2SV", "message", "Hello &lt;b&gt;you&lt;/b&gt;,<br>please turn it on.", "html"])
        guard case .done(let words) = model.state else { Issue.record("\(model.state)"); return }
        #expect(words == "Sent 2 of 2 reminders.")
    }

    @Test func anEmptyTextOrAnotherBucketHoldsNothing() async throws {
        try await connect()
        await model.preview(key: "no_2sv", subject: "", message: "x")
        guard case .problem(let empty) = model.state else { Issue.record("\(model.state)"); return }
        #expect(empty == "Write a subject and a message first.")
        await model.preview(key: "admins", subject: "x", message: "x")
        guard case .problem(let other) = model.state else { Issue.record("\(model.state)"); return }
        #expect(other == "Not a list that gets a reminder.")
        #expect(sent().isEmpty)
    }

    @Test func eachBucketStartsFromGamGUIsText() {
        #expect(BucketReminders.reminders["no_2sv"]?.subject == "Please turn on 2-Step Verification")
        #expect(BucketReminders.reminders["no_recovery"]?.message.contains(BucketReminders.securityPage) == true)
    }
}
