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
        case notAServiceAccount
        case unreadable(String, Int32)
    }

    /// The credentials present in `folder`, as `Secret`s. Throws unless the ones GAM needs are there
    /// and well-formed; a problem with the optional `client_secrets.json` only leaves it out, as in
    /// GamGUI.
    public static func read(_ folder: URL) throws -> [Credential: Secret] {
        let dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { throw Failure.notAFolder }
        defer { close(dir) }
        return try read(in: dir).found
    }

    /// A file's identity: the inode its bytes were read from.
    package struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// The credentials in the open folder `dir`, and the identity of each file read.
    package static func read(in dir: Int32) throws -> (found: [Credential: Secret], read: [Credential: FileIdentity]) {
        var found: [Credential: Secret] = [:], identities: [Credential: FileIdentity] = [:]
        for credential in Credential.allCases {
            do {
                if let (data, identity) = try readFile(credential.fileName, in: dir) {
                    try check(data, as: credential)
                    found[credential] = Secret(data)
                    identities[credential] = identity
                }
            } catch where !Credential.required.contains(credential) {
                continue
            }
        }
        let missing = Credential.required.filter { found[$0] == nil }
        guard missing.isEmpty else { throw Failure.missing(missing) }
        return (found, identities)
    }

    /// UTF-8 JSON objects (GAM reads nothing else; a UTF-16 file parses in Foundation but not in GAM),
    /// and a service-account file that names its account.
    private static func check(_ data: Data, as credential: Credential) throws {
        guard !data.starts(with: [0xFE, 0xFF]), !data.starts(with: [0xFF, 0xFE]), !data.contains(0),
              String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.notJSON(credential.fileName) }
        if credential == .oauth2Service {
            guard let email = object["client_email"] as? String, email.contains("@") else {
                throw Failure.notAServiceAccount
            }
        }
    }

    private static func readFile(_ name: String, in dir: Int32) throws -> (Data, FileIdentity)? {
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
        // read(2), not FileHandle: a failed read (a USB or network volume, an offloaded iCloud file)
        // must be an error, not an Objective-C exception that kills the app.
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                data.append(contentsOf: chunk[0..<n])
                guard data.count <= sizeCap else { throw Failure.tooLarge(name) }
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0 {
                throw Failure.unreadable(name, errno)
            } else {
                return (data, FileIdentity(info))
            }
        }
    }
}
