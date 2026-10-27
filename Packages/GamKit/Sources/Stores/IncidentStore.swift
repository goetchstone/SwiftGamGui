import CryptoKit
import Foundation
import GamEngine

/// Incidents kept on this Mac (docs/plans/2026-10-22-incidents.md, slice 3), so one survives the app restarting or being
/// rebuilt and can be picked up after the fact. Each is a folder in `root` (`<Application Support>/SwiftGamGui/incidents/`)
/// named by its ID, holding `incident.json` (what only a person can say: a title, when it was opened and by whom, how it
/// was reported, and notes, `{"version": 1, …}`) and `evidence/`: one folder per saved read of the logs, each exactly as
/// this app exports them (`IncidentLogs.exportAll`: a CSV a log and `about.txt`), an export picked by the operator copied
/// in byte for byte. Everything else (where each account stands, findings, what's left to do) is worked out from the
/// evidence when shown, never saved. Files are read by descriptor and written as the other stores' are
/// (`SignatureStore.load` and `writeFile`): `0600` in `0700` folders. It names people and addresses: it stays on this
/// Mac. Bounded (invariant 9): `cap` incidents, `notesCap` notes, `exportsCap` saved reads an incident, `fileCap` bytes a
/// file.
public struct IncidentStore: Sendable {
    public struct Note: Sendable, Equatable {
        public let at: Date
        public let text: String

        public init(at: Date, text: String) {
            self.at = at
            self.text = text
        }
    }

    public struct Record: Sendable, Equatable, Identifiable {
        public let id: String
        /// The tenant it happened on: it opens only while connected to it.
        public let domain: String
        public var title: String
        /// When it was opened: the day it was identified, which may be before it was saved here.
        public var opened: Date
        public var openedBy: String
        /// How it came to light: an alert, a person, a check.
        public var reported: String
        /// Oldest first.
        public var notes: [Note]
        /// The warnings the operator picked for the emails the attacker sent (Respond's Who it reached).
        public var warnings: [Warning] = []
        /// The post-incident review, as the operator writes it (Report).
        public var review = Review()
    }

    /// The post-incident review (the standard's lessons learned): the incident's type and severity, the review meeting, how
    /// they got in, what went well, what to do better, and the plan going forward, one item a line. Typed by the operator.
    public struct Review: Sendable, Equatable {
        public var kind = ""
        public var severity = ""
        public var meeting: Date?
        public var attendees = ""
        public var cause = ""
        public var wentWell = ""
        public var improve = ""
        public var plan = ""

        public init(kind: String = "", severity: String = "", meeting: Date? = nil, attendees: String = "", cause: String = "",
                    wentWell: String = "", improve: String = "", plan: String = "") {
            (self.kind, self.severity, self.meeting, self.attendees) = (kind, severity, meeting, attendees)
            (self.cause, self.wentWell, self.improve, self.plan) = (cause, wentWell, improve, plan)
        }

        /// Its text fields by their names in the file, in the order the screen asks them.
        var texts: [(key: String, value: String)] {
            [("kind", kind), ("severity", severity), ("attendees", attendees), ("cause", cause), ("wentWell", wentWell),
             ("improve", improve), ("plan", plan)]
        }
    }

    /// A warning picked for an email the attacker sent: both bare Message-IDs, as the Gmail log names them.
    public struct Warning: Sendable, Equatable {
        public let email: String
        public let warning: String

        public init(email: String, warning: String) {
            (self.email, self.warning) = (email, warning)
        }
    }

    /// A saved read of the logs, read and checked, ready to be kept (`keep(_:in:)`): its files as read, and as text.
    public struct Export: Sendable {
        public let export: ActivityLogs.Export
        let files: [(name: String, bytes: [UInt8])]
    }

    public enum Problem: Error, Equatable, Sendable {
        /// A title, name or note isn't the right length, or an ID isn't one.
        case invalid(String)
        /// `cap` incidents, or `exportsCap` saved reads, are kept already.
        case full(String)
        /// The folder isn't one of this app's exports of the logs.
        case notAnExport(String)
        /// A file couldn't be read or saved (the system's error number).
        case file(String, Int32)

