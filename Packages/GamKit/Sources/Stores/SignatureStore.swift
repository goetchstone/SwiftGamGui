import Darwin
import Foundation
import GamEngine

/// The saved signature templates (design doc D2): `signatures.json` in the folder it's given, holding
/// `{"version": 1, "templates": {name: body}}`. GamGUI's store (`core/signatures.py:152-246`) in what
/// the operator sees: its three starters on first use, its name rules and messages, `names()` in
/// Python's order, and an emptied store staying empty. Native where GamGUI's could lose templates:
/// - **atomic writes**: a new file beside the old, then `rename`, so a failed save leaves the old file
///   whole. The folder is made `0700` before the file is created `0600`, never under the umask;
/// - **an unreadable file is moved aside** to `signatures.json.unreadable-<UTC time>` and reported,
///   never replaced. GamGUI loaded its seeds over a corrupt file, and its next save destroyed whatever
///   the operator had (`signatures.py:205-213`);
/// - **replacing is asked**: saving over a name throws `.exists` unless the screen asked first, since
///   nothing keeps the old body. Delete is the screen's to confirm too.
///
/// Names and bodies compare by their exact text, as Python compares, never by Swift's canonical
/// equivalence: "é" and "e" + U+0301 are two templates here, as they were in GamGUI.
public struct SignatureStore: Sendable {
    public enum Problem: Error, Equatable, Sendable {
        /// GamGUI's three refusals, in its words (`signatures.py:234-240`).
        case nameRequired, nameTooLong, bodyEmpty
        /// The name is saved already: saving over it needs `replacing: true`, which the screen asks first.
        case exists(String)
        /// The file would pass `sizeCap`, which the next load would refuse.
        case tooLarge
        /// The file couldn't be opened or read (the system's error number). Nothing was moved or replaced.
        case unreadable(Int32)
        /// The file isn't this format's templates, and moving it aside failed, so the store didn't open.
        case notMovedAside(Int32)
        /// The save failed; the file is as it was.
        case notSaved(Int32)
        /// GamGUI has no templates file.
        case noGamGUITemplates
        /// GamGUI's templates file was refused, and nothing was copied.
        case gamGUIUnreadable(Refusal)

        public var message: String {
            switch self {
            case .nameRequired: "Template name is required."
            case .nameTooLong: "Template name must be \(SignatureStore.maxNameLength) characters or fewer."
            case .bodyEmpty: "Template body is empty — put some HTML in the editor before saving."
            case .exists(let name): "There's already a template named “\(name)”."
            case .tooLarge: "The saved templates would pass \(SignatureStore.sizeCap >> 20) MB. Delete some before saving more."
            case .unreadable(let code): "Couldn't read the saved templates: \(Self.reason(code))."
            case .notMovedAside(let code):
                "The saved templates can't be read, and couldn't be moved aside to keep them: \(Self.reason(code))."
            case .notSaved(let code): "Couldn't save the templates: \(Self.reason(code)). Nothing was changed."
            case .noGamGUITemplates: "GamGUI has no saved templates on this Mac."
            case .gamGUIUnreadable(let refusal): "GamGUI's templates weren't copied: \(refusal.reason)."
            }
        }

        static func reason(_ code: Int32) -> String { String(cString: strerror(code)) }
    }

    /// Why a file wasn't read.
    public enum Refusal: Error, Equatable, Sendable {
        case link, notAFile, tooLarge, notTemplates, failed(Int32)

        var reason: String {
            switch self {
            case .link: "the file is a link"
            case .notAFile: "it isn't a regular file"
            case .tooLarge: "the file is larger than \(SignatureStore.sizeCap >> 20) MB"
            case .notTemplates: "the file isn't GamGUI's templates"
            case .failed(let code): Problem.reason(code)
            }
        }
    }

