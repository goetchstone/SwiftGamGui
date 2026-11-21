import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import Stores
import TestSupport
import Testing
import Vault

/// Signatures S1c: one person's Gmail signature, previewed, confirmed and set through ChangeCore, end to
/// end against the strict mock with its argv log. Ports GamGUI's signature route tests
/// (`tests/test_users_web.py`) and the incidents behind them (its failure-log 2026-09-23 and 2026-09-25):
/// the designer opened on a colleague, an Apply ran what the form said then rather than what the preview
/// showed, and a preview held on one tenant what was read on another. And GamGUI's signature backups (#163, #164,
/// `tests/test_signature_backups.py` and `test_signature_putback.py`): the signature a run replaces is kept first, and
/// a kept run is put back as a run of its own.
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
    let backups: SignatureBackupStore
    let confirmed = OperatorConfirmation(confirmed: true)

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let gam = try Fixtures.gamReadingSignatures(in: scratch.appending(path: "gam"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: gam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        state = scratch.appending(path: "mock-state")
        backups = SignatureBackupStore(folder: scratch.appending(path: "signature-backups"))
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: auditURL), tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path], signatureKeeper: backups)
        changes = SignatureChanges(executor: executor, setup: setup, directory: directory, backups: backups)
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
        #expect(changes.activePeople.map(\.primaryEmail) == ["admin@example.com", "alice@example.com", "carol@example.com",
                                                               "dana@example.com"], "active people only, in code-point order")
    }

    /// `test_signatures_test_user_is_an_explicit_choice_otherwise`: an admin outside the directory or a
    /// suspended one: nobody, never the first. A failed check of another domain leaves the connected one's admin.
    @Test func theDefaultPersonIsOtherwiseNobody() async throws {
        try await connect(admin: "outside@example.com")
        #expect(setup.connectedAdmin == "outside@example.com")
        #expect(changes.defaultPerson == nil, "not in the directory")
        try await connect(admin: "bob@example.com")
        #expect(setup.connectedAdmin == "bob@example.com")
        #expect(changes.defaultPerson == nil, "suspended")
        try await connect(admin: "carol@example.com")
        #expect(changes.defaultPerson?.primaryEmail == "carol@example.com")
        try await connect("example.org", admin: "partialdwd@example.org")
        #expect(setup.active == Domain("example.com"), "the failed check left example.com connected")
        #expect(setup.connectedAdmin == "carol@example.com", "and its admin with it")
        #expect(changes.defaultPerson?.primaryEmail == "carol@example.com")
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
        #expect(done.message == "Replaced Alice Anders's signature. The one it replaced is kept on this Mac.")
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

    /// `test_signature_set_failure_says_why_with_gams_error_expandable`, and GamGUI's
    /// `test_someone_whose_signature_cant_be_read_isnt_overwritten`: a signature that can't be read first isn't replaced,
    /// said in words with why, never "GAM failed"; nothing is written, and nothing kept.
    @Test func aSignatureThatCantBeReadIsntReplaced() async throws {
        try await connect()
        try marker("nogmail/alice@example.com")
        await changes.preview(person: try user("alice@example.com"), template: "{name}", current: nil)
        await changes.confirm(try pending(), confirmed)
        let off = try problem()
        #expect(off.summary == "\(Executor.notRead) \(GamError.Kind.serviceNotEnabled.remediation)")

        let gone = GamUser(record: ["primaryEmail": .string("gone-missing@example.com")])
        await changes.preview(person: gone, template: "Hi", current: nil)
        await changes.confirm(try pending(), confirmed)
        let missing = try problem()
        #expect(missing.summary == "\(Executor.notRead) The requested user, group, or resource was not found.")
        #expect(!missing.summary.contains("GAM failed"))
        #expect(writes().isEmpty && backups.runs().isEmpty)
    }

    /// A set GAM refuses after the read: the headline says why in words, GAM's own error one click away. What was read is
    /// kept all the same (GamGUI keeps before it writes).
    @Test func aFailedSetSaysWhyWithGamsError() async throws {
        try await connect()
        try marker("provisioning/alice@example.com", "9")
        await changes.preview(person: try user("alice@example.com"), template: "{name}", current: nil)
        await changes.confirm(try pending(), confirmed)
        let refused = try problem()
        #expect(refused.summary == "Couldn't set the signature. \(GamError.Kind.unknown.remediation)")
        #expect(refused.detail?.contains("Requested client not authorized") == true)
        #expect(backups.runs().first?.run?.entries == [.init(email: "alice@example.com", previous: "Best,<br>Alice", set: "Alice Anders")])
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

    /// GamGUI's `test_a_run_keeps_the_old_signature_before_it_writes` and
    /// `test_a_run_s_old_signature_goes_back_and_what_it_replaces_is_kept`: the signature replaced is read exactly and kept
    /// before the write; the kept run is listed, and its Put Back sets it again, keeping what it replaces in turn.
    @Test func aReplacedSignatureIsKeptAndPutBack() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        await changes.preview(person: alice, template: "{name}", current: nil)
        await changes.confirm(try pending(), confirmed)
        guard case .done(let done) = changes.state, let keptRun = done.keptRun else { Issue.record("\(changes.state)"); return }
        await changes.loadKept()
        let first = try #require(changes.kept?.first?.run)
        #expect(changes.kept?.count == 1 && first.id == keptRun && first.domain == "example.com")
        #expect(first.what == "Set signature for alice@example.com")
        #expect(first.entries == [.init(email: "alice@example.com", previous: "Best,<br>Alice", set: "Alice Anders")])

        await changes.previewPutBack(keptRun)
        let putBack = try pending()
        #expect(putBack.isPutBack && putBack.isScoped && putBack.people.map(\.primaryEmail) == ["alice@example.com"])
        #expect(putBack.title == "Put back the signatures \u{201C}Set signature for alice@example.com\u{201D} replaced: 1 person.")
        #expect(putBack.body == "Best,<br>Alice" && putBack.confirmLabel == "Put Back 1 Signature")
        #expect(putBack.preview.needsConfirmClick && putBack.preview.typedCountAbove == Guard.countConfirmAbove)
        await changes.confirm(putBack, confirmed)
        guard case .done(let restored) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(restored.message == "Put back 1 of 1 signature." && !restored.partial)
        #expect(writes().last == ["user", "alice@example.com", "signature", "Best,<br>Alice", "html"])
        await access.load("alice@example.com")
        #expect(try access.lists(for: "alice@example.com")?.signature.get() == "Best,<br>Alice")
        // So a Put Back can be put back too.
        let newest = try #require(backups.runs().first?.run)
        #expect(newest.id == restored.keptRun && newest.what == "Put back of Set signature for alice@example.com")
        #expect(newest.entries == [.init(email: "alice@example.com", previous: "Alice Anders", set: "Best,<br>Alice")])
    }

    /// GamGUI's `test_someone_changed_since_that_run_is_left_as_they_are`: a signature that isn't what that run left there
    /// is someone's change since, left as it is and said; nothing is written for them.
    @Test func aSignatureChangedSinceThatRunIsLeftAsItIs() async throws {
        try await connect()
        let alice = try user("alice@example.com")
        await changes.preview(person: alice, template: "<b>{name}</b>", current: nil)
        await changes.confirm(try pending(), confirmed)
        guard case .done(let done) = changes.state, let first = done.keptRun else { Issue.record("\(changes.state)"); return }
        await changes.preview(person: alice, template: "<i>changed later</i>", current: nil)
        await changes.confirm(try pending(), confirmed)
        let written = writes().count
        await changes.previewPutBack(first)
        await changes.confirm(try pending(), confirmed)
        guard case .done(let result) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(result.message == "Put back 0 of 1 signature. 1 was left as it is, changed since that run: alice@example.com.")
        #expect(result.partial && result.failedCount == 0 && result.retry == nil && result.keptRun == nil)
        #expect(writes().count == written)
        await access.load("alice@example.com")
        #expect(try access.lists(for: "alice@example.com")?.signature.get() == "<i>changed later</i>")
    }

    /// GamGUI's `test_an_empty_old_signature_goes_back_as_empty`, and `put_back_plan`: an old signature GAM would read as a
    /// file to load, or change on the way in, is left out and named, never sent.
    @Test func whoCantGoBackExactlyIsLeftOutAndNamed() async throws {
        try await connect()
        let id = "0000000000002-0000f00d"
        try write(run: id, entries: [("carol@example.com", "", "Carol Clark<br>Operations"),
                                     ("alice@example.com", " HTML_File ", "Best,<br>Alice"),
                                     ("dana@example.com", "line\r\nbreak", "")])
        await changes.previewPutBack(id)
        let putBack = try pending()
        #expect(putBack.people.map(\.primaryEmail) == ["carol@example.com"])
        #expect(putBack.putBack?.leftOut == [
            .init(email: "alice@example.com", why: "GAM would read it as a file to load, so it's left for you to put back by hand"),
            .init(email: "dana@example.com", why: "GAM would change it on the way in, so it can't go back exactly")])
        #expect(putBack.notes.count == 1 && putBack.notes[0].hasPrefix("Left out 2, each put back only by hand: alice@example.com ("))
        await changes.confirm(putBack, confirmed)
        #expect(writes() == [["user", "carol@example.com", "signature", "", "html"]])
        await access.load("carol@example.com")
        #expect(try access.lists(for: "carol@example.com")?.signature.get() == "")
    }

    /// GamGUI's `test_a_run_that_cant_be_read_or_doesnt_exist_puts_nothing_back`, and this app's domain check: a run of
    /// another domain, one that isn't whole, and one that isn't there put nothing back.
    @Test func aRunThatCantBePutBackPutsNothingBack() async throws {
        try await connect()
        try write(run: "0000000000003-0000beef", domain: "example.org", entries: [("alice@example.com", "Old", "Best,<br>Alice")])
        await changes.previewPutBack("0000000000003-0000beef")
        #expect(try problem().summary == "That run was on example.org, so it's put back only there: connect example.org on Setup first.")
        for bad in ["nope", "../x", ""] {
            await changes.previewPutBack(bad)
            #expect(try problem().summary == "That run can't be put back: it isn't a kept run.")
        }
        try Data("{not json\n".utf8).write(to: scratch.appending(path: "signature-backups/0000000000004-0000cafe.jsonl"))
        await changes.previewPutBack("0000000000004-0000cafe")
        #expect(try problem().summary == "That run can't be put back: it isn't whole.")
        await changes.loadKept()
        #expect(changes.kept?.map(\.id) == ["0000000000004-0000cafe", "0000000000003-0000beef"])
        #expect(writes().isEmpty)
    }

    /// Review of Phase A: putting back the oldest of five kept runs deleted it as the Put Back began, and with it the old
    /// signature of whoever the Put Back left out. The run put back outlives its Put Back.
    @Test func aPutBackKeepsTheRunItRestores() async throws {
        try await connect()
        for index in 2...SignatureBackupStore.keptRuns {
            try write(run: "000000000000\(index)-0000000\(index)", entries: [("dana@example.com", "run \(index)", "")])
        }
        let oldest = "0000000000001-00000001"
        try write(run: oldest, entries: [("alice@example.com", "Old A", "Best,<br>Alice"), ("carol@example.com", "Carol\\nClark", "x")])
        await changes.previewPutBack(oldest)
        let putBack = try pending()
        #expect(putBack.people.map(\.primaryEmail) == ["alice@example.com"] && putBack.putBack?.leftOut.count == 1)
        await changes.confirm(putBack, confirmed)
        guard case .done(let done) = changes.state, done.keptRun != nil else { Issue.record("\(changes.state)"); return }
        #expect(writes() == [["user", "alice@example.com", "signature", "Old A", "html"]])
        #expect(try backups.load(oldest).entries.map(\.email) == ["alice@example.com", "carol@example.com"],
                "carol's old signature, left out, is still there to put back by hand")
    }

    /// Many people's Put Back asks for the count typed, as any run of many signatures (D5).
    @Test func aPutBackOfManyWantsTheCountTyped() async throws {
        try await connect()
        changes.typedCountAbove = 1
        try write(run: "0000000000005-0000d00d", entries: [("alice@example.com", "Old A", "Best,<br>Alice"),
                                                         ("carol@example.com", "Old C", "Carol Clark<br>Operations")])
        await changes.previewPutBack("0000000000005-0000d00d")
        let putBack = try pending()
        #expect(putBack.preview.decision.requiresTypedCount)
        await changes.confirm(putBack, confirmed)
        #expect(changes.typedProblem == SignatureChanges.typedCountRefusal(2) && writes().isEmpty)
        await changes.confirm(putBack, OperatorConfirmation(confirmed: true, typedCount: "2"))
        #expect(writes().map { $0[3] } == ["Old A", "Old C"])
    }

    /// A kept run's file as the store writes one, in the folder this suite's store keeps in.
    private func write(run id: String, domain: String = "example.com", entries: [(String, String, String)]) throws {
        let folder = scratch.appending(path: "signature-backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lines = [JSONValue.dumps(.object(["run": .string(id), "when": .number("1.0"), "what": .string("a test run"),
                                              "domain": .string(domain)]))]
        for (email, previous, set) in entries {
            lines.append(JSONValue.dumps(.object(["email": .string(email), "previous": .string(previous), "set": .string(set)])))
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: "\(id).jsonl"))
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

    /// GamGUI failure-log 2026-09-25: what was read on one tenant is never held for another. A run kept on example.com
    /// isn't previewed on example.org after a switch.
    @Test func putBackAfterADomainSwitchIsRefused() async throws {
        try await connect()
        await changes.preview(person: try user("alice@example.com"), template: "{name}", current: nil)
        await changes.confirm(try pending(), confirmed)
        guard case .done(let done) = changes.state, let keptRun = done.keptRun else { Issue.record("\(changes.state)"); return }
        try await connect("example.org", admin: "admin@example.org")
        #expect(setup.active == Domain("example.org"))
        await changes.previewPutBack(keptRun)
        #expect(try problem().summary == "That run was on example.com, so it's put back only there: connect example.com on Setup first.")
        #expect(writes().count == 1)
    }
}
