import Darwin
import Foundation

/// The private folder the guided setup's Terminal commands write GAM's credentials into (GamGUI's
/// `managed_setup_dir`), and the import from it. Once the Vault holds the credentials, the plain-text
/// copies here are wiped, since a same-user process could read them without a Keychain prompt; a
/// folder the operator picked (their own `~/.gam`) is never touched.
///
/// Ported with GamGUI's failure history (`core/setup.py`, `import_dir`, `_is_managed`, `_wipe_file`),
/// and two holes its wipe also had (PR #16's review):
/// - **ours by identity, not by name**: the folder is opened without following a link, must be private
///   and this user's, and must be the inode `prepare` made just before (a case-variant spelling once
///   skipped the wipe; a folder swapped for a link once had GamGUI wipe files it never imported);
/// - **only what reached the Vault**: a file is wiped only while it is still the inode read, inside the
///   folder held open since the read, and still holds exactly the bytes the Vault took. A credential
///   GAM rewrote in place meanwhile (a command still running) is left for the next import;
/// - **never another path's bytes**: a file with another hard link (say, to `~/.gam/oauth2.txt`) only
///   loses its name here; overwriting it would zero the other path's file too;
/// - **only after the Vault has them**: a failed store wipes nothing.
public struct SetupFolder: Sendable, Equatable {
    public enum Failure: Error, Equatable, Sendable {
        /// Not a private folder of this user's (a link, someone else's, readable by others).
        case unsafe(String)
        /// The folder at `url` is no longer the one `prepare` made.
        case replaced
    }

    public let url: URL
    let identity: CredentialFolder.FileIdentity

    /// `setup` beside the per-call run folder, in the app's own Application Support folder.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "SwiftGamGui/setup")
    }

    /// Creates the folder (`0700`) if needed and checks it, through one descriptor: a real directory
    /// (a link in its place is refused, never followed), this user's, private, with no ACL allow entry.
    /// Called before each use, so a folder deleted or loosened since is made private again.
    public static func prepare(_ url: URL = defaultURL) throws -> SetupFolder {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let dir = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw Failure.unsafe(url.path) }
        defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid() else { throw Failure.unsafe(url.path) }
        _ = fchmod(dir, 0o700)
        guard FolderSafety.isPrivate(fd: dir), fstat(dir, &info) == 0 else { throw Failure.unsafe(url.path) }
        return SetupFolder(url: url, identity: CredentialFolder.FileIdentity(info))
    }

    /// The credentials GAM wrote here, read by descriptor (invariant 5) from the folder `prepare` made.
    /// Call `wipe()` on the result once the Vault holds them; dropping it without wiping leaves the files.
    package func stage() throws -> Staged {
        let dir = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw Failure.replaced }
        var info = stat()
        guard fstat(dir, &info) == 0, CredentialFolder.FileIdentity(info) == identity else {
            close(dir)
            throw Failure.replaced
        }
        guard FolderSafety.isPrivate(fd: dir) else {
            close(dir)
            throw Failure.unsafe(url.path)
        }
        do {
            let (found, read) = try CredentialFolder.read(in: dir)
            return Staged(dir: dir, found: found, read: read)
        } catch {
            close(dir)
            throw error
        }
    }

    /// Credentials read from the setup folder, with the folder held open so the wipe acts on the same
    /// directory the read did.
    package final class Staged: @unchecked Sendable {
        package let found: [Credential: Secret]
        private let read: [Credential: CredentialFolder.FileIdentity]
        private let dir: Int32

        init(dir: Int32, found: [Credential: Secret], read: [Credential: CredentialFolder.FileIdentity]) {
            self.dir = dir
            self.found = found
            self.read = read
        }

        deinit { close(dir) }

        /// Removes each file read, if it is still the inode read and still holds the bytes the Vault took;
        /// one with no other link is overwritten first. APFS makes a true secure erase unreliable, so the
        /// overwrite is defence in depth; the guarantee is that nothing else is ever destroyed. Returns
        /// the credentials removed.
        @discardableResult
        package func wipe() -> [Credential] {
            read.keys.sorted().filter { credential in
                guard let identity = read[credential], let bytes = found[credential]?.bytes else { return false }
                return wipe(credential.fileName, expecting: identity, holding: bytes)
            }
        }

        /// The credential files still in the folder after a wipe: one rewritten since the read, or an
        /// optional one the read refused (not JSON, too large). The operator is told to remove them.
        package func remaining() -> [Credential] {
            Credential.allCases.filter { credential in
                var info = stat()
                return fstatat(dir, credential.fileName, &info, AT_SYMLINK_NOFOLLOW) == 0
            }
        }

        private func wipe(_ name: String, expecting identity: CredentialFolder.FileIdentity, holding bytes: Data) -> Bool {
            let fd = openat(dir, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return false }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  CredentialFolder.FileIdentity(info) == identity, Self.contents(of: fd, size: Int(info.st_size)) == bytes
            else {
                close(fd)
                return false
            }
            if info.st_nlink == 1 {
                Self.overwrite(fd, size: Int(info.st_size))
            }
            close(fd)
            // unlink has to name the file: re-check the name still points at that inode first. Losing
            // the last sliver of a race can only leave a file, never remove the wrong one.
            guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  CredentialFolder.FileIdentity(info) == identity
            else { return false }
            return unlinkat(dir, name, 0) == 0
        }

        /// The file's bytes, read from the start through `fd`, or nil past the import's size cap.
        private static func contents(of fd: Int32, size: Int) -> Data? {
            guard size <= CredentialFolder.sizeCap else { return nil }
            guard size > 0 else { return Data() }
            var data = Data(count: size)
            let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, size, 0) }
            return n == size ? data : nil
        }

        private static func overwrite(_ fd: Int32, size: Int) {
            let zeros = [UInt8](repeating: 0, count: 16 * 1024)
            var offset = 0
            while offset < size {
                let n = zeros.withUnsafeBytes { pwrite(fd, $0.baseAddress!, min(size - offset, $0.count), off_t(offset)) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return }
                offset += n
            }
            _ = fsync(fd)
        }
    }
}
