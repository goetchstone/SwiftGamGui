/// Who has a copy of one email in Spam, each by Gmail's own ID, read from GAM's `print messages` over every active user
/// (`GamCommands.findSpamCopies`). The dry run `MessageCopies` reads can't see these: `trash messages` lists without Spam
/// and Trash (`_processMessagesThreads`, 7.48.30, passes `includeSpamTrash` only for delete, modify and untrash), so a
/// copy Gmail filed to Spam is neither counted nor pulled by query; each one found here is trashed by its ID instead
/// (`GamCommands.trashMessages`). GAM writes each user's progress or failure on stderr (printShowMessagesThreads):
///
///     Getting all Messages that match query ((rfc822msgid:a@b in:spam)) for alice@example.com (1/3)
///     Got 1 Message that matched query ((rfc822msgid:a@b in:spam)) for alice@example.com...
///     User: carol@example.com, Gmail Service/App not enabled (2/3)
///
/// and every copy as a CSV row on stdout once all are read: `User,threadId,id,Message-ID,LabelsCount,Labels`. A user is
/// searched when its "Getting all" line came and no failure line did; every user GAM listed must be one or the other, or
/// the read is refused as not whole. A copy is kept only when its labels can be told apart (as many words as GAM's
/// `LabelsCount`: a user label's name may hold a space) and say Spam and not Trash, and its Message-ID is exactly the one
/// asked for; one in Trash, or the sender's own Sent copy (kept as evidence), isn't one to trash. Anything else leaves that
/// mailbox unsearched, never read as clear.
public struct SpamCopies: Sendable, Equatable {
    public struct Mailbox: Sendable, Equatable, Identifiable {
        public let email: String
        /// Gmail's IDs of its copies in Spam, in GAM's order.
        public let ids: [String]
        public var id: String { email }

        public init(email: String, ids: [String]) {
            self.email = email
            self.ids = ids
        }
    }

    /// A mailbox GAM couldn't search, or held a copy that couldn't be read as one to trash: why, in words.
    public struct Unsearched: Sendable, Equatable, Identifiable {
        public let email: String
        public let why: String
        public var id: String { email }

        public init(email: String, why: String) {
            self.email = email
            self.why = why
        }
    }

    /// The mailboxes with a copy in Spam, in GAM's order.
    public let mailboxes: [Mailbox]
    public let unsearched: [Unsearched]
    /// Every mailbox searched, with a copy in Spam or without, in GAM's order.
    public let searched: [String]
    /// GAM's other lines (not progress), as printed: shown, never dropped.
    public let otherLines: [String]

    public var total: Int { mailboxes.reduce(0) { $0 + $1.ids.count } }

