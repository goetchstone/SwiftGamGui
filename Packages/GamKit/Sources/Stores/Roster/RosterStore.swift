import CryptoKit
import Darwin
import Foundation
import GamEngine
import Synchronization

/// The roster snapshot kept on this Mac (plan 2026-11-11, C2.5; GamGUI's `core/roster_store.py`). A snapshot is student
/// data: the names and addresses of every teacher and student in a district, and who is in which class. So:
///
/// - **One per domain**, a file in `<Application Support>/SwiftGamGui/roster/` named by a hash of the domain (its spelling
///   never becomes a path): the folder `0700`, refused if it's a link or someone else's, opened once and every file reached
///   from it without following links; the file `0600`, written under `.saving-<pid>-<name>` and renamed into place, so a
///   half-written snapshot never replaces a whole one, and every half-written copy of that domain's file is swept by the
///   next save and by Purge. A copy a quit or crash left before its rename has no snapshot to Purge, so every look, and
///   the app's launch, also sweeps every half-written copy of any domain (`sweepAbandoned`).
/// - **For `keepDays` days.** Past them, the next look deletes it, and expiry fails closed: dates it can't read, an import
///   dated in the future, or a stored expiry past `imported + keepDays` all delete it. **Purge** deletes it at once.
/// - **The screen reads its metadata and issues alone, never the people.** The file is a head, then the body:
///   `SGGROST1`, the head's length (8 bytes, little-endian), the head as JSON (the metadata, the issue counts and the
///   issues kept), then the body as JSON (schools, terms, courses, classes, people, enrolments). `meta` and `issues`
///   read the head; `load` reads the whole. GamGUI keeps SQLite; this format is this app's own, and nothing else reads it.
///
/// Nothing here talks to Google. One save, read, purge or sweep at a time, across the app and across every running copy
/// of it (two saves of one domain once swept each other's temporary file in GamGUI): the in-process lock, and the
/// folder's descriptor held under `flock(LOCK_EX)`. So while the store is held no save is in progress anywhere, and
/// every `.saving-*` file found is abandoned.
public struct RosterStore: Sendable {
    public static let keepDays = 14
    /// The head's most: the metadata and 1,000 issues of each kind come to a few MB.
    static let headCap = 64 * 1024 * 1024
    static let magic = Array("SGGROST1".utf8)
    private static let lock = Mutex(())

    public let root: URL
    let now: @Sendable () -> Date

    public static var defaultRoot: URL { SignatureStore.defaultRoot.appending(path: "roster") }

    public init(root: URL = RosterStore.defaultRoot, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

    /// What the screen shows of a kept roster, and what its audit record says: never a row.
    public struct Meta: Sendable, Equatable {
        public let source: String
        public let label: String
        public let sha256: String
        /// `2026-11-11T09:30:00Z`.
        public let importedAt: String
        public let expiresAt: String
        public let counts: RosterSnapshot.Counts
        public let others: Int
        public let domain: String
    }

    /// The kept roster's issue counts and the rows kept of each, without the rest of it.
    public struct Issues: Sendable, Equatable {
        public let counts: [RosterSnapshot.IssueCount]
        public let rows: [RosterSnapshot.Issue]
    }

    /// The roster couldn't be kept or read: why, in words.
    public struct Failure: Error, Equatable, Sendable {
        public let message: String

        public init(_ message: String) { self.message = message }
    }

    /// The domain's snapshot file name: a hash, so a domain's spelling never becomes a path.
    public static func fileName(_ domain: String) -> String {
        let key = PythonText.lower(PythonText.strip(domain))
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24) + ".roster"
    }

    // MARK: keep, read, purge

    /// Keep `snapshot` as the domain's roster, replacing any earlier one. Returns its metadata.
    @discardableResult
    public func save(_ snapshot: RosterSnapshot, domain: String, label: String, sha256: String) throws(Failure) -> Meta {
        try held(make: true) { folder throws(Failure) in
            try saveLocked(folder, snapshot, domain: domain, label: label, sha256: sha256)
        }
    }

