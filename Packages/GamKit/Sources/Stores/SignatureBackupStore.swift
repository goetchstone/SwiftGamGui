import ChangeCore
import Darwin
import Foundation
import GamEngine
import Synchronization
import Vault

/// Signature backups: each person's Gmail signature as it was, kept on this Mac before a run replaces it, and what a Put
/// Back sets again. A port of GamGUI's `core/signature_backups.py` (#163, #164). Gmail keeps no copy of a replaced
/// signature, so ChangeCore's executor reads each one exactly (`Signature.exact`) and keeps it here, through
/// `SignatureKeeper`, before the write; nothing else keeps into it (`WriteRouteTests`). A screen lists and loads the runs.
///
/// One file per run, `<13-digit ms>-<8 hex>.jsonl`, in a `0700` folder of the app's data folder, made `0600` with
/// `O_CREAT|O_EXCL|O_NOFOLLOW`: a header line (`run`, `when`, `what`, `domain`), then one line per person (`email`,
/// `previous`, `set`), each flushed before that person's write, so a run cut off midway still holds every signature it
/// replaced. Only the last `keptRuns` runs are kept, made room for when a run that kept someone ends: never before (an
/// attempt that keeps nobody, a sign-in expired or every read refused, pushes nothing out, and its own empty file is
/// removed), never one still being written (a long run would lose its copies to shorter ones started meanwhile: each open
/// run holds an exclusive `flock` on its file, which any store in any process tests before it removes one, and each keep
/// checks its file is still there), and never
/// the run that one put back (whoever it didn't put back, left out, changed since or stopped before, is still there to put
/// back, until a later run that keeps someone pushes it out). GamGUI prunes when a run starts, which loses both.
///
/// Native, where GamGUI's could lose a copy or read the wrong one: the header names the domain the run was on (a Put
/// Back of another domain's run is refused); a keep that fails partway is cut back off the file, so the copies before it
/// stay readable; a file is never written past `sizeCap`, the most a load reads (invariant 9), so a run stops rather than
/// keep a copy no load could give back; and the folder is opened without following a link.
public final class SignatureBackupStore: SignatureKeeper, Sendable {
    /// GamGUI's `KEEP_RUNS`.
    public static let keptRuns = 5
    /// The most a run's file holds, and the most a load reads: about 1,600 people at Gmail's longest signature (10,000
    /// characters) kept with as long a new one, many more at a usual one.
    public static let sizeCap = 32 * 1024 * 1024
    public static let folderName = "signature-backups"
    static let suffix = ".jsonl"

    /// The app's: `signature-backups` in its data folder, beside the audit log and the templates.
    public static var defaultFolder: URL { SignatureStore.defaultRoot.appending(path: folderName) }

    public let folder: URL
    /// `sizeCap`, but for tests.
    let cap: Int
    private let now: @Sendable () -> Date

    /// `now` and `cap` are for tests.
    public init(folder: URL, now: @escaping @Sendable () -> Date = { Date() }, cap: Int = sizeCap) {
        self.folder = folder
        self.now = now
        self.cap = cap
    }

    /// One person's signature as a run found it, and what the run set.
    public struct Entry: Sendable, Equatable {
        public let email: String
        /// Their stored signature before the run, byte for byte; "" for none.
        public let previous: String
        /// What the run set.
        public let set: String

        public init(email: String, previous: String, set: String) {
            self.email = email
            self.previous = previous
            self.set = set
        }
    }

    /// A kept run, whole.
    public struct Run: Sendable, Identifiable {
        public let id: String
        public let when: Date
        /// What it applied to, in words (its title in the jobs tray).
        public let what: String
        /// The domain it ran on: a Put Back runs only there.
        public let domain: String
        public let entries: [Entry]
    }

    /// A kept run as listed: the run, or why it can't be read whole. Never dropped: its people's old signatures may be in it.
    public struct Listed: Sendable, Identifiable {
        public let id: String
        public let run: Run?
        public let problem: String?
    }

