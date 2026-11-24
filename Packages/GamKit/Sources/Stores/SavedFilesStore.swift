import Foundation
import GamEngine

/// The files this app saved through a save panel, newest first: each one's path, when, and what it was (a Builder table, the
/// audit log…), for Files to list with Show in Finder (plan F4). A listed difference from GamGUI, whose window hands a download
/// to the browser and never learns where it went. `saved-files.json` in the folder it's given,
/// `{"version": 1, "files": [{"path", "at", "what"}]}`, handled as the marked sign-ins' file is (`SignatureStore.load` and
/// `writeFile`): read by descriptor, a file this format can't read moved aside and reported, never replaced, and written
/// atomically, `0600` in a `0700` folder. It names where the operator saved things, which can name people: it stays on this Mac.
/// At most `cap` files (invariant 9), the oldest dropped first; the same path saved again is listed once, newest.
public struct SavedFilesStore: Sendable {
    public struct Saved: Sendable, Equatable, Identifiable {
        /// Absolute, as the save panel gave it.
        public let path: String
        public let at: Date
        /// What it was, in words ("Builder table").
        public let what: String
        public var id: String { path }
        public var url: URL { URL(filePath: path) }
    }

    public static let fileName = "saved-files.json"
    public static let format = 1
    public static let cap = 50
    static let pathLength = 4_096
    static let whatLength = 100

    public let root: URL
    /// Where opening moved an unreadable file, for the screen to say so; nil when nothing was moved.
    public private(set) var quarantined: URL?
    /// Newest first.
    public private(set) var files: [Saved]
    /// Tests only: called with the new file when half a save is written; a throw is a failed write.
    var interrupt: (@Sendable (URL) throws -> Void)?

    /// The files listed in `root`, or none when there's no list yet. A file that isn't this format's is moved aside and named in
    /// `quarantined`. Throws, opening nothing, when it can't be read or moved aside: a store that opened anyway would save over it.
    public init(root: URL, now: Date = Date()) throws(SignatureStore.Problem) {
        self.root = root
        let loaded = try SignatureStore.load(Self.fileName, from: root, now: now, parse: Self.files(in:))
        files = loaded.value ?? []
        quarantined = loaded.quarantined
    }

    /// Lists `url`, saved at `at` as `what`, first; an earlier listing of the same path goes. A path this store wouldn't keep
    /// (not a file URL, not absolute, too long, a control character) keeps nothing.
    public mutating func record(_ url: URL, what: String, at: Date = Date()) throws(SignatureStore.Problem) {
        guard url.isFileURL, let saved = Self.valid(path: url.path, at: at, what: what) else { return }
        let changed = Array(([saved] + files.filter { $0.path != saved.path }).prefix(Self.cap))
        try write(changed)
        files = changed
    }

    static func valid(path: String, at: Date, what: String) -> Saved? {
        let what = what.trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/"), path.utf8.count <= pathLength, what.count <= whatLength,
              !(path + what).unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        return Saved(path: path, at: at, what: what)
    }

    /// The files in this format's file, or nil for anything else, a file this store wouldn't keep among it.
    static func files(in bytes: [UInt8]) -> [Saved]? {
        guard let text = String(validating: bytes, as: UTF8.self), let file = JSONValue.parse(text),
              file["version"]?.int == format, let entries = file["files"]?.array, entries.count <= cap
        else { return nil }
        var files: [Saved] = []
        for entry in entries {
            guard let path = entry["path"]?.string, let what = entry["what"]?.string, let stamp = entry["at"]?.string,
                  let at = try? Date(stamp, strategy: .iso8601), let saved = valid(path: path, at: at, what: what), saved.what == what
            else { return nil }
            files.append(saved)
        }
        return files
    }

    /// Writes `files` as the whole file (`SignatureStore.writeFile`).
    private func write(_ files: [Saved]) throws(SignatureStore.Problem) {
        let entries = files.map { saved -> JSONValue in
            .object(["path": .string(saved.path), "at": .string(saved.at.formatted(.iso8601)), "what": .string(saved.what)])
        }
        let file = JSONValue.object(["version": .number(String(Self.format)), "files": .array(entries)])
        do {
            try SignatureStore.writeFile(Array((JSONValue.dumps(file) + "\n").utf8), named: Self.fileName, in: root, interrupt: interrupt)
        } catch let problem as SignatureStore.Problem {
            throw problem
        } catch {
            throw .notSaved(EIO)
        }
    }
}
