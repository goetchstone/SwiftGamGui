import Foundation

/// Reports' mail review (GamGUI's `core/mail_review.py`, roadmap 3.2): every active account's forwarding that is on, and every
/// mail delegate, from the parallel reads (`GamCommands.parallelPrintForward`, `parallelPrintDelegates`, GamGUI #198: each
/// active person's own `user <u> print forward enabledonly` or `print delegates shownames`, `gamParallel` workers at once).
///
/// Each worker announces its person on stderr ("Getting Forward Enabled for <u>", "Getting all Delegates for <u>"), warns by
/// name for one it couldn't read ("User: <u>, Gmail Service/App not enabled"), and skips a refused token without a word; GAM's
/// `showcmds` then writes its End line with the worker's exit code. So each person given is read, unread with a reason, or
/// skipped (no End, or an End with no word), and only a read one says anything about forwarding or delegates: one not read
/// never counts as "forwards nothing" (invariant 10).
public struct MailReview: Sendable, Equatable {
    public struct Forwarding: Sendable, Equatable, Hashable {
        public let user: String
        public let to: String
        public let disposition: String
    }

    public struct Delegation: Sendable, Equatable, Hashable {
        public let user: String
        public let delegate: String
        public let name: String
        public let status: String
    }

    public struct Unread: Sendable, Equatable, Hashable {
        public let user: String
        /// `gmailOff` or `notRead`: fixed words, never GAM's line.
        public let why: String
    }

    /// Every person the read was given: `read` of `listed`; `unread` warned by name or failed; `skipped` never finished or
    /// passed over without a word.
    public struct Accounted: Sendable, Equatable {
        public var listed = 0
        public var read = 0
        public var unread: [Unread] = []
        public var skipped = 0
        public var complete: Bool { unread.isEmpty && skipped == 0 }
    }

    public static let gmailOff = "Gmail is off for them"
    public static let notRead = "GAM couldn't read them"

    public let forwarding: [Forwarding]
    public let forwardingAccounts: Accounted
    public let delegations: [Delegation]
    public let delegationAccounts: Accounted

    public init(forwarding: [Forwarding], forwardingAccounts: Accounted, delegations: [Delegation], delegationAccounts: Accounted) {
        self.forwarding = forwarding
        self.forwardingAccounts = forwardingAccounts
        self.delegations = delegations
        self.delegationAccounts = delegationAccounts
    }

    public var complete: Bool { forwardingAccounts.complete && delegationAccounts.complete }

    /// Each delegating account, in address order, with its delegates.
    public var delegatedByUser: [(user: String, delegations: [Delegation])] {
        Dictionary(grouping: delegations, by: \.user).map { ($0.key, $0.value) }
            .sorted { $0.user.unicodeScalars.lexicographicallyPrecedes($1.user.unicodeScalars) }
    }

