import Foundation

/// Reports' mail review (GamGUI's `core/mail_review.py`, roadmap 3.2): every active account's forwarding that is on, and every
/// mail delegate, from `all users print forward enabledonly` and `all users print delegates shownames`.
///
/// GAM reads one account at a time and announces each on stderr ("Getting Forward Enabled for <u> (i/N)", "Getting all
/// Delegates for <u> (i/N)"), warns by name for one it couldn't read ("User: <u>, Gmail Service/App not enabled"), and skips a
/// refused token without a word. So every account GAM listed is read, unread with a reason, or skipped, and only a read one
/// says anything about forwarding or delegates: one not read never counts as "forwards nothing" (invariant 10).
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

    /// Every account GAM listed: `read` of `listed`; `unread` warned by name; `skipped` passed over without a word.
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
    nonisolated(unsafe) private static let gotUsers = try! Regex(#"Got (\d+) Users?\b"#)

    /// GamGUI's `account_for`: what GAM's stderr says about each account, or nil when it listed none and announced none.
    public static func accountFor(_ stderr: String) -> Accounted? {
        var getting = Set<String>(), warned: [String: String] = [:], listed = 0
        for raw in stderr.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = PythonText.strip(String(raw))
            if let match = try? Self.getting.wholeMatch(in: line) {
                if let user = match.output[1].substring { getting.insert(PythonText.lower(String(user))) }
                if match.output.count > 3, let total = match.output[3].substring.flatMap({ Int($0) }) { listed = max(listed, total) }
            } else if let match = try? Self.warning.wholeMatch(in: line), let user = match.output[1].substring,
                      let rest = match.output[2].substring {
                warned[PythonText.lower(String(user))] = rest.contains("Service/App not enabled") ? gmailOff : notRead
            } else if let match = try? Self.gotUsers.firstMatch(in: line), let count = match.output[1].substring.flatMap({ Int($0) }) {
                listed = max(listed, count)
            }
        }
        if listed == 0, getting.isEmpty { return nil }
        let seen = getting.union(warned.keys)
        listed = max(listed, seen.count)
        let unread = warned.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }
            .map { Unread(user: $0.key, why: $0.value) }
        return Accounted(listed: listed, read: getting.subtracting(warned.keys).count, unread: unread,
                         skipped: max(0, listed - seen.count))
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
