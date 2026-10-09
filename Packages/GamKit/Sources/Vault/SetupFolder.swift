import Darwin
import Foundation

/// The private folder the guided setup's Terminal commands write GAM's credentials into (GamGUI's
/// `managed_setup_dir`), and the import from it. Once the Vault holds the credentials, the plain-text
/// copies here are wiped, since a same-user process could read them without a Keychain prompt; a
/// folder the operator picked (their own `~/.gam`) is never touched.
///
/// Ported with GamGUI's failure history (`core/setup.py`, `import_dir`, `_is_managed`, `_wipe_file`):
/// - **ours by identity, not by name**: the folder is opened without following a link and must be the
///   inode `prepare` made (a case-variant spelling once skipped the wipe; a folder swapped for a link
///   once had GamGUI wipe files it never imported);
/// - **only what was read**: each file is wiped only if it is still the inode whose bytes reached the
///   Vault, looked up inside the same open folder; anything else is left alone;
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

    /// `~/Library/Application Support/SwiftGamGui/setup`, beside the per-call run folder.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "SwiftGamGui/setup")
    }

    /// Creates the folder (`0700`) if needed and checks it: a real directory, this user's, private, with
    /// no ACL entry granting access. Nothing is changed through a link: one in its place is refused.
    public static func prepare(_ url: URL = defaultURL) throws -> SetupFolder {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let dir = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw Failure.unsafe(url.path) }
        defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid() else { throw Failure.unsafe(url.path) }
        _ = fchmod(dir, 0o700)
        guard fstat(dir, &info) == 0, info.st_mode & 0o077 == 0, !FolderSafety.grantsByACL(url.path) else {
            throw Failure.unsafe(url.path)
        }
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

        /// Overwrites and removes each file read, if it is still the same inode. APFS makes a true
        /// secure erase unreliable, so the overwrite is defence in depth; the guarantee is that nothing
        /// else is ever destroyed. Returns the credentials wiped.
        @discardableResult
        package func wipe() -> [Credential] {
            read.keys.sorted().filter { wipe($0.fileName, expecting: read[$0]!) }
        }

        private func wipe(_ name: String, expecting identity: CredentialFolder.FileIdentity) -> Bool {
            let fd = openat(dir, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return false }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  CredentialFolder.FileIdentity(info) == identity
            else {
                close(fd)
                return false
            }
            let zeros = [UInt8](repeating: 0, count: 16 * 1024)
            var left = Int(info.st_size)
            while left > 0 {
                let n = zeros.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, min(left, $0.count)) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                left -= n
            }
            _ = fsync(fd)
            close(fd)
            // unlink has to name the file: re-check the name still points at that inode first. Losing
            // the last sliver of a race can only leave a file, never remove the wrong one.
            guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  CredentialFolder.FileIdentity(info) == identity
            else { return false }
            return unlinkat(dir, name, 0) == 0
        }
    }
}
