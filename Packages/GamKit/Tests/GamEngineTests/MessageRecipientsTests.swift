import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// Who an email went to, from the sender's own copy: the strict mock answers the recipients read as GAM 7.48.30's
/// `printShowMessagesThreads` writes it (read from its source), and `MessageRecipients` reads every address in its
/// To, Cc and Bcc headers, never dropping one silently. The fixture: carol sent the phish (her Sent copy has the Bcc
/// list, inside and outside the tenant); alice received it (inbox and Spam); carol has no copy of alice's other email.
@Suite("Message recipients")
struct MessageRecipientsTests {
    let mock = GamRunner(binary: Fixtures.mockGam)
    static let phish = try! GamCommands.MessageID(validating: "<CAPh1sh+Invite=0001@mail.example.com>")
    static let header = "User,threadId,id,Date,Subject,From,Reply-To,To,Delivered-To,Content-Type,Message-ID,LabelsCount,Labels"

    private func withState(_ body: (URL) async throws -> Void) async throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-rcpt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try await body(state)
    }

    private func mark(_ state: URL, _ folder: String, _ name: String) throws {
        try FileManager.default.createDirectory(at: state.appending(path: folder), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "\(folder)/\(name)").path, contents: Data())
    }

    private func read(_ sender: String, argv: [String]? = nil, state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        let result = try await mock.runRaw(argv ?? GamCommands.searchMessages(email: sender, query: Self.phish.anyCopyQuery).argv,
                                           configDirectory: config, extraEnvironment: environment)
        // Without the fresh config folder's first-run banner, as the authenticated runner hands it on.
        let stdout = PythonText.lines(result.stdout).filter { !$0.hasPrefix("Created: ") && !$0.hasPrefix("Config File: ") }
            .map { $0 + "\n" }.joined()
        return GamResult(exitCode: result.exitCode, stdout: stdout, stderr: result.stderr,
                         stdoutTruncated: result.stdoutTruncated, stderrTruncated: result.stderrTruncated)
    }

    /// The sender's copy: GAM's columns (its default headers, then the others sorted), each header under its own name,
    /// Date the message's own time, the labels; read into every recipient, in header order, inside and out.
    @Test func theSendersCopyListsEveryRecipient() async throws {
        let result = try await read("carol@example.com")
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(PythonText.lines(result.stdout) == [
            Self.header + ",Bcc,MIME-Version",
            "carol@example.com,19a0c0ffee000003,19a0c0ffee000003,2026-10-19T13:12:03+00:00,You're invited: Fall party,"
                + "Carol Clark <carol@example.com>,,carol@example.com,,\"multipart/alternative; boundary=\"\"0000000000001234\"\"\","
                + "<CAPh1sh+Invite=0001@mail.example.com>,1,SENT,\"alice@example.com, \"\"Brown, Bob\"\" <bob@example.com>, Dana Davis "
                + "<DANA@example.com>, \"\"Pat Partner\"\" <pat@partner.example>, guest@example.org (Guest), team@example.net, "
                + "ops@alias.example.net, undisclosed-recipients:;\",1.0",
        ])
        let copy = try #require(try MessageRecipients.read(result, argv: []))
        #expect(copy.addresses == ["carol@example.com", "alice@example.com", "bob@example.com", "DANA@example.com",
                                   "pat@partner.example", "guest@example.org", "team@example.net", "ops@alias.example.net"])
        #expect(copy.unreadable.isEmpty && copy.hasBcc && copy.labels == ["SENT"])
        #expect(copy.subject == "You're invited: Fall party" && copy.date == "2026-10-19T13:12:03+00:00"
                && copy.from == "Carol Clark <carol@example.com>")
    }

    /// A recipient's copies (with Spam: includespamtrash) carry no Bcc; a copy in Trash is still found; a purged one,
    /// or none, is GAM's header alone and exit 60, read as no copy.
    @Test func aCopyFoundOrGone() async throws {
        let alice = try #require(try MessageRecipients.read(try await read("alice@example.com"), argv: []))
        #expect(alice.addresses == ["carol@example.com"] && !alice.hasBcc && alice.labels == ["INBOX", "UNREAD", "SPAM"])
        let other = try GamCommands.MessageID(validating: "<CAOther+Note=0002@mail.example.com>")
        let none = try await read("", argv: GamCommands.searchMessages(email: "carol@example.com", query: other.anyCopyQuery).argv)
        #expect(none.exitCode == 60 && PythonText.lines(none.stdout) == [Self.header])
        #expect(try MessageRecipients.read(none, argv: []) == nil)
        try await withState { state in
            try mark(state, "trashed", "19a0c0ffee000003")
            #expect(try MessageRecipients.read(try await read("carol@example.com", state: state), argv: [])?.labels == ["SENT", "TRASH"])
            try mark(state, "deleted", "19a0c0ffee000003")
            let purged = try await read("carol@example.com", state: state)
            let gone = try MessageRecipients.read(purged, argv: [])
            #expect(purged.exitCode == 60 && gone == nil)
        }
    }

    /// A sender GAM can't read as: not a user (the token, exit 50), Gmail off (the labels, exit 73); the header is still
    /// printed, and the read fails with GAM's words.
    @Test func aSenderGamCantReadFails() async throws {
        let nobody = try await read("nobody@example.com")
        #expect(nobody.exitCode == 50 && nobody.stderr == "User: nobody@example.com, User Print Failed: invalid_grant: Invalid email or User ID\n")
        #expect(PythonText.lines(nobody.stdout) == [Self.header])
        #expect(throws: GamError.self) { try MessageRecipients.read(nobody, argv: []) }
        try await withState { state in
            try mark(state, "nogmail", "carol@example.com")
            let off = try await read("carol@example.com", state: state)
            #expect(off.exitCode == 73 && off.stderr == "User: carol@example.com, Gmail Service/App not enabled\n")
            #expect(throws: GamError.self) { try MessageRecipients.read(off, argv: []) }
        }
    }

    /// Any other shape of an rfc822msgid: search is refused rather than guessed at, and a bad count is GAM's usage error.
    @Test func otherSearchesAreNotModelled() async throws {
        let base = ["user", "carol@example.com", "print", "messages", "query", Self.phish.anyCopyQuery]
        for argv in [base, base + ["includespamtrash", "headers", "all", "showlabels"],
                     base + ["includespamtrash", "headers", "from", "showlabels", "showdate"],
                     base + ["includespamtrash", "headers", "all", "showlabels", "showdate", "showbody"],
                     ["user", "carol@example.com", "print", "messages", "query", "rfc822msgid:a b@c", "includespamtrash",
                      "headers", "all", "showlabels", "showdate"]] {
            let refused = try await read("", argv: argv)
            #expect(refused.exitCode == 2 && refused.stderr.contains("isn't modelled"), "\(argv): \(refused.stderr)")
        }
        let bad = try await read("", argv: base + ["max_to_print", "fifty"])
        #expect(bad.exitCode == 2 && bad.stderr.hasSuffix("ERROR: Invalid argument: Expected <integer x>=0>\n"))
    }

    /// RFC 5322 address lists as GAM prints them decoded: a display name (quoted or not, with a comma or an @), a
    /// comment and a group's name are never the address; a piece with an @ but no address is kept as unreadable.
    @Test func everyAddressInAHeader() {
        let cases: [(String, [String], [String])] = [
            ("a@example.com", ["a@example.com"], []),
            ("\"Doe, Jane\" <jane@example.org>, b@example.com", ["jane@example.org", "b@example.com"], []),
            ("Doe, Jane <jane@example.org>", ["jane@example.org"], []),   // a decoded name's comma
            ("\"evil@example.org\" <real@example.org>", ["real@example.org"], []),
            ("x@example.org (was y@example.org)", ["x@example.org"], []),
            ("Team: a@example.com, b@example.net;, undisclosed-recipients:;", ["a@example.com", "b@example.net"], []),
            ("<a@example.com>,,<b@example.com> ", ["a@example.com", "b@example.com"], []),
            ("\"John Doe\"@example.com", [], ["\"John Doe\"@example.com"]),
            ("alice@example.com <Alice@Example.com>", ["Alice@Example.com"], []),   // Outlook's name is the address
            ("Alice <a@x.example>; Bob <b@y.example>", ["a@x.example", "b@y.example"], []),
            ("a@x.example; b@y.example", ["a@x.example", "b@y.example"], []),
            ("Team: a@x.example; b@y.example", ["a@x.example", "b@y.example"], []),
            // Two addresses in one piece: the sender wrote it, so it's kept whole as unreadable, never cut to one.
            ("a@x.example b@y.example", [], ["a@x.example b@y.example"]),
            ("a@x.example\n b@y.example", [], ["a@x.example\n b@y.example"]),
            ("Alice <a@x.example> Bob <b@y.example>", [], ["Alice <a@x.example> Bob <b@y.example>"]),
            ("<a@x.example> <b@y.example>", [], ["<a@x.example> <b@y.example>"]),
            ("a@x.example <b@y.example>", [], ["a@x.example <b@y.example>"]),
            ("Open <a@x.example", ["a@x.example"], []),
            ("Bad <not an address@example.com>", [], ["Bad <not an address@example.com>"]),
            ("", [], []),
        ]
        for (header, addresses, unreadable) in cases {
            let read = MessageRecipients.addresses(in: header)
            #expect(read.addresses == addresses && read.unreadable == unreadable, "\(header): \(read)")
        }
    }

    /// GAM names a repeat "To 1"; a mailer may write "CC" or "BCC". Each is read, an address once, case aside; never
    /// Delivered-To.
    @Test func everyRecipientHeaderByItsName() throws {
        let csv = "User,threadId,id,Date,Subject,To,To 1,CC,BCC,Delivered-To,Labels\n"
            + "s@example.com,t,i,d,Hi,a@example.com,b@example.com,\"A@EXAMPLE.COM, c@example.com\",x@example.org,s@example.com,SENT\n"
        let copy = try #require(try MessageRecipients.read(GamResult(exitCode: 0, stdout: csv, stderr: "", stdoutTruncated: false,
                                                                     stderrTruncated: false), argv: []))
        #expect(copy.addresses == ["a@example.com", "b@example.com", "c@example.com", "x@example.org"] && copy.hasBcc)
        #expect(MessageRecipients.isHeader("To 12", "to") && !MessageRecipients.isHeader("To x", "to")
                && !MessageRecipients.isHeader("Tox", "to") && !MessageRecipients.isHeader("To ", "to"))
        #expect(throws: MessageCopies.Incomplete.self) {
            try MessageRecipients.read(GamResult(exitCode: 0, stdout: csv, stderr: "", stdoutTruncated: true, stderrTruncated: false), argv: [])
        }
        // No row with 0 isn't "no copy": a refused token GAM skips without a word leaves just that (R6).
        #expect(throws: MessageCopies.Incomplete.self) {
            try MessageRecipients.read(GamResult(exitCode: 0, stdout: "User,threadId,id\n", stderr: "", stdoutTruncated: false,
                                                 stderrTruncated: false), argv: [])
        }
    }

    /// Copies of one ID that aren't the same email are each named, so the operator sees the ID matched more than one.
    @Test func everyDistinctHeading() throws {
        let csv = "User,threadId,id,Subject,From,To,Labels\n"
            + "s@example.com,t,1,Invite,Carol <c@example.com>,a@example.com,INBOX\n"
            + "s@example.com,t,2,Invite,Carol <c@example.com>,a@example.com,SPAM\n"
            + "s@example.com,t,3,Invoice,Billing <b@example.org>,a@example.com,INBOX\n"
        let copy = try #require(try MessageRecipients.read(GamResult(exitCode: 0, stdout: csv, stderr: "", stdoutTruncated: false,
                                                                     stderrTruncated: false), argv: []))
        #expect(copy.headings == [.init(from: "Carol <c@example.com>", subject: "Invite"),
                                  .init(from: "Billing <b@example.org>", subject: "Invoice")])
    }

    /// The tenant's domains are its domains and their aliases, case aside; anything else is outside.
    @Test func insideIsTheTenantsDomains() async throws {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        let result = try await mock.runRaw(GamCommands.printDomains().argv, configDirectory: config, extraEnvironment: Fixtures.mockEnvironment)
        let stdout = PythonText.lines(result.stdout).filter { !$0.hasPrefix("Created: ") && !$0.hasPrefix("Config File: ") }.joined(separator: "\n")
        let domains = try TenantDomains.read(GamResult(exitCode: result.exitCode, stdout: stdout, stderr: result.stderr,
                                                       stdoutTruncated: false, stderrTruncated: false), argv: [])
        #expect(domains.names == ["example.com", "alias.example.net", "example.net"])
        #expect(domains.isInternal("DANA@Example.COM") && domains.isInternal("ops@alias.example.net"))
        #expect(!domains.isInternal("pat@partner.example") && !domains.isInternal("a@sub.example.com") && !domains.isInternal("example.com"))
        #expect(throws: MessageCopies.Incomplete.self) {
            try TenantDomains.read(GamResult(exitCode: 0, stdout: "", stderr: "", stdoutTruncated: false, stderrTruncated: false), argv: [])
        }
        // A domain or alias not yet verified receives no mail for the tenant: its addresses are outside (R4).
        let json = #"[{"domainName": "example.com", "verified": true, "domainAliases": [{"domainAliasName": "new.example", "verified": false}]},"#
            + #" {"domainName": "acquired.example", "verified": false}]"#
        let verified = try TenantDomains.read(GamResult(exitCode: 0, stdout: json, stderr: "", stdoutTruncated: false, stderrTruncated: false), argv: [])
        #expect(verified.names == ["example.com"] && !verified.isInternal("bob@acquired.example") && !verified.isInternal("a@new.example"))
    }
}
