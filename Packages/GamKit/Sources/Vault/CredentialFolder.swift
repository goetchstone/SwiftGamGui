import Darwin
import Foundation

/// Reads GAM's credential files from a folder the operator picked (a GAM config folder, `~/.gam`), by
/// descriptor (invariant 5). Each file is opened relative to the folder with `O_NOFOLLOW | O_NONBLOCK`,
/// must be a regular file under a size cap, and is read from that same descriptor: a symlinked
/// credential is refused, and a FIFO named `oauth2service.json` can't hang the import (GamGUI
/// failure-log 2026-09-23). The operator's files are never modified or removed here.
public enum CredentialFolder {
    /// Every credential GAM writes is a few KB.
    public static let sizeCap = 64 * 1024

    public enum Failure: Error, Equatable, Sendable {
        case notAFolder
        case missing([Credential])
        case notARegularFile(String)
        case tooLarge(String)
        case notJSON(String)
        case unreadable(String, Int32)
    }

    /// The credentials present in `folder`. Throws `missing` unless the ones GAM needs are there;
    /// `client_secrets.json` is optional.
    public static func read(_ folder: URL) throws -> [Credential: Data] {
        let dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { throw Failure.notAFolder }
        defer { close(dir) }
        var found: [Credential: Data] = [:]
        for credential in Credential.allCases {
            if let data = try readFile(credential.fileName, in: dir) {
                guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    throw Failure.notJSON(credential.fileName)
                }
                found[credential] = data
            }
        }
        let missing = Credential.required.filter { found[$0] == nil }
        guard missing.isEmpty else { throw Failure.missing(missing) }
        return found
    }

    private static func readFile(_ name: String, in dir: Int32) throws -> Data? {
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: return nil
            case ELOOP: throw Failure.notARegularFile(name)
            default: throw Failure.unreadable(name, errno)
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw Failure.notARegularFile(name)
        }
        guard Int(info.st_size) <= sizeCap else { throw Failure.tooLarge(name) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: sizeCap + 1)
        guard data.count <= sizeCap else { throw Failure.tooLarge(name) }
        return data
    }
}
