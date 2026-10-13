import Darwin
import Foundation
import GamEngine

/// GamGUI's onboarding roles, read and never written (design doc D5, slice O1): this app has no role editor
/// yet, so the Onboard screen offers the roles the operator keeps in GamGUI. The file sits in GamGUI's
/// app-data folder, so it's read as invariant 5 reads credentials: the folder opened once, the file
/// `openat` without following a link or blocking on a FIFO, a regular file under `SignatureStore.sizeCap`,
/// read from that same descriptor (`SignatureStore.read`). It's migrated as GamGUI's own load migrates it
/// (`Onboarding.roleFile`). A file GamGUI couldn't read is reported: GamGUI showed its starter role over
/// it, which here would offer a role the operator never made.
///
/// There's no default location: the app builds GamGUI's path at run time, and tests and the demo pass a
/// temporary file (GamGUI failure-log 2026-09-25: a fixture generator built a store on the real data).
public enum GamGUIRoles {
    public enum Problem: Error, Equatable, Sendable {
        /// GamGUI has no roles file (or no folder for it).
        case noFile
        /// The file was refused before it was read: a link, not a regular file, too large, or an error.
        case refused(SignatureStore.Refusal)
        /// The file was read but GamGUI's own load couldn't make roles of it.
        case unreadable

        public var message: String {
            switch self {
            case .noFile:
                "GamGUI has no onboarding roles on this Mac. Until this app has its own role editor, roles come from "
                    + "GamGUI's Onboarding \u{2192} Role templates."
            case .refused(let refusal):
                "GamGUI's onboarding roles weren't read: \(refusal.reason)."
            case .unreadable:
                "GamGUI's onboarding roles file can't be read (GamGUI would show its starter role instead). "
                    + "Open GamGUI's Onboarding page and save a role again to rewrite it."
            }
        }
    }

    /// The roles in `file`, GamGUI's `onboarding.json`, as GamGUI's load reads them.
    public static func read(_ file: URL) throws(Problem) -> GamGUIRoleFile {
        let folder = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else {
            let code = errno
            throw code == ENOENT ? .noFile : .refused(.failed(code))
        }
        defer { close(folder) }
        let bytes: [UInt8]?
        do { bytes = try SignatureStore.read(file.lastPathComponent, in: folder) } catch { throw .refused(error) }
        guard let bytes else { throw .noFile }
        // GamGUI reads it with `read_text()`: strict UTF-8, so anything else is a file it couldn't read.
        guard let text = String(validating: bytes, as: UTF8.self), let roles = Onboarding.roleFile(text) else { throw .unreadable }
        return roles
    }
}
