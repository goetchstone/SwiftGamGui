import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// Signatures S1c: one person's Gmail signature, previewed, confirmed and set through ChangeCore, end to
/// end against the strict mock with its argv log. Ports GamGUI's signature route tests
/// (`tests/test_users_web.py`) and the incidents behind them (its failure-log 2026-09-23 and 2026-09-25):
/// the designer opened on a colleague, an Apply ran what the form said then rather than what the preview
/// showed, and a preview held on one tenant what was read on another.
@MainActor
@Suite("Signature changes", .serialized)
final class SignatureChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-signatures-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: SignatureChanges
    let access: UserAccess
    let argvLog: URL
    let auditURL: URL
    let state: URL
    let confirmed = OperatorConfirmation(confirmed: true)

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        state = scratch.appending(path: "mock-state")
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
        changes = SignatureChanges(executor: executor, setup: setup, directory: directory)
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": state.path]
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Imports `domain` with an `oauth2.txt` naming `admin`, checks access (a pass connects it), and loads
    /// its directory. A `*partialdwd*` admin's check fails in the mock, leaving the last domain connected.
    private func connect(_ domain: String = "example.com", admin: String = "admin@example.com") async throws {
        let folder = scratch.appending(path: "config-\(domain)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "\#(admin)"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
        await directory.load()
    }

    private func user(_ email: String) throws -> GamUser {
        try #require(directory.users?.first { $0.primaryEmail == email })
    }

    private func pending() throws -> SignatureChanges.Pending {
        guard case .previewing(let pending) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return pending
    }

    private func problem() throws -> SignatureChanges.Problem {
        guard case .problem(let problem) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return problem
    }

    /// The signature writes the mock ran, as argv (logged as a count then its elements, NUL-separated).
    private func writes() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.count > 2 && $0[2] == "signature" }
    }

    private func bytes(_ calls: [[String]]) -> [[[UInt8]]] { calls.map { $0.map { Array($0.utf8) } } }

    private func marker(_ path: String, _ text: String = "") throws {
        let file = state.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    // MARK: who it opens on

    /// GamGUI review F18 (`test_signatures_test_user_is_the_connected_admin`): the page opened on whoever
    /// sorted first, a colleague whose live signature its default path then overwrote. It opens on the
    /// operator's own account when that's an active user.
    @Test func theDefaultPersonIsTheConnectedAdminWhenActive() async throws {
        try await connect(admin: "Carol@example.com")
        #expect(changes.defaultPerson?.primaryEmail == "carol@example.com")
        #expect(changes.activePeople.map(\.primaryEmail) == ["alice@example.com", "carol@example.com", "dana@example.com"],
                "active people only, in code-point order")
    }

    /// `test_signatures_test_user_is_an_explicit_choice_otherwise`: an admin outside the directory, a
    /// suspended one, or none known (the last check, of another domain, failed): nobody, never the first.
    @Test func theDefaultPersonIsOtherwiseNobody() async throws {
        try await connect(admin: "admin@example.com")
        #expect(setup.connectedAdmin == "admin@example.com")
        #expect(changes.defaultPerson == nil, "not in the directory")
        try await connect(admin: "bob@example.com")
        #expect(setup.connectedAdmin == "bob@example.com")
        #expect(changes.defaultPerson == nil, "suspended")
        try await connect(admin: "carol@example.com")
        #expect(changes.defaultPerson?.primaryEmail == "carol@example.com")
        try await connect("example.org", admin: "partialdwd@example.org")
        #expect(setup.active == Domain("example.com"), "the failed check left example.com connected")
        #expect(setup.connectedAdmin == nil)
        #expect(changes.defaultPerson == nil, "the admin isn't known")
    }

    // MARK: the preview and the confirm

    @Test func thePreviewHoldsThatPersonsRender() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        let classic = try #require(Signature.seeds.first { $0.name == "Classic" }).body
        let render = Signature.render(classic, for: alice)
        await changes.preview(person: alice, template: classic, current: nil)
        let pending = try pending()
        #expect(Array(pending.body.utf8) == Array(render.utf8))
        #expect(pending.title == "Replace Alice Anders's signature")
        #expect(pending.confirmLabel == "Replace Signature")
        #expect(pending.warnings.isEmpty)
        #expect(pending.preview.steps.first?.shownArgv == ["user", "alice@example.com", "signature", ArgvRedaction.mask, "html"])
        await changes.confirm(pending, confirmed)
        guard case .done(let done) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(done.message == "Replaced Alice Anders's signature.")
        #expect(bytes(writes()) == bytes([["user", "alice@example.com", "signature", render, "html"]]))
        #expect(changes.finished == 1)
        let end = try #require(AuditLog.records(at: auditURL).first)
        #expect(end["action"]?.string == "setSignature")
        #expect(end["argv"]?.array?.compactMap(\.string) == ["user", "alice@example.com", "signature", ArgvRedaction.mask, "html"])
    }

    /// `test_signatures_apply_runs_only_what_was_previewed` and `_is_single_use` (GamGUI failure-log
    /// 2026-09-23, "stale Apply"): a confirm runs the preview it was given exactly as held, and only while
    /// it's the one the screen shows. An edited template, another person, a replay or a bare confirm
    /// writes nothing; a directory change since the preview doesn't change what runs.
    @Test func confirmRunsWhatThePreviewHeld() async throws {
        try await connect()
        let alice = try user("alice@example.com"), carol = try user("carol@example.com")
        await changes.preview(person: alice, template: "{name} · {title}", current: nil)
        let first = try pending()
        await changes.preview(person: alice, template: "{name} EDITED", current: nil)
        let edited = try pending()
        await changes.confirm(first, confirmed)
        #expect(writes().isEmpty, "the template was edited after the first preview")
        await changes.preview(person: carol, template: "{name} EDITED", current: nil)
        let switched = try pending()
        await changes.confirm(edited, confirmed)
        #expect(writes().isEmpty, "the person changed after that preview")
        await changes.confirm(switched, OperatorConfirmation())
        #expect(writes().isEmpty, "a bare confirm")
        #expect(try problem().summary == "This change needs confirmation — preview it, then confirm.")

        await changes.preview(person: alice, template: "{name} · {title}", current: nil)
        let held = try pending()
        directory.patch("alice@example.com", on: Domain("example.com")!, generation: setup.generation) {
            $0.with(title: "Chief of Staff", department: $0.department)
        }
        await changes.confirm(held, confirmed)
        #expect(bytes(writes()) == bytes([["user", "alice@example.com", "signature", "Alice Anders · IT Director", "html"]]),
                "what the preview held, not a render of the directory as it is now")
        await changes.confirm(held, confirmed)
        #expect(writes().count == 1, "a replayed confirm")
    }

    /// Design doc D5 (GamGUI `routes/signatures.py:196`): a signature is set only from its confirm step,
    /// with the typed count above 25 people, as GamGUI asks.
    @Test func aSignatureAlwaysNeedsTheConfirmClick() async throws {
        try await connect()
        await changes.preview(person: try user("alice@example.com"), template: "{name}", current: nil)
        let pending = try pending()
        #expect(pending.preview.needsConfirmClick)
        #expect(pending.preview.typedCountAbove == Guard.countConfirmAbove)
        await changes.confirm(pending, OperatorConfirmation())
        #expect(writes().isEmpty)
        #expect(try problem().summary == "This change needs confirmation — preview it, then confirm.")
    }

    /// GAM reads a body that is only a file keyword (`file`, `HTML_File`, ` gdoc `…) as a file or document to
    /// load. The render is checked, not the template: a title can be the word.
    @Test func aKeywordBodyNeverReachesGam() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        for template in ["file", " HTML_File ", "TextFile", "g_doc", "GCSHTML\n"] {
            await changes.preview(person: alice, template: template, current: nil)
            let refused = try problem()
            #expect(refused.summary.hasPrefix("GAM would take “\(PythonText.strip(template))” as a file or document to load"),
                    "\(refused.summary)")
        }
        directory.patch("alice@example.com", on: Domain("example.com")!, generation: setup.generation) {
            $0.with(title: " gcs_doc ", department: $0.department)
        }
        await changes.preview(person: try user("alice@example.com"), template: "{title}", current: nil)
        #expect(try problem().summary.hasPrefix("GAM would take “gcs_doc”"))
        await changes.preview(person: alice, template: "file me", current: nil)
        #expect(try pending().warnings.isEmpty, "a body that only holds the word is a signature")
        #expect(writes().isEmpty)
    }

    /// GAM accepts an empty signature and clears the one set; a curly quote in a tag and a body GAM stores
    /// differently (F1) are said before the confirm. None changes the argv.
    @Test func anEmptyRenderWarnsItClears() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        await changes.preview(person: alice, template: "[[{phone}]]", current: nil)
        let pending = try pending()
        #expect(pending.warnings == ["This renders empty for Alice Anders: confirming clears their Gmail signature."])
        await changes.confirm(pending, confirmed)
        #expect(bytes(writes()) == bytes([["user", "alice@example.com", "signature", "", "html"]]))

        await changes.preview(person: alice, template: "<div style=“color:red”>{name}</div>", current: nil)
        #expect(try self.pending().warnings == [Signature.smartQuoteWarning("<div style=“color:red”>")])
        await changes.preview(person: alice, template: "{name}\\nIT\r\n", current: nil)
        #expect(try self.pending().warnings == ["GAM will store this with its carriage returns removed and each \\n changed to a line "
                                                + "break (<br/>). The Rendered view shows what Gmail will hold."])
        await changes.preview(person: alice, template: "{name}\\nIT", current: nil)
        #expect(try self.pending().warnings == ["GAM will store this with each \\n changed to a line break (<br/>). The Rendered "
                                                + "view shows what Gmail will hold."])
        #expect(try self.pending().body == "Alice Anders\\nIT", "the argv keeps the body as rendered")
    }

    /// `test_signature_set_failure_says_why_with_gams_error_expandable`: the headline says why in words, GAM's
    /// own error is one click away, never in the headline.
    @Test func aFailedSetSaysWhyWithGamsError() async throws {
        try await connect()
        try marker("nogmail/alice@example.com")
        await changes.preview(person: try user("alice@example.com"), template: "{name}", current: nil)
        await changes.confirm(try pending(), confirmed)
        let off = try problem()
        #expect(off.summary == "Couldn't set the signature. \(GamError.Kind.serviceNotEnabled.remediation)")
        #expect(off.detail?.contains("Gmail Service/App not enabled") == true)

        let gone = GamUser(record: ["primaryEmail": .string("gone-missing@example.com")])
        await changes.preview(person: gone, template: "Hi", current: nil)
        await changes.confirm(try pending(), confirmed)
        let missing = try problem()
        #expect(missing.summary == "Couldn't set the signature. The requested user, group, or resource was not found.")
        #expect(!missing.summary.contains("GAM failed"))
        #expect(missing.detail?.contains("invalid_grant: Invalid email or User ID") == true)
    }

    /// Live, 2026-09-30: a signature set seconds after `create user` was refused "Requested client not
    /// authorized" until Google finished the account. That's said only for an account that has never
    /// signed in; for anyone else the same words are GAM's unexplained error.
    @Test func aNewAccountsRefusalSaysToWait() async throws {
        try await connect()
        try marker("created/new.hire@example.com")
        try marker("provisioning/new.hire@example.com", "1")
        let hire = GamUser(record: ["primaryEmail": .string("new.hire@example.com"),
                                    "lastLoginTime": .string("1970-01-01T00:00:00.000Z")])
        await changes.preview(person: hire, template: "{email}", current: nil)
        await changes.confirm(try pending(), confirmed)
        let waiting = try problem()
        #expect(waiting.summary == "Couldn't set the signature. Google is still setting up this new account: wait a few minutes, then try again.")
        #expect(waiting.detail?.contains("Requested client not authorized") == true)

        try marker("provisioning/alice@example.com", "1")
        await changes.preview(person: try user("alice@example.com"), template: "{email}", current: nil)
        await changes.confirm(try pending(), confirmed)
        #expect(try problem().summary == "Couldn't set the signature. \(GamError.Kind.unknown.remediation)")
    }

    // MARK: the current signature, and putting it back

    /// Read with the person's other lists, as GAM showed it (GamGUI's reader), on its own: Gmail off for
    /// them fails only this read.
    @Test func theCurrentSignatureIsReadWithThePersonsLists() async throws {
        try await connect()
        await access.load("alice@example.com")
        #expect(try access.lists(for: "alice@example.com")?.signature.get() == "Best,<br>Alice")
        await access.load("dana@example.com")
        #expect(try access.lists(for: "dana@example.com")?.signature.get() == "", "GAM's None")
        try marker("nogmail/carol@example.com")
        await access.load("carol@example.com")
        let lists = try #require(access.lists(for: "carol@example.com"), "the other lists are read")
        guard case .failure(let failure) = lists.signature else { Issue.record("\(lists.signature)"); return }
        #expect(failure.summary.contains("Gmail Service/App not enabled"))
    }

    @Test func putBackPreviewsTheBodyAsRead() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        await access.load("alice@example.com")
        let current = try #require(try access.lists(for: "alice@example.com")?.signature.get())
        await changes.preview(person: alice, template: "{name}", current: current)
        await changes.confirm(try pending(), confirmed)
        guard case .done(let done) = changes.state, let previous = done.previous else { Issue.record("\(changes.state)"); return }
        #expect(previous.body == "Best,<br>Alice")
        await access.load("alice@example.com")
        #expect(try access.lists(for: "alice@example.com")?.signature.get() == "Alice Anders")

        await changes.previewPutBack(previous: previous)
        let putBack = try pending()
        #expect(putBack.body == "Best,<br>Alice")
        #expect(putBack.title == "Put back Alice Anders's previous signature")
        #expect(putBack.preview.needsConfirmClick)
        await changes.confirm(putBack, confirmed)
        guard case .done(let restored) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(restored.message == "Put back Alice Anders's previous signature.")
        #expect(restored.previous == nil)
        #expect(writes().last == ["user", "alice@example.com", "signature", "Best,<br>Alice", "html"])
        await access.load("alice@example.com")
        #expect(try access.lists(for: "alice@example.com")?.signature.get() == "Best,<br>Alice")

        // A signature someone set in Gmail that is only a file keyword can't be put back through GAM.
        let word = SignatureChanges.Previous(person: alice, body: " File ", domain: Domain("example.com")!, generation: setup.generation)
        await changes.previewPutBack(previous: word)
        #expect(try problem().summary.hasPrefix("GAM would take “File” as a file or document to load"))
        #expect(writes().count == 2)
    }

    /// The person and their current signature are the screen's reads of the connected tenant; a switch
    /// landing while the preview is held (the executor's tenant already the next one) refuses it.
    @Test func aPreviewHeldAfterASwitchIsRefused() async throws {
        try await connect()
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault,
                                         runtimeDirectory: try RuntimeDirectory.prepare(scratch.appending(path: "run2")))
        let next = setup.generation + 1
        let switched = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { (Domain("example.org")!, next) },
                                extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_STATE": state.path])
        let changes = SignatureChanges(executor: switched, setup: setup, directory: directory)
        await changes.preview(person: try user("alice@example.com"), template: "{name}", current: "Best,<br>Alice")
        guard case .problem(let refused) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(refused.summary == Executor.PreviewRefusal.tenantChanged.message)
    }

    /// GamGUI failure-log 2026-09-25: what was read on one tenant is never held for another. The body a Put
    /// Back restores was read on example.com; after a switch it isn't previewed on example.org.
    @Test func putBackAfterADomainSwitchIsRefused() async throws {
        try await connect()
        await access.load("alice@example.com")
        let current = try #require(try access.lists(for: "alice@example.com")?.signature.get())
        await changes.preview(person: try user("alice@example.com"), template: "{name}", current: current)
        await changes.confirm(try pending(), confirmed)
        guard case .done(let done) = changes.state, let previous = done.previous else { Issue.record("\(changes.state)"); return }
        try await connect("example.org", admin: "admin@example.org")
        #expect(setup.active == Domain("example.org"))
        await changes.previewPutBack(previous: previous)
        #expect(try problem().summary == Executor.PreviewRefusal.tenantChanged.message)
        #expect(writes().count == 1)
    }
}
