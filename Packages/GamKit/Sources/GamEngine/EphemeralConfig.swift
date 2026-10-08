import Darwin
import Foundation
import Synchronization

/// A private `GAMCFGDIR` holding GAM's credential files for exactly one `gam` call (invariant 4).
///
/// The directory is `0700` and every file `0600`, created exclusively and never through a symlink.
/// It is held by **descriptor** from creation to wipe, so moving it or planting a symlink at its path
/// can't redirect a read or the wipe. `wipe()` zeroes regular files that have no other hard link
/// (bounded), unlinks everything else without opening it, and removes the tree; only "no such file"
/// counts as gone. Three backstops cover a wipe that never ran: the caller's own `wipe()`,
/// `wipeAllLive()` at app termination, and `sweepStale(in:)` at launch for a crash. Port of GamGUI's
/// `core/secrets/ephemeral.py`, its failure history, and the PR #1 review.
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

    /// Directories materialized by this process and not yet wiped, by path.
    static let live = Mutex<[String: EphemeralConfig]>([:])

    public let url: URL
    private let dirFD: Int32
    private let device: dev_t
    private let inode: ino_t
    private let wiped = Mutex(false)

    private init(url: URL, dirFD: Int32, device: dev_t, inode: ino_t) {
        self.url = url
        self.dirFD = dirFD
        self.device = device
        self.inode = inode
    }

    deinit {
        // Only reached after a successful wipe (the live registry holds every unwiped instance).
        if !wiped.withLock({ $0 }) { close(dirFD) }
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
        let path = String(cString: made)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0 else {
            let error = errno
            if fd >= 0 { close(fd) }
            rmdir(path)
            throw Failure.io("open \(prefix)dir", error)
        }
        let config = EphemeralConfig(url: URL(filePath: path), dirFD: fd, device: info.st_dev, inode: info.st_ino)
        // Registered before anything is written, so the termination backstop can't miss it.
        live.withLock { $0[path] = config }
        do {
            try config.writeExclusive(Data("\(getpid())".utf8), named: pidFileName)
            for (name, contents) in files {
                try config.writeExclusive(contents, named: name)
            }
        } catch {
            config.wipe()
            throw error
        }
        return config
    }

    /// Reads a file GAM may have rewritten (a refreshed `oauth2.txt`), through the directory's own
    /// descriptor: a regular file with one link, never through a symlink, at most `cap` bytes.
    public func readFile(_ name: String, cap: Int = 1 << 20) -> Data? {
        guard Self.isPlainName(name), !wiped.withLock({ $0 }) else { return nil }
        let fd = openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              Int(info.st_size) <= cap
        else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: cap)
    }

    /// Empties and removes the directory. Idempotent. Returns true when no file is left in it and its
    /// path no longer names it; otherwise it stays registered so `wipeAllLive()` tries again.
    @discardableResult
    public func wipe() -> Bool {
        if wiped.withLock({ $0 }) { return true }
        // Contents first, through the descriptor: this empties the real directory even if its path
        // was swapped or it was moved elsewhere.
        for name in Self.names(in: dirFD) {
            Self.removeEntry(named: name, in: dirFD, depth: 0)
        }
        let emptied = Self.names(in: dirFD).isEmpty
        let detached = removeOwnEntry()
        guard emptied, detached else { return false }
        wiped.withLock { $0 = true }
        close(dirFD)
        Self.live.withLock { _ = $0.removeValue(forKey: url.path) }
        return true
    }

    /// Removes the directory's entry from its parent, but only if the entry is still this directory.
    /// True when the path no longer names it (removed, or something else now sits there).
    private func removeOwnEntry() -> Bool {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return errno == ENOENT }
        defer { close(parent) }
        let name = url.lastPathComponent
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        guard info.st_dev == device, info.st_ino == inode else { return true }
        unlinkat(parent, name, AT_REMOVEDIR)
        return fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
    }

    /// Wipes every directory this process materialized and didn't wipe (only those under `base`, when
    /// given). Call at app termination, after `GamRunner.stopAll()`. Returns the paths left behind.
    @discardableResult
    public static func wipeAllLive(under base: URL? = nil) -> [String] {
        let prefix = base.map { $0.path + "/" }
        let configs = live.withLock { $0 }.filter { prefix == nil || $0.key.hasPrefix(prefix!) }
        return configs.compactMap { path, config in config.wipe() ? nil : path }
    }

    /// Removes orphaned `gamcfg-*` directories a crash or force-quit left under `base`. A directory
    /// whose recorded owner is dead goes at once; a live-looking owner protects it for up to a day;
    /// one with no usable marker goes once older than `maxAge`. Directories this process is using,
    /// and anything that isn't a real directory (a symlink), are never touched. Returns how many
    /// were actually removed.
    @discardableResult
    public static func sweepStale(in base: URL, maxAge: TimeInterval = 600, now: Date = Date()) -> Int {
        let baseFD = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard baseFD >= 0 else { return 0 }
        defer { close(baseFD) }
        let using = Set(live.withLock { $0 }.keys)
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
                if fstatat(baseFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT {
                    removed += 1
                }
            }
        }
        return removed
    }

    // MARK: - File primitives (descriptor-relative, never following a link)

    /// One path component: checked on the bytes, so no Unicode composition can hide a `/`.
    static func isPlainName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return !bytes.isEmpty && bytes != [0x2E] && bytes != [0x2E, 0x2E]
            && !bytes.contains(0x2F) && !bytes.contains(0x00)
    }

    private func writeExclusive(_ data: Data, named name: String) throws {
        let fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
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

    /// Zeroes a regular file in place, but only one with a single link: a hard link to a file outside
    /// the directory must be unlinked, never written through.
    private static func zero(named name: String, in dirFD: Int32) {
        // O_NONBLOCK: if the entry was swapped for a FIFO since fstatat, the open fails at once.
        let fd = openat(dirFD, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { return }
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

    /// Creates the directory (`0700`) if needed and checks it is safe to use. Nothing is changed
    /// through a symlink: a link in its place is refused before any `chmod`.
    @discardableResult
    public static func prepare(_ url: URL = defaultURL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw EphemeralConfig.Failure.unsafeRuntimeDirectory(url.path)
        }
        chmod(url.path, 0o700)
        try verify(url)
        return url
    }

    /// A real directory (not a symlink), owned by this user, no permission bits for anyone else, and
    /// no ACL entry granting access (an inherited allow entry would reach the `0600` files).
    static func verify(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, !grantsByACL(url.path)
        else { throw EphemeralConfig.Failure.unsafeRuntimeDirectory(url.path) }
    }

    static func grantsByACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var which = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, which, &entry) == 0, let current = entry {
            var tag = acl_tag_t(rawValue: 0)
            if acl_get_tag_type(current, &tag) == 0, tag == ACL_EXTENDED_ALLOW { return true }
            which = Int32(ACL_NEXT_ENTRY.rawValue)
        }
        return false
    }
}