    private func saveLocked(_ folder: Int32?, _ snapshot: RosterSnapshot, domain: String, label: String,
                            sha256: String) throws(Failure) -> Meta {
        let couldnt = { (code: Int32) in Failure("Couldn't keep the roster on this Mac (\(String(cString: strerror(code)))).") }
        guard let folder else { throw couldnt(ENOENT) }
        let name = Self.fileName(domain), temporary = ".saving-\(getpid())-\(name)"
        if let code = sweep(folder, matching: { $0.hasSuffix("-\(name)") }) { throw couldnt(code) }
        let at = now()
        let meta = Meta(source: snapshot.source, label: PythonText.string(label.unicodeScalars.prefix(200)), sha256: sha256,
                        importedAt: Self.stamp(at), expiresAt: Self.stamp(at.addingTimeInterval(Double(Self.keepDays) * 86_400)),
                        counts: snapshot.counts, others: snapshot.others,
                        domain: PythonText.lower(PythonText.strip(domain)))
        let bytes: [UInt8]
        do {
            bytes = try Self.encode(snapshot, meta: meta)
        } catch {
            throw Failure("Couldn't keep the roster on this Mac (it couldn't be written out).")
        }
        let fd = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw couldnt(errno) }
        var written = false
        defer {
            if !written { unlinkat(folder, temporary, 0) }
        }
        var offset = 0
        let failed: Int32? = bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let wrote = write(fd, raw.baseAddress! + offset, min(raw.count - offset, 1 << 20))
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else { return wrote == 0 ? EIO : errno }
                offset += wrote
            }
            return nil
        }
        if let failed {
            close(fd)
            throw couldnt(failed)
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else {
            let code = errno
            close(fd)
            throw couldnt(code)
        }
        close(fd)
        guard renameat(folder, temporary, folder, name) == 0 else { throw couldnt(errno) }
        written = true
        return meta
    }

    /// The kept roster's metadata, or nil when there's none. One past its days is deleted here and reads as none; one
    /// that can't be read is deleted too, and said: its days can't be told, and student data never stays unbounded.
    public func meta(domain: String) throws(Failure) -> Meta? {
        try held(make: false) { folder throws(Failure) in try headLocked(folder, domain)?.meta }
    }

    /// The kept roster's issue counts and kept rows, without the people: what the screen shows on every look.
    public func issues(domain: String) throws(Failure) -> Issues? {
        try held(make: false) { folder throws(Failure) in try headLocked(folder, domain)?.issues }
    }

    /// The kept roster, whole, or nil when there's none (or it has expired).
    public func load(domain: String) throws(Failure) -> RosterSnapshot? {
        try held(make: false) { folder throws(Failure) -> RosterSnapshot? in
            guard let folder, let head = try headLocked(folder, domain) else { return nil }
            guard let bytes = try read(folder, Self.fileName(domain), from: 16 + head.length, cap: Int.max),
                  let body = try? JSONDecoder().decode(Body.self, from: Data(bytes))
            else { throw Failure("Couldn't read the kept roster.") }
            var snapshot = RosterSnapshot(source: head.meta.source)
            (snapshot.schools, snapshot.terms, snapshot.courses) = (body.schools, body.terms, body.courses)
            (snapshot.classes, snapshot.people, snapshot.enrollments) = (body.classes, body.people, body.enrollments)
            (snapshot.issueCounts, snapshot.issueSample, snapshot.others) = (head.issues.counts, head.issues.rows, head.meta.others)
            return snapshot
        }
    }

    /// Delete the domain's kept roster, and any half-written save of it. True when there was one.
    @discardableResult
    public func purge(domain: String) throws(Failure) -> Bool {
        try held(make: false) { folder throws(Failure) in
            guard let folder else { return false }
            return try purgeLocked(folder, domain)
        }
    }

    private func purgeLocked(_ folder: Int32, _ domain: String) throws(Failure) -> Bool {
        let name = Self.fileName(domain)
        var found = true
        if unlinkat(folder, name, 0) != 0 {               // the snapshot first: nothing found after it may keep it
            guard errno == ENOENT else { throw Failure("Couldn't delete the kept roster (\(String(cString: strerror(errno)))).") }
            found = false
        }
        if let code = sweep(folder, matching: { $0.hasSuffix("-\(name)") }) {
            throw Failure("Deleted the kept roster, but not a half-written copy of it (\(String(cString: strerror(code)))).")
        }
        return found
    }

    /// Delete every half-written save, of any domain. Run at launch, and by every look. Every save, in any running copy
    /// of the app, holds the store (`held`), so none is in progress while this holds it: whatever process a name records
    /// and however recent the file, it was abandoned.
    public func sweepAbandoned() {
        try? held(make: false) { folder throws(Failure) in
            if let folder { _ = sweep(folder, matching: { _ in true }) }
        }
    }

    // MARK: the folder and the file

    /// Run `body` holding the store: the in-process lock, then the folder's descriptor under `flock(LOCK_EX)`, which
    /// another running copy of the app takes too, released when the descriptor closes. `body` gets nil when there's no
    /// folder and `make` is off.
    private func held<T: Sendable>(make: Bool, _ body: (Int32?) throws(Failure) -> T) throws(Failure) -> T {
        try Self.lock.withLock { _ throws(Failure) -> T in
            guard let folder = try openFolder(make: make) else { return try body(nil) }
            defer { close(folder) }
            while flock(folder, LOCK_EX) != 0 {
                let code = errno
                guard code == EINTR else {
                    throw Failure("\(root.path) couldn't be locked (\(String(cString: strerror(code)))), so no roster is kept there.")
                }
            }
            // The folder locked must still be the one at the path: one moved away while this waited would take a save
            // that no later look, expiry or Purge reaches (review 2026-11-13).
            var locked = stat(), atPath = stat()
            guard fstat(folder, &locked) == 0, lstat(root.path, &atPath) == 0,
                  locked.st_dev == atPath.st_dev, locked.st_ino == atPath.st_ino else {
                throw Failure("\(root.path) was moved or replaced while in use, so no roster is kept there. Try again.")
            }
            return try body(folder)
        }
    }

    /// The names in the folder that `keep` keeps.
    private func listing(_ folder: Int32, where keep: (String) -> Bool) -> [String]? {
        let copy = fcntl(folder, F_DUPFD_CLOEXEC, 0)     // shares the locked description: never let a child keep it
        guard copy >= 0, let listing = fdopendir(copy) else {
            let code = errno
            if copy >= 0 { close(copy) }
            errno = code
            return nil
        }
        defer { closedir(listing) }
        rewinddir(listing)
        var names: [String] = []
        while let entry = readdir(listing) {
            let found = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if keep(found) { names.append(found) }
        }
        return names
    }

    /// The store's folder, `0700`, opened without following a link and refused if it isn't a folder or isn't this
    /// user's. Nil when it doesn't exist and `make` is off.
    private func openFolder(make: Bool) throws(Failure) -> Int32? {
        var info = stat()
        if lstat(root.path, &info) != 0 {
            guard errno == ENOENT, make else { return nil }
            try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            mkdir(root.path, 0o700)
            guard lstat(root.path, &info) == 0 else { throw Failure("Couldn't make \(root.path), so no roster is kept.") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw Failure("\(root.path) isn't a folder (it may be a link), so no roster is kept there.")
        }
        guard info.st_uid == getuid() else { throw Failure("\(root.path) belongs to another user, so no roster is kept there.") }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("\(root.path) couldn't be opened, so no roster is kept there.") }
        // What was opened is what was checked: a folder swapped in between lstat and open is refused.
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR, opened.st_uid == getuid(),
              opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            close(fd)
            throw Failure("\(root.path) changed while it was opened, so no roster is kept there. Try again.")
        }
        fchmod(fd, 0o700)
        return fd
    }

    /// Delete every half-written save (`.saving-*`) whose name `matching` keeps, whichever process left it: called holding
    /// the store, when no save is in progress. A link is removed as a link, never followed; a folder by that name is left
    /// (it can't hold a save, and refusing on it would block a purge). The error number of a failure, else nil.
    private func sweep(_ folder: Int32, matching: (String) -> Bool) -> Int32? {
        guard let leftovers = listing(folder, where: { $0.hasPrefix(".saving-") && matching($0) }) else { return errno }
        for leftover in leftovers {
            var info = stat()
            guard fstatat(folder, leftover, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR { continue }
            if unlinkat(folder, leftover, 0) != 0, errno != ENOENT { return errno }
        }
        return nil
    }

    /// `name`'s bytes from `offset`, at most `cap` of them, read by descriptor (a plain file only, never through a link).
    /// Nil when what's there is short or isn't a plain file; a read that failed (the disk, not the content) throws, so a
    /// good roster is never deleted as damaged for it (review 2026-11-13).
    private func read(_ folder: Int32, _ name: String, from offset: Int, cap: Int) throws(Failure) -> [UInt8]? {
        let failed = Failure("The kept roster couldn't be read just now. Try again.")
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ELOOP { return nil }
            throw failed
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failed }
        guard info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) >= offset else { return nil }
        let count = min(Int(info.st_size) - offset, cap)
        var bytes = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let step = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, count - got, off_t(offset + got)) }
            if step < 0, errno == EINTR { continue }
            guard step >= 0 else { throw failed }
            if step == 0 { return nil }                  // shorter than it said: the content, not the disk
            got += step
        }
        return bytes
    }

    // MARK: the head

    private struct Head {
        let meta: Meta
        let issues: Issues
        /// The head's length in bytes, after the 16 that frame it.
        let length: Int
    }

    /// The head, or nil when there's no roster or it has expired (and so was deleted). A head that can't be read deletes
    /// the file and says so.
    private func headLocked(_ folder: Int32?, _ domain: String) throws(Failure) -> Head? {
        guard let folder else { return nil }
        _ = sweep(folder, matching: { _ in true })
        let name = Self.fileName(domain)
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure("The kept roster isn't a plain file, so it isn't read.") }
        let unreadable = Failure("The kept roster couldn't be read, so it was deleted. Upload the export again.")
        // A read the disk keeps failing (a file made unreadable, a failing volume) never shows its stored expiry, so the
        // file's own age bounds it: the app never rewrites a roster in place, so its mtime is the save (GamGUI #121).
        func readOrAge(from offset: Int, cap: Int) throws(Failure) -> [UInt8]? {
            do {
                return try read(folder, name, from: offset, cap: cap)
            } catch {
                let saved = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)), at = now()
                if at >= saved.addingTimeInterval(Double(Self.keepDays) * 86_400) || saved > at.addingTimeInterval(86_400) {
                    _ = try purgeLocked(folder, domain)
                    throw Failure("The kept roster couldn't be read and was past its \(Self.keepDays) days, so it was deleted. "
                                  + "Upload the export again.")
                }
                throw error
            }
        }
        guard let frame = try readOrAge(from: 0, cap: 16), frame.count == 16, Array(frame.prefix(8)) == Self.magic else {
            _ = try purgeLocked(folder, domain)
            throw unreadable
        }
        let length = Int(frame.u64(8) & 0x7FFF_FFFF_FFFF_FFFF)
        guard length <= Self.headCap, let bytes = try readOrAge(from: 16, cap: length), bytes.count == length,
              let decoded = decodeHead(bytes, length: length)
        else {
            _ = try purgeLocked(folder, domain)
            throw unreadable
        }
        guard let head = decoded else {
            _ = try purgeLocked(folder, domain)          // past its days, or dates it can't trust
            return nil
        }
        return head
    }

    /// The head as written, or nil when it isn't one; `.some(nil)` when it is one, but past its days or with dates it
    /// can't trust.
    private func decodeHead(_ bytes: [UInt8], length: Int) -> Head?? {
        guard let text = UTF8Check.decode(bytes), let head = JSONValue.parse(text)?.object, let meta = head["meta"]?.object,
              let countList = head["issue_counts"]?.array, let rowList = head["issues"]?.array
        else { return nil }
        var counts: [RosterSnapshot.IssueCount] = []
        for item in countList {
            guard let pair = item.array, pair.count == 2, let code = pair[0].string, let count = pair[1].int else { return nil }
            counts.append(.init(code: code, count: count))
        }
        var rows: [RosterSnapshot.Issue] = []
        for item in rowList {
            guard let cells = item.array, cells.count == 5, let code = cells[0].string, let file = cells[1].string,
                  let row = cells[2].int, let sourceID = cells[3].string, let detail = cells[4].string
            else { return nil }
            rows.append(.init(code: code, file: file, row: row, sourceID: sourceID, detail: detail))
        }
        if expired(importedAt: meta["imported_at"], expiresAt: meta["expires_at"]) { return .some(nil) }
        var tally = RosterSnapshot.Counts()
        let stored = meta["counts"]?.object
        func count(_ key: String) -> Int { stored?[key]?.int ?? 0 }
        (tally.schools, tally.terms, tally.courses, tally.classes) = (count("schools"), count("terms"), count("courses"), count("classes"))
        (tally.teachers, tally.students, tally.enrollments) = (count("teachers"), count("students"), count("enrollments"))
        let found = Meta(source: meta["source"]?.string ?? "", label: meta["label"]?.string ?? "",
                         sha256: meta["sha256"]?.string ?? "", importedAt: meta["imported_at"]?.string ?? "",
                         expiresAt: meta["expires_at"]?.string ?? "", counts: tally, others: meta["others"]?.int ?? 0,
                         domain: meta["domain"]?.string ?? "")
        return .some(Head(meta: found, issues: Issues(counts: counts, rows: rows), length: length))
    }

    // MARK: the format

    private struct Body: Codable {
        let schools: [RosterSnapshot.School]
        let terms: [RosterSnapshot.Term]
        let courses: [RosterSnapshot.Course]
        let classes: [RosterSnapshot.Class]
        let people: [RosterSnapshot.Person]
        let enrollments: [RosterSnapshot.Enrollment]
    }

    static func encode(_ snapshot: RosterSnapshot, meta: Meta) throws -> [UInt8] {
        var counts = JSONObject()
        for (key, value) in meta.counts.ordered { counts[key] = .number(String(value)) }
        let metaObject: JSONObject = [
            "source": .string(meta.source), "label": .string(meta.label), "sha256": .string(meta.sha256),
            "imported_at": .string(meta.importedAt), "expires_at": .string(meta.expiresAt), "counts": .object(counts),
            "others": .number(String(meta.others)), "domain": .string(meta.domain),
        ]
        let head: JSONObject = [
            "meta": .object(metaObject),
            "issue_counts": .array(snapshot.issueCounts.map { .array([.string($0.code), .number(String($0.count))]) }),
            "issues": .array(snapshot.issueSample.map {
                .array([.string($0.code), .string($0.file), .number(String($0.row)), .string($0.sourceID), .string($0.detail)])
            }),
        ]
        let headBytes = Array(JSONValue.dumps(.object(head)).utf8)
        let body = try JSONEncoder().encode(Body(schools: snapshot.schools, terms: snapshot.terms, courses: snapshot.courses,
                                                 classes: snapshot.classes, people: snapshot.people,
                                                 enrollments: snapshot.enrollments))
        var length = UInt64(headBytes.count).littleEndian
        return magic + withUnsafeBytes(of: &length) { Array($0) } + headBytes + Array(body)
    }

    /// `%Y-%m-%dT%H:%M:%SZ` in UTC.
    static func stamp(_ date: Date) -> String {
        let parts = Calendar.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", parts.year!, parts.month!, parts.day!, parts.hour!,
                      parts.minute!, parts.second!)
    }

    /// A stamp read back strictly, as `datetime.strptime(…, "%Y-%m-%dT%H:%M:%SZ")` reads it, or nil.
    static func date(_ text: String) -> Date? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 20, scalars[4] == "-", scalars[7] == "-", scalars[10] == "T", scalars[13] == ":",
              scalars[16] == ":", scalars[19] == "Z" else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            let digits = scalars[range]
            guard digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            return Int(PythonText.string(digits))
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10), let hour = number(11..<13),
              let minute = number(14..<16), let second = number(17..<19), year >= 1,
              (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else { return nil }
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = Calendar.utc.date(from: parts),
              Calendar.utc.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day)
        else { return nil }
        return date
    }

    /// Past its days, or its dates can't be read, or it says it was imported in the future: fails closed, since the
    /// snapshot is student data. A stored expiry is never trusted past `imported + keepDays`.
    func expired(importedAt: JSONValue?, expiresAt: JSONValue?) -> Bool {
        guard let importedText = importedAt?.string, let expiresText = expiresAt?.string,
              let imported = Self.date(importedText), let expires = Self.date(expiresText)
        else { return true }
        let at = now()
        let limit = min(expires, imported.addingTimeInterval(Double(Self.keepDays) * 86_400))
        return at >= limit || imported > at.addingTimeInterval(86_400)
    }
}

extension Calendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
