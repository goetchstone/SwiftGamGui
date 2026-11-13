import CryptoKit
import Darwin
import Foundation
import GamEngine

/// What Plan an Import needs below the screen (GamGUI's `web/routes/roster.py`): the picked files read bounded, the kept
/// roster's issues grouped by kind, and the Issues CSV's rows. Nothing here runs GAM.
public enum RosterImport {
    /// Rows shown per kind of issue; the Issues CSV has every row kept.
    public static let issuesShown = 20

    /// The files the operator picked (ZIPs, CSVs, or a folder, whose own files are taken and its folders left), read by
    /// descriptor, never through a link: bounded by `caps.members` files and `caps.upload` bytes before any is read, and
    /// each read at most one byte past what's left of the cap. A picked folder's files keep their own names, which are
    /// only ever matched.
    public static func readPicked(_ urls: [URL], caps: RosterCaps = .standard) throws(Roster.Refusal) -> [Roster.Upload] {
        var picked: [(name: String, url: URL)] = []
        for url in urls {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw .package("“\(url.lastPathComponent)” couldn't be read. Choose it again.") }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                picked.append((url.lastPathComponent, url))
            case S_IFDIR:
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    var childInfo = stat()
                    guard lstat(child.path, &childInfo) == 0 else { continue }
                    switch childInfo.st_mode & S_IFMT {
                    case S_IFDIR: continue
                    case S_IFREG: picked.append((child.lastPathComponent, child))
                    default: throw .package(linked(child.lastPathComponent))
                    }
                    if picked.count > caps.members { throw tooMany }
                }
            default:
                throw .package(linked(url.lastPathComponent))
            }
            if picked.count > caps.members { throw tooMany }
        }
        var uploads: [Roster.Upload] = []
        var left = caps.upload
        let tooBig = Roster.Refusal.package("That's more than \(caps.upload >> 20) MB, more than a roster export should be.")
        var descriptors: [(name: String, fd: Int32, size: Int)] = []
        defer { descriptors.forEach { close($0.fd) } }
        for (name, url) in picked {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw .package(errno == ELOOP ? linked(name) : "“\(name)” couldn't be read. Choose it again.") }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                close(fd)
                throw .package(linked(name))
            }
            descriptors.append((name, fd, Int(info.st_size)))
        }
        if descriptors.reduce(0, { $0 + $1.size }) > caps.upload { throw tooBig }
        for (name, fd, _) in descriptors {
            var bytes: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let want = min(chunk.count, left + 1 - bytes.count)
                guard want > 0 else { throw tooBig }
                let got = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, want) }
                guard got >= 0 else { throw .package("“\(name)” couldn't be read. Choose it again.") }
                if got == 0 { break }
                bytes += chunk[..<got]
            }
            if bytes.count > left { throw tooBig }
            left -= bytes.count
            uploads.append(Roster.Upload(name: name, bytes: bytes))
        }
        return uploads
    }

    private static let tooMany = Roster.Refusal.package(
        "That's more files than a roster export holds. Choose its ZIP, or the CSV files in its folder.")

    private static func linked(_ name: String) -> String {
        "“\(PythonText.string(name.unicodeScalars.prefix(80)))” is a link or a special file, not a file. Choose the export's own files."
    }

    /// What an import is called on the screen and in the audit (GamGUI's): the file's name, or how many were picked.
    public static func label(_ uploads: [Roster.Upload]) -> String {
        uploads.count == 1 ? uploads[0].name : "\(uploads.count) CSV files"
    }

    /// The SHA-256 of what was picked, piece by piece: what the audit record names.
    public static func digest(_ uploads: [Roster.Upload]) -> String {
        var hasher = SHA256()
        for upload in uploads { hasher.update(data: upload.bytes) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One kind of issue on the screen: its words, its whole count and its rows (the first `issuesShown`, or every row
    /// kept).
    public struct Kind: Sendable, Equatable, Identifiable {
        public let code: String
        public let count: Int
        public let cause: String
        public let fix: String
        public let rows: [RosterSnapshot.Issue]

        public var id: String { code }
    }

    /// Each kind, most frequent first (GamGUI's `_issues`).
    public static func kinds(_ issues: RosterStore.Issues?, shown: Int? = issuesShown) -> [Kind] {
        guard let issues else { return [] }
        return issues.counts.sorted { ($0.count, $1.code) > ($1.count, $0.code) }.map { item in
            let words = RosterSnapshot.issueWords[item.code] ?? (item.code, "")
            let rows = issues.rows.filter { $0.code == item.code }
            return Kind(code: item.code, count: item.count, cause: words.cause, fix: words.fix,
                        rows: shown.map { Array(rows.prefix($0)) } ?? rows)
        }
    }

    /// The Issues CSV for the SIS team (GamGUI's `issues.csv`): each kind's cause and fix, and every row kept, header first.
    /// Written formula-safe by the app's one private CSV writer.
    public static func issuesCSV(_ issues: RosterStore.Issues?) -> [[String]] {
        var rows = [["kind", "cause", "fix", "file", "line", "ID", "detail", "kind_total"]]
        for kind in kinds(issues, shown: nil) {
            for row in kind.rows {
                rows.append([kind.code, kind.cause, kind.fix, row.file, String(row.row), row.sourceID, row.detail, String(kind.count)])
            }
        }
        return rows
    }

    public static let issuesFileName = "roster-issues.csv"
}

