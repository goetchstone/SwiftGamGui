import CryptoKit
import Darwin
import Foundation
import GamEngine
import Synchronization
import Vault

/// The audit runs' schedules and the runs they keep (plan F7a, GamGUI #176's `ScheduleStore` and `KeptRuns`), on this Mac: tenant
/// data at rest. Read again on every look and every change, so a change made from another window is never saved over.
///
/// ```
/// <app data>/schedules/                      0700, held by a descriptor, never followed through a link
///     schedules.json                         0600: every domain's schedules
///     kept/<sha256(domain)[:24]>/<run>/      0700 each, opened one from the other by descriptor
///         <13-digit sequence>-<8 hex>.jsonl  0600: a header line, then one line per kept table: its columns and rows
/// ```
///
/// - **Every folder by descriptor.** The store's folder is opened `O_DIRECTORY | O_NOFOLLOW` and each one under it `openat` the
///   same way from the one above, so a link anywhere from the store down is refused (said, never followed), and no path is
///   built from a stored name. Each is ours, and made `0700`. GamGUI checks each level by path with `lstat`.
/// - **Every file by descriptor.** `openat` with `O_NOFOLLOW | O_NONBLOCK` (a FIFO never hangs a read), `fstat` a regular file,
///   read from that descriptor under a cap: `fileCap` for the schedules, `keptCap` for a kept run (GamGUI reads a kept run
///   whole, unbounded), `headerCap` for a listing, which reads the header line alone. Written under a temporary name `0600`
///   with `O_CREAT | O_EXCL | O_NOFOLLOW`, flushed (`F_FULLFSYNC`), then renamed into place: only a whole file is ever read.
/// - **One lock.** Every change, and the "still scheduled? keep, prune, count" of a finished run, holds an exclusive `flock` on
///   the store's folder, from any store in any process (GamGUI's two in-process locks): a run finishing as it is unscheduled,
///   or its domain removed, keeps nothing.
/// - **Bounded** (invariant 9): `keepCap` runs per run and domain, `keepRowsCap` rows a table, `keptCap` bytes a run.
/// - **Unknown is said** (failure-log 2026-11-18, 2026-11-13): no file is the empty store; a schedules file the disk failed to
///   read is unknown, said, and never saved over; one that isn't a store is moved aside (`setAside`) before an empty one
///   starts. A kept run that can't be read is listed as such, never read as none, and never the run a table is compared with.
public final class AuditScheduleStore: Sendable {
    public static let folderName = "schedules"
    public static let fileName = "schedules.json"
    /// Bytes a schedules file may hold: this app's is a few KB, so anything larger isn't one (GamGUI's `_FILE_CAP`).
    static let fileCap = 1 << 20
    /// Bytes the first line of a kept run may take (`_HEADER_CAP`).
    static let headerCap = 1_000_000
    /// Bytes a kept run may hold, written or read: a few tables at `keepRowsCap` rows. A run that would be larger isn't kept.
    public static let keptCap = 64 << 20
    /// A half-written kept run older than this is a crash's leftover (`_STALE_TEMP`).
    static let staleTemp: Double = 3600
    static let keptSuffix = ".jsonl", tempPrefix = ".kept-"

    /// The app's: `schedules` in its data folder, beside the audit log and the signature backups.
    public static var defaultRoot: URL { SignatureStore.defaultRoot.appending(path: folderName) }

    public let root: URL
    private let aside = Mutex<URL?>(nil)
    /// `keptCap`, but for tests.
    let cap: Int
    /// `keepRowsCap`, but for tests.
    let rowsCap: Int
    /// The clock a stale temporary file is judged by; tests set one.
    private let now: @Sendable () -> Double
    /// Tests only: runs between a finished run's comparison and its keep, where a test unschedules it or removes its domain.
    let meanwhile: (@Sendable () -> Void)?

    public convenience init(root: URL, cap: Int = keptCap, rowsCap: Int = AuditSchedules.keepRowsCap,
                            now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.init(root: root, cap: cap, rowsCap: rowsCap, now: now, meanwhile: nil)
    }