    /// Why a run can't be read whole, or can't be kept, in words. Never a part of a run.
    public struct Problem: Error, Sendable, Equatable {
        public let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    // MARK: a run being written (the executor's, through SignatureKeeper)

    /// A new run's file for `what` on `domain`, `0600` in the `0700` folder. Nothing is pruned here (`prune`, when a run
    /// that kept someone ends). `restoring`: the runs it puts back, spared then. Throws when it can't be made: then the
    /// executor replaces nothing.
    public func start(what: String, domain: Domain, restoring: Set<String>) throws -> any KeptSignatureRun {
        let dir = try privateFolder()
        var handedOver = false
        defer { if !handedOver { Darwin.close(dir) } }
        let id = Self.newID(now(), after: try listed(in: dir).first.flatMap(Self.milliseconds))
        let name = id + Self.suffix
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Problem("its file couldn't be made (\(String(cString: strerror(errno))))") }
        // Exactly 0600 whatever the umask: it can only have narrowed the mode `openat` was given. Locked while it's open,
        // so no store, in this process or another, prunes it.
        guard fchmod(fd, 0o600) == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlinkat(dir, name, 0)
            throw Problem("its file couldn't be made private (\(String(cString: strerror(code))))")
        }
        let run = KeptRun(id: id, name: name, fd: fd, dir: dir, cap: cap, restoring: restoring, store: self)
        handedOver = true
        let header: JSONObject = ["run": .string(id), "when": .number(String(now().timeIntervalSince1970)),
                                  "what": .string(what), "domain": .string(domain.name)]
        do {
            try run.append(.object(header))
        } catch {
            run.close()
            throw error
        }
        return run
    }

    /// Makes room as a run that kept someone ends: the newest `keptRuns` runs that aren't being written stay, and `sparing`
    /// (that run, and the runs it put back) stays whatever its age; the rest are removed. A run is being written while its
    /// file is locked (`flock`, by whichever store or process holds it open): one that can't be locked now is neither
    /// counted nor removed. Each removed is removed holding its lock. A folder that can't be listed prunes nothing.
    fileprivate func prune(in dir: Int32, sparing: Set<String>) {
        var closed = 0
        for old in (try? listed(in: dir)) ?? [] {
            let fd = openat(dir, old + Self.suffix, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            closed += 1
            if closed > Self.keptRuns, !sparing.contains(old) { unlinkat(dir, old + Self.suffix, 0) }
        }
    }

    /// `<13-digit ms>-<8 hex>`, as GamGUI names a run, made to sort after `after` (the newest run's milliseconds): ids only
    /// go forward, so a clock set back, or two runs in one millisecond, never makes the newest run sort as the oldest, and
    /// "the oldest" pruned is the oldest made. GamGUI's are the clock's alone.
    static func newID(_ when: Date, after newest: Int64? = nil) -> String {
        let clock = max(0, Int64((when.timeIntervalSince1970 * 1000).rounded(.down)))
        let milliseconds = newest.map { max(clock, $0 + 1) } ?? clock
        let digits = String(milliseconds), hex = String(UInt32.random(in: .min ... .max), radix: 16)
        return String(repeating: "0", count: max(0, 13 - digits.count)) + digits + "-"
            + String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// The milliseconds an id of this store's form starts with (13 digits, then `-`); nil for any other id.
    static func milliseconds(_ id: String) -> Int64? {
        let scalars = Array(id.unicodeScalars)
        guard scalars.count > 14, scalars[13] == "-", scalars[..<13].allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int64(String(String.UnicodeScalarView(scalars[..<13])))
    }

    // MARK: the kept runs

    /// The kept runs, newest first, each read whole or listed by its id with why it can't be. None when there's no folder
    /// yet; a folder there that can't be opened or listed throws, never reads as none. Reads every file: call it off the
    /// main actor.
    public func runs() throws(Problem) -> [Listed] {
        let dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else {
            let code = errno
            if code == ENOENT { return [] }
            throw Problem("their folder couldn't be opened (\(String(cString: strerror(code))))")
        }
        defer { Darwin.close(dir) }
        var found: [Listed] = []
        for id in try listed(in: dir) {
            do throws(Problem) {
                found.append(Listed(id: id, run: try read(id, in: dir), problem: nil))
            } catch {
                found.append(Listed(id: id, run: nil, problem: error.reason))
            }
        }
        return found
    }

    /// The kept run `id`, whole, or why not. The id only picks among the files the folder lists: the file opened is the
    /// listing's, never a path built from it (GamGUI's CodeQL fix in #164), and an id with a `/`, a NUL or a leading `.`
    /// is refused before that.
    public func load(_ id: String) throws(Problem) -> Run {
        guard Self.usableID(id) else { throw Problem("it isn't a kept run") }
        let dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw Problem("it isn't a kept run") }
        defer { Darwin.close(dir) }
        guard let listed = try listed(in: dir).first(where: { $0.utf8.elementsEqual(id.utf8) }) else {
            throw Problem("it isn't a kept run")
        }
        return try read(listed, in: dir)
    }

    /// An id a file can be named by here: not empty, and no `/`, NUL or leading `.`.
    static func usableID(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix(".") && !id.unicodeScalars.contains { $0 == "/" || $0 == "\0" }
    }

    /// The ids of the regular files `<id>.jsonl` in the open folder, newest first. A link, a folder or anything else is
    /// neither listed nor pruned. Throws when the folder can't be listed.
    private func listed(in dir: Int32) throws(Problem) -> [String] {
        let copy = dup(dir)
        guard copy >= 0, let stream = fdopendir(copy) else {
            let code = errno
            if copy >= 0 { Darwin.close(copy) }
            throw Problem("their folder couldn't be listed (\(String(cString: strerror(code))))")
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var ids: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(Self.suffix) else { continue }
            let id = String(name.dropLast(Self.suffix.count))
            var info = stat()
            guard Self.usableID(id), fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG
            else { continue }
            ids.append(id)
        }
        return ids.sorted { $1.unicodeScalars.lexicographicallyPrecedes($0.unicodeScalars) }
    }

    /// `<id>.jsonl` in the open folder, read by descriptor (no link followed, a regular file, at most `sizeCap`) and parsed
    /// whole.
    private func read(_ id: String, in dir: Int32) throws(Problem) -> Run {
        let bytes: [UInt8]
        do {
            guard let read = try SignatureStore.read(id + Self.suffix, in: dir, cap: cap) else {
                throw Problem("it isn't a kept run")
            }
            bytes = read
        } catch let refusal as SignatureStore.Refusal {
            throw Problem(refusal == .tooLarge ? "it's larger than this app reads" : "it couldn't be read (\(refusal.reason))")
        } catch let problem as Problem {
            throw problem
        } catch {
            throw Problem("it couldn't be read")
        }
        return try Self.parse(bytes, id: id)
    }

    /// A run's file, whole: a header naming this run, then each entry, every line JSON with every field. Anything else is a
    /// problem, never part of a run. A last line with no line break is an append that never finished (power lost while a
    /// copy was being written): that person's write never ran, since it waits for the keep, so the line is left out and
    /// the copies before it are the run. GamGUI reads such a run as not whole.
    static func parse(_ bytes: [UInt8], id: String) throws(Problem) -> Run {
        let whole = Problem("it isn't whole")
        guard let end = bytes.lastIndex(of: 0x0A), let text = String(validating: bytes[...end], as: UTF8.self) else { throw whole }
        let lines = PythonText.splitLF(text)
        guard let first = lines.first, let head = JSONValue.parse(first)?.object, let run = head["run"]?.string,
              let when = head["when"]?.double, when.isFinite, let what = head["what"]?.string, let domain = head["domain"]?.string,
              run.utf8.elementsEqual(id.utf8)
        else { throw whole }
        var entries: [Entry] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let entry = JSONValue.parse(line)?.object, let email = entry["email"]?.string,
                  let previous = entry["previous"]?.string, let set = entry["set"]?.string
            else { throw whole }
            entries.append(Entry(email: email, previous: previous, set: set))
        }
        return Run(id: id, when: Date(timeIntervalSince1970: when), what: what, domain: domain, entries: entries)
    }

    /// The folder, opened for a new run: made `0700` if it's new (its parents as the system makes them), set back to
    /// `0700` if it was loosened, and never through a link.
    private func privateFolder() throws(Problem) -> Int32 {
        try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(folder.path, 0o700) == 0 || errno == EEXIST else {
            throw Problem("its folder couldn't be made (\(String(cString: strerror(errno))))")
        }
        let dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw Problem("its folder couldn't be opened (\(String(cString: strerror(errno))))") }
        guard fchmod(dir, 0o700) == 0 else {
            let code = errno
            Darwin.close(dir)
            throw Problem("its folder couldn't be made private (\(String(cString: strerror(code))))")
        }
        return dir
    }
}