    /// What a copy from GamGUI did, each list in `names` order. Identical templates are skipped unsaid.
    public struct CopyReport: Equatable, Sendable {
        /// Names this store lacked, now saved.
        public var copied: [String] = []
        /// Names GamGUI saved with another body: this store's body was kept.
        public var kept: [String] = []
        /// Names this store wouldn't save (blank, padded, too long, or a blank or non-text body), left out.
        public var refused: [String] = []
    }

    public static let fileName = "signatures.json"
    /// The format this version reads and writes. A later one (template history) migrates from it.
    public static let format = 1
    /// GamGUI's `_MAX_NAME_LEN`, in code points, as Python's `len` counts.
    public static let maxNameLength = 60
    /// The most a load reads: far past any set of signatures (Gmail keeps 10,000 characters of each).
    public static let sizeCap = 4 * 1024 * 1024

    /// The app's own folder, beside the audit log. Nothing here uses it on its own: each caller names
    /// the folder, so a test or a fixture generator can't reach the operator's templates by leaving it
    /// out (GamGUI failure-log 2026-09-25).
    public static var defaultRoot: URL { URL.applicationSupportDirectory.appending(path: "SwiftGamGui") }
    /// GamGUI's templates (its `app_data_dir()`), read only by `copy(fromGamGUI:)`.
    public static var gamGUIFile: URL { URL.applicationSupportDirectory.appending(path: "GamGUI/signatures.json") }

    /// GamGUI's three starters (`signatures.py:162-189`), in its order. Each line break below is one of
    /// its `\n`s; a trailing backslash joins two of its literals.
    public static let seeds: [(name: String, body: String)] = [
        ("Classic", """
            <div style="font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;\
            font-size:13px;line-height:1.5;color:#3f4a5a;">
              <div style="font-weight:600;color:#1f2733;">{name}</div>
              <div>[[{title} · ]]Your Company</div>
              <div style="color:#6b7280;">{email}[[ · {phone}]]</div>
            </div>
            """),
        ("Modern accent", """
            <table cellpadding="0" cellspacing="0" role="presentation" \
            style="font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;\
            font-size:13px;color:#3f4a5a;">
              <tr>
                <td style="border-left:3px solid #52647B;padding:1px 0 1px 12px;line-height:1.5;">
                  <div style="font-weight:600;font-size:14px;color:#1f2733;">{name}</div>
                  <div style="color:#52647B;">[[{title} · ]]Your Company</div>
                  <div style="color:#6b7280;">{email}[[ · {phone}]]</div>
                  [[<div style="color:#6b7280;">{department}</div>]]
                </td>
              </tr>
            </table>
            """),
        ("Minimal", """
            <div style="font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;\
            font-size:13px;color:#3f4a5a;">{name}[[ · {title}]] · Your Company · {email}</div>
            """),
    ]

    public let root: URL
    public var url: URL { root.appending(path: Self.fileName) }
    /// Where opening moved an unreadable file, for the screen to say so; nil when nothing was moved.
    public private(set) var quarantined: URL?
    /// Name to body, keyed by exact text.
    private var templates: JSONObject
    /// Tests only: called with the new file when half a save is written; a throw is a failed write.
    var interrupt: (@Sendable (URL) throws -> Void)?

    /// The templates saved in `root`, or GamGUI's starters when there's no file yet (nothing is written
    /// until a save). A file that isn't this format's templates (corrupt, another format, a link, too
    /// large) is moved aside first and named in `quarantined`. Throws, opening nothing, when the file
    /// can't be read or moved aside: a store that opened anyway would save over it.
    public init(root: URL, now: Date = Date()) throws {
        self.root = root
        let dir = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else {
            let code = errno
            guard code == ENOENT else { throw Problem.unreadable(code) }
            templates = Self.seeded
            return
        }
        defer { close(dir) }
        do {
            guard let bytes = try Self.read(Self.fileName, in: dir) else {
                templates = Self.seeded
                return
            }
            if let saved = Self.templates(in: bytes) {
                templates = saved
                return
            }
        } catch .failed(let code) {
            throw Problem.unreadable(code)
        } catch {}
        quarantined = try Self.moveAside(in: dir, of: root, now: now)
        templates = Self.seeded
    }

