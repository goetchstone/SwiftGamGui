import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock runs the Phishing screen's commands the way GAM 7.48.30 runs them (read from its source, not a
/// tenant): the dry run over every active user and one mailbox's trash (`_processMessagesThreads`), and the read of the
/// copies in Spam (printShowMessagesThreads) with one mailbox's trash of them by ID. The fixture
/// mailboxes (`mock_gam/messages.csv`): alice has the phish in her inbox and in Spam, bob (suspended) in his inbox,
/// carol sent it (her Sent copy only), dana has two copies; alice also has another email.
@Suite("Mock phishing")
struct MockPhishingTests {
    let mock = GamRunner(binary: Fixtures.mockGam)
    static let phish = try! GamCommands.MessageID(validating: "<CAPh1sh+Notice=0001@mail.example.com>")
    static let query = "rfc822msgid:CAPh1sh+Notice=0001@mail.example.com -in:sent"

    private func withState(_ body: (URL) async throws -> Void) async throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-phish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try await body(state)
    }

    private func run(_ argv: [String], state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        let raw = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
        // As the app's runner hands it on: without the first-run banner naming this call's config folder.
        return GamResult(exitCode: raw.exitCode, stdout: AuthenticatedRunner.withoutConfigNoise(raw.stdout, configDirectory: config),
                         stderr: raw.stderr, stdoutTruncated: raw.stdoutTruncated, stderrTruncated: raw.stderrTruncated)
    }

    private func find(state: URL? = nil) async throws -> GamResult {
        try await run(GamCommands.findMessageCopies(Self.phish).argv, state: state)
    }

    private func trash(_ email: String, copies: Int, state: URL? = nil) async throws -> GamResult {
        try await run(GamCommands.trashMessage(email: email, Self.phish, copies: copies).argv, state: state)
    }

    /// Lines without the fresh config folder's first-run banner, and without GAM's progress.
    private func lines(_ text: String) -> [String] {
        PythonText.lines(text).filter {
            !$0.isEmpty && !$0.hasPrefix("Created: ") && !$0.hasPrefix("Config File: ") && !GamError.isProgress($0)
        }
    }

    /// GAM's dry run: a count per active user on stderr (bob, suspended, isn't one; Spam and Sent copies aren't
    /// counted), nothing on stdout, and the last user's exit code, never 0.
    @Test func theDryRunCountsEveryActiveMailbox() async throws {
        let result = try await find()
        #expect(lines(result.stdout).isEmpty)
        #expect(lines(result.stderr) == [
            "User: alice@example.com, Message: 1, Not Trashed: Use the \"doit\" argument to perform action (1/3)",
            "User: carol@example.com, Messages: 0, Not Trashed: No Messages matched (2/3)",
            "User: dana@example.com, Messages: 2, Not Trashed: Count 2 exceeds maximum to Trash 1 (3/3)",
        ])
        #expect(result.exitCode == 51)
        // GAM's progress, as show_gettings prints it: skipped by a reader, but for `all users`' own count.
        #expect(result.stderr.contains("Getting all Messages that match query ((\(Self.query))) for alice@example.com (1/3)"))
        #expect(result.stderr.contains("Got 3 Users...\r\n"))
        let copies = try MessageCopies(result, argv: GamCommands.findMessageCopies(Self.phish).argv)
        #expect(copies.mailboxes.map(\.email) == ["alice@example.com", "carol@example.com", "dana@example.com"])
        #expect(copies.mailboxes.map(\.finding) == [.copies(1), .none, .copies(2)] && copies.otherLines.isEmpty)
        #expect(copies.withCopies.map(\.email) == ["alice@example.com", "dana@example.com"] && copies.totalCopies == 3)
    }

    /// The exit code is whichever user GAM reported last: no copy (60) and Gmail off (73) as well.
    @Test func theLastUserSetsTheExitCode() async throws {
        try await withState { state in
            try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: state.appending(path: "nogmail/dana@example.com").path, contents: Data())
            let result = try await find(state: state)
            #expect(result.exitCode == 73)
            #expect(lines(result.stderr).last == "User: dana@example.com, Gmail Service/App not enabled (3/3)")
            let copies = try MessageCopies(result, argv: GamCommands.findMessageCopies(Self.phish).argv)
            #expect(copies.mailboxes.map(\.finding) == [.copies(1), .none, .gmailOff] && !copies.looksLikeMissingScope)
            // dana, still last, with her copies trashed: no copy (60).
            try FileManager.default.removeItem(at: state.appending(path: "nogmail/dana@example.com"))
            _ = try await trash("dana@example.com", copies: 2, state: state)
            #expect(try await find(state: state).exitCode == 60)
        }
    }

    /// One mailbox's run: GAM's "Trash N Messages" and each "Trashed" on stdout, exit 0; the copies are gone from a
    /// search after it, and only theirs: alice's other email, her Spam copy and the others' copies stay.
    @Test func aMailboxsCopiesAreTrashed() async throws {
        try await withState { state in
            let alice = try await trash("alice@example.com", copies: 1, state: state)
            #expect(alice.exitCode == 0, "\(alice.stderr)")
            #expect(lines(alice.stdout) == ["User: alice@example.com, Trash 1 Message",
                                            "  User: alice@example.com, Message: 19a0c0ffee000001, Trashed"])
            let dana = try await trash("dana@example.com", copies: 2, state: state)
            #expect(dana.exitCode == 0 && lines(dana.stdout) == [
                "User: dana@example.com, Trash 2 Messages",
                "  User: dana@example.com, Message: 19a0c0ffee000004, Trashed (1/2)",
                "  User: dana@example.com, Message: 19a0c0ffee000005, Trashed (2/2)",
            ])
            let trashed = try FileManager.default.contentsOfDirectory(atPath: state.appending(path: "trashed").path).sorted()
            #expect(trashed == ["19a0c0ffee000001", "19a0c0ffee000004", "19a0c0ffee000005"])
            let after = try MessageCopies(try await find(state: state), argv: [])
            #expect(after.mailboxes.map(\.finding) == [.none, .none, .none])
            // Again: nothing left to trash is GAM's "No Messages matched" (60), not a success.
            let again = try await trash("alice@example.com", copies: 1, state: state)
            #expect(again.exitCode == 60 && lines(again.stderr) == ["User: alice@example.com, Messages: 0, Not Trashed: No Messages matched"])
        }
    }

    /// The cap: a mailbox holding more than the run allows is left untouched (51), never trashed in part. Without
    /// `notquick`, GAM asks Gmail for only as many as the cap, so the count can't show more: why the builders say it.
    @Test func aMailboxOverTheCapIsLeftAlone() async throws {
        try await withState { state in
            let over = try await trash("dana@example.com", copies: 1, state: state)
            #expect(over.exitCode == 51 && lines(over.stdout).isEmpty)
            #expect(lines(over.stderr) == ["User: dana@example.com, Messages: 2, Not Trashed: Count 2 exceeds maximum to Trash 1"])
            #expect(!FileManager.default.fileExists(atPath: state.appending(path: "trashed").path))
            let quick = try await run(["all", "users", "trash", "messages", "query", Self.query], state: state)
            #expect(lines(quick.stderr).last == "User: dana@example.com, Message: 1, Not Trashed: Use the \"doit\" argument to perform action (3/3)")
            // GAM's 0 is no limit at all.
            let unlimited = try await run(["user", "dana@example.com", "trash", "messages", "query", Self.query, "notquick",
                                           "max_to_trash", "0"], state: state)
            #expect(lines(unlimited.stderr) == ["User: dana@example.com, Messages: 2, Not Trashed: Use the \"doit\" argument to perform action"])
        }
    }

    /// A mailbox GAM can't act as: an address that isn't a user (the token), and a person with Gmail off.
    @Test func aMailboxGamCantSearchFailsAsGamFails() async throws {
        let nobody = try await trash("nobody@example.com", copies: 1)
        #expect(nobody.exitCode == 50 && nobody.stderr == "User: nobody@example.com, User Trash Failed: invalid_grant: Invalid email or User ID\n")
        try await withState { state in
            try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: state.appending(path: "nogmail/alice@example.com").path, contents: Data())
            let off = try await trash("alice@example.com", copies: 1, state: state)
            #expect(off.exitCode == 73 && lines(off.stderr) == ["User: alice@example.com, Gmail Service/App not enabled"])
            #expect(!FileManager.default.fileExists(atPath: state.appending(path: "trashed").path))
        }
    }

    /// GAM reads every argument before any user, so a malformed command changes nothing and is a usage error (exit 2,
    /// GAM's words); the shapes the app never sends, a domain-wide `doit` and any other search, are refused.
    @Test func aMalformedCommandIsAUsageError() async throws {
        let base = ["user", "alice@example.com", "trash", "messages"]
        let cases: [([String], String)] = [
            (base + ["query"], "ERROR: Missing argument: Expected <Query>"),
            (base + ["query", ""], "ERROR: Empty argument: Expected <Non-empty Query>"),
            (base + ["query", Self.query, "max_to_trash"], "ERROR: Missing argument: Expected <integer x>=0>"),
            (base + ["query", Self.query, "max_to_trash", "-1"], "ERROR: Invalid argument: Expected <integer x>=0>"),
            (base + ["query", Self.query, "max_to_trash", "one"], "ERROR: Invalid argument: Expected <integer x>=0>"),
            (base + ["query", Self.query, "doit", "now"], "ERROR: Invalid argument"),
            (base + ["notquick", "doit"], "ERROR: Missing argument: Expected <query|matchlabel|ids|labelids>"),
        ]
        for (argv, error) in cases {
            let result = try await run(argv)
            // By prefix: GAM marks the bad word on its command line, which the mock's shared helper approximates.
            #expect(result.exitCode == 2 && lines(result.stderr).last?.hasPrefix(error) == true, "\(argv): \(result.stderr)")
        }
        // GAM's getArgument: keywords in any case, underscores dropped.
        let spelled = try await run(base + ["QUERY", Self.query, "NotQuick", "Max_To_Trash", "1"])
        #expect(spelled.exitCode == 51, "\(spelled.stderr)")
        for argv in [["all", "users", "trash", "messages", "query", Self.query, "notquick", "doit"],
                     base + ["query", "from:carol@example.com"], base + ["query", "rfc822msgid:a@b"],
                     base + ["query", "rfc822msgid:a b@c -in:sent"], base + ["query", Self.query, "query", Self.query],
                     base + ["query", Self.query, "matchlabel", "inbox"], ["user", "bob@example.com", "trash", "messages", "query", Self.query]] {
            let refused = try await run(argv)
            #expect(refused.exitCode == 2 && refused.stderr.contains("isn't modelled"), "\(argv): \(refused.stderr)")
        }
    }

    private func spam(state: URL? = nil) async throws -> GamResult {
        try await run(GamCommands.findSpamCopies(Self.phish).argv, state: state)
    }

    /// The copies in Spam: every active user searched, numbered, Spam and Trash listed (includespamtrash) and the query
    /// keeping Spam; each copy a CSV row with its ID, Message-ID and labels once all are read; the last user's code.
    @Test func theSpamReadListsEachCopyInSpam() async throws {
        let result = try await spam()
        #expect(lines(result.stdout) == ["User,threadId,id,Message-ID,LabelsCount,Labels",
                                         "alice@example.com,19a0c0ffee000002,19a0c0ffee000002,<CAPh1sh+Notice=0001@mail.example.com>,1,SPAM"])
        #expect(lines(result.stderr).isEmpty && result.exitCode == 60, "carol and dana have none; dana is last")
        let spamQuery = "rfc822msgid:CAPh1sh+Notice=0001@mail.example.com in:spam"
        #expect(result.stderr.contains("Getting all Messages that match query ((\(spamQuery))) for carol@example.com (2/3)"))
        let copies = try SpamCopies(result, argv: [], message: Self.phish)
        #expect(copies.mailboxes == [.init(email: "alice@example.com", ids: ["19a0c0ffee000002"])] && copies.total == 1)
        #expect(copies.searched == ["alice@example.com", "carol@example.com", "dana@example.com"] && copies.unsearched.isEmpty)
    }

    /// Gmail off is GAM's warning before that user's search (the labels are read first), numbered as the others are.
    @Test func aMailboxWithGmailOffIsUnsearchedInSpam() async throws {
        try await withState { state in
            try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: state.appending(path: "nogmail/carol@example.com").path, contents: Data())
            let result = try await spam(state: state)
            #expect(lines(result.stderr) == ["User: carol@example.com, Gmail Service/App not enabled (2/3)"] && result.exitCode == 60)
            #expect(!result.stderr.contains("for carol@example.com (2/3)"), "no search for carol")
            let copies = try SpamCopies(result, argv: [], message: Self.phish)
            #expect(copies.unsearched == [.init(email: "carol@example.com", why: "Gmail is off")])
            #expect(copies.searched == ["alice@example.com", "dana@example.com"] && copies.mailboxes.count == 1)
        }
    }

    /// One mailbox's copies trashed by ID: no list, so Spam is no bar; GAM's "Trash N Messages" and each "Trashed", exit 0.
    /// The copy, in Trash, still shows in the Spam read with TRASH beside SPAM, and is no copy to trash; an ID the mailbox
    /// hasn't got is GAM's "Does not exist" for it (50), the rest trashed.
    @Test func aSpamCopyIsTrashedByItsID() async throws {
        try await withState { state in
            let alice = try await run(try GamCommands.trashMessages(email: "alice@example.com", ids: ["19a0c0ffee000002"]).argv, state: state)
            #expect(alice.exitCode == 0, "\(alice.stderr)")
            #expect(lines(alice.stdout) == ["User: alice@example.com, Trash 1 Message",
                                            "  User: alice@example.com, Message: 19a0c0ffee000002, Trashed"])
            let after = try await spam(state: state)
            #expect(lines(after.stdout).last == "alice@example.com,19a0c0ffee000002,19a0c0ffee000002,<CAPh1sh+Notice=0001@mail.example.com>,2,SPAM TRASH")
            #expect(try SpamCopies(after, argv: [], message: Self.phish).mailboxes.isEmpty)
            // The dry run never saw it, and still counts alice's inbox copy.
            #expect(try MessageCopies(try await find(state: state), argv: []).mailboxes.first?.finding == .copies(1))
            let mixed = try await run(try GamCommands.trashMessages(email: "dana@example.com", ids: ["19a0c0ffee000002", "19a0c0ffee000004"]).argv,
                                      state: state)
            #expect(mixed.exitCode == 50)
            #expect(lines(mixed.stderr) == ["  User: dana@example.com, Message: 19a0c0ffee000002, Trash Failed: Does not exist (1/2)"])
            #expect(lines(mixed.stdout) == ["User: dana@example.com, Trash 2 Messages", "  User: dana@example.com, Message: 19a0c0ffee000004, Trashed (2/2)"])
        }
    }

    /// Forms the app never sends are refused: another query or detail for the Spam read, a list selector or a word more
    /// for the trash by ID, and a trash by ID as a user with no token.
    @Test func otherSpamFormsAreRefused() async throws {
        let spamQuery = "rfc822msgid:CAPh1sh+Notice=0001@mail.example.com in:spam"
        let read = ["all", "users", "print", "messages", "query", spamQuery, "includespamtrash", "headers", "message-id", "showlabels"]
        #expect(read == GamCommands.findSpamCopies(Self.phish).argv)
        for argv in [Array(read.prefix(6)) + ["headers", "message-id", "showlabels"], Array(read.prefix(8)) + ["all", "showlabels"],
                     Array(read.prefix(5)) + [Self.query] + Array(read.suffix(4)), read + ["showdate"],
                     ["user", "alice@example.com", "trash", "messages", "ids", "file"], ["user", "alice@example.com", "trash", "messages", "ids", "a b"]] {
            let refused = try await run(argv)
            #expect(refused.exitCode == 2 && refused.stderr.contains("isn't modelled"), "\(argv): \(refused.stderr)")
        }
        // GAM takes `doit` after ids (it's a word of the selection), which the app never sends: not modelled; a word GAM
        // doesn't know is its invalid argument.
        let extra = try await run(["user", "alice@example.com", "trash", "messages", "ids", "19a0c0ffee000002", "doit"])
        #expect(extra.exitCode == 2 && extra.stderr.contains("isn't modelled"), "\(extra.stderr)")
        let nonsense = try await run(["user", "alice@example.com", "trash", "messages", "ids", "19a0c0ffee000002", "now"])
        #expect(nonsense.exitCode == 2 && nonsense.stderr.contains("ERROR: Invalid argument"), "\(nonsense.stderr)")
        let suspended = try await run(["user", "bob@example.com", "trash", "messages", "ids", "19a0c0ffee000006"])
        #expect(suspended.exitCode == 2 && suspended.stderr.contains("isn't modelled"), "\(suspended.stderr)")
        let nobody = try await run(["user", "nobody@example.com", "trash", "messages", "ids", "19a0c0ffee000002"])
        #expect(nobody.exitCode == 50 && nobody.stderr == "User: nobody@example.com, User Trash Failed: invalid_grant: Invalid email or User ID\n")
    }
}

