import Foundation
import GamEngine

/// Sign-ins the operator marked as a person's own ("That was them", docs/plans/2026-10-22-incidents.md): a sign-in
/// Google marked suspicious that was the person, by domain, account and address, with the operator's note and when. The
/// log reader makes no suspect of a marked sign-in; the mark stays listed beside the findings and can be undone, never
/// hidden. `known-sign-ins.json` in the folder it's given, `{"version": 1, "marks": [{"domain", "account", "address",
/// "note", "at"}]}`, handled as the signature templates' file is (`SignatureStore.load` and `writeFile`): read by
/// descriptor, a file this format can't read moved aside and reported, never replaced, and written atomically, `0600` in
/// a `0700` folder. It names people and addresses: it stays on this Mac. At most `cap` marks (invariant 9).
public struct KnownSignInStore: Sendable {
    public struct Mark: Sendable, Equatable, Identifiable {
        public let domain: String
        public let account: String
        public let address: String
        /// How the operator knows: shown with the mark, and in the incident's record.
        public let note: String
        public let at: Date
        /// One mark per domain, account and address, case aside.
        public var id: String { [domain, account, address].map { $0.lowercased() }.joined(separator: "|") }
    }

    public enum Problem: Error, Equatable, Sendable {
        /// Not one account, one IP address, or a note of the right length.
        case invalid(String)
        /// `cap` marks are saved already.
        case full
        /// The file couldn't be read, moved aside or saved, in the signature store's words.
        case file(SignatureStore.Problem)

        public var message: String {
            switch self {
            case .invalid(let why): why
            case .full: "\(KnownSignInStore.cap) sign-ins are marked already: undo some before marking more."
            case .file(let problem): problem.message.replacingOccurrences(of: "templates", with: "marked sign-ins")
            }
        }
    }

    public static let fileName = "known-sign-ins.json"
    public static let format = 1
    public static let cap = 500
    public static let noteLength = 500

    public let root: URL
    /// Where opening moved an unreadable file, for the screen to say so; nil when nothing was moved.
    public private(set) var quarantined: URL?
    /// Newest first.
    public private(set) var marks: [Mark]
    /// Tests only: called with the new file when half a save is written; a throw is a failed write.
    var interrupt: (@Sendable (URL) throws -> Void)?

    /// The marks saved in `root`, or none when there's no file yet. A file that isn't this format's, or holds a mark this
    /// store wouldn't save, is moved aside and named in `quarantined`. Throws, opening nothing, when it can't be read or
    /// moved aside: a store that opened anyway would save over it.
    public init(root: URL, now: Date = Date()) throws(Problem) {
        self.root = root
        let loaded: (value: [Mark]?, quarantined: URL?)
        do { loaded = try SignatureStore.load(Self.fileName, from: root, now: now, parse: Self.marks(in:)) } catch {
            throw .file(error)
        }
        marks = loaded.value ?? []
        quarantined = loaded.quarantined
    }

    /// The marks for `domain`, newest first.
    public func marks(for domain: String) -> [Mark] { marks.filter { $0.domain == domain.lowercased() } }

    /// Marks `account` signing in from `address` as theirs, with the operator's `note`, and returns the mark saved. Marking
    /// one already marked replaces its note and time.
    @discardableResult
    public mutating func mark(domain: String, account: String, address: String, note: String, at: Date = Date()) throws(Problem) -> Mark {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mark = Self.valid(domain: domain, account: account, address: address, note: note, at: at) else {
            throw .invalid(note.isEmpty ? "Say how you know it was them." : note.count > Self.noteLength
                           ? "The note must be \(Self.noteLength) characters or fewer."
                           : "“\(account)” from “\(address)” isn't one account and one IP address.")
        }
        var changed = marks.filter { $0.id != mark.id }
        guard changed.count < Self.cap else { throw .full }
        changed.insert(mark, at: 0)
        try write(changed)
        marks = changed
        return mark
    }

    /// Undoes the mark `id`: the reader can make a suspect of that sign-in again. One that isn't saved changes nothing.
    public mutating func unmark(_ id: String) throws(Problem) {
        let changed = marks.filter { $0.id != id }
        guard changed.count != marks.count else { return }
        try write(changed)
        marks = changed
    }

    /// A mark as this store saves it, or nil: one domain, one account, one IP address, and a note of 1 to `noteLength`
    /// characters, all as given but trimmed and the names lowercased.
    static func valid(domain: String, account: String, address: String, note: String, at: Date) -> Mark? {
        let domain = domain.trimmingCharacters(in: .whitespaces).lowercased()
        let account = account.trimmingCharacters(in: .whitespaces).lowercased()
        let address = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard domain.contains("."), domain.count <= 253, domain.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789.-".contains($0) }),
              Address.looksLikeEmail(account), Address.isIP(address), (1...noteLength).contains(note.count)
        else { return nil }
        return Mark(domain: domain, account: account, address: address, note: note, at: at)
    }

    /// The marks in this format's file, or nil for anything else, a mark this store wouldn't save among it.
    static func marks(in bytes: [UInt8]) -> [Mark]? {
        guard let text = String(validating: bytes, as: UTF8.self), let file = JSONValue.parse(text),
              file["version"]?.int == format, let entries = file["marks"]?.array, entries.count <= cap
        else { return nil }
        var marks: [Mark] = []
        for entry in entries {
            guard let domain = entry["domain"]?.string, let account = entry["account"]?.string, let address = entry["address"]?.string,
                  let note = entry["note"]?.string, let stamp = entry["at"]?.string, let at = try? Date(stamp, strategy: .iso8601),
                  let mark = valid(domain: domain, account: account, address: address, note: note, at: at)
            else { return nil }
            marks.append(mark)
        }
        return marks
    }

    /// Writes `marks` as the whole file (`SignatureStore.writeFile`).
    private func write(_ marks: [Mark]) throws(Problem) {
        let entries = marks.map { mark -> JSONValue in
            .object(["domain": .string(mark.domain), "account": .string(mark.account), "address": .string(mark.address),
                     "note": .string(mark.note), "at": .string(mark.at.formatted(.iso8601))])
        }
        let file = JSONValue.object(["version": .number(String(Self.format)), "marks": .array(entries)])
        do {
            try SignatureStore.writeFile(Array((JSONValue.dumps(file) + "\n").utf8), named: Self.fileName, in: root, interrupt: interrupt)
        } catch let problem as SignatureStore.Problem {
            throw .file(problem)
        } catch {
            throw .file(.notSaved(EIO))
        }
    }
}
