import ChangeCore
import Foundation
import GamEngine

/// What this app's audit log shows of Phishing's trash runs, email by email: the log reader's Still to do shows an email
/// pulled once its latest run trashed it from every mailbox Find found it in (docs/domains/phishing.md D13). The executor
/// writes a begin and an end record for each step that runs, with the step's `about`; each trash step names its email
/// there, the domain it ran on, how many steps its run holds for that email, and whether Find searched every mailbox for
/// it. The argv alone
/// can't say it: a step in Spam names Gmail's IDs, not the email, and a run stopped part way leaves no record of the
/// steps it never began.
public enum PhishingAudit {
    /// One email's latest run, as its records show it.
    public struct Run: Sendable, Equatable {
        /// The Message-ID, bare (`GamCommands.MessageID.id`).
        public let messageID: String
        /// When its newest record was written (a finished run's last step's end), and who ran it.
        public let at: Date
        public let by: String
        /// The steps the run held for this email, those that ended trashed and those that failed; the rest never ended
        /// (not begun after a Stop, cut off mid-call, or still running).
        public let steps: Int
        public let trashed: Int
        public let failed: Int
        /// The mailboxes its records name, each once (a mailbox with copies in Spam as well has two steps).
        public let mailboxes: Int
        /// Find searched every mailbox and its Spam for the email before the run (`Search.searchedEverywhere`).
        public let searchedEverywhere: Bool
    }

    static let messageKey = "message_id", stepsKey = "message_steps", searchedKey = "searched_everywhere", domainKey = "domain"

    /// A trash step's `about`, for the audit's `extra` (and the debug demo's log).
    public static func about(_ message: GamCommands.MessageID, on domain: String, steps: Int, searchedEverywhere: Bool) -> [String: String] {
        [messageKey: message.id, domainKey: domain, stepsKey: String(steps), searchedKey: searchedEverywhere ? "true" : "false"]
    }

    /// Records read, newest first (invariant 9): a Pull All of a hundred emails is two records a step.
    public static let scanLimit = 100_000

    /// Each email's latest run on `domain` in `log`, newest first: the log is the app's, for every domain it connects, and
    /// one phish can reach two of them. A record without `message_steps` or its domain (written before Phishing named its
    /// email) is passed over: what its run held can't be told whole. Call it off the main actor.
    public static func latestRuns(in log: URL, on domain: String, limit: Int = scanLimit) -> [Run] {
        struct Seen {
            let messageID: String, at: Date, by: String, steps: Int, searchedEverywhere: Bool
            /// Each step's newest end's `ok`: true trashed, false failed, anything else neither.
            var ends: [Int: JSONValue] = [:]
            var mailboxes: Set<String> = []
        }
        var latest: [String: String] = [:], seen: [String: Seen] = [:], order: [String] = []
        var read = 0
        AuditLog.forEachRecord(at: log) { record in
            read += 1
            guard record["action"]?.string == WriteAction.trashMessage.rawValue, let extra = record["extra"]?.object,
                  extra[domainKey]?.string.map(PythonText.lower) == PythonText.lower(domain),
                  let id = extra[messageKey]?.string, let steps = extra[stepsKey]?.string.flatMap({ Int($0) }), steps > 0,
                  let preview = extra["preview"]?.string, let step = extra["step"].flatMap({ $0.int }),
                  let at = record["ts"]?.string.flatMap(AuditEntry.instant)
            else { return read < limit }
            // The newest run seen for an email is its latest: an earlier run's records are passed over.
            if latest[id] == nil { latest[id] = preview }
            guard latest[id] == preview else { return read < limit }
            if seen[id] == nil {
                order.append(id)
                seen[id] = Seen(messageID: id, at: at, by: record["actor"]?.string ?? "", steps: steps,
                                searchedEverywhere: extra[searchedKey]?.string == "true")
            }
            if let target = record["target"]?.string { seen[id]?.mailboxes.insert(PythonText.lower(target)) }
            // Newest first, so a step's first end seen is its newest.
            if extra["phase"]?.string == "end", seen[id]?.ends[step] == nil { seen[id]?.ends[step] = record["ok"] ?? .null }
            return read < limit
        }
        return order.compactMap { seen[$0] }.map { run in
            let results = run.ends.values
            return Run(messageID: run.messageID, at: run.at, by: run.by, steps: run.steps,
                       trashed: results.filter { $0 == .bool(true) }.count, failed: results.filter { $0 == .bool(false) }.count,
                       mailboxes: run.mailboxes.count, searchedEverywhere: run.searchedEverywhere)
        }
    }
}
