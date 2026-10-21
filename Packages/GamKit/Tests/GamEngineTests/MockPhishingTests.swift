import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock runs the Phishing screen's two commands the way GAM 7.48.30's `_processMessagesThreads` runs them
/// (read from its source, not a tenant): the dry run over every active user, then one mailbox's trash. The fixture
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
        return try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
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