/// `SpamCopies` reads GAM's lines and rows: every user GAM listed accounted for, and only a copy that is plainly this email
/// in Spam kept to trash.
@Suite("Spam copies")
struct SpamCopiesTests {
    static let phish = try! GamCommands.MessageID(validating: "<a@b.example>")
    static let header = "User,threadId,id,Message-ID,LabelsCount,Labels\n"

    private func result(_ stderr: String, _ stdout: String = header, exit: Int32 = 60, truncated: Bool = false) -> GamResult {
        GamResult(exitCode: exit, stdout: stdout, stderr: stderr, stdoutTruncated: truncated, stderrTruncated: false)
    }

    private func getting(_ user: String, _ at: String = "") -> String {
        "Getting all Messages that match query ((rfc822msgid:a@b.example in:spam)) for \(user)@example.com\(at)\n"
    }

    @Test func eachSearchedUserAndTheirCopies() throws {
        let copies = try SpamCopies(result("Got 4 Users...\n" + getting("a", " (1/4)") + "User: b@example.com, Gmail Service/App not enabled (2/4)\n"
                + getting("c", " (3/4)") + "User: c@example.com, Message: 19ab, Print Failed: Does not exist (1/1)\n"
                + getting("d", " (4/4)") + "WARNING: something GAM said\n",
            Self.header + "a@example.com,t1,19aa,<a@b.example>,2,SPAM UNREAD\n" + "a@example.com,t2,19ac,<a@b.example>,1,SPAM\n"
                + "a@example.com,t1,19aa,<a@b.example>,2,SPAM UNREAD\n" + "c@example.com,t3,19ad,<a@b.example>,1,SPAM\n"
                + "d@example.com,t4,19ae,<a@b.example>,2,SPAM TRASH\n", exit: 50), argv: [], message: Self.phish)
        #expect(copies.mailboxes == [.init(email: "a@example.com", ids: ["19aa", "19ac"])], "a copy printed twice is one; d's is in Trash")
        #expect(copies.unsearched == [.init(email: "b@example.com", why: "Gmail is off"),
                                      .init(email: "c@example.com", why: "Message: 19ab, Print Failed: Does not exist")])
        #expect(copies.searched == ["a@example.com", "d@example.com"] && copies.otherLines == ["WARNING: something GAM said"])
        // The sender's own Sent copy, if Gmail ever files it to Spam, is kept as evidence (D2), as the dry run keeps it.
        let sent = try SpamCopies(result(getting("a"), Self.header + "a@example.com,t1,19aa,<a@b.example>,2,SENT SPAM\n", exit: 0),
                                  argv: [], message: Self.phish)
        #expect(sent.mailboxes.isEmpty && sent.unsearched.isEmpty && sent.searched == ["a@example.com"])
        // One user: GAM numbers nothing.
        let one = try SpamCopies(result(getting("a")), argv: [], message: Self.phish)
        #expect(one.searched == ["a@example.com"] && one.mailboxes.isEmpty)
    }

    /// A copy that isn't plainly this email in Spam (another Message-ID, no SPAM label, an ID GAM couldn't be handed back)
    /// leaves its mailbox unsearched: never trashed, never clear.
    @Test func aCopyNotPlainlyThisEmailInSpamIsLeftAlone() throws {
        for row in ["a@example.com,t1,19aa,<other@b.example>,1,SPAM\n", "a@example.com,t1,19aa,<a@b.example>,1,INBOX\n",
                    "a@example.com,t1,,<a@b.example>,1,SPAM\n", "a@example.com,t1,19 aa,<a@b.example>,1,SPAM\n",
                    "a@example.com,t1,19aa,<A@B.EXAMPLE>,1,SPAM\n", "a@example.com,t1,19aa,<a@b.example>,2,SPAM Old TRASH\n",
                    "a@example.com,t1,19aa,<a@b.example>,,SPAM\n"] {
            let copies = try SpamCopies(result(getting("a"), Self.header + row, exit: 0), argv: [], message: Self.phish)
            #expect(copies.mailboxes.isEmpty && copies.unsearched.map(\.email) == ["a@example.com"], "\(row)")
            #expect(copies.unsearched.first?.why.hasSuffix("that isn't plainly this email in Spam: look at it by hand.") == true)
        }
    }

    /// A read that isn't whole is never shown as whole: a user missing, counted twice, numbered against another total,
    /// fewer than listed, a copy for a user never reported, or output past the runner's cap.
    @Test func aReadThatIsntWholeIsRefused() {
        for (stderr, stdout) in [(getting("a", " (1/3)") + getting("c", " (3/3)"), Self.header),
                                 (getting("a", " (1/2)") + getting("a", " (2/2)"), Self.header),
                                 (getting("a", " (1/2)") + getting("b", " (2/3)"), Self.header),
                                 (getting("a", " (1/2)") + getting("b", " (1/2)"), Self.header),
                                 (getting("a", " (1/2)") + getting("b"), Self.header),
                                 ("", Self.header), ("Got 2 Users...\n" + getting("a"), Self.header),
                                 (getting("a"), Self.header + "z@example.com,t,19aa,<a@b.example>,1,SPAM\n")] {
            #expect(throws: MessageCopies.Incomplete.self, "\(stderr)") {
                try SpamCopies(result(stderr, stdout), argv: [], message: Self.phish)
            }
        }
        #expect(throws: MessageCopies.Incomplete.self) {
            try SpamCopies(result(getting("a"), Self.header, truncated: true), argv: [], message: Self.phish)
        }
    }

    /// The command itself failing (a usage error, the admin's sign-in, a missing scope) is GAM's error.
    @Test func aFailedCommandIsItsError() {
        for (stderr, exit) in [("Command: gam all users print messages\n\nERROR: Invalid argument: x\n", Int32(2)),
                               ("ERROR: invalid_grant: Token has been expired or revoked\n", 18),
                               ("ERROR: 403: Request had insufficient authentication scopes\n" + getting("a", " (1/2)"), 50)] {
            #expect(throws: GamError.self) { try SpamCopies(result(stderr, exit: exit), argv: [], message: Self.phish) }
        }
    }
}

