import Darwin
import Foundation
import Synchronization

/// A private `GAMCFGDIR` holding GAM's credential files for exactly one `gam` call (invariant 4).
///
/// The directory is `0700` and every file `0600`, created exclusively and never through a symlink.
/// `wipe()` zeroes each regular file (bounded) and removes the tree; it never opens anything that
/// isn't a regular file, so a planted symlink, FIFO or device can't aim it elsewhere or hang it. Three
/// backstops cover a wipe that never ran: the caller's own `wipe()`, `wipeAllLive()` at app
/// termination, and `sweepStale(in:)` at launch for a crash. Port of GamGUI's
/// `core/secrets/ephemeral.py` and the failure history recorded there.
public final class EphemeralConfig: Sendable {
    public static let pidFileName = ".swiftgamgui.pid"
    static let prefix = "gamcfg-"
    /// Every file we write is a few KB. The cap stops a planted huge sparse file from turning the
    /// zeroing into a memory or disk exhaustion (GamGUI failure-log 2026-09-23).
    static let zeroChunk = 64 * 1024
    static let zeroMax = 1 << 20
    /// A live-looking owner PID protects a directory from the sweep only this long: PIDs are reused,
    /// and no real `gam` call lasts a day.
    static let livePIDTrust: TimeInterval = 24 * 60 * 60
    static let maxDepth = 8

    /// Paths materialized by this process and not yet wiped.
    static let live = Mutex<Set<String>>([])

    public let url: URL

    private init(url: URL) {
        self.url = url
    }

    public enum Failure: Error, Equatable, Sendable {
        case unsafeRuntimeDirectory(String)
        case invalidFileName(String)
        case io(String, Int32)
    }

    /// Creates a fresh directory under `base` and writes `files` (name → contents) into it. All or
    /// nothing: if any step fails, the directory is wiped before the error is thrown.
    public static func materialize(files: [String: Data], in base: URL) throws -> EphemeralConfig {
        try RuntimeDirectory.verify(base)
        for name in files.keys where !isPlainName(name) {
            throw Failure.invalidFileName(name)
        }
        var template = Array(base.appending(path: "\(prefix)XXXXXXXX").path.utf8CString)
        guard let made = mkdtemp(&template) else {
            throw Failure.io("mkdtemp", errno)
        }
        let config = EphemeralConfig(url: URL(filePath: String(cString: made)))
        // Registered before anything is written, so the termination backstop can't miss it.
        live.withLock { _ = $0.insert(config.url.path) }
        do {
            let dir = open(config.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dir >= 0 else { throw Failure.io("open dir", errno) }
            defer { close(dir) }
            try writeExclusive(Data("\(getpid())".utf8), named: pidFileName, in: dir)
            for (name, contents) in files {
                try writeExclusive(contents, named: name, in: dir)
            }
        } catch {
            config.wipe()
            throw error
        }
        return config
    }

    /// Reads a file GAM may have rewritten (a refreshed `oauth2.txt`): regular files only, never
    /// through a symlink, at most `cap` bytes.
    public func readFile(_ name: String, cap: Int = 1 << 20) -> Data? {
        guard Self.isPlainName(name) else { return nil }
        let fd = open(url.appending(path: name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= cap else {
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: cap)
    }

    /// Zeroes and removes the directory. Idempotent. Returns true when it is gone; a directory that
    /// survives stays registered so `wipeAllLive()` tries again.
    @discardableResult
    public func wipe() -> Bool {
        let gone = Self.removeTree(at: url)
        if gone {
            Self.live.withLock { _ = $0.remove(url.path) }
        }
        return gone
    }

    /// Wipes every directory this process materialized and didn't wipe (only those under `base`, when
    /// given). Call at app termination. Returns the paths that could not be removed.
    @discardableResult
    public static func wipeAllLive(under base: URL? = nil) -> [String] {
        let prefix = base.map { $0.path + "/" }
        let paths = live.withLock { $0 }.filter { prefix == nil || $0.hasPrefix(prefix!) }
        var left: [String] = []
        for path in paths {
            if removeTree(at: URL(filePath: path)) {
                live.withLock { _ = $0.remove(path) }
            } else {
                left.append(path)
            }
        }
        return left
    }

    /// Removes orphaned `gamcfg-*` directories a crash or force-quit left under `base`. A directory
    /// whose recorded owner is dead goes at once; a live-looking owner protects it for up to a day;
    /// one with no usable marker goes once older than `maxAge`. Directories this process is using,
    /// and anything that isn't a real directory (a symlink), are never touched. Returns the count.
    @discardableResult
    public static func sweepStale(in base: URL, maxAge: TimeInterval = 600, now: Date = Date()) -> Int {
        let baseFD = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard baseFD >= 0 else { return 0 }
        defer { close(baseFD) }
        let using = live.withLock { $0 }
        var removed = 0
        for name in names(in: baseFD) where name.hasPrefix(prefix) {
            var info = stat()
            guard fstatat(baseFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  !using.contains(base.appending(path: name).path)
            else { continue }
            let age = now.timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec)
            let stale: Bool
            if let pid = ownerPID(of: name, in: baseFD) {
                stale = !isAlive(pid) || age > livePIDTrust
            } else {
                stale = age > maxAge
            }
            if stale {
                removeEntry(named: name, in: baseFD, depth: 0)
                removed += 1
            }
        }
        return removed
    }

    // MARK: - File primitives (descriptor-relative, never following a link)

    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func writeExclusive(_ data: Data, named name: String, in dir: Int32) throws {
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io("create \(name)", errno) }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw Failure.io("chmod \(name)", errno) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { throw Failure.io("write \(name)", errno) }
                offset += n
            }
        }
    }

