import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// The Phishing screen's model end to end against the strict mock: Find is GAM's dry run (a read that trashes
/// nothing), Trash holds one ChangeCore step per mailbox Find showed copies in, and the confirm runs exactly those
/// commands, once each, audited. The mock's mailboxes: alice has one copy (and one in Spam), carol sent it (Sent only),
/// dana has two, bob (suspended) one; alice has another email too.
@MainActor
@Suite("Phishing changes", .serialized)
final class PhishingChangesTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-phish-\(UUID().uuidString)")
    let vault = Vault(store: MemoryStore())
    let setup: SetupModel
    let executor: Executor
    let changes: PhishingChanges
    let argvLog: URL
    let auditURL: URL
    let state: URL
    static let pasted = "Message-ID: <CAPh1sh+Invite=0001@mail.example.com>"
    static let message = try! GamCommands.MessageID(validating: pasted)

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        argvLog = scratch.appending(path: "argv.log")
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        state = scratch.appending(path: "mock-state")
        let setup = setup
        executor = Executor(runner: runner, audit: AuditLog(url: auditURL), actor: "admin@example.com", tenant: { @MainActor in
            setup.active.map { ($0, setup.generation) }
        }, extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                              "GAM_MOCK_STATE": state.path])
        changes = PhishingChanges(setup: setup, runner: runner, executor: executor)
        changes.environment = ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_STATE": state.path]
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect() async throws {
        let folder = scratch.appending(path: "gamcfg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Data(#"{"decoded_id_token": {"email": "admin@example.com"}}"#.utf8).write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
    }

    /// Every `trash messages` the mock ran, as argv (it logs each as a count then its elements, NUL-separated).
    private func trashCalls() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.count > 3 && $0[2] == "trash" }
    }

    private func search() throws -> PhishingChanges.Search {
        guard case .found(let search) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return search
    }

    private func typed(_ count: String, word: String = "") -> OperatorConfirmation {
        OperatorConfirmation(confirmed: true, typedWord: word, typedCount: count)
    }

    /// Find: GAM's dry run, once, over every active user; each mailbox with its count, the sender's Sent copy and a
    /// Spam copy not among them, and nothing trashed.
    @Test func findShowsWhoHasACopy() async throws {
        try await connect()
        await changes.find(Self.pasted)
        let search = try search()
        #expect(search.message == Self.message)
        #expect(search.copies.mailboxes.map(\.email) == ["alice@example.com", "carol@example.com", "dana@example.com"])
        #expect(search.copies.mailboxes.map(\.finding) == [.copies(1), .none, .copies(2)])
        #expect(search.commandLine == "gam all users trash messages query 'rfc822msgid:CAPh1sh+Invite=0001@mail.example.com -in:sent' "
                + "notquick max_to_trash 1")
        #expect(trashCalls() == [GamCommands.findMessageCopies(Self.message).argv])
        // What the ID matched, as the first mailbox has it: to check it's the phish before trashing it everywhere.
        let sample = try #require(search.sample)
        #expect(sample.mailbox == "alice@example.com" && sample.copy.from == "Carol Clark <carol@example.com>"
                && sample.copy.subject == "You're invited: Fall party" && search.sampleProblem == nil)
        #expect(!FileManager.default.fileExists(atPath: state.appending(path: "trashed").path), "a dry run trashes nothing")
        #expect(AuditLog.records(at: auditURL).isEmpty, "a read isn't audited as a change")
    }

    /// A Message-ID that isn't one never reaches GAM.
    @Test func aBadMessageIDIsRefusedBeforeGam() async throws {
        try await connect()
        await changes.find("<a@b in:inbox>")
        guard case .problem(let problem) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(problem.summary == "A Message-ID has no spaces: paste only its value, like <…@mail.example.com>.")
        #expect(trashCalls().isEmpty)
    }

    /// Trash holds one destructive step per mailbox with copies, capped at the copies Find saw, and asks for the number
    /// of mailboxes typed. Confirmed, it runs exactly those commands, once each, audited per mailbox; Find then shows
    /// none left, and the email stays in carol's Sent and alice's Spam.
    @Test func theRunExecutesExactlyWhatWasPreviewed() async throws {
        try await connect()
        await changes.find(Self.pasted)
        await changes.previewTrash()
        let pending = try #require(changes.pending, "\(changes.refusal ?? "")")
        let held = pending.preview.steps.map(\.shownArgv)
        #expect(held == [try GamCommands.trashMessage(email: "alice@example.com", Self.message, copies: 1).argv,
                         try GamCommands.trashMessage(email: "dana@example.com", Self.message, copies: 2).argv])
        #expect(pending.preview.steps.map(\.target) == ["alice@example.com", "dana@example.com"])
        #expect(pending.preview.decision.maxRisk == .destructive && pending.preview.decision.requiresTypedCount && !pending.needsWord)
        #expect(pending.preview.steps.map(\.summary) == ["Move the copy in alice@example.com's mailbox to its Trash.",
                                                         "Move the 2 copies in dana@example.com's mailbox to its Trash."])
        #expect(trashCalls().count == 1, "a preview runs nothing")

        await changes.confirm(pending, typed("2"))
        let run = try #require(changes.run)
        #expect(changes.refusal == nil, "\(changes.refusal ?? "")")
        #expect(run.ended && run.trashed == 2 && run.summary == "Trashed from 2 of 2 mailboxes.", "\(run.results)")
        #expect(Array(trashCalls().dropFirst()) == held, "exactly the held commands, once each")
        let ends = AuditLog.records(at: auditURL).reversed().filter { $0["extra"]?.object?["phase"]?.string == "end" }
        #expect(ends.map { $0["target"]?.string } == ["alice@example.com", "dana@example.com"])
        #expect(ends.allSatisfy { $0["action"]?.string == "trashMessage" && $0["ok"]?.bool == true })
        #expect(changes.pending == nil, "a held trash is spent by its run")
        if case .found = changes.state { Issue.record("the search from before the run is still shown") }

        await changes.find(Self.pasted)
        #expect(try search().copies.withCopies.isEmpty)
        let trashed = try FileManager.default.contentsOfDirectory(atPath: state.appending(path: "trashed").path).sorted()
        #expect(trashed == ["19a0c0ffee000001", "19a0c0ffee000004", "19a0c0ffee000005"], "neither the Sent nor the Spam copy")
    }

    /// The confirm the executor asks for, whatever a screen sends: the number of mailboxes, typed and current.
    @Test func aRunNeedsTheMailboxCountTyped() async throws {
        try await connect()
        await changes.find(Self.pasted)
        for confirmation in [OperatorConfirmation(confirmed: true), typed("3"), typed("two"), OperatorConfirmation(typedCount: "2")] {
            await changes.previewTrash()
            let pending = try #require(changes.pending)
            await changes.confirm(pending, confirmation)
            #expect(changes.refusal != nil && changes.run == nil, "\(confirmation)")
        }
        #expect(trashCalls().count == 1, "only Find ran")
    }

    /// A mailbox whose copy went since Find (its owner deleted it) is GAM's "No Messages matched", said for that
    /// mailbox; the run goes on to the rest.
    @Test func aCopyGoneSinceFindIsReportedAndTheRestRun() async throws {
        try await connect()
        await changes.find(Self.pasted)
        await changes.previewTrash()
        let pending = try #require(changes.pending)
        try FileManager.default.createDirectory(at: state.appending(path: "trashed"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "trashed/19a0c0ffee000001").path, contents: Data())
        await changes.confirm(pending, typed("2"))
        let run = try #require(changes.run)
        guard case .failed(let message, _)? = run.results.first else { Issue.record("\(run.results)"); return }
        #expect(message.hasSuffix("User: alice@example.com, Messages: 0, Not Trashed: No Messages matched"))
        #expect(run.results.last??.isSucceeded == true && run.summary == "Trashed from 1 of 2 mailboxes; 1 failed.")
    }

    /// Nothing to trash: no preview is held.
    @Test func noCopiesNoPreview() async throws {
        try await connect()
        await changes.find("<CAOther+Note=0002@mail.example.com>")
        #expect(try search().copies.withCopies.map(\.email) == ["alice@example.com"])
        await changes.find("<nobody-sent-this@mail.example.com>")
        #expect(try search().copies.withCopies.isEmpty)
        await changes.previewTrash()
        #expect(changes.pending == nil && changes.refusal == "No mailbox has a copy to trash.")
    }

    private func recipients() throws -> PhishingChanges.Recipients {
        guard case .read(let recipients) = changes.recipients else { throw NotPreviewing(state: "\(changes.recipients)") }
        return recipients
    }

    /// Who got it, from the sender's own copy: every To, Cc and Bcc, the tenant's domains and aliases inside, the rest
    /// outside; two reads, no write.
    @Test func theSendersCopyListsWhoGotIt() async throws {
        try await connect()
        await changes.listRecipients(sender: " carol@example.com ", message: Self.pasted)
        let listed = try recipients()
        #expect(listed.sender == "carol@example.com" && listed.isSentCopy && !listed.inTrash && listed.copy?.hasBcc == true)
        #expect(listed.outside == ["pat@partner.example", "guest@example.org"])
        #expect(listed.inside == ["carol@example.com", "alice@example.com", "bob@example.com", "DANA@example.com",
                                  "team@example.net", "ops@alias.example.net"])
        #expect(listed.commandLine == "gam user carol@example.com print messages query rfc822msgid:CAPh1sh+Invite=0001@mail.example.com "
                + "includespamtrash max_to_print 50 headers all showlabels showdate")
        #expect(trashCalls().isEmpty && AuditLog.records(at: auditURL).isEmpty, "reads only")
    }

    /// A copy the sender didn't send (they received it) is said to be one, and no copy left is said as such.
    @Test func aReceivedCopyOrNoneIsSaid() async throws {
        try await connect()
        await changes.listRecipients(sender: "alice@example.com", message: Self.pasted)
        let received = try recipients()
        #expect(!received.isSentCopy && received.copy?.hasBcc == false && received.inside == ["carol@example.com"])
        // Find saw copies in mailboxes these headers don't name: the list isn't everyone (review R1).
        await changes.find(Self.pasted)
        #expect(received.unnamed(in: try search()) == ["alice@example.com", "dana@example.com"])
        await changes.listRecipients(sender: "carol@example.com", message: Self.pasted)
        #expect(try recipients().unnamed(in: try search()).isEmpty, "the sender's Bcc names both")
        await changes.listRecipients(sender: "carol@example.com", message: "<CAOther+Note=0002@mail.example.com>")
        let none = try recipients()
        #expect(none.copy == nil && none.inside.isEmpty && none.outside.isEmpty)
    }

    /// A sender that isn't an address, or a Message-ID that isn't one, never reaches GAM; a sender GAM can't read as is
    /// GAM's error in words.
    @Test func aBadSenderIsRefused() async throws {
        try await connect()
        for (sender, message) in [("carol", Self.pasted), ("carol@example.com,dana@example.com", Self.pasted),
                                  ("carol@example.com", "<a b@c>")] {
            await changes.listRecipients(sender: sender, message: message)
            guard case .problem = changes.recipients else { Issue.record("\(sender): \(changes.recipients)"); continue }
        }
        await changes.listRecipients(sender: "nobody@example.com", message: Self.pasted)
        guard case .problem(let problem) = changes.recipients else { Issue.record("\(changes.recipients)"); return }
        #expect(problem.detail?.contains("User: nobody@example.com, User Print Failed: invalid_grant") == true)
    }

    /// The recipients CSV is the list the screen shows, in its order (outside, then inside), with each address's header.
    @Test func theRecipientsCSVIsWhatsShown() async throws {
        try await connect()
        await changes.listRecipients(sender: "carol@example.com", message: Self.pasted)
        let listed = try recipients()
        let rows = PhishingChanges.recipientsRows(listed)
        #expect(rows.map { $0[0] } == listed.outside + listed.inside)
        #expect(rows == [["pat@partner.example", "outside", "Bcc"], ["guest@example.org", "outside", "Bcc"],
                         ["carol@example.com", "inside", "To"], ["alice@example.com", "inside", "Bcc"],
                         ["bob@example.com", "inside", "Bcc"], ["DANA@example.com", "inside", "Bcc"],
                         ["team@example.net", "inside", "Bcc"], ["ops@alias.example.net", "inside", "Bcc"]])
        #expect(PhishingChanges.recipientsColumns == ["address", "where", "header"])
        #expect(PhishingChanges.exportName("recipients", on: Date(timeIntervalSince1970: 1_792_400_000)).hasPrefix("phishing-recipients-2026-"))
    }

    /// The copies CSV is every mailbox Find read, as shown; once the trash has run, each one's outcome beside it.
    @Test func theCopiesCSVIsWhatsShownThenWhatRan() async throws {
        try await connect()
        await changes.find(Self.pasted)
        let search = try search()
        #expect(PhishingChanges.copiesRows(search, run: nil) == [["alice@example.com", "copies", "1", ""],
                                                                  ["carol@example.com", "none", "0", ""],
                                                                  ["dana@example.com", "copies", "2", ""]])
        await changes.previewTrash()
        await changes.confirm(try #require(changes.pending), typed("2"))
        let run = try #require(changes.run)
        #expect(PhishingChanges.copiesRows(run.pending.search, run: run) == [["alice@example.com", "copies", "1", "trashed"],
                                                                              ["carol@example.com", "none", "0", ""],
                                                                              ["dana@example.com", "copies", "2", "trashed"]])
    }

    /// A new search drops the held trash: a confirm can't run a preview no longer shown.
    @Test func aNewSearchDropsTheHeldTrash() async throws {
        try await connect()
        await changes.find(Self.pasted)
        await changes.previewTrash()
        let pending = try #require(changes.pending)
        await changes.find(Self.pasted)
        for _ in 0..<100 where await executor.isHeld(pending.id) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await executor.isHeld(pending.id) == false && changes.pending == nil)
        await changes.confirm(pending, typed("2"))
        #expect(changes.run == nil && trashCalls().count == 2, "two searches, no trash")
    }
}