/// One run's file, open for appending: `keep` before each write, `close` when the run ends.
final class KeptRun: KeptSignatureRun {
    let id: String
    private let name: String
    private let cap: Int
    /// The runs this one puts back: never pruned as it ends.
    private let restoring: Set<String>
    private let store: SignatureBackupStore
    private let state: Mutex<State>

    private struct State {
        var fd: Int32
        var dir: Int32
        var kept = 0
        var bytes = 0
    }

    fileprivate init(id: String, name: String, fd: Int32, dir: Int32, cap: Int, restoring: Set<String>, store: SignatureBackupStore) {
        self.id = id
        self.name = name
        self.cap = cap
        self.restoring = restoring
        self.store = store
        state = Mutex(State(fd: fd, dir: dir))
    }

    var keptCount: Int { state.withLock { $0.kept } }

    func keep(email: String, previous: String, setting: String) throws {
        try append(.object(["email": .string(email), "previous": .string(previous), "set": .string(setting)]))
        state.withLock { $0.kept += 1 }
    }

    /// One line, written whole and flushed to disk, or cut back off and thrown: a keep that fails partway leaves the copies
    /// before it readable. Never past `sizeCap`.
    fileprivate func append(_ record: JSONValue) throws {
        let line = Array((JSONValue.dumps(record) + "\n").utf8)
        try state.withLock { (state: inout State) throws(SignatureBackupStore.Problem) in
            guard state.fd >= 0 else { throw SignatureBackupStore.Problem("the run has ended") }
            guard state.bytes + line.count <= cap else {
                throw SignatureBackupStore.Problem("it would be larger than this app reads")
            }
            do {
                try SignatureStore.writeAll(state.fd, line[...])
                guard fcntl(state.fd, F_FULLFSYNC) == 0 || fsync(state.fd) == 0 else { throw SignatureStore.Problem.notSaved(errno) }
            } catch {
                _ = ftruncate(state.fd, off_t(state.bytes))
                _ = lseek(state.fd, off_t(state.bytes), SEEK_SET)
                throw SignatureBackupStore.Problem("a copy couldn't be written (\(error))")
            }
            // Still a file in the folder: a copy flushed into a file someone removed is no copy, so the run stops instead.
            var info = stat()
            guard fstat(state.fd, &info) == 0, info.st_nlink > 0 else {
                throw SignatureBackupStore.Problem("its file was removed while the run went on")
            }
            state.bytes += line.count
        }
    }

    func close() {
        let ended = state.withLock { (state: inout State) -> (dir: Int32, kept: Int)? in
            guard state.fd >= 0 else { return nil }
            // A run that kept nobody (stopped before anyone, or refused every read) leaves no file, removed while it's still
            // locked, and pushes nothing out.
            if state.kept == 0 { unlinkat(state.dir, name, 0) }
            Darwin.close(state.fd)
            state.fd = -1
            let dir = state.dir
            state.dir = -1
            return (dir, state.kept)
        }
        guard let ended else { return }
        // One that kept someone makes room, sparing itself and what it put back.
        if ended.kept > 0 { store.prune(in: ended.dir, sparing: restoring.union([id])) }
        Darwin.close(ended.dir)
    }

    deinit { close() }
}
