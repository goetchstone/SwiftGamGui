/// Who has a copy of one email, read from GAM's dry run of `trash messages` over every active user
/// (`GamCommands.findMessageCopies`). GAM prints one line per user, every one on stderr, in its own words
/// (`_processMessagesThreads` and its printers, 7.48.30):
///
///     User: alice@example.com, Message: 1, Not Trashed: Use the "doit" argument to perform action (1/3)
///     User: carol@example.com, Messages: 0, Not Trashed: No Messages matched (2/3)
///     User: dana@example.com, Messages: 2, Not Trashed: Count 2 exceeds maximum to Trash 1 (3/3)
///     User: erin@example.com, Gmail Service/App not enabled (4/4)
///     User: frank@example.com, Trash Failed: <Google's words> (5/5)
///     User: gail@example.com, User Trash Failed: <a token refused> (6/6)
///
/// and sets its exit code for each user, so the last user's decides it: never 0 across a real domain. So the
/// result is these lines, never the exit code; an exit code no per-user line sets, or an account-wide failure,
/// means the command itself failed, and a list that didn't come back whole is refused rather than shown as whole.
public struct MessageCopies: Sendable, Equatable {
    public enum Finding: Sendable, Equatable {
        /// This many copies (Spam and Trash aren't searched).
        case copies(Int)
        /// None: the search leaves out the sender's own Sent copy.
        case none
        /// GAM's "Gmail Service/App not enabled": Gmail is off for them, or (for every user at once) the Gmail
        /// scope isn't delegated, which GAM reports the same way.
        case gmailOff
        /// GAM couldn't search this mailbox: its words.
        case failed(String)
    }

    public struct Mailbox: Sendable, Equatable, Identifiable {
        public let email: String
        public let finding: Finding
        public var id: String { email }

        public var copies: Int {
            if case .copies(let count) = finding { return count }
            return 0
        }
    }

    /// Every active user GAM searched, in its order (by address).
    public let mailboxes: [Mailbox]
    /// GAM's other lines (not progress), as printed: shown, never dropped.
    public let otherLines: [String]

    public var withCopies: [Mailbox] { mailboxes.filter { $0.copies > 0 } }
    public var totalCopies: Int { mailboxes.reduce(0) { $0 + $1.copies } }

    /// Mailboxes GAM couldn't search (Gmail off, or a failure): a copy there is unknown, never "none".
    public var unsearched: [Mailbox] {
        mailboxes.filter { if case .failed = $0.finding { true } else { $0.finding == .gmailOff } }
    }

    /// More copies than one email is likely to leave in one mailbox: worth a look before trashing them.
    public var unusual: [Mailbox] { mailboxes.filter { $0.copies > 2 } }

    /// Every mailbox said Gmail is off: more likely the Gmail scope isn't delegated than Gmail off for everyone.
    public var looksLikeMissingScope: Bool {
        !mailboxes.isEmpty && mailboxes.allSatisfy { $0.finding == .gmailOff }
    }

    /// The exit codes GAM's per-user printers set here (ACTION_FAILED_RC, ACTION_NOT_PERFORMED_RC,
    /// NO_ENTITIES_FOUND_RC, SERVICE_NOT_APPLICABLE_RC), and 0 when none set one. Any other is the command failing.
    static let perUserExitCodes: Set<Int32> = [0, 50, 51, 60, 73]

    /// The answer didn't come back whole: some users weren't reported, or GAM's output passed the runner's cap.
    public struct Incomplete: Error, Sendable, Equatable {
        public let reason: String
    }