/// `MessageCopies` reads GAM's lines, never its exit code, and refuses a list that isn't whole.
@Suite("Message copies")
struct MessageCopiesTests {
    private func result(_ stderr: String, exit: Int32 = 51, truncated: Bool = false) -> GamResult {
        GamResult(exitCode: exit, stdout: "", stderr: stderr, stdoutTruncated: false, stderrTruncated: truncated)
    }

    @Test func eachLineIsOneMailbox() throws {
        let copies = try MessageCopies(result("""
            Getting all Users that match query (isSuspended=False isGuest=False), may take some time on a large Google Workspace Account...
            Got 5 Users...
            User: a@example.com, Message: 1, Not Trashed: Use the "doit" argument to perform action (1/5)
            \rGot 3 Messages that matched query ((x)) for b@example.com...\r
            User: b@example.com, Messages: 3, Not Trashed: Count 3 exceeds maximum to Trash 1 (2/5)
            User: c@example.com, Gmail Service/App not enabled (3/5)
            User: d@example.com, User:, Trash Failed: invalid_grant: Invalid email or User ID (4/5)
            WARNING: something GAM said
            User: e@example.com, Trash Failed: Precondition check failed. (5/5)
            """), argv: [])
        #expect(copies.mailboxes.map(\.finding) == [.copies(1), .copies(3), .gmailOff, .failed("invalid_grant: Invalid email or User ID"),
                                                    .failed("Precondition check failed.")])
        #expect(copies.otherLines == ["WARNING: something GAM said"] && copies.totalCopies == 4)
        // One user: GAM numbers nothing.
        let one = try MessageCopies(result("User: a@example.com, Messages: 0, Not Trashed: No Messages matched\n", exit: 60), argv: [])
        #expect(one.mailboxes == [.init(email: "a@example.com", finding: .none)])
    }

    /// A token refused for every user (API controls blocking the client, the token endpoint down) is each mailbox
    /// unsearched, in GAM 7.48.30's form and the older one: never "no copies" (review of 2026-10-19, F1).
    @Test func aRefusedTokenIsThatMailboxUnsearched() throws {
        let copies = try MessageCopies(result("Got 3 Users...\n"
            + "User: a@example.com, User Trash Failed: access_denied: Requested client not authorized (1/3)\n"
            + "User: b@example.com, User:, Trash Failed: internal_failure: Backend Error (2/3)\n"
            + "User: c@example.com, User Trash Failed: invalid_grant: Bad Request (3/3)\n", exit: 50), argv: [])
        #expect(copies.mailboxes.map(\.finding) == [.failed("access_denied: Requested client not authorized"),
                                                    .failed("internal_failure: Backend Error"), .failed("invalid_grant: Bad Request")])
        #expect(copies.withCopies.isEmpty && copies.unsearched.count == 3, "one user's invalid_grant isn't the admin's sign-in (F3)")
    }

    /// A user's line in words GAM may use after a bump is that mailbox unsearched, with GAM's words: never clear.
    @Test func aUsersLineInUnknownWordsIsUnsearched() throws {
        let copies = try MessageCopies(result("User: a@example.com, Messages: 1, Not Trashed: Something new (1/2)\n"
            + "User: b@example.com, Messages: 0, Not Trashed: Nothing found, reworded (2/2)\n", exit: 60), argv: [])
        #expect(copies.mailboxes.map(\.finding) == [.failed("Messages: 1, Not Trashed: Something new"),
                                                    .failed("Messages: 0, Not Trashed: Nothing found, reworded")])
        #expect(copies.withCopies.isEmpty && copies.unsearched.count == 2)
    }

    /// Every mailbox off: GAM says the same when the Gmail scope isn't delegated.
    @Test func everyMailboxOffLooksLikeAMissingScope() throws {
        let copies = try MessageCopies(result("User: a@example.com, Gmail Service/App not enabled (1/2)\n"
                                              + "User: b@example.com, Gmail Service/App not enabled (2/2)\n", exit: 73), argv: [])
        #expect(copies.looksLikeMissingScope)
    }

    /// A list that isn't whole is never shown as whole: a user missing, counted twice, numbered against another
    /// total, or output past the runner's cap.
    @Test func aListThatIsntWholeIsRefused() {
        let line = { (user: String, at: String) in "User: \(user)@example.com, Messages: 0, Not Trashed: No Messages matched \(at)\n" }
        for stderr in [line("a", "(1/3)") + line("c", "(3/3)"), line("a", "(1/2)") + line("a", "(2/2)"),
                       line("a", "(1/2)") + line("b", "(2/3)"), line("a", "(1/2)") + line("b", "(1/2)"),
                       line("a", "(1/2)") + "User: b@example.com, Messages: 0, Not Trashed: No Messages matched\n"] {
            #expect(throws: MessageCopies.Incomplete.self) { try MessageCopies(result(stderr, exit: 60), argv: []) }
        }
        // Nobody reported (a user GAM skips without a word, in a one-user domain), or fewer than `all users` listed.
        for stderr in ["", "Got 1 Users...\n", "Got 3 Users...\n" + line("a", "(1/2)") + line("b", "(2/2)"),
                       "Got 2 Users...\nUser: a@example.com, Messages: 0, Not Trashed: No Messages matched\n"] {
            #expect(throws: MessageCopies.Incomplete.self) { try MessageCopies(result(stderr, exit: 0), argv: []) }
        }
        #expect(throws: MessageCopies.Incomplete.self) {
            try MessageCopies(result(line("a", "(1/1)"), exit: 60, truncated: true), argv: [])
        }
    }

    /// The command itself failing (a usage error, the admin's sign-in, a missing scope, a crash) is GAM's error,
    /// whatever per-user lines came before it.
    @Test func aFailedCommandIsItsError() {
        for (stderr, exit) in [("Command: gam all users trash messages\n\nERROR: Invalid argument: x\n", Int32(2)),
                               ("ERROR: invalid_grant: Token has been expired or revoked\n", 18),
                               ("ERROR: 403: Request had insufficient authentication scopes\n"
                                    + "User: a@example.com, Messages: 0, Not Trashed: No Messages matched (1/2)\n", 50),
                               ("User: a@example.com, Messages: 0, Not Trashed: No Messages matched (1/2)\nTraceback (most recent call last):\n", 1)] {
            #expect(throws: GamError.self) { try MessageCopies(result(stderr, exit: exit), argv: []) }
        }
    }

    /// A line that isn't a user's, and isn't an account-wide failure, is kept as printed.
    @Test func anUnknownLineIsKeptAsPrinted() throws {
        let copies = try MessageCopies(result("WARNING: something new\n"
                                              + "User: b@example.com, Messages: 0, Not Trashed: No Messages matched\n", exit: 60), argv: [])
        #expect(copies.mailboxes.count == 1 && copies.otherLines == ["WARNING: something new"])
    }
}