    /// Reads a finished `print messages`. Throws the `GamError` when the command itself failed (an exit code no per-user
    /// line sets, or an account-wide failure among the lines that aren't a user's), and `MessageCopies.Incomplete` unless
    /// every user GAM listed was reported, once, and every copy printed is a searched user's.
    public init(_ result: GamResult, argv: [String], message: GamCommands.MessageID) throws {
        typealias Incomplete = MessageCopies.Incomplete
        guard MessageCopies.perUserExitCodes.contains(result.exitCode) else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        // By address lowercased; `names` keeps each as GAM printed it first.
        var order: [String] = [], names: [String: String] = [:], searched: Set<String> = [], failed: [String: String] = [:]
        var indexOf: [String: Int] = [:]
        var other: [String] = [], total: Int?, listed: Int?
        // One user's (i/n): every user's must agree on n, and each user keeps one i.
        func count(_ email: String, _ match: Regex<(Substring, Substring, Substring)>.Match?) throws {
            guard let match, let index = Int(match.1), let of = Int(match.2) else { return }
            if total.map({ $0 != of }) ?? false { throw Incomplete(reason: "GAM's user counts disagree, so the list can't be trusted as whole.") }
            total = of
            if let seen = indexOf[email], seen != index { throw Incomplete(reason: "GAM reported \(email) twice, so the list can't be trusted as whole.") }
            indexOf[email] = index
        }
        let counted = /\ \((\d{1,9})\/(\d{1,9})\)$/
        for line in PythonText.lines(result.stderr).map({ PythonText.strip($0) }) where !line.isEmpty {
            if let getting = line.wholeMatch(of: /Getting all Messages that match query \(.*\) for ([^\s,]+)(\ \(\d{1,9}\/\d{1,9}\))?/) {
                let email = PythonText.lower(String(getting.1))
                guard !searched.contains(email) else {
                    throw Incomplete(reason: "GAM searched \(email) twice, so the list can't be trusted as whole.")
                }
                if names[email] == nil { order.append(email); names[email] = String(getting.1) }
                searched.insert(email)
                try count(email, line.firstMatch(of: counted))
                continue
            }
            if GamError.isProgress(line) {
                // `all users`' own count (getPageMessage: "Got 3 Users..."), before any user is searched.
                if let match = line.wholeMatch(of: /Got (\d{1,9}) Users?\b.*/), let count = Int(match.1) { listed = count }
                continue
            }
            guard let head = line.firstMatch(of: /^User: ([^\s,]+),\ /) else {
                other.append(line)
                continue
            }
            // A user's failure: before its search (Gmail off, read with the labels first) or during it. One message's
            // ("User: u, Message: id, … (j/n)") numbers the messages, not the users.
            let email = PythonText.lower(String(head.1))
            var why = Substring(line[head.range.upperBound...])
            let match = why.firstMatch(of: counted)
            if let match { why = why[..<match.range.lowerBound] }
            if names[email] == nil { order.append(email); names[email] = String(head.1) }
            if failed[email] == nil { failed[email] = why == "Gmail Service/App not enabled" ? "Gmail is off" : String(why) }
            if !why.hasPrefix("Message: ") { try count(email, match) }
        }
        let failure = GamError(exitCode: result.exitCode, stderr: other.joined(separator: "\n"), argv: argv, stdout: result.stdout)
        if !other.isEmpty, failure.kinds.contains(where: \.isAccountWide) { throw failure }
        guard !result.stderrTruncated, !result.stdoutTruncated else {
            throw Incomplete(reason: "GAM printed more than \(GamRunner.outputCap / 1_048_576) MiB, so not every mailbox's answer was read.")
        }
        guard !order.isEmpty else { throw Incomplete(reason: "GAM reported no mailbox at all, so none can be said to be clear.") }
        if let listed, listed != order.count {
            throw Incomplete(reason: "GAM reported \(order.count) of the \(listed) users it listed.")
        }
        // With more than one user GAM numbers each (i/n): every number from 1 to n, once each, one per user, or a user is
        // missing.
        if let total, indexOf.count != order.count || indexOf.count != total || Set(indexOf.values) != Set(1...max(total, 1)) {
            throw Incomplete(reason: "GAM reported \(order.count) of the \(total) users it searched.")
        }

        // The copies, each a searched user's: kept in Spam only, exactly this email, by an ID GAM can be handed back.
        var ids: [String: [String]] = [:]
        let wanted = "<\(message.id)>"
        for record in GamOutput.records(result.stdout) {
            func text(_ key: String) -> String { Fields.text(record[key]) }
            let email = PythonText.lower(text("User")), id = text("id")
            guard searched.contains(email) || failed[email] != nil else {
                throw Incomplete(reason: "GAM printed a copy for \(text("User")), a user it didn't report searching.")
            }
            guard failed[email] == nil else { continue }
            // GAM joins label names with a space (csv_output_field_delimiter), and a user label's name may hold one: the
            // labels are told apart only when the words are as many as GAM's own count of them.
            let words = text("Labels").split(whereSeparator: \.isWhitespace), labels = Set(words)
            let apart = Int(text("LabelsCount")) == words.count
            if apart, labels.contains("TRASH") || labels.contains("SENT") { continue }
            guard apart, labels.contains("SPAM"), PythonText.strip(text("Message-ID")).utf8.elementsEqual(wanted.utf8),
                  GamCommands.idList([id]) != nil
            else {
                failed[email] = "Gmail matched a copy (\(id.isEmpty ? "no ID" : id)) that isn't plainly this email in Spam: look at it by hand."
                continue
            }
            if !(ids[email]?.contains(id) ?? false) { ids[email, default: []].append(id) }
        }
        mailboxes = order.compactMap { email in
            guard failed[email] == nil, let theirs = ids[email] else { return nil }
            return Mailbox(email: names[email] ?? email, ids: theirs)
        }
        unsearched = order.compactMap { email in failed[email].map { Unsearched(email: names[email] ?? email, why: $0) } }
        self.searched = order.filter { failed[$0] == nil }.map { names[$0] ?? $0 }
        otherLines = other
    }

    init(mailboxes: [Mailbox], unsearched: [Unsearched] = [], searched: [String], otherLines: [String] = []) {
        self.mailboxes = mailboxes
        self.unsearched = unsearched
        self.searched = searched
        self.otherLines = otherLines
    }
}