    init(root: URL, cap: Int = keptCap, rowsCap: Int = AuditSchedules.keepRowsCap,
         now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }, meanwhile: (@Sendable () -> Void)?) {
        self.root = root
        self.cap = cap
        self.rowsCap = rowsCap
        self.now = now
        self.meanwhile = meanwhile
    }

    /// Where a schedules file that wasn't a store went, said on Home and the run's pane; nil when none was.
    public var setAside: URL? { aside.withLock { $0 } }

    public typealias Problem = AuditSchedules.Problem
    public typealias Schedule = AuditSchedules.Schedule

    private static let unread = "The schedules file couldn't be read just now, so what is due is unknown. Nothing was changed. Try again."
    private func notAFile() -> Problem {
        Problem("\(root.appending(path: Self.fileName).path) isn't a file (it may be a link), so what is due is unknown and nothing "
                + "is saved over it.")
    }

    // MARK: the folders

    /// The store's folder as a held descriptor, never through a link, ours, `0700` when made. Nil when it doesn't exist and
    /// `make` is off.
    private func openRoot(make: Bool) throws(Problem) -> Int32? {
        if make {
            try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard mkdir(root.path, 0o700) == 0 || errno == EEXIST else {
                throw Problem("The schedules' folder couldn't be made (\(String(cString: strerror(errno)))).")
            }
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT, !make { return nil }
            // A link: O_NOFOLLOW with O_DIRECTORY says "not a directory" on macOS.
            if code == ELOOP || code == ENOTDIR {
                throw Problem("\(root.path) isn't a folder (it may be a link), so what is due is unknown and nothing is saved there.")
            }
            throw Problem(Self.unread)
        }
        do {
            try Self.ours(fd, root.path, make: make,
                          other: "belongs to another user, so what is due is unknown and nothing is saved there.")
        } catch {
            close(fd)
            throw error
        }
        if make { excludeFromBackup() }
        return fd
    }

    /// The store's folder kept out of Time Machine (`isExcludedFromBackup`): the kept tables are the domain's data, and a backup
    /// would keep rows the operator deleted here. Only once the folder was opened as ours, never through a link; best effort (a
    /// volume that can't hold the flag still keeps the store).
    private func excludeFromBackup() {
        var url = root
        guard (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// The folder `name` in the open folder `dir`, as a descriptor: made `0700` with `make`, never through a link. Nil when it
    /// doesn't exist and `make` is off.
    private static func openFolder(_ name: String, in dir: Int32, shown: String, make: Bool) throws(Problem) -> Int32? {
        if make, mkdirat(dir, name, 0o700) != 0, errno != EEXIST {
            throw Problem("\(shown) couldn't be made (\(String(cString: strerror(errno)))), so nothing is kept there.")
        }
        let fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT, !make { return nil }
            if code == ELOOP || code == ENOTDIR {
                throw Problem("\(shown) isn't a folder (it may be a link), so the kept runs in it are left alone.")
            }
            throw Problem("The kept runs' folder couldn't be read just now. Try again.")
        }
        do {
            try ours(fd, shown, make: make, other: "belongs to another user, so nothing is kept there.")
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    /// A folder this Mac account owns, made exactly `0700` when `make`.
    private static func ours(_ fd: Int32, _ shown: String, make: Bool, other: String) throws(Problem) {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Problem("\(shown) couldn't be read just now. Try again.") }
        guard info.st_uid == getuid() else { throw Problem("\(shown) \(other)") }
        if make, info.st_mode & 0o7777 != 0o700, fchmod(fd, 0o700) != 0 {
            throw Problem("\(shown) couldn't be made private (\(String(cString: strerror(errno)))).")
        }
    }

    /// The kept runs' folder of `domain`'s `run`: each level opened from the one above. Nil when one doesn't exist yet and
    /// `make` is off. `top` stops at the domain's folder.
    private func openKept(_ root: Int32, domain: Domain, run: String?, make: Bool) throws(Problem) -> Int32? {
        let keptShown = self.root.appending(path: "kept").path
        guard let kept = try Self.openFolder("kept", in: root, shown: keptShown, make: make) else { return nil }
        defer { close(kept) }
        let top = Self.domainFolder(domain)
        guard let domainDir = try Self.openFolder(top, in: kept, shown: "\(keptShown)/\(top)", make: make) else { return nil }
        guard let run else { return domainDir }
        defer { close(domainDir) }
        return try Self.openFolder(run, in: domainDir, shown: "\(keptShown)/\(top)/\(run)", make: make)
    }

    /// A domain's folder name: the first 24 hex of the SHA-256 of its name (GamGUI's `_top`), so no domain names a path.
    static func domainFolder(_ domain: Domain) -> String {
        SHA256.hash(data: Data(domain.name.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    /// Holds the store's one lock while `body` runs: an exclusive `flock` on the folder, which every store in every process takes
    /// before a change.
    private func locked<T>(make: Bool, _ body: (Int32?) throws(Problem) -> T) throws(Problem) -> T {
        guard let dir = try openRoot(make: make) else { return try body(nil) }
        defer { close(dir) }
        while flock(dir, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Problem("The schedules couldn't be locked (\(String(cString: strerror(errno)))).") }
        }
        defer { flock(dir, LOCK_UN) }
        return try body(dir)
    }

    // MARK: the schedules file

    /// `domain`'s schedules by run key. A problem when they can't be told.
    public func schedules(_ domain: Domain) throws(Problem) -> [String: Schedule] {
        try locked(make: false) { (dir: Int32?) throws(Problem) in try load(dir)[domain.name] ?? [:] }
    }

    /// Every domain's schedules, from the file in the held folder `dir`.
    private func load(_ dir: Int32?) throws(Problem) -> [String: [String: Schedule]] {
        guard let dir else { return [:] }
        let bytes: [UInt8]
        do {
            guard let read = try SignatureStore.read(Self.fileName, in: dir, cap: Self.fileCap) else { return [:] }
            bytes = read
        } catch .link, .notAFile {
            throw notAFile()
        } catch .tooLarge {
            return try moveAside(dir)
        } catch {
            throw Problem(Self.unread)
        }
        guard let every = Self.parse(bytes) else { return try moveAside(dir) }
        return every
    }

    /// A schedules file, whole: this version, each domain lowercased and stripped, each run a key, each schedule whole. Nil for
    /// anything else.
    static func parse(_ bytes: [UInt8]) -> [String: [String: Schedule]]? {
        guard !bytes.isEmpty, let text = String(validating: bytes, as: UTF8.self), let file = JSONValue.parse(text),
              file["version"]?.int == AuditSchedules.fileVersion, let domains = file["domains"]?.object
        else { return nil }
        var every: [String: [String: Schedule]] = [:]
        for (domain, runs) in domains {
            guard !domain.isEmpty, domain == PythonText.lower(PythonText.strip(domain)), let runs = runs.object else { return nil }
            var found: [String: Schedule] = [:]
            for (run, raw) in runs {
                guard let schedule = schedule(run, raw) else { return nil }
                found[run] = schedule
            }
            every[domain] = found
        }
        return every
    }

    private static func schedule(_ run: String, _ raw: JSONValue) -> Schedule? {
        guard AuditSchedules.isRunKey(run), let cadence = raw["cadence"]?.string.flatMap(AuditSchedules.Cadence.init(rawValue:)),
              let keep = raw["keep"]?.int, (1...AuditSchedules.keepCap).contains(keep),
              let since = raw["since"]?.double, AuditSchedules.isTime(since)
        else { return nil }
        let done = raw["done"] == nil ? 0 : raw["done"]?.double ?? -1
        guard AuditSchedules.isTime(done) else { return nil }
        return Schedule(run: run, cadence: cadence, keep: keep, since: since, done: done)
    }

    /// Keeps a file that isn't a store under a new name in the held folder, and starts empty: a save then writes a new file
    /// instead of over it. One that can't be moved stays, unknown, and nothing is saved over it.
    private func moveAside(_ dir: Int32) throws(Problem) -> [String: [String: Schedule]] {
        let name = "\(Self.fileName).unreadable-\(Int(now()))-\(String(format: "%06x", UInt32.random(in: 0..<0x1000000)))"
        guard renameatx_np(dir, Self.fileName, dir, name, UInt32(RENAME_EXCL)) == 0 else {
            throw Problem("The schedules file isn't one GAM GUI can read, and it couldn't be moved aside, so what is due is unknown "
                          + "and nothing is saved over it.")
        }
        aside.withLock { $0 = root.appending(path: name) }
        return [:]
    }

    private func save(_ every: [String: [String: Schedule]], in dir: Int32) throws(Problem) {
        var domains = JSONObject()
        for domain in every.keys.sorted() {
            guard let runs = every[domain], !runs.isEmpty else { continue }
            var object = JSONObject()
            for run in runs.keys.sorted() {
                let s = runs[run]!
                object[run] = .object(["cadence": .string(s.cadence.rawValue), "keep": .number(String(s.keep)),
                                       "since": .number(String(s.since)), "done": .number(String(s.done))])
            }
            domains[domain] = .object(object)
        }
        let file = JSONValue.object(["version": .number(String(AuditSchedules.fileVersion)), "domains": .object(domains)])
        try Self.writeWhole(Array((JSONValue.dumps(file) + "\n").utf8), named: Self.fileName, in: dir, temporary: ".schedules-",
                            replacing: true)
    }

    /// `bytes` as the file `name` in the open folder `dir`: a new `0600` file, filled and flushed, then renamed into place (over
    /// the old one with `replacing`, else never over another). A failure leaves no new file.
    static func writeWhole(_ bytes: [UInt8], named name: String, in dir: Int32, temporary prefix: String,
                           replacing: Bool) throws(Problem) {
        let temporary = prefix + UUID().uuidString
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Problem("It couldn't be saved (\(String(cString: strerror(errno)))).") }
        var placed = false
        defer { if !placed { unlinkat(dir, temporary, 0) } }
        do {
            defer { close(fd) }
            // Exactly 0600 whatever the umask: it can only have narrowed the mode `openat` was given.
            guard fchmod(fd, 0o600) == 0 else { throw SignatureStore.Problem.notSaved(errno) }
            try SignatureStore.writeAll(fd, bytes[...])
            guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw SignatureStore.Problem.notSaved(errno) }
        } catch {
            throw Problem("It couldn't be written. Check the disk has room.")
        }
        let renamed = replacing ? renameat(dir, temporary, dir, name) : renameatx_np(dir, temporary, dir, name, UInt32(RENAME_EXCL))
        guard renamed == 0 else { throw Problem("It couldn't be saved (\(String(cString: strerror(errno)))).") }
        placed = true
    }

    /// Schedules `run` on `domain`, or (`cadence` nil) stops scheduling it. A run already scheduled keeps when it last counted.
    func put(_ dir: Int32, domain: Domain, run: String, cadence: AuditSchedules.Cadence?, keep: Int,
             now: Double) throws(Problem) -> Schedule? {
        guard AuditSchedules.isRunKey(run) else { throw Problem("That isn't one of the audit runs.") }
        if cadence != nil, !(1...AuditSchedules.keepCap).contains(keep) || !AuditSchedules.isTime(now) {
            throw Problem("Keep a whole number of runs, from 1 to \(AuditSchedules.keepCap).")
        }
        var every = try load(dir)
        var runs = every[domain.name] ?? [:]
        let old = runs.removeValue(forKey: run)
        let new = cadence.map { Schedule(run: run, cadence: $0, keep: keep, since: old?.since ?? now, done: old?.done ?? 0) }
        if let new { runs[run] = new }
        every[domain.name] = runs
        if new != nil || old != nil { try save(every, in: dir) }
        return new
    }

    /// A run of `run` that counts finished at `when`: it is due again a cadence on. This run's time, even if an earlier one is
    /// later: that one came from a clock set ahead, and kept, it would hold the schedule off for as long as the clock was wrong.
    private func markDone(_ dir: Int32, domain: Domain, run: String, when: Double) throws(Problem) {
        guard AuditSchedules.isTime(when) else { throw Problem("This Mac's clock doesn't give a time a date can be made of.") }
        var every = try load(dir)
        guard let old = every[domain.name]?[run] else { return }
        every[domain.name]?[run] = Schedule(run: old.run, cadence: old.cadence, keep: old.keep, since: old.since, done: when)
        try save(every, in: dir)
    }

    // MARK: kept runs

    /// `<13 digits>-<8 hex>`, the name of a kept run without its suffix.
    static func isKeptID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard scalars.count == 22, scalars[13] == "-" else { return false }
        return scalars[..<13].allSatisfy { ("0"..."9").contains($0) }
            && scalars[14...].allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// The names in the open folder, each once.
    private static func names(in dir: Int32) throws(Problem) -> [String] {
        let copy = dup(dir)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw Problem("The kept runs' folder couldn't be read just now. Try again.")
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            // A failed `readdir` returns nil as the end does: only `errno` tells them apart, and a listing cut short is never
            // "none kept".
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Problem("The kept runs' folder couldn't be read just now. Try again.") }
                return names
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    /// The kept runs' ids in the open folder, newest first: every `<id>.jsonl` that isn't a link (a FIFO is listed, and read as
    /// "It isn't a file."). Named by a sequence, so the newest is the last kept, whatever the clock said.
    private static func keptIDs(in dir: Int32) throws(Problem) -> [String] {
        try names(in: dir).compactMap { name -> String? in
            guard name.hasSuffix(keptSuffix) else { return nil }
            let id = String(name.dropLast(keptSuffix.count))
            var info = stat()
            guard isKeptID(id), fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT != S_IFLNK else { return nil }
            return id
        }.sorted { $1.unicodeScalars.lexicographicallyPrecedes($0.unicodeScalars) }
    }

    /// `domain`'s kept runs of `run`, newest first, their headers only. One that can't be read is listed with its problem.
    public func runs(_ domain: Domain, run: String) throws(Problem) -> [AuditSchedules.KeptRun] {
        guard AuditSchedules.isRunKey(run), let root = try openRoot(make: false) else { return [] }
        defer { close(root) }
        guard let dir = try openKept(root, domain: domain, run: run, make: false) else { return [] }
        defer { close(dir) }
        return try Self.keptIDs(in: dir).map { read($0, in: dir, domain: domain, run: run, whole: false) }
    }

    /// The kept run `id`, rows included. Picks among the files the folder lists, never a path built from `id`.
    public func load(_ domain: Domain, run: String, id: String) throws(Problem) -> AuditSchedules.KeptRun {
        let gone = AuditSchedules.KeptRun(id: id, problem: "It is no longer kept.")
        guard AuditSchedules.isRunKey(run), let root = try openRoot(make: false) else { return gone }
        defer { close(root) }
        guard let dir = try openKept(root, domain: domain, run: run, make: false) else { return gone }
        defer { close(dir) }
        guard let listed = try Self.keptIDs(in: dir).first(where: { $0.utf8.elementsEqual(id.utf8) }) else { return gone }
        return read(listed, in: dir, domain: domain, run: run, whole: true)
    }

    /// The kept run `<id>.jsonl` in the open folder: its header (and, `whole`, its rows), or why it can't be read.
    private func read(_ id: String, in dir: Int32, domain: Domain, run: String, whole: Bool) -> AuditSchedules.KeptRun {
        let fd = openat(dir, id + Self.keptSuffix, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .init(id: id, problem: "It couldn't be read just now.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .init(id: id, problem: "It couldn't be read just now.") }
        guard info.st_mode & S_IFMT == S_IFREG else { return .init(id: id, problem: "It isn't a file.") }
        guard info.st_size <= cap else { return .init(id: id, problem: "It's larger than this app reads.") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        let bytes: [UInt8]
        switch Self.readAll(fd, cap: whole ? cap : Self.headerCap, untilLine: !whole) {
        case .read(let read): bytes = read
        case .tooLarge: return .init(id: id, problem: "It's larger than this app reads.")
        case .failed: return .init(id: id, problem: "It couldn't be read just now.")
        }
        return Self.parseKept(bytes, id: id, domain: domain, run: run, whole: whole) ?? .init(id: id, problem: "It isn't whole.")
    }

    private enum Read { case read([UInt8]), tooLarge, failed }

    /// What the open file holds, up to `cap` bytes, or (`untilLine`) up to and including its first line break (a header with
    /// none in `cap` bytes is cut there, and then isn't whole). Too large only when the whole was asked and it held more.
    private static func readAll(_ fd: Int32, cap: Int, untilLine: Bool) -> Read {
        var bytes: [UInt8] = [], chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                if untilLine, let end = chunk[..<count].firstIndex(of: 0x0A) {
                    bytes += chunk[...end]
                    return .read(Array(bytes.prefix(cap)))
                }
                bytes += chunk[..<count]
                if bytes.count > cap { return untilLine ? .read(Array(bytes.prefix(cap))) : .tooLarge }
            } else if count == 0 {
                return .read(bytes)
            } else if errno != EINTR {
                return .failed
            }
        }
    }

    /// A list of text, every item text; nil for anything else.
    private static func texts(_ value: JSONValue?) -> [String]? {
        guard let items = value?.array else { return nil }
        let found = items.compactMap(\.string)
        return found.count == items.count ? found : nil
    }

    /// A kept run's file: its header naming this run, domain and id, then (`whole`) every kept table's columns and rows, each
    /// table's count matched and each row as long as its columns. Version 2 (GamGUI #178's `KEPT_VERSION`) keeps a table's columns
    /// with its rows; version 1 kept them in the header, and is still read. Nil for anything else.
    static func parseKept(_ bytes: [UInt8], id: String, domain: Domain, run: String, whole: Bool) -> AuditSchedules.KeptRun? {
        guard let text = String(validating: bytes, as: UTF8.self) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, let head = JSONValue.parse(String(first))?.object, let version = head["version"]?.int,
              version == 1 || version == AuditSchedules.keptVersion,
              head["id"]?.string.map({ $0.utf8.elementsEqual(id.utf8) }) == true, head["domain"]?.string == domain.name,
              head["run"]?.string == run, let when = head["when"]?.double, AuditSchedules.isTime(when),
              let days = head["days"]?.int, (0...AuditSchedules.maxDays).contains(days), let raw = head["tables"]?.array
        else { return nil }
        var tables: [AuditSchedules.KeptTable] = []
        for item in raw {
            // Version 1 kept the columns here; 2 keeps them with the rows.
            let columns = version == 1 ? texts(item["columns"]) : []
            guard let key = item["key"]?.string, let title = item["title"]?.string, let columns,
                  let known = item["known"]?.bool, let partial = item["partial"]?.bool, let count = item["count"]?.int, count >= 0,
                  let kept = item["kept"]?.bool
            else { return nil }
            tables.append(.init(key: key, title: title, columns: columns, known: known, partial: partial, count: count, kept: kept))
        }
        if whole {
            var rows: [String: (columns: [String]?, rows: [[String]])] = [:]
            for line in lines.dropFirst() where !line.isEmpty {
                guard let body = JSONValue.parse(String(line)), let key = body["table"]?.string, let found = body["rows"]?.array
                else { return nil }
                let columns: [String]?
                if body["columns"] == nil {
                    columns = nil
                } else {
                    guard let listed = texts(body["columns"]) else { return nil }
                    columns = listed
                }
                var table: [[String]] = []
                for row in found {
                    guard let cells = row.array else { return nil }
                    var out: [String] = []
                    for cell in cells {
                        if case .null = cell { out.append("") } else if let text = cell.string { out.append(text) } else { return nil }
                    }
                    table.append(out)
                }
                rows[key] = (columns, table)
            }
            for index in tables.indices where tables[index].kept {
                guard let found = rows[tables[index].key], found.rows.count == tables[index].count else { return nil }
                if let columns = found.columns {
                    tables[index].columns = columns
                } else if version != 1 {
                    return nil   // version 2 keeps a table's columns with its rows
                }
                let width = tables[index].columns.count
                guard found.rows.allSatisfy({ $0.count == width }) else { return nil }
                tables[index].rows = found.rows
            }
        }
        return .init(id: id, when: when, days: days, tables: tables)
    }

    /// Keeps a run's tables whole, as the next kept run of `run` on `domain`, in the held store folder `root`.
    private func keep(_ root: Int32, domain: Domain, run: String, when: Double, days: Int,
                      tables: [AuditSchedules.Table]) throws(Problem) {
        guard let dir = try openKept(root, domain: domain, run: run, make: true) else { throw Problem("Its folder couldn't be made.") }
        defer { close(dir) }
        // Named by the order kept, not by the clock: a run kept while the Mac's clock was wrong would otherwise sort ahead of
        // every later one, be compared with forever and outlive them all in a prune.
        let last = try Self.keptIDs(in: dir).first.flatMap { Int($0.prefix(13)) } ?? 0
        // A 14th digit would name a file no listing sees, so no prune or delete would ever take it.
        guard last < 9_999_999_999_999 else {
            throw Problem("Its kept runs' names have run out (a file there isn't one this app wrote). Delete the kept runs.")
        }
        let digits = String(last + 1), hex = String(UInt32.random(in: .min ... .max), radix: 16)
        let id = String(repeating: "0", count: max(0, 13 - digits.count)) + digits + "-" + String(repeating: "0", count: 8 - hex.count) + hex
        let heads = tables.map { table in
            AuditSchedules.KeptTable(key: table.key, title: table.title, columns: table.columns, known: table.known,
                                     partial: table.partial, count: table.rows.count, kept: table.known && table.rows.count <= rowsCap)
        }
        // The first line, which a listing reads alone, holds no columns (version 2, GamGUI #178): a read GAM flattens has as many
        // as its widest record needs (13 a member for every member of the largest shared drive), which would make it too long to
        // read back under `headerCap`.
        let header: JSONObject = [
            "version": .number(String(AuditSchedules.keptVersion)), "id": .string(id), "domain": .string(domain.name),
            "run": .string(run), "when": .number(String(when)), "days": .number(String(days)),
            "tables": .array(heads.map { t in
                .object(["key": .string(t.key), "title": .string(t.title), "known": .bool(t.known), "partial": .bool(t.partial),
                         "count": .number(String(t.count)), "kept": .bool(t.kept)])
            }),
        ]
        var bytes = Array((JSONValue.dumps(.object(header)) + "\n").utf8)
        for (table, head) in zip(tables, heads) where head.kept {
            let line: JSONObject = ["table": .string(table.key), "columns": .array(table.columns.map(JSONValue.string)),
                                    "rows": .array(table.rows.map { .array($0.map(JSONValue.string)) })]
            bytes += Array((JSONValue.dumps(.object(line)) + "\n").utf8)
            guard bytes.count <= cap else {
                throw Problem("It holds more than this app keeps of a run (\(cap >> 20) MB), so the next run can't say what changed "
                              + "since this one.")
            }
        }
        try Self.writeWhole(bytes, named: id + Self.keptSuffix, in: dir, temporary: Self.tempPrefix, replacing: false)
    }

    /// Removes `name` (a folder with `AT_REMOVEDIR`) from the open folder: true when it went, false when it was already gone.
    /// Any other failure (a file locked in Finder, EPERM) is counted in `failed`, so a delete that left data is never said done
    /// (GamGUI's `_unlink`, which raises all but FileNotFoundError).
    private static func remove(_ name: String, in dir: Int32, flags: Int32 = 0, failed: inout [Int32]) -> Bool {
        if unlinkat(dir, name, flags) == 0 { return true }
        if errno != ENOENT { failed.append(errno) }
        return false
    }

    /// A problem for the removals that failed, or nil when none did.
    private static func notDeleted(_ failed: [Int32]) -> Problem? {
        guard let code = failed.first else { return nil }
        return Problem("\(failed.count) of its files couldn't be deleted (\(String(cString: strerror(code)))): check they aren't "
                       + "locked in Finder, then try again.")
    }

    /// Deletes all but the newest `keep` kept runs (and a crash's half-written leftovers, best effort); how many went. Throws
    /// when one couldn't be deleted, after trying every one.
    private func prune(_ root: Int32, domain: Domain, run: String, keep: Int) throws(Problem) -> Int {
        guard let dir = try openKept(root, domain: domain, run: run, make: false) else { return 0 }
        defer { close(dir) }
        var gone = 0, failed: [Int32] = []
        for id in try Self.keptIDs(in: dir).dropFirst(max(keep, 0)) where Self.remove(id + Self.keptSuffix, in: dir, failed: &failed) {
            gone += 1
        }
        for name in try Self.names(in: dir) where name.hasPrefix(Self.tempPrefix) {
            var info = stat()
            if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0, now() - Double(info.st_mtimespec.tv_sec) > Self.staleTemp {
                unlinkat(dir, name, 0)
            }
        }
        if let problem = Self.notDeleted(failed) { throw problem }
        return gone
    }

    /// Every kept run of `run` on `domain`, its half-written leftovers and its folder; how many runs went. Throws when anything
    /// there couldn't be deleted, after trying every one: a file locked in Finder, or something else left in its folder.
    private func deleteAll(_ root: Int32, domain: Domain, run: String) throws(Problem) -> Int {
        guard let dir = try openKept(root, domain: domain, run: run, make: false) else { return 0 }
        var gone = 0, failed: [Int32] = []
        do {
            defer { close(dir) }
            for name in try Self.names(in: dir) {
                if name.hasSuffix(Self.keptSuffix), Self.isKeptID(String(name.dropLast(Self.keptSuffix.count))) {
                    if Self.remove(name, in: dir, failed: &failed) { gone += 1 }
                } else if name.hasPrefix(Self.tempPrefix) {
                    _ = Self.remove(name, in: dir, failed: &failed)
                }
            }
        }
        if let domainDir = try openKept(root, domain: domain, run: nil, make: false) {
            _ = Self.remove(run, in: domainDir, flags: AT_REMOVEDIR, failed: &failed)
            close(domainDir)
        }
        if let problem = Self.notDeleted(failed) { throw problem }
        return gone
    }

    // MARK: what a screen and a run ask

    /// A finished run, on the domain it read: when `run` is scheduled there, each table against the last kept run that read it,
    /// then this run kept (when `answered`), the oldest beyond its count deleted, and the schedule told it counted. Nothing is
    /// kept or counted for a run that isn't scheduled, or whose schedule can't be read. Reads and writes files: off the main
    /// actor.
    public func afterRun(_ domain: Domain, run: String, tables: [AuditSchedules.Table], days: Int, answered: Bool, when: Double,
                         clock: AuditSchedules.Clock) -> AuditSchedules.AfterRun {
        let schedule: Schedule?
        do throws(Problem) {
            schedule = try schedules(domain)[run]
        } catch {
            return .init(changes: [:], note: "\(error.reason) So this run isn't kept and isn't compared.", problem: true)
        }
        guard schedule != nil else { return .init(changes: [:]) }
        // A table built on a step with no answer can hold "unknown" cells with no partial flag: never compared.
        guard answered else {
            return .init(changes: Dictionary(tables.map { ($0.key, AuditSchedules.Change(key: $0.key, why: AuditSchedules.notAnswered)) },
                                             uniquingKeysWith: { a, _ in a }),
                         note: "Not kept, and it doesn't count as its scheduled run: a step has no answer.", problem: true)
        }
        var changes: [String: AuditSchedules.Change]
        do throws(Problem) {
            let earlier = try runs(domain, run: run)
            changes = AuditSchedules.changesSince(tables, days: days, earlier: earlier, clock: clock) { id in
                do throws(Problem) {
                    return try load(domain, run: run, id: id)
                } catch {
                    return .init(id: id, problem: error.reason)
                }
            }
        } catch {
            changes = Dictionary(tables.map { table in
                (table.key, AuditSchedules.Change(key: table.key, why: !table.known ? AuditSchedules.notKnownNow
                                                  : table.partial ? AuditSchedules.partUnknownNow : AuditSchedules.keptUnread))
            }, uniquingKeysWith: { a, _ in a })
        }
        meanwhile?()
        do throws(Problem) {
            return try locked(make: true) { (dir: Int32?) throws(Problem) -> AuditSchedules.AfterRun in
                guard let dir else { throw Problem(Self.unread) }
                // Looked at again: it may have been unscheduled, or its domain removed, while this run read.
                let now: Schedule?
                do throws(Problem) {
                    now = try load(dir)[domain.name]?[run]
                } catch {
                    return .init(changes: changes, note: "\(error.reason) So this run isn't kept.", problem: true)
                }
                guard let now else { return .init(changes: changes, note: "Not kept: it stopped being scheduled while it ran.") }
                var after = AuditSchedules.AfterRun(changes: changes,
                                                    note: "Kept on this Mac, as one of the last \(now.keep) run\(now.keep != 1 ? "s" : "") it keeps.")
                do throws(Problem) {
                    try keep(dir, domain: domain, run: run, when: when, days: days, tables: tables)
                    do throws(Problem) {
                        _ = try prune(dir, domain: domain, run: run, keep: now.keep)
                    } catch {
                        after.note = "Kept on this Mac, but its older runs beyond the last \(now.keep) couldn't all be deleted: \(error.reason)"
                        after.problem = true
                    }
                } catch {
                    after.note = "It couldn't be kept on this Mac: \(error.reason)"
                    after.problem = true
                }
                do throws(Problem) {
                    try markDone(dir, domain: domain, run: run, when: when)
                } catch {
                    after.note += " It counts as its scheduled run, but that couldn't be saved, so it may still say it's due."
                    after.problem = true
                }
                return after
            }
        } catch {
            return .init(changes: changes, note: "\(error.reason) So this run isn't kept.", problem: true)
        }
    }

    /// Saves `run`'s schedule on `domain` (`cadence` nil: stops scheduling it), then makes what it keeps match: its newest
    /// `keep`, or none. The saved schedule, and how many kept runs were deleted (nil: they couldn't all be). Throws when the
    /// schedule itself couldn't be saved; then nothing was deleted.
    @discardableResult
    public func setSchedule(_ domain: Domain, run: String, cadence: AuditSchedules.Cadence?, keep: Int,
                            now: Double) throws(Problem) -> (saved: Schedule?, gone: Int?) {
        try locked(make: true) { (dir: Int32?) throws(Problem) in
            guard let dir else { throw Problem(Self.unread) }
            let saved = try put(dir, domain: domain, run: run, cadence: cadence, keep: keep, now: now)
            sweepTemporaries(dir)
            let gone: Int?
            if let saved {
                gone = try? prune(dir, domain: domain, run: run, keep: saved.keep)
            } else {
                gone = try? deleteAll(dir, domain: domain, run: run)
            }
            return (saved, gone)
        }
    }

    /// A crash's half-written schedules files (tenant data too), older than `staleTemp`, in the held store folder.
    private func sweepTemporaries(_ dir: Int32) {
        for name in (try? Self.names(in: dir)) ?? [] where name.hasPrefix(".schedules-") {
            var info = stat()
            if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
               now() - Double(info.st_mtimespec.tv_sec) > Self.staleTemp {
                unlinkat(dir, name, 0)
            }
        }
    }

    /// Every kept run of `run` on `domain`; how many went. Its schedule stays.
    public func deleteKept(_ domain: Domain, run: String) throws(Problem) -> Int {
        guard AuditSchedules.isRunKey(run) else { return 0 }
        return try locked(make: false) { (dir: Int32?) throws(Problem) in
            guard let dir else { return 0 }
            return try deleteAll(dir, domain: domain, run: run)
        }
    }

    /// The runs `domain` has a kept-runs folder for in the held store folder, whatever they hold, sorted; nil when the domain has
    /// no folder. A link among them is passed over: nothing to follow.
    private func runFolders(_ dir: Int32, domain: Domain) throws(Problem) -> [String]? {
        guard let domainDir = try openKept(dir, domain: domain, run: nil, make: false) else { return nil }
        defer { close(domainDir) }
        return try Self.names(in: domainDir).filter { name in
            var info = stat()
            return AuditSchedules.isRunKey(name) && fstatat(domainDir, name, &info, AT_SYMLINK_NOFOLLOW) == 0
                && info.st_mode & S_IFMT == S_IFDIR
        }.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// The runs `domain` has kept runs folders for, whatever they hold (GamGUI #178's `run_keys`): a run nothing here runs any
    /// more still has its kept runs listed, so they can be deleted. A problem when that can't be told.
    public func runKeys(_ domain: Domain) throws(Problem) -> [String] {
        try locked(make: false) { (dir: Int32?) throws(Problem) in
            guard let dir else { return [] }
            return try runFolders(dir, domain: domain) ?? []
        }
    }

    /// Every schedule of `domain` and every run they kept (Setup removed it): how many of each went. The schedules go first, so
    /// a run finishing meanwhile finds itself unscheduled and keeps nothing.
    public func forget(_ domain: Domain) throws(Problem) -> (schedules: Int, kept: Int) {
        try locked(make: false) { (dir: Int32?) throws(Problem) in
            guard let dir else { return (0, 0) }
            var every = try load(dir)
            let schedules = every.removeValue(forKey: domain.name)?.count ?? 0
            if schedules > 0 { try save(every, in: dir) }
            guard let runs = try runFolders(dir, domain: domain) else { return (schedules, 0) }
            var kept = 0, problem: Problem?
            for run in runs {   // every run tried, the first problem thrown once all were
                do throws(Problem) { kept += try deleteAll(dir, domain: domain, run: run) } catch { problem = problem ?? error }
            }
            if let keptDir = try Self.openFolder("kept", in: dir, shown: root.appending(path: "kept").path, make: false) {
                var failed: [Int32] = []
                // Something left in the domain's folder (a link a run's listing passed over) is data left: said.
                _ = Self.remove(Self.domainFolder(domain), in: keptDir, flags: AT_REMOVEDIR, failed: &failed)
                close(keptDir)
                problem = problem ?? Self.notDeleted(failed)
            }
            if let problem { throw problem }
            return (schedules, kept)
        }
    }
}