    /// The names in GamGUI's order: Python's `sorted`, code point by code point.
    public var names: [String] { Self.sorted(templates.keys) }

    public func body(_ name: String) -> String? { templates[name]?.string }

    /// Saves `body` under `name` stripped, as GamGUI's `save` does, with its checks in its order. A name
    /// already saved throws `.exists` unless `replacing`.
    public mutating func save(_ name: String, body: String, replacing: Bool = false) throws {
        let name = try Self.checked(name)
        guard !PythonText.strip(body).isEmpty else { throw Problem.bodyEmpty }
        guard replacing || templates[name] == nil else { throw Problem.exists(name) }
        var changed = templates
        changed[name] = .string(body)
        try write(changed)
        templates = changed
    }

    /// Removes `name`; a name not saved changes nothing.
    public mutating func delete(_ name: String) throws {
        guard templates[name] != nil else { return }
        var changed = templates
        changed[name] = nil
        try write(changed)
        templates = changed
    }

    /// Copies in the templates GamGUI saved, when the operator asks (design doc D2). GamGUI's file is
    /// only read, by descriptor as invariant 5 reads credentials, since it sits in an app-data folder:
    /// not through a link, a regular file under `sizeCap`. One save, and only when something was copied.
    public mutating func copy(fromGamGUI file: URL) throws -> CopyReport {
        let folder = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else {
            let code = errno
            throw code == ENOENT ? Problem.noGamGUITemplates : Problem.gamGUIUnreadable(.failed(code))
        }
        defer { close(folder) }
        let bytes: [UInt8]?
        do { bytes = try Self.read(file.lastPathComponent, in: folder) } catch { throw Problem.gamGUIUnreadable(error) }
        guard let bytes else { throw Problem.noGamGUITemplates }
        // GamGUI's own test of its file (`_load`): an object whose "templates" is an object.
        guard let text = String(validating: bytes, as: UTF8.self),
              let theirs = JSONValue.parse(text)?["templates"]?.object
        else { throw Problem.gamGUIUnreadable(.notTemplates) }

        var report = CopyReport(), merged = templates
        for (name, value) in theirs {
            guard let body = value.string, (try? Self.checked(name))?.utf8.elementsEqual(name.utf8) == true,
                  !PythonText.strip(body).isEmpty
            else {
                report.refused.append(name)
                continue
            }
            if let mine = merged[name]?.string {
                if !mine.utf8.elementsEqual(body.utf8) { report.kept.append(name) }
            } else {
                merged[name] = .string(body)
                report.copied.append(name)
            }
        }
        if !report.copied.isEmpty {
            try write(merged)
            templates = merged
        }
        return CopyReport(copied: Self.sorted(report.copied), kept: Self.sorted(report.kept),
                          refused: Self.sorted(report.refused))
    }

    // MARK: rules

    static var seeded: JSONObject {
        seeds.reduce(into: JSONObject()) { $0[$1.name] = .string($1.body) }
    }

    /// GamGUI's name rules: stripped as `str.strip` strips, required, at most 60 code points.
    static func checked(_ name: String) throws(Problem) -> String {
        let name = PythonText.strip(name)
        guard !name.isEmpty else { throw .nameRequired }
        guard name.unicodeScalars.count <= maxNameLength else { throw .nameTooLong }
        return name
    }

