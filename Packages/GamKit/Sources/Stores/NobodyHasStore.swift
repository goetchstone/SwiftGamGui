import Foundation
import GamEngine

/// The emails Phishing's Find showed no mailbox here has, every mailbox and its Spam searched (`Search.nobodyHasIt`), by
/// domain and Message-ID, with when and who was connected: the log reader shows such an email done, said as checked, never
/// ticked silently (phishing.md D14). Find is a read, so the audit log never has it, and the usual outcome of Pull All for an
/// email is that nobody here has it (sent only outside, removed since, never delivered). `nobody-has.json` in the folder
/// it's given, `{"version": 1, "checks": [{"domain", "message_id", "at", "by"}]}`, handled as the marked sign-ins' file is
/// (`SignatureStore.load` and `writeFile`): read by descriptor, a file this format can't read moved aside and reported,
/// never replaced, and written atomically, `0600` in a `0700` folder. It names emails: it stays on this Mac. At most `cap`
/// checks (invariant 9), the oldest dropped first: a check is kept by itself, so it never refuses one.
public struct NobodyHasStore: Sendable {
    public struct Check: Sendable, Equatable, Identifiable {
        public let domain: String
        /// Bare, as Phishing searches by it (`GamCommands.MessageID.id`).
        public let messageID: String
        public let at: Date
        /// The admin connected when Find ran; "" when none was known.
        public let by: String
        /// One check per domain and email: the newest.
        public var id: String { domain + "|" + messageID }
    }

    public static let fileName = "nobody-has.json"
    public static let format = 1
    public static let cap = 2_000

    public let root: URL
    /// Where opening moved an unreadable file, for the screen to say so; nil when nothing was moved.
    public private(set) var quarantined: URL?
    /// Newest first.
    public private(set) var checks: [Check]
    /// Tests only: called with the new file when half a save is written; a throw is a failed write.
    var interrupt: (@Sendable (URL) throws -> Void)?

    /// The checks saved in `root`, or none when there's no file yet. A file that isn't this format's, or holds a check this
    /// store wouldn't save, is moved aside and named in `quarantined`. Throws, opening nothing, when it can't be read or
    /// moved aside: a store that opened anyway would save over it.
    public init(root: URL, now: Date = Date()) throws(SignatureStore.Problem) {
        self.root = root
        let loaded = try SignatureStore.load(Self.fileName, from: root, now: now, parse: Self.checks(in:))
        checks = loaded.value ?? []
        quarantined = loaded.quarantined
    }

    /// The checks for `domain`, newest first.
    public func checks(for domain: String) -> [Check] { checks.filter { $0.domain == domain.lowercased() } }

    /// Keeps that Find showed nobody on `domain` has these emails, at `at`, replacing an older check of each. A Message-ID
    /// Phishing couldn't search by, or a domain or admin that isn't one, keeps nothing.
    public mutating func record(domain: String, messageIDs: [String], by: String, at: Date = Date()) throws(SignatureStore.Problem) {
        let new = messageIDs.compactMap { Self.valid(domain: domain, messageID: $0, at: at, by: by) }
        guard !new.isEmpty else { return }
        let ids = Set(new.map(\.id))
        let changed = Array((new + checks.filter { !ids.contains($0.id) }).prefix(Self.cap))
        try write(changed)
        checks = changed
    }

    /// A check as this store saves it, or nil: one domain, a Message-ID Phishing can search by (kept bare), and an admin's
    /// address or none.
    static func valid(domain: String, messageID: String, at: Date, by: String) -> Check? {
        let domain = domain.trimmingCharacters(in: .whitespaces).lowercased(), by = by.trimmingCharacters(in: .whitespaces).lowercased()
        guard domain.contains("."), domain.count <= 253, domain.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789.-".contains($0) }),
              let message = try? GamCommands.MessageID(validating: messageID), by.isEmpty || Address.looksLikeEmail(by)
        else { return nil }
        return Check(domain: domain, messageID: message.id, at: at, by: by)
    }

    /// The checks in this format's file, or nil for anything else, a check this store wouldn't save among it.
    static func checks(in bytes: [UInt8]) -> [Check]? {
        guard let text = String(validating: bytes, as: UTF8.self), let file = JSONValue.parse(text),
              file["version"]?.int == format, let entries = file["checks"]?.array, entries.count <= cap
        else { return nil }
        var checks: [Check] = []
        for entry in entries {
            guard let domain = entry["domain"]?.string, let messageID = entry["message_id"]?.string, let by = entry["by"]?.string,
                  let stamp = entry["at"]?.string, let at = try? Date(stamp, strategy: .iso8601),
                  let check = valid(domain: domain, messageID: messageID, at: at, by: by), check.messageID == messageID
            else { return nil }
            checks.append(check)
        }
        return checks
    }

    /// Writes `checks` as the whole file (`SignatureStore.writeFile`).
    private func write(_ checks: [Check]) throws(SignatureStore.Problem) {
        let entries = checks.map { check -> JSONValue in
            .object(["domain": .string(check.domain), "message_id": .string(check.messageID), "at": .string(check.at.formatted(.iso8601)),
                     "by": .string(check.by)])
        }
        let file = JSONValue.object(["version": .number(String(Self.format)), "checks": .array(entries)])
        do {
            try SignatureStore.writeFile(Array((JSONValue.dumps(file) + "\n").utf8), named: Self.fileName, in: root, interrupt: interrupt)
        } catch let problem as SignatureStore.Problem {
            throw problem
        } catch {
            throw .notSaved(EIO)
        }
    }
}
