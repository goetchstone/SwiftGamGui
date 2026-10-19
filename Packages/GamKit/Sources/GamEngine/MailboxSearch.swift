import Foundation

/// GamGUI's "Search a mailbox" (`GamCommands.searchMessages`, detail `.headers`, at most `GamCommands.messageCap` messages,
/// Spam and Trash included), one row per message: when Gmail has it, who it's from, each recipient header's addresses, the
/// subject and its labels (docs/plans/2026-10-19-compromised-account.md slice 3: a taken-over account's Sent mail checked
/// for other phishing waves). The headers are read by `MessageRecipients`' rules: by name with GAM's numbered repeats
/// ("To 1"), never `Delivered-To`; a Bcc header is only in the sender's own copy, and only when Gmail wrote the message.
public enum MailboxSearch {
    /// What a compromised account's mailbox is searched for first: what it sent in the last three days.
    public static let defaultQuery = "in:sent newer_than:3d"

    public struct Message: Sendable, Equatable, Identifiable {
        public let id: String
        /// When Gmail has it, as GAM prints it (`showdate`), and as a date when it reads as one.
        public let date: String
        public let when: Date?
        public let from: String
        public let subject: String
        public let to: [String]
        public let cc: [String]
        public let bcc: [String]
        /// A recipient GAM printed that can't be read as one address: shown as it is, never dropped.
        public let unreadable: [String]
        /// Gmail's labels (`SENT`, `INBOX`, `TRASH`…).
        public let labels: [String]
        public let messageID: String

        public init(record: GamOutput.Record) {
            func text(_ key: String) -> String { record[key]?.string ?? "" }
            id = text("id")
            date = text("Date")
            when = (try? Date(date, strategy: .iso8601))
            from = text("From")
            subject = text("Subject")
            messageID = text("Message-ID")
            labels = MessageRecipients.words(text("Labels"))
            var unreadable: [String] = []
            func addresses(_ kind: String) -> [String] {
                var found: [String] = [], seen: Set<String> = []
                for (column, value) in record.sorted(by: { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) })
                where MessageRecipients.isHeader(column, kind) {
                    guard let header = value.string else { continue }
                    let read = MessageRecipients.addresses(in: header)
                    for address in read.addresses where seen.insert(PythonText.lower(address)).inserted { found.append(address) }
                    unreadable += read.unreadable
                }
                return found
            }
            to = addresses("to")
            cc = addresses("cc")
            bcc = addresses("bcc")
            self.unreadable = unreadable
        }

        /// Everyone it went to, each once (case aside): To, then Cc, then Bcc.
        public var recipients: [String] {
            var seen: Set<String> = []
            return (to + cc + bcc).filter { seen.insert(PythonText.lower($0)).inserted }
        }
    }

    /// A finished search's messages, newest first as Gmail lists them: none is GAM's NO_ENTITIES_FOUND_RC (60) with its
    /// header line alone. Throws the `GamError` when the read failed, and `MessageCopies.Incomplete` when GAM's output passed
    /// the runner's cap (the rest would pass as all there is).
    public static func messages(_ result: GamResult, argv: [String]) throws -> [Message] {
        guard result.exitCode == 0 || result.exitCode == 60 else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        guard !result.stdoutTruncated else {
            throw MessageCopies.Incomplete(reason: "GAM printed more than \(GamRunner.outputCap / 1_048_576) MiB, so the messages weren't all read.")
        }
        return GamOutput.records(result.stdout).map(Message.init(record:))
    }
}