    static func sorted(_ names: [String]) -> [String] {
        names.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// The templates in this format's file, or nil for anything else.
    static func templates(in bytes: [UInt8]) -> JSONObject? {
        guard let text = String(validating: bytes, as: UTF8.self), let file = JSONValue.parse(text),
              file["version"]?.int == format, let templates = file["templates"]?.object,
              templates.allSatisfy({ $0.value.string != nil })
        else { return nil }
        return templates
    }

    // MARK: files

    /// The file `name` in the open folder `dir`, by descriptor: opened without following a link or
    /// blocking on a FIFO, a regular file under `sizeCap`, read from that same descriptor. Nil when
    /// there's no such file.
    static func read(_ name: String, in dir: Int32) throws(Refusal) -> [UInt8]? {
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            switch code {
            case ENOENT: return nil
            case ELOOP: throw .link
            default: throw .failed(code)
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .failed(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notAFile }
        guard info.st_size <= sizeCap else { throw .tooLarge }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var bytes: [UInt8] = [], chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                bytes += chunk[..<count]
                guard bytes.count <= sizeCap else { throw .tooLarge }
            } else if count == 0 {
                return bytes
            } else if errno != EINTR {
                throw .failed(errno)
            }
        }
    }

    /// Renames the unreadable file to `signatures.json.unreadable-<UTC time>`, adding `-2`, `-3`… when
    /// that name is taken: never over another file.
    static func moveAside(in dir: Int32, of root: URL, now: Date) throws(Problem) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let at = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        func pad(_ value: Int?, _ width: Int = 2) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let stamp = "\(pad(at.year, 4))-\(pad(at.month))-\(pad(at.day))T\(pad(at.hour))\(pad(at.minute))\(pad(at.second))Z"
        for attempt in 1...100 {
            let name = "\(fileName).unreadable-\(stamp)" + (attempt == 1 ? "" : "-\(attempt)")
            if renameatx_np(dir, fileName, dir, name, UInt32(RENAME_EXCL)) == 0 { return root.appending(path: name) }
            guard errno == EEXIST else { throw .notMovedAside(errno) }
        }
        throw .notMovedAside(EEXIST)
    }

    /// Writes `templates` as the whole file, atomically: a new file in the folder, created `0600` after
    /// the folder is made `0700`, filled and flushed, then renamed over the old one. A failure anywhere
    /// leaves the old file as it was and removes the new one.
    private func write(_ templates: JSONObject) throws {
        let file = JSONValue.object(["version": .number(String(Self.format)), "templates": .object(templates)])
        let bytes = Array((JSONValue.dumps(file) + "\n").utf8)
        guard bytes.count <= Self.sizeCap else { throw Problem.tooLarge }
        let dir = try Self.privateFolder(root)
        defer { close(dir) }
        let temporary = ".\(Self.fileName).\(UUID().uuidString)"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Problem.notSaved(errno) }
        var renamed = false
        defer { if !renamed { unlinkat(dir, temporary, 0) } }
        do {
            defer { close(fd) }
            // Exactly 0600 whatever the umask: it can only have narrowed the mode `openat` was given.
            guard fchmod(fd, 0o600) == 0 else { throw Problem.notSaved(errno) }
            let half = bytes.count / 2
            try Self.writeAll(fd, bytes[..<half])
            try interrupt?(root.appending(path: temporary))
            try Self.writeAll(fd, bytes[half...])
            guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw Problem.notSaved(errno) }
        }
        guard renameat(dir, temporary, dir, Self.fileName) == 0 else { throw Problem.notSaved(errno) }
        renamed = true
    }

    /// The folder, opened for a save: made `0700` if it's new (its parents as the system makes them),
    /// set back to `0700` if it was loosened.
    private static func privateFolder(_ root: URL) throws(Problem) -> Int32 {
        try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(root.path, 0o700) == 0 || errno == EEXIST else { throw .notSaved(errno) }
        let dir = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { throw .notSaved(errno) }
        guard fchmod(dir, 0o700) == 0 else {
            let code = errno
            close(dir)
            throw .notSaved(code)
        }
        return dir
    }

    private static func writeAll(_ fd: Int32, _ bytes: ArraySlice<UInt8>) throws(Problem) {
        var rest = bytes
        while !rest.isEmpty {
            let count = rest.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                rest = rest.dropFirst(count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw .notSaved(count < 0 ? errno : EIO)
            }
        }
    }
}