        public var message: String {
            switch self {
            case .invalid(let why), .full(let why), .notAnExport(let why): why
            case .file(let what, let code): "Couldn't \(what): \(String(cString: strerror(code)))."
            }
        }
    }

    public static let fileName = "incident.json"
    public static let format = 1
    public static let cap = 200
    public static let notesCap = 500
    public static let exportsCap = 100
    public static let fileCap = 256 * 1024 * 1024
    /// An export's files together.
    public static let exportCap = 1024 * 1024 * 1024
    public static let titleLength = 200
    public static let nameLength = 100
    public static let noteLength = 2_000
    /// A review's answer (the plan going forward holds a line an item).
    public static let reviewLength = 8_000

    public let root: URL
    /// Newest opened first.
    public private(set) var records: [Record]
    /// Incidents whose file couldn't be read: moved aside, and named here for the screen to say so.
    public private(set) var unreadable: [String]

    /// The incidents kept in `root`, or none when there's no folder yet. Throws, opening nothing, when the folder can't be
    /// read: a store that opened anyway could make a second incident over one it didn't see.
    public init(root: URL, now: Date = Date()) throws(Problem) {
        self.root = root
        records = []
        unreadable = []
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: root.path) } catch {
            let code = Int32((error as NSError).underlyingErrors.first.map { ($0 as NSError).code } ?? Int(EIO))
            guard code == ENOENT || (error as NSError).code == NSFileReadNoSuchFileError else { throw .file("read the incidents", code) }
            return
        }
        for id in names.sorted() where Self.isID(id) {
            let folder = root.appending(path: id, directoryHint: .isDirectory)
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true
            else { continue }
            do {
                let loaded = try SignatureStore.load(Self.fileName, from: folder, now: now) { Self.record(in: $0, id: id) }
                if let record = loaded.value { records.append(record) } else if loaded.quarantined != nil { unreadable.append(id) }
            } catch {
                unreadable.append(id)
            }
        }
        records.sort { ($0.opened, $0.id) > ($1.opened, $1.id) }
        records = Array(records.prefix(Self.cap))
    }

    /// The incidents on `domain`, newest opened first.
    public func records(for domain: String) -> [Record] { records.filter { $0.domain == domain.lowercased() } }

    /// A new incident on `domain`, saved, and returned.
    @discardableResult
    public mutating func create(domain: String, title: String, opened: Date, openedBy: String, reported: String,
                                now: Date = Date()) throws(Problem) -> Record {
        guard records.count < Self.cap else { throw .full("\(Self.cap) incidents are kept already.") }
        // The day it was opened, on this Mac's calendar: the ID sorts and reads as that day.
        let day = Calendar.current.dateComponents([.year, .month, .day], from: opened)
        let stamp = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        // Never an ID kept already: saving it would write over that incident's record.
        var id = ""
        repeat { id = "\(stamp)-\(UUID().uuidString.prefix(6).lowercased())" }
        while FileManager.default.fileExists(atPath: root.appending(path: id).path) || records.contains { $0.id == id }
        let record = try Self.valid(Record(id: id, domain: domain.trimmingCharacters(in: .whitespaces).lowercased(), title: title,
                                           opened: opened, openedBy: openedBy, reported: reported, notes: []))
        try write(record)
        records.insert(record, at: 0)
        records.sort { ($0.opened, $0.id) > ($1.opened, $1.id) }
        return record
    }

    /// Saves `record`'s details and notes over the kept one.
    public mutating func save(_ record: Record) throws(Problem) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { throw .invalid("That incident isn't kept here.") }
        let record = try Self.valid(record)
        try write(record)
        records[index] = record
    }

    /// Adds a note at `at` (which can be earlier than now: "called the bank at 9") to the incident `id`.
    public mutating func addNote(_ text: String, at: Date, to id: String) throws(Problem) {
        guard var record = records.first(where: { $0.id == id }) else { throw .invalid("That incident isn't kept here.") }
        guard record.notes.count < Self.notesCap else { throw .full("\(Self.notesCap) notes are kept already.") }
        record.notes.append(Note(at: at, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        record.notes.sort { $0.at < $1.at }
        try save(record)
    }

    // MARK: evidence

    /// The incident's evidence folder, made `0700` (and the incident's and `root`) if new: where a pull of the logs made
    /// while it's open is exported to.
    public func evidenceFolder(of id: String) throws(Problem) -> URL {
        guard Self.isID(id) else { throw .invalid("That isn't an incident's ID.") }
        let folder = root.appending(path: id, directoryHint: .isDirectory).appending(path: "evidence", directoryHint: .isDirectory)
        for each in [root, folder.deletingLastPathComponent(), folder] {
            do { close(try SignatureStore.privateFolder(each)) } catch { throw .file("make the incident's folder", Self.code(error)) }
        }
        return folder
    }

    /// The export of the logs in `folder` (picked by the operator), read and checked: `about.txt` and at least one log's CSV
    /// (`<log>-log.csv` for a log this app reads, headed as `ActivityLogs.table` heads it), each a regular file of at most
    /// `fileCap` bytes, read by descriptor without following a link. Other files are left out.
    public static func readExport(at folder: URL) throws(Problem) -> Export {
        let dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { throw .file("open the folder", errno) }
        defer { close(dir) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        var files: [(name: String, bytes: [UInt8])] = [], logs: [(application: ActivityLogs.Application, csv: String)] = []
        var about: String?
        let header = Array((ActivityLogs.tableHeader.joined(separator: ",")).utf8)
        for name in names {
            let application = name.hasSuffix("-log.csv") ? ActivityLogs.Application(rawValue: String(name.dropLast(8))) : nil
            guard name == "about.txt" || application != nil else { continue }
            let bytes: [UInt8]
            do {
                guard let read = try SignatureStore.read(name, in: dir, cap: fileCap) else { continue }
                bytes = read
            } catch {
                throw .notAnExport("\(name) wasn't read: \(Self.reason(error)).")
            }
            guard files.reduce(bytes.count, { $0 + $1.bytes.count }) <= exportCap else {
                throw .notAnExport("The export is larger than \(exportCap >> 30) GB together.")
            }
            guard let text = String(validating: bytes, as: UTF8.self) else { throw .notAnExport("\(name) isn't text.") }
            if let application {
                guard bytes.starts(with: header) else { throw .notAnExport("\(name) isn't one of this app's exports of a log.") }
                logs.append((application, text))
            } else {
                guard text.hasPrefix("Incident logs exported ") else { throw .notAnExport("about.txt isn't one of this app's exports.") }
                about = text
            }
            files.append((name, bytes))
        }
        guard let about, !logs.isEmpty else {
            throw .notAnExport("The folder isn't an export of the incident logs: it needs about.txt and a log's CSV, as Export All writes them.")
        }
        return Export(export: ActivityLogs.Export(name: folder.lastPathComponent, about: about, logs: logs), files: files)
    }

    /// Keeps `export` as evidence of the incident `id`: a new folder in its evidence (named as the export's, " (2)" and on
    /// when that's taken), each file written `0600`, never through a link. Whole or not at all. Returns the folder's name.
    @discardableResult
    public func keep(_ export: Export, in id: String) throws(Problem) -> String {
        let evidence = try evidenceFolder(of: id)
        guard (try? FileManager.default.contentsOfDirectory(atPath: evidence.path).count) ?? 0 < Self.exportsCap else {
            throw .full("\(Self.exportsCap) reads of the logs are kept for this incident already.")
        }
        let base = String(export.export.name.filter { $0 != "/" && $0 != ":" && !$0.isNewline }.prefix(100))
        var made: URL?
        for n in 1...99 {
            let name = (base.isEmpty || base.hasPrefix(".") ? "Incident logs" : base) + (n == 1 ? "" : " (\(n))")
            let folder = evidence.appending(path: name, directoryHint: .isDirectory)
            if mkdir(folder.path, 0o700) == 0 { made = folder; break }
            guard errno == EEXIST else { throw .file("save the evidence", errno) }
        }
        guard let folder = made else { throw .file("save the evidence", EEXIST) }
        do {
            let dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard dir >= 0 else { throw Problem.file("save the evidence", errno) }
            defer { close(dir) }
            guard fchmod(dir, 0o700) == 0 else { throw Problem.file("save the evidence", errno) }
            for file in export.files {
                let fd = openat(dir, file.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw Problem.file("save the evidence", errno) }
                defer { close(fd) }
                guard fchmod(fd, 0o600) == 0 else { throw Problem.file("save the evidence", errno) }
                do { try SignatureStore.writeAll(fd, file.bytes[...]) } catch { throw Problem.file("save the evidence", Self.code(error)) }
                guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw Problem.file("save the evidence", errno) }
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error as? Problem ?? .file("save the evidence", EIO)
        }
        return folder.lastPathComponent
    }

    /// Whether `export`, just saved to an incident whose readable saved reads are named `names` and which keeps `saved`
    /// reads in all, would read back last and whole: its name after every other (`exports(of:)` reads them by name), under
    /// `exportsCap`, and each file and all of them under `fileCap` and `exportCap`. Then the evidence with it added in memory
    /// is what reading every saved read back gives, and none need be read again (failure log 2026-10-23).
    public static func readsBackLast(_ export: ActivityLogs.Export, after names: [String], saved: Int) -> Bool {
        let sizes = [export.about.utf8.count] + export.logs.map(\.csv.utf8.count)
        return names.allSatisfy { $0 < export.name } && saved < exportsCap && sizes.allSatisfy { $0 <= fileCap }
            && sizes.reduce(0, +) <= exportCap
    }

    /// Every read of the logs kept for the incident `id`, oldest first (by name: an export's name is when it was made), and
    /// the names of any that couldn't be read.
    public func exports(of id: String) -> (exports: [ActivityLogs.Export], unreadable: [String]) {
        guard Self.isID(id) else { return ([], []) }
        let evidence = root.appending(path: id, directoryHint: .isDirectory).appending(path: "evidence", directoryHint: .isDirectory)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: evidence.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        var exports: [ActivityLogs.Export] = [], unreadable: [String] = []
        for name in names.prefix(Self.exportsCap) {
            do { exports.append(try Self.readExport(at: evidence.appending(path: name, directoryHint: .isDirectory)).export) } catch {
                unreadable.append(name)
            }
        }
        return (exports, unreadable)
    }

    /// Copies every saved read of the incident `id` into `folder` (made `0700`; each read a folder of its own, each file `0600`),
    /// as the report's export holds them, and returns each file's path in `folder` with its SHA-256: what shows the evidence
    /// unchanged. Each file read by descriptor without following a link, a regular file of at most `fileCap` bytes, in pieces
    /// (a file can be 256 MB); written exclusively, never over anything. Throws, naming the file, at the first that can't be.
    public func copyEvidence(of id: String, to folder: URL) throws(Problem) -> [(file: String, sha256: String)] {
        guard Self.isID(id) else { throw .invalid("That isn't an incident's ID.") }
        let evidence = root.appending(path: id, directoryHint: .isDirectory).appending(path: "evidence", directoryHint: .isDirectory)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: evidence.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        do { close(try SignatureStore.privateFolder(folder)) } catch { throw .file("make the evidence folder", Self.code(error)) }
        var hashes: [(file: String, sha256: String)] = []
        for name in names.prefix(Self.exportsCap) {
            let from = open(evidence.appending(path: name, directoryHint: .isDirectory).path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            // A stray file is no saved read; anything else that won't open (a link, no access) is evidence left out: said.
            guard from >= 0 else {
                if errno == ENOTDIR { continue }
                throw .file("read the evidence \(name)", errno)
            }
            defer { close(from) }
            let target = folder.appending(path: name, directoryHint: .isDirectory)
            guard mkdir(target.path, 0o700) == 0 else { throw .file("copy the evidence \(name)", errno) }
            let to = open(target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard to >= 0 else { throw .file("copy the evidence \(name)", errno) }
            defer { close(to) }
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: evidence.appending(path: name).path)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted()
            for file in files {
                let hash = try Self.copy(file, from: from, to: to, what: "\(name)/\(file)")
                hashes.append(("\(folder.lastPathComponent)/\(name)/\(file)", hash))
            }
        }
        return hashes
    }

    /// Copies the file `name` from the folder `from` to `to`, by descriptors, hashing it on the way: its SHA-256 in hex.
    private static func copy(_ name: String, from: Int32, to: Int32, what: String) throws(Problem) -> String {
        let source = openat(from, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw .file("read the evidence \(what)", errno) }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0 else { throw .file("read the evidence \(what)", errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .invalid("The evidence \(what) isn't a regular file.") }
        guard info.st_size <= fileCap else { throw .invalid("The evidence \(what) is larger than \(fileCap >> 20) MB.") }
        let copy = openat(to, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard copy >= 0 else { throw .file("copy the evidence \(what)", errno) }
        defer { close(copy) }
        guard fchmod(copy, 0o600) == 0 else { throw .file("copy the evidence \(what)", errno) }
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 1 << 20), total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw .file("read the evidence \(what)", errno) }
            if count == 0 { break }
            total += count
            guard total <= fileCap else { throw .invalid("The evidence \(what) is larger than \(fileCap >> 20) MB.") }
            hasher.update(data: buffer[..<count])
            do { try SignatureStore.writeAll(copy, buffer[..<count]) } catch { throw .file("copy the evidence \(what)", Self.code(error)) }
        }
        guard fcntl(copy, F_FULLFSYNC) == 0 || fsync(copy) == 0 else { throw .file("copy the evidence \(what)", errno) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: the file

    static func isID(_ id: String) -> Bool {
        id.count == 17 && id.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{6}/) != nil
    }

    /// `record` as this store keeps it, trimmed, or why not.
    static func valid(_ record: Record) throws(Problem) -> Record {
        var record = record
        record.title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.openedBy = record.openedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        record.reported = record.reported.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isID(record.id) else { throw .invalid("That isn't an incident's ID.") }
        guard record.domain.contains("."), record.domain.count <= 253 else { throw .invalid("Connect a domain on Setup first.") }
        guard (1...titleLength).contains(record.title.count) else { throw .invalid("Give the incident a title of \(titleLength) characters or fewer.") }
        guard record.openedBy.count <= nameLength else { throw .invalid("The name must be \(nameLength) characters or fewer.") }
        guard record.reported.count <= noteLength else { throw .invalid("How it was reported must be \(noteLength) characters or fewer.") }
        guard record.notes.count <= notesCap, record.notes.allSatisfy({ (1...noteLength).contains($0.text.count) }) else {
            throw .invalid("A note must be 1 to \(noteLength) characters.")
        }
        // A Message-ID is printable ASCII, at most a header line long.
        func isMessageID(_ id: String) -> Bool { (1...998).contains(id.utf8.count) && id.utf8.allSatisfy { (0x21...0x7E).contains($0) } }
        guard record.warnings.count <= notesCap else { throw .invalid("At most \(notesCap) warnings picked are kept with an incident.") }
        guard record.warnings.allSatisfy({ isMessageID($0.email) && isMessageID($0.warning) }) else {
            throw .invalid("A warning picked isn't an email's Message-ID.")
        }
        guard record.review.kind.count <= nameLength, record.review.severity.count <= nameLength,
              record.review.texts.allSatisfy({ $0.value.count <= reviewLength }) else {
            throw .invalid("The type and severity must be \(nameLength) characters or fewer, and each answer of the review \(reviewLength).")
        }
        return record
    }

    /// The record in this format's file, or nil for anything else.
    static func record(in bytes: [UInt8], id: String) -> Record? {
        guard let text = String(validating: bytes, as: UTF8.self), let file = JSONValue.parse(text), file["version"]?.int == format,
              file["id"]?.string == id, let domain = file["domain"]?.string, let title = file["title"]?.string,
              let opened = file["opened"]?.string.flatMap({ try? Date($0, strategy: .iso8601) }),
              let openedBy = file["openedBy"]?.string, let reported = file["reported"]?.string, let entries = file["notes"]?.array
        else { return nil }
        var notes: [Note] = []
        for entry in entries {
            guard let at = entry["at"]?.string.flatMap({ try? Date($0, strategy: .iso8601) }), let text = entry["text"]?.string else { return nil }
            notes.append(Note(at: at, text: text))
        }
        // Kept since 2026-10-24: a file from before has none.
        var warnings: [Warning] = []
        for entry in file["warnings"]?.array ?? [] {
            guard let email = entry["email"]?.string, let warning = entry["warning"]?.string else { return nil }
            warnings.append(Warning(email: email, warning: warning))
        }
        // Kept since 2026-10-27: a file from before has none.
        var review = Review()
        if let kept = file["review"] {
            guard case .object(let fields) = kept else { return nil }
            func text(_ key: String) -> String? {
                guard let value = fields[key] else { return "" }
                return value.string
            }
            guard let kind = text("kind"), let severity = text("severity"), let attendees = text("attendees"), let cause = text("cause"),
                  let wentWell = text("wentWell"), let improve = text("improve"), let plan = text("plan") else { return nil }
            var meeting: Date?
            if let at = fields["meeting"], at != .null {
                guard let date = at.string.flatMap({ try? Date($0, strategy: .iso8601) }) else { return nil }
                meeting = date
            }
            review = Review(kind: kind, severity: severity, meeting: meeting, attendees: attendees, cause: cause, wentWell: wentWell,
                            improve: improve, plan: plan)
        }
        return try? valid(Record(id: id, domain: domain, title: title, opened: opened, openedBy: openedBy, reported: reported, notes: notes,
                                 warnings: warnings, review: review))
    }

    /// Writes `record` as the whole of its `incident.json`, making its folder (and `root`) `0700` first.
    private func write(_ record: Record) throws(Problem) {
        let folder = root.appending(path: record.id, directoryHint: .isDirectory)
        do { close(try SignatureStore.privateFolder(root)) } catch { throw .file("save the incident", Self.code(error)) }
        let notes = record.notes.map { JSONValue.object(["at": .string($0.at.formatted(.iso8601)), "text": .string($0.text)]) }
        var review = JSONObject()
        for (key, value) in record.review.texts { review[key] = .string(value) }
        review["meeting"] = record.review.meeting.map { .string($0.formatted(.iso8601)) } ?? .null
        let file = JSONValue.object(["version": .number(String(Self.format)), "id": .string(record.id), "domain": .string(record.domain),
                                     "title": .string(record.title), "opened": .string(record.opened.formatted(.iso8601)),
                                     "openedBy": .string(record.openedBy), "reported": .string(record.reported), "notes": .array(notes),
                                     "warnings": .array(record.warnings.map { .object(["email": .string($0.email), "warning": .string($0.warning)]) }),
                                     "review": .object(review)])
        do {
            try SignatureStore.writeFile(Array((JSONValue.dumps(file) + "\n").utf8), named: Self.fileName, in: folder, interrupt: nil)
        } catch {
            throw .file("save the incident", Self.code(error))
        }
    }

    private static func code(_ error: any Error) -> Int32 {
        switch error as? SignatureStore.Problem {
        case .notSaved(let code)?, .unreadable(let code)?, .notMovedAside(let code)?: code
        case .tooLarge?: EFBIG
        default: EIO
        }
    }

    private static func reason(_ error: any Error) -> String {
        switch error as? SignatureStore.Refusal {
        case .link?: "it's a link"
        case .notAFile?: "it isn't a regular file"
        case .tooLarge?: "it's larger than \(fileCap >> 20) MB"
        case .failed(let code)?: String(cString: strerror(code))
        default: "it couldn't be read"
        }
    }
}
