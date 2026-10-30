@testable import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// The Phishing screen's model end to end against the strict mock: Find is GAM's dry run (a read that trashes
/// nothing) and the read of the copies in Spam, Trash holds one ChangeCore step per mailbox Find showed copies in and one
/// per mailbox with copies in Spam, and the confirm runs exactly those commands, once each, audited. The mock's
/// mailboxes: alice has one copy and one in Spam, carol sent it (Sent only), dana has two, bob (suspended) one; alice has
/// another email too.
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
    static let pasted = "Message-ID: <CAPh1sh+Notice=0001@mail.example.com>"
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

    /// The one email's search shown.
    private func search() throws -> PhishingChanges.Search {
        guard case .found(let found) = changes.state, found.results.count == 1, let search = found.searches.first
        else { throw NotPreviewing(state: "\(changes.state)") }
        return search
    }

    private func found() throws -> PhishingChanges.Found {
        guard case .found(let found) = changes.state else { throw NotPreviewing(state: "\(changes.state)") }
        return found
    }

    private func typed(_ count: String, word: String = "") -> OperatorConfirmation {
        OperatorConfirmation(confirmed: true, typedWord: word, typedCount: count)
    }

    /// Find: GAM's dry run, once, over every active user, each mailbox with its count (the sender's Sent copy and the
    /// Spam copy not among them), and beside it the copies in Spam, each by its ID; nothing trashed.
    @Test func findShowsWhoHasACopy() async throws {
        try await connect()
        await changes.find(Self.pasted)
        let search = try search()
        #expect(search.message == Self.message)
        #expect(search.copies.mailboxes.map(\.email) == ["admin@example.com", "alice@example.com", "carol@example.com", "dana@example.com"])
        #expect(search.copies.mailboxes.map(\.finding) == [.none, .copies(1), .none, .copies(2)])
        #expect(search.commandLine == "gam all users trash messages query 'rfc822msgid:CAPh1sh+Notice=0001@mail.example.com -in:sent' "
                + "notquick max_to_trash 1")
        #expect(trashCalls() == [GamCommands.findMessageCopies(Self.message).argv])
        let spam = try #require(search.spam, "\(search.spamProblem ?? "")")
        #expect(spam.mailboxes == [.init(email: "alice@example.com", ids: ["19a0c0ffee000002"])])
        #expect(spam.searched == ["admin@example.com", "alice@example.com", "carol@example.com", "dana@example.com"]
                && spam.unsearched.isEmpty)
        #expect(search.spamCommandLine == "gam all users print messages query 'rfc822msgid:CAPh1sh+Notice=0001@mail.example.com in:spam' "
                + "includespamtrash headers message-id showlabels")
        #expect(search.mailboxesWithCopies == ["alice@example.com", "dana@example.com"])
        // What the ID matched, as the first mailbox has it: to check it's the phish before trashing it everywhere.
        let sample = try #require(search.sample)
        #expect(sample.mailbox == "alice@example.com" && sample.copy.from == "Carol Clark <carol@example.com>"
                && sample.copy.subject == "Shared file: Q4 invoices" && search.sampleProblem == nil)
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

    /// Trash holds one destructive step per mailbox with copies, capped at the copies Find saw, then one per mailbox with
    /// copies in Spam, naming exactly those by ID, and asks for the number of steps typed. Confirmed, it runs exactly
    /// those commands, once each, audited per step; Find then shows none left, and the email stays in carol's Sent.
    @Test func theRunExecutesExactlyWhatWasPreviewed() async throws {
        try await connect()
        await changes.find(Self.pasted)
        await changes.previewTrash()
        let pending = try #require(changes.pending, "\(changes.refusal ?? "")")
        let held = pending.preview.steps.map(\.shownArgv)
        #expect(held == [try GamCommands.trashMessage(email: "alice@example.com", Self.message, copies: 1).argv,
                         try GamCommands.trashMessage(email: "dana@example.com", Self.message, copies: 2).argv,
                         try GamCommands.trashMessages(email: "alice@example.com", ids: ["19a0c0ffee000002"]).argv])
        #expect(pending.preview.steps.map(\.target) == ["alice@example.com", "dana@example.com", "alice@example.com"])
        #expect(pending.mailboxes == ["alice@example.com", "dana@example.com"] && pending.typedCount == "3")
        #expect(pending.preview.decision.maxRisk == .destructive && pending.preview.decision.requiresTypedCount && !pending.needsWord)
        #expect(pending.preview.steps.map(\.summary) == ["Move the copy in alice@example.com's mailbox to its Trash.",
                                                         "Move the 2 copies in dana@example.com's mailbox to its Trash.",
                                                         "Move the copy in alice@example.com's Spam to Trash."])
        #expect(trashCalls().count == 1, "a preview runs nothing")

        await changes.confirm(pending, typed("3"))
        let run = try #require(changes.run)
        #expect(changes.refusal == nil, "\(changes.refusal ?? "")")
        #expect(run.ended && run.trashed == 3 && run.summary == "Trashed from 2 of 2 mailboxes and 1 of 1 Spam folder.",
                "\(run.results)")
        #expect(Array(trashCalls().dropFirst()) == held, "exactly the held commands, once each")
        let ends = AuditLog.records(at: auditURL).reversed().filter { $0["extra"]?.object?["phase"]?.string == "end" }
        #expect(ends.map { $0["target"]?.string } == ["alice@example.com", "dana@example.com", "alice@example.com"])
        #expect(ends.allSatisfy { $0["action"]?.string == "trashMessage" && $0["ok"]?.bool == true })
        #expect(changes.pending == nil, "a held trash is spent by its run")
        if case .found = changes.state { Issue.record("the search from before the run is still shown") }

        await changes.find(Self.pasted)
        #expect(try search().copies.withCopies.isEmpty && search().spam?.mailboxes.isEmpty == true, "a copy now in Trash isn't one")
        let trashed = try FileManager.default.contentsOfDirectory(atPath: state.appending(path: "trashed").path).sorted()
        #expect(trashed == ["19a0c0ffee000001", "19a0c0ffee000002", "19a0c0ffee000004", "19a0c0ffee000005"], "not the Sent copy")
    }

    /// The confirm the executor asks for, whatever a screen sends: the number of steps, typed and current (the mailboxes
    /// alone, 2, isn't it: alice's Spam is a step of its own).
    @Test func aRunNeedsTheStepCountTyped() async throws {
        try await connect()
        await changes.find(Self.pasted)
        for confirmation in [OperatorConfirmation(confirmed: true), typed("2"), typed("4"), typed("three"),
                             OperatorConfirmation(typedCount: "3")] {
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
        await changes.confirm(pending, typed("3"))
        let run = try #require(changes.run)
        guard case .failed(let message, _)? = run.results.first else { Issue.record("\(run.results)"); return }
        #expect(message.hasSuffix("User: alice@example.com, Messages: 0, Not Trashed: No Messages matched"))
        #expect(run.results.dropFirst().allSatisfy { $0?.isSucceeded == true }
                && run.summary == "Trashed from 1 of 2 mailboxes and 1 of 1 Spam folder; 1 failed.")
    }

    /// A copy in Spam gone for good since Find (emptied from Trash) is GAM's "Does not exist" for that ID: that step fails
    /// in GAM's words, the rest run; nothing else is trashed in its place.
    @Test func aSpamCopyGoneSinceFindFailsThatStepAlone() async throws {
        try await connect()
        await changes.find(Self.pasted)
        await changes.previewTrash()
        let pending = try #require(changes.pending)
        try FileManager.default.createDirectory(at: state.appending(path: "deleted"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "deleted/19a0c0ffee000002").path, contents: Data())
        await changes.confirm(pending, typed("3"))
        let run = try #require(changes.run)
        guard case .failed(let message, _)? = run.results.last else { Issue.record("\(run.results)"); return }
        #expect(message.contains("User: alice@example.com, Message: 19a0c0ffee000002, Trash Failed: Does not exist"), "\(message)")
        #expect(run.summary == "Trashed from 2 of 2 mailboxes and 0 of 1 Spam folder; 1 failed.")
        let trashed = try FileManager.default.contentsOfDirectory(atPath: state.appending(path: "trashed").path).sorted()
        #expect(trashed == ["19a0c0ffee000001", "19a0c0ffee000004", "19a0c0ffee000005"])
    }

    /// A mailbox GAM can't read (Gmail off) is unsearched in both reads, never clear, and nothing is held for it.
    @Test func aMailboxGamCantReadIsNeitherClearNorTrashed() async throws {
        try await connect()
        try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "nogmail/alice@example.com").path, contents: Data())
        await changes.find(Self.pasted)
        let search = try search()
        #expect(search.copies.mailboxes.first { $0.email == "alice@example.com" }?.finding == .gmailOff)
        #expect(search.spam?.unsearched == [.init(email: "alice@example.com", why: "Gmail is off")] && search.spam?.mailboxes.isEmpty == true)
        await changes.previewTrash()
        #expect(try #require(changes.pending).trashes == [.init(message: Self.message, email: "dana@example.com", place: .mailbox(copies: 2))])
    }

    /// Every copy in Spam: the sample is read from a Spam copy (to check it's the phish before trashing), and Trash holds
    /// the Spam step alone, by ID.
    @Test func anEmailOnlyInSpamIsCheckedAndTrashedFromThere() async throws {
        try await connect()
        await changes.find("<CASpam+Only=0003@mail.example.com>")
        let search = try search()
        #expect(search.copies.withCopies.isEmpty && search.mailboxesWithCopies == ["dana@example.com"])
        let sample = try #require(search.sample, "\(search.sampleProblem ?? "")")
        #expect(sample.mailbox == "dana@example.com" && sample.copy.subject == "Invoice overdue")
        await changes.previewTrash()
        let pending = try #require(changes.pending)
        #expect(pending.trashes == [.init(message: search.message, email: "dana@example.com", place: .spam(ids: ["19a0c0ffee000008"]))])
        #expect(pending.preview.steps.map(\.summary) == ["Move the copy in dana@example.com's Spam to Trash."])
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
        #expect(listed.commandLine == "gam user carol@example.com print messages query rfc822msgid:CAPh1sh+Notice=0001@mail.example.com "
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
        #expect(PhishingChanges.copiesColumns == ["mailbox", "found", "copies", "in spam", "trash"])
        #expect(PhishingChanges.copiesRows(search, run: nil) == [["admin@example.com", "none", "0", "0", ""],
                                                                  ["alice@example.com", "copies", "1", "1", ""],
                                                                  ["carol@example.com", "none", "0", "0", ""],
                                                                  ["dana@example.com", "copies", "2", "0", ""]])
        await changes.previewTrash()
        await changes.confirm(try #require(changes.pending), typed("3"))
        let run = try #require(changes.run)
        #expect(PhishingChanges.copiesRows(try #require(run.pending.search(of: search.message)), run: run) == [
            ["admin@example.com", "none", "0", "0", ""],
            ["alice@example.com", "copies", "1", "1", "trashed; spam: trashed"],
            ["carol@example.com", "none", "0", "0", ""],
            ["dana@example.com", "copies", "2", "0", "trashed"],
        ])
    }

    static let other = "<CAOther+Note=0002@mail.example.com>", nobody = "<nobody-sent-this@mail.example.com>"

    /// Pull All (D12): several Message-IDs, one per line, each searched as one is (its dry run and its Spam read), a
    /// repeat once. Only the emails some mailbox has are held, every step of every one in one preview, the number of
    /// steps typed once; confirmed, each runs exactly as held, audited, and Find shows none left.
    @Test func pullAllHoldsEveryEmailSomeoneHasInOnePreview() async throws {
        try await connect()
        await changes.find([Self.pasted, Self.other, Self.nobody, "<CAPh1sh+Notice=0001@mail.example.com>"].joined(separator: "\n"))
        let found = try found()
        let notice = Self.message, other = try GamCommands.MessageID(validating: Self.other)
        #expect(found.results.map(\.message.id) == [notice.id, other.id, "nobody-sent-this@mail.example.com"], "a repeat once")
        #expect(found.withCopies.map(\.message) == [notice, other] && found.nobodyHas.map(\.message.id) == ["nobody-sent-this@mail.example.com"])
        #expect(found.unsure.isEmpty && found.failed.isEmpty)
        // Searched two at a time, so in either order: one dry run each.
        let dryRuns = try [notice, other, GamCommands.MessageID(validating: Self.nobody)].map { GamCommands.findMessageCopies($0).argv }
        #expect(trashCalls().count == 3 && Set(trashCalls()) == Set(dryRuns), "\(trashCalls())")

        await changes.previewTrash()
        let pending = try #require(changes.pending, "\(changes.refusal ?? "")")
        #expect(pending.trashes == [.init(message: notice, email: "alice@example.com", place: .mailbox(copies: 1)),
                                    .init(message: notice, email: "dana@example.com", place: .mailbox(copies: 2)),
                                    .init(message: notice, email: "alice@example.com", place: .spam(ids: ["19a0c0ffee000002"])),
                                    .init(message: other, email: "alice@example.com", place: .mailbox(copies: 1))])
        #expect(pending.messages == [notice, other] && pending.mailboxes == ["alice@example.com", "dana@example.com"])
        #expect(pending.typedCount == "4" && !pending.needsWord && pending.preview.decision.requiresTypedCount)
        #expect(pending.preview.steps.map(\.summary) == [
            "Move the copy of <CAPh1sh+Notice=0001@mail.example.com> in alice@example.com's mailbox to its Trash.",
            "Move the 2 copies of <CAPh1sh+Notice=0001@mail.example.com> in dana@example.com's mailbox to its Trash.",
            "Move the copy of <CAPh1sh+Notice=0001@mail.example.com> in alice@example.com's Spam to Trash.",
            "Move the copy of <CAOther+Note=0002@mail.example.com> in alice@example.com's mailbox to its Trash."])
        let held = pending.preview.steps.map(\.shownArgv)
        #expect(held == [try GamCommands.trashMessage(email: "alice@example.com", notice, copies: 1).argv,
                         try GamCommands.trashMessage(email: "dana@example.com", notice, copies: 2).argv,
                         try GamCommands.trashMessages(email: "alice@example.com", ids: ["19a0c0ffee000002"]).argv,
                         try GamCommands.trashMessage(email: "alice@example.com", other, copies: 1).argv])

        await changes.confirm(pending, typed("4"))
        let run = try #require(changes.run, "\(changes.refusal ?? "")")
        #expect(run.ended && run.trashed == 4 && run.summary == "Trashed 4 of 4 steps for 2 emails.", "\(run.results)")
        #expect(Array(trashCalls().dropFirst(3)) == held, "exactly the held commands, once each")
        let ends = AuditLog.records(at: auditURL).reversed().filter { $0["extra"]?.object?["phase"]?.string == "end" }
        #expect(ends.count == 4 && ends.allSatisfy { $0["action"]?.string == "trashMessage" && $0["ok"]?.bool == true })
        #expect(PhishingChanges.allCopiesRows(found.results, run: run).map { $0[0] + " " + $0[1] + " " + $0[5] } == [
            "CAPh1sh+Notice=0001@mail.example.com admin@example.com ",
            "CAPh1sh+Notice=0001@mail.example.com alice@example.com trashed; spam: trashed",
            "CAPh1sh+Notice=0001@mail.example.com carol@example.com ",
            "CAPh1sh+Notice=0001@mail.example.com dana@example.com trashed",
            "CAOther+Note=0002@mail.example.com admin@example.com ",
            "CAOther+Note=0002@mail.example.com alice@example.com trashed",
            "CAOther+Note=0002@mail.example.com carol@example.com ",
            "CAOther+Note=0002@mail.example.com dana@example.com ",
            "nobody-sent-this@mail.example.com admin@example.com ",
            "nobody-sent-this@mail.example.com alice@example.com ",
            "nobody-sent-this@mail.example.com carol@example.com ",
            "nobody-sent-this@mail.example.com dana@example.com ",
        ])
        #expect(PhishingChanges.allCopiesColumns == ["message_id", "mailbox", "found", "copies", "in spam", "trash"])

        await changes.find([Self.pasted, Self.other].joined(separator: "\n"))
        let again = try self.found()
        #expect(again.withCopies.isEmpty && again.nobodyHas.count == 2, "none left, the Sent copy aside")
    }

    /// Several Message-IDs are checked line by line before GAM: one that isn't is refused with its line, and more than a
    /// hundred at once are refused. Commas separate them too (no Message-ID holds one); the header line is taken.
    @Test func pullAllChecksEveryLineBeforeGam() async throws {
        try await connect()
        await changes.find("<CAPh1sh+Notice=0001@mail.example.com>\n<a b@c>")
        guard case .problem(let problem) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(problem.summary == "Line 2: A Message-ID has no spaces: paste only its value, like <…@mail.example.com>.")
        await changes.find((1...101).map { "<n\($0)@mail.example.com>" }.joined(separator: "\n"))
        guard case .problem(let many) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(many.summary == "At most 100 Message-IDs at once: find the rest after these.")
        #expect(trashCalls().isEmpty, "nothing reached GAM")
        #expect(try PhishingChanges.messages("Message-ID: <a@b.c>, <d@e.f>\n\n  <a@b.c>  ").map(\.id) == ["a@b.c", "d@e.f"])
    }

    /// An email no mailbox has a copy of while a mailbox couldn't be searched (Gmail off) is unsure, never "nobody has it";
    /// an email that couldn't be searched at all is a CSV row of its own.
    @Test func pullAllNeverCallsAnUnsearchedEmailClear() async throws {
        try await connect()
        var kept: [[String]] = []
        changes.keepNobodyHas = { domain, ids, _ in kept.append([domain] + ids) }
        try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "nogmail/alice@example.com").path, contents: Data())
        await changes.find([Self.pasted, Self.other].joined(separator: "\n"))
        let found = try found()
        #expect(found.withCopies.map(\.message) == [Self.message] && found.unsure.map(\.message.id) == ["CAOther+Note=0002@mail.example.com"])
        #expect(found.nobodyHas.isEmpty)
        #expect(kept.isEmpty, "an unsure email is never kept as nobody having it")
        let failed = try GamCommands.MessageID(validating: "<gone@mail.example.com>")
        let rows = PhishingChanges.allCopiesRows([(failed, .failure(PhishingChanges.Problem(summary: "GAM stopped.", detail: nil)))], run: nil)
        #expect(rows == [["gone@mail.example.com", "", "not searched: GAM stopped.", "", "", ""]])
    }

    /// A tenant switch (here a credential import) or Stop during a Pull All: the emails being searched finish, no more
    /// start, and nothing is shown for it (review of 2026-10-23: all eight went on, unseen, against the tenant left).
    @Test func pullAllStopsStartingSearchesOnASwitchOrStop() async throws {
        try await connect()
        let ids = (1...8).map { "<n\($0)@mail.example.com>" }.joined(separator: "\n")
        let switched = Task { await changes.find(ids) }
        while !changes.isFinding { await Task.yield() }
        await setup.importFolder(scratch.appending(path: "gamcfg"), as: "example.com")
        let atSwitch = trashCalls().count
        await switched.value
        #expect(trashCalls().count <= atSwitch + PhishingChanges.searchedAtOnce, "\(trashCalls().count) dry runs, \(atSwitch) at the switch")

        try await connect()
        let before = trashCalls().count
        let stopped = Task { await changes.find(ids) }
        while !changes.isFinding { await Task.yield() }
        changes.stopFinding()
        await stopped.value
        #expect(trashCalls().count - before <= PhishingChanges.searchedAtOnce && !changes.isFinding)
        guard case .idle = changes.state else { Issue.record("\(changes.state)"); return }
    }

    /// After a run, Find Again and the CSV cover every email the Find had, the ones not trashed (unsure: a mailbox
    /// couldn't be read) among them, never only those trashed (review of 2026-10-23).
    @Test func pullAllKeepsEveryEmailAfterTheRun() async throws {
        try await connect()
        try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "nogmail/alice@example.com").path, contents: Data())
        await changes.find([Self.pasted, Self.other, Self.nobody].joined(separator: "\n"))
        await changes.previewTrash()
        let pending = try #require(changes.pending)
        #expect(pending.messages == [Self.message] && pending.found.results.count == 3)
        await changes.confirm(pending, typed(pending.typedCount))
        let run = try #require(changes.run)
        #expect(run.pending.found.results.map(\.message.id)
                == ["CAPh1sh+Notice=0001@mail.example.com", "CAOther+Note=0002@mail.example.com", "nobody-sent-this@mail.example.com"])
        #expect(Set(PhishingChanges.allCopiesRows(run.pending.found.results, run: run).map { $0[0] }).count == 3)
    }

    /// A header folded onto two lines is one Message-ID, alone or among others, and the limit counts emails, not repeats.
    @Test func aFoldedHeaderIsOneAndRepeatsDontCount() throws {
        #expect(try PhishingChanges.messages("Message-ID:\n <CAPh1sh+Notice=0001@mail.example.com>").map(\.id)
                == ["CAPh1sh+Notice=0001@mail.example.com"])
        #expect(try PhishingChanges.messages("message-id:\n <a@b.c>\n<d@e.f>").map(\.id) == ["a@b.c", "d@e.f"])
        #expect(try PhishingChanges.messages(Array(repeating: "<a@b.c>", count: 150).joined(separator: "\n")).map(\.id) == ["a@b.c"])
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
        await changes.confirm(pending, typed("3"))
        #expect(changes.run == nil && trashCalls().count == 2, "two searches, no trash")
    }

    /// What the log reader is told (D13), from the records the executor wrote: each email's latest run. A Pull All stopped
    /// part way leaves the email it was in short of its steps and the next with no record at all, which no argv could
    /// show; trashing what Find finds again is the latest run, whole.
    @Test func theAuditShowsEachEmailsLatestRun() async throws {
        try await connect()
        await changes.find([Self.pasted, Self.other].joined(separator: "\n"))
        await changes.previewTrash()
        let pending = try #require(changes.pending, "\(changes.refusal ?? "")")
        // Stop asked as the second step begins: it finishes, the other two never begin.
        let id = pending.preview.id, began = StepCounter()
        await executor.setBeforeEachStep { [executor] in
            if await began.next() == 2 { _ = await executor.stopAfterCurrentStep(id) }
        }
        await changes.confirm(pending, typed("4"))
        #expect(try #require(changes.run).trashed == 2)
        let stopped = PhishingAudit.latestRuns(in: auditURL, on: "example.com")
        #expect(stopped.map(\.messageID) == [Self.message.id], "the other email's step never began")
        #expect(stopped.map { [$0.steps, $0.trashed, $0.failed, $0.mailboxes] } == [[3, 2, 0, 2]])
        #expect(stopped.allSatisfy { $0.searchedEverywhere && $0.by == "admin@example.com" })

        await executor.setBeforeEachStep(nil)
        await changes.find(Self.pasted)
        await changes.previewTrash()
        let rest = try #require(changes.pending, "\(changes.refusal ?? "")")
        #expect(rest.trashes == [.init(message: Self.message, email: "alice@example.com", place: .spam(ids: ["19a0c0ffee000002"]))])
        await changes.confirm(rest, typed("1"))
        let latest = PhishingAudit.latestRuns(in: auditURL, on: "example.com")
        #expect(latest.map { [$0.steps, $0.trashed, $0.failed, $0.mailboxes] } == [[1, 1, 0, 1]] && latest[0].searchedEverywhere)
        #expect(latest[0].at > stopped[0].at)
    }

    /// A step that failed counts as failed, and a Find that couldn't search a mailbox (Gmail off) is said by the run, so
    /// neither reads as done.
    @Test func theAuditSaysAFailedStepAndAnUnsearchedMailbox() async throws {
        try await connect()
        await changes.find(Self.pasted)
        await changes.previewTrash()
        try FileManager.default.createDirectory(at: state.appending(path: "trashed"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "trashed/19a0c0ffee000001").path, contents: Data())
        await changes.confirm(try #require(changes.pending), typed("3"))
        let failed = PhishingAudit.latestRuns(in: auditURL, on: "example.com")
        #expect(failed.map { [$0.steps, $0.trashed, $0.failed] } == [[3, 2, 1]] && failed[0].searchedEverywhere)

        try FileManager.default.removeItem(at: state)
        try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "nogmail/alice@example.com").path, contents: Data())
        await changes.find(Self.pasted)
        #expect(try search().searchedEverywhere == false)
        await changes.previewTrash()
        await changes.confirm(try #require(changes.pending), typed("1"))
        let unsearched = PhishingAudit.latestRuns(in: auditURL, on: "example.com")
        #expect(unsearched.map { [$0.steps, $0.trashed, $0.failed] } == [[1, 1, 0]] && !unsearched[0].searchedEverywhere)
    }

    /// What Find shows nobody has (every mailbox and its Spam searched) is handed on to be kept, with its domain (D14); the
    /// emails someone has are not. Find is a read: nothing reaches the audit log.
    @Test func findHandsOnWhatNobodyHas() async throws {
        try await connect()
        var kept: [[String]] = []
        changes.keepNobodyHas = { domain, ids, _ in kept.append([domain] + ids) }
        await changes.find([Self.pasted, Self.nobody].joined(separator: "\n"))
        #expect(kept == [["example.com", "nobody-sent-this@mail.example.com"]])
        await changes.find(Self.pasted)
        #expect(kept.count == 1, "someone has it")
        #expect(AuditLog.records(at: auditURL).isEmpty)
    }

    /// A trash record from before Phishing named its email (no `message_steps`) is passed over: its argv names the email,
    /// but not how many steps its run held, so it can never show a run whole. A run is its domain's alone: one phish can
    /// reach two tenants the app connects, and trashing it from one leaves the other's copies.
    @Test func aRecordThatCantSayItsRunIsPassedOver() throws {
        let log = AuditLog(url: auditURL), write = try GamCommands.trashMessage(email: "alice@example.com", Self.message, copies: 1)
        let extra: JSONObject = ["preview": .string(UUID().uuidString), "step": .number("0"), "phase": .string("end")]
        try log.record(write.action.rawValue, target: "alice@example.com", argv: write.argv, exitCode: 0, ok: true, actor: "admin@example.com",
                       extra: extra)
        #expect(PhishingAudit.latestRuns(in: auditURL, on: "example.com").isEmpty)
        var named = extra
        for (key, value) in PhishingAudit.about(Self.message, on: "example.com", steps: 1, searchedEverywhere: true) { named[key] = .string(value) }
        try log.record(write.action.rawValue, target: "alice@example.com", argv: write.argv, exitCode: 0, ok: true, actor: "admin@example.com",
                       extra: named)
        #expect(PhishingAudit.latestRuns(in: auditURL, on: "example.com").map { [$0.steps, $0.trashed] } == [[1, 1]])
        #expect(PhishingAudit.latestRuns(in: auditURL, on: "example.org").isEmpty, "another domain's run is its own")
    }
}

/// Counts the steps a run begins, for a test that stops one part way.
private actor StepCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