    /// Reads a finished dry run. Throws the `GamError` when the command itself failed (an exit code no per-user line
    /// sets, or an account-wide failure among the lines that aren't a user's), and `Incomplete` unless every user it
    /// listed was reported, once: a domain-wide search that reports nobody is never read as "no copies" (review of
    /// 2026-10-19: a line in an unknown form, or a user GAM skips without a word, once read as an all-clear).
    public init(_ result: GamResult, argv: [String]) throws {
        guard Self.perUserExitCodes.contains(result.exitCode) else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        var mailboxes: [Mailbox] = [], other: [String] = [], counted: [Int] = [], total: Int?, listed: Int?
        for line in PythonText.lines(result.stderr).map({ PythonText.strip($0) }) where !line.isEmpty {
            if GamError.isProgress(line) {
                // `all users`' own count (getPageMessage: "Got 3 Users..."), before any user is searched.
                if let match = line.wholeMatch(of: /Got (\d{1,9}) Users?\b.*/), let count = Int(match.1) { listed = count }
                continue
            }
            guard let (mailbox, count) = Self.mailbox(line) else {
                other.append(line)
                continue
            }
            mailboxes.append(mailbox)
            if let count {
                counted.append(count.index)
                if total.map({ $0 != count.total }) ?? false {
                    throw Incomplete(reason: "GAM's user counts disagree, so the list can't be trusted as whole.")
                }
                total = count.total
            }
        }
        // Account-wide only from a line that isn't one user's: one user's `invalid_grant` is that user's, not the
        // admin's expired sign-in, which fails the listing of users itself.
        let failure = GamError(exitCode: result.exitCode, stderr: other.joined(separator: "\n"), argv: argv, stdout: result.stdout)
        if !other.isEmpty, failure.kinds.contains(where: \.isAccountWide) { throw failure }
        guard !result.stderrTruncated else {
            throw Incomplete(reason: "GAM printed more than \(GamRunner.outputCap / 1_048_576) MiB, so not every mailbox's answer was read.")
        }
        guard !mailboxes.isEmpty else {
            throw Incomplete(reason: "GAM reported no mailbox at all, so none can be said to be clear.")
        }
        if let listed, listed != mailboxes.count {
            throw Incomplete(reason: "GAM reported \(mailboxes.count) of the \(listed) users it listed.")
        }
        // With more than one user GAM numbers each line (i/n): every number from 1 to n, once, or a user is missing.
        if let total, counted.count != mailboxes.count || counted.sorted() != Array(1...max(total, 1)) {
            throw Incomplete(reason: "GAM reported \(mailboxes.count) of the \(total) users it searched.")
        }
        guard Set(mailboxes.map { PythonText.lower($0.email) }).count == mailboxes.count else {
            throw Incomplete(reason: "GAM reported a user twice, so the list can't be trusted as whole.")
        }
        self.mailboxes = mailboxes
        otherLines = other
    }

    init(mailboxes: [Mailbox], otherLines: [String] = []) {
        self.mailboxes = mailboxes
        self.otherLines = otherLines
    }

    /// One user's line: the mailbox and GAM's (i/n), or nil for a line that isn't one user's. A user's line in words not
    /// known here is that mailbox `.failed` with them: not read, so never read as clear.
    static func mailbox(_ line: String) -> (Mailbox, (index: Int, total: Int)?)? {
        var text = Substring(line)
        var count: (index: Int, total: Int)?
        if let match = text.firstMatch(of: /\ \((\d{1,9})\/(\d{1,9})\)$/), let index = Int(match.1), let total = Int(match.2) {
            count = (index, total)
            text = text[..<match.range.lowerBound]
        }
        guard let head = text.firstMatch(of: /^User: ([^\s,]+),\ /) else { return nil }
        let email = String(head.1), rest = text[head.range.upperBound...]
        let finding: Finding
        if let match = rest.wholeMatch(of: /Messages?: (\d{1,9}), Not Trashed: (.*)/), let found = Int(match.1) {
            let why = match.2
            if why == "No Messages matched", found == 0 {
                finding = .none
            } else if found > 0, why == "Use the \"doit\" argument to perform action"
                        || why.wholeMatch(of: /Count \d{1,9} exceeds maximum to Trash \d{1,9}/) != nil {
                finding = .copies(found)
            } else {
                finding = .failed(String(rest))
            }
        } else if rest == "Gmail Service/App not enabled" {
            finding = .gmailOff
        } else if let match = rest.wholeMatch(of: /(?:User:, |User )?Trash Failed: (.+)/) {
            // GAM's own failure, or a token refused for the user (handleOAuthTokenError: "User Trash Failed", as seen
            // live for a set, onboarding.json; the older "User:, " form too).
            finding = .failed(String(match.1))
        } else {
            // A user's line in a form not known here (a GAM bump's new words): that mailbox wasn't read as clear.
            finding = .failed(String(rest))
        }
        return (Mailbox(email: email, finding: finding), count)
    }
}