    nonisolated(unsafe) private static let getting = try! Regex(#"^Getting (?:Forward Enabled|all Delegates) for (\S+?)(?: \((\d+)/(\d+)\))?\s*$"#)
    nonisolated(unsafe) private static let warning = try! Regex(#"^User: (\S+?), (.*?)(?: \(\d+/\d+\))?\s*$"#)
    /// GAM's poolCallback, with showcmds: "<ts>,<i>/<N>,End,<rc>,gam user <u> …" once a worker is done.
    nonisolated(unsafe) private static let end = try! Regex(#"^[^,]*,\d+/\d+,End,(-?\d+),gam user (\S+)(?:\s|$)"#)

    /// GAM's showcmds framing ("<ts>,<i>/<N>,Start|End,"), not what GAM said.
    nonisolated(unsafe) private static let framing = try! Regex(#"^[^,]*,\d+/\d+,(?:Start|End),"#)

    /// GamGUI's `parallel_ends` (#200): each person's worker's exit code in a parallel read, from GAM's showcmds End lines,
    /// lowercased. A person with no End line never finished.
    public static func ends(_ stderr: String) -> [String: Int] {
        var ends: [String: Int] = [:]
        for raw in stderr.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n") {
            let line = String(raw)
            if let match = try? end.prefixMatch(in: line), let code = match.output[1].substring.flatMap({ Int($0) }),
               let user = match.output[2].substring {
                ends[PythonText.lower(String(user))] = code
            }
        }
        return ends
    }

    /// A parallel read's stderr without GAM's showcmds framing: what the workers said, for an error.
    public static func said(_ stderr: String) -> String {
        stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { (try? framing.prefixMatch(in: $0)) == nil }.joined(separator: "\n")
    }

    /// The stdin of a parallel read (GamGUI's `people_csv`): a `primaryEmail` column, one address a row.
    public static func peopleCSV(_ emails: [String]) -> String {
        "primaryEmail\n" + emails.map { PythonText.strip($0) }.filter { !$0.isEmpty }.map { $0 + "\n" }.joined()
    }

    /// A parallel read's limit (GamGUI's `parallel_timeout`): room for ~3 s a person a worker, past which it is cut off, and
    /// its workers with it.
    public static func parallelTimeout(people: Int) -> Duration {
        .milliseconds(120_000 + people * 3_000 / GamCommands.gamParallel)
    }

    /// GamGUI's `account_for_parallel`: what a parallel read's stderr says about each of `people`, the people it was given. Each
    /// worker is one person's read, so its own lines mean what they mean for one: its "Getting … for <u>" and an End code of 0
    /// is read; a Gmail-off warning or another code is unread; an End with no "Getting" is a refused token, passed over without
    /// a word. A person with no End line at all never finished (cut off, or never started): skipped, never "forwards nothing".
    public static func accountForParallel(_ stderr: String, people: [String]) -> Accounted {
        var ends: [String: Int] = [:], getting = Set<String>(), warned: [String: String] = [:]
        for raw in stderr.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = PythonText.strip(String(raw))
            if let match = try? Self.end.prefixMatch(in: line), let code = match.output[1].substring.flatMap({ Int($0) }),
               let user = match.output[2].substring {
                ends[PythonText.lower(String(user))] = code
            } else if let match = try? Self.getting.wholeMatch(in: line), let user = match.output[1].substring {
                getting.insert(PythonText.lower(String(user)))
            } else if let match = try? Self.warning.wholeMatch(in: line), let user = match.output[1].substring,
                      let rest = match.output[2].substring {
                warned[PythonText.lower(String(user))] = rest.contains("Service/App not enabled") ? gmailOff : notRead
            }
        }
        let everyone = Set(people.map { PythonText.lower(PythonText.strip($0)) }.filter { !$0.isEmpty })
            .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        var accounted = Accounted(listed: everyone.count)
        for person in everyone {
            if let why = warned[person] {
                accounted.unread.append(Unread(user: person, why: why))
            } else if let code = ends[person] {
                if code != 0 { accounted.unread.append(Unread(user: person, why: notRead)) }
                else if getting.contains(person) { accounted.read += 1 }
                else { accounted.skipped += 1 }
            } else {
                accounted.skipped += 1
            }
        }
        return accounted
    }

    private static func text(_ record: GamOutput.Record, _ key: String) -> String { record[key]?.string ?? "" }

    /// The accounts forwarding is on for (a row that says off is left out all the same).
    public static func forwarding(_ records: [GamOutput.Record]) -> [Forwarding] {
        records.filter { PythonText.lower(text($0, "forwardEnabled")) == "true" && !text($0, "User").isEmpty }
            .map { Forwarding(user: text($0, "User"), to: text($0, "forwardTo"), disposition: text($0, "disposition")) }
            .sorted { PythonText.lower($0.user).unicodeScalars.lexicographicallyPrecedes(PythonText.lower($1.user).unicodeScalars) }
    }

    public static func delegations(_ records: [GamOutput.Record]) -> [Delegation] {
        records.filter { !text($0, "User").isEmpty && !text($0, "delegateAddress").isEmpty }
            .map { Delegation(user: text($0, "User"), delegate: text($0, "delegateAddress"), name: text($0, "delegateName"),
                              status: text($0, "delegationStatus")) }
            .sorted { a, b in
                let x = (PythonText.lower(a.user), PythonText.lower(a.delegate)), y = (PythonText.lower(b.user), PythonText.lower(b.delegate))
                return x.0 != y.0 ? x.0.unicodeScalars.lexicographicallyPrecedes(y.0.unicodeScalars)
                    : x.1.unicodeScalars.lexicographicallyPrecedes(y.1.unicodeScalars)
            }
    }
}