    /// Removes `url` (a directory we created) and everything under it. True when nothing is left.
    static func removeTree(at url: URL) -> Bool {
        let parentFD = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else {
            return access(url.path, F_OK) != 0
        }
        defer { close(parentFD) }
        removeEntry(named: url.lastPathComponent, in: parentFD, depth: 0)
        var info = stat()
        return fstatat(parentFD, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0
    }

    /// Directories are descended (bounded depth) and removed; regular files are zeroed, then
    /// unlinked; anything else (a symlink, FIFO, socket, device) is unlinked without being opened.
    static func removeEntry(named name: String, in dirFD: Int32, depth: Int) {
        var info = stat()
        guard fstatat(dirFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            let fd = openat(dirFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                if depth < maxDepth {
                    for child in names(in: fd) {
                        removeEntry(named: child, in: fd, depth: depth + 1)
                    }
                }
                close(fd)
            }
            unlinkat(dirFD, name, AT_REMOVEDIR)
        case S_IFREG:
            zero(named: name, in: dirFD)
            unlinkat(dirFD, name, 0)
        default:
            unlinkat(dirFD, name, 0)
        }
    }

    private static func zero(named name: String, in dirFD: Int32) {
        // O_NONBLOCK: if the entry was swapped for a FIFO since fstatat, the open fails at once.
        let fd = openat(dirFD, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        let size = min(Int(info.st_size), zeroMax)
        let chunk = [UInt8](repeating: 0, count: min(zeroChunk, max(size, 1)))
        var written = 0
        while written < size {
            let n = chunk.withUnsafeBytes { write(fd, $0.baseAddress!, min(chunk.count, size - written)) }
            guard n > 0 else { break }
            written += n
        }
        fsync(fd)
    }

    static func names(in dirFD: Int32) -> [String] {
        let copy = dup(dirFD)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var result: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." {
                result.append(name)
            }
        }
        return result
    }

    private static func ownerPID(of dirName: String, in baseFD: Int32) -> pid_t? {
        let dir = openat(baseFD, dirName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return nil }
        defer { close(dir) }
        let fd = openat(dir, pidFileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buffer = [UInt8](repeating: 0, count: 32)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0, let text = String(bytes: buffer[0..<n], encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }   // 0 and negatives mean "process group" to kill(2): never trust them
        return pid
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// The private parent of every `gamcfg-*` directory.
public enum RuntimeDirectory {
    /// `~/Library/Application Support/SwiftGamGui/run`: its own folder, never the Python GamGUI's.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "SwiftGamGui/run")
    }

    /// Creates the directory (`0700`) if needed and checks it is safe to use.
    @discardableResult
    public static func prepare(_ url: URL = defaultURL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(url.path, 0o700)
        try verify(url)
        return url
    }

    /// A real directory (not a symlink), owned by this user, with no access for anyone else.
    static func verify(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0
        else { throw EphemeralConfig.Failure.unsafeRuntimeDirectory(url.path) }
    }
}
