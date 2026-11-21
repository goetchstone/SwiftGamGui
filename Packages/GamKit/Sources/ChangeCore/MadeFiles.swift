import Foundation
import GamEngine

/// Files (plan F4, GamGUI #174's `core/files.py` `sheets_made`): the Google Sheets this app exported, read back from the audit
/// log. Read only: it runs no `gam` and writes nothing.
///
/// Each `export_to_sheet` record (and GamGUI's `sensitive_export`, which this app never writes: a log both apps wrote reads
/// alike), newest first, with the link GAM printed (`extra.url`, shown as a link only when it's a Google file's), its domain,
/// the read (`extra.command` and the argv) and whose Drive (the target). What became of the file is what the record kept from
/// the upload's own lines (`extra.upload`), never its error summary. This app writes a begin and an end record for each write:
/// only the end is an export's outcome. A begin with no end (the app quit mid-export) isn't listed here; Home shows it as an
/// outcome unknown. At most `sheetsShown`, from the newest `recordsScanned` records (invariant 9); the screen says when it
/// stopped at either.
public enum MadeFiles {
    public static let sheetsShown = 50
    public static let recordsScanned = 50_000
    /// The records an export leaves: this app's, and GamGUI's sensitive one.
    public static let exportActions: Set<String> = [WriteAction.exportToSheet.rawValue, "sensitive_export"]

    /// One export, as its record has it.
    public struct SheetMade: Sendable, Identifiable {
        /// Its place in the list, newest first.
        public let id: Int
        /// The record's `ts`, as written.
        public let when: String
        /// "" for a record that names none.
        public let domain: String
        /// The catalog id of the read.
        public let command: String
        /// What ran: the read and its todrive options, as the record keeps it.
        public let argv: [String]
        /// Whose Drive: the record's target ("" for none, or GamGUI's "(admin Drive)").
        public let owner: String
        public let sensitive: Bool
        /// The link, and whether a file was made: yes, no or unknown.
        public let outcome: SheetExport.Outcome

        /// What ran, quoted as it's typed: a title with spaces is one argument.
        public var commandLine: String { argv.isEmpty ? "" : GamCommandLine.text(argv) }
    }

    public struct Sheets: Sendable {
        public let made: [SheetMade]
        /// There are more than `sheetsShown`: the oldest aren't listed.
        public let more: Bool
        /// False: the read stopped after `recordsScanned` records, so older exports weren't looked for.
        public let scannedAll: Bool
        /// The log couldn't be read: what was exported is unknown, never "none" (invariant 10).
        public let problem: String

        public init(made: [SheetMade], more: Bool, scannedAll: Bool, problem: String = "") {
            self.made = made
            self.more = more
            self.scannedAll = scannedAll
            self.problem = problem
        }
    }

    /// The Sheets the audit log at `log` says this app exported, newest first. No log yet is nothing exported; a log that can't
    /// be opened (or isn't a file) is said, never read as empty.
    public static func sheets(in log: URL) -> Sheets {
        let fd = open(log.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            if code == ENOENT { return Sheets(made: [], more: false, scannedAll: true) }
            return Sheets(made: [], more: false, scannedAll: false, problem: unreadable(code))
        }
        var info = stat()
        let regular = fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        close(fd)
        guard regular else { return Sheets(made: [], more: false, scannedAll: false, problem: unreadable(EISDIR)) }
        var made: [SheetMade] = [], scanned = 0, more = false
        AuditLog.forEachRecord(at: log) { record in
            scanned += 1
            guard let action = record["action"]?.string, exportActions.contains(action) else { return scanned < recordsScanned }
            let extra = record["extra"]?.object ?? [:]
            // This app's begin record is no outcome: its end is.
            guard extra["phase"]?.string != "begin" else { return scanned < recordsScanned }
            guard made.count < sheetsShown else {
                more = true
                return false
            }
            made.append(sheet(record, extra: extra, at: made.count, sensitive: action == "sensitive_export"))
            return scanned < recordsScanned
        }
        return Sheets(made: made, more: more, scannedAll: more || scanned < recordsScanned)
    }

    static func unreadable(_ code: Int32) -> String {
        "The audit log couldn't be read (\(String(cString: strerror(code)))), so what was exported can't be told."
    }

    static func sheet(_ record: JSONObject, extra: JSONObject, at index: Int, sensitive: Bool) -> SheetMade {
        let url = extra["url"]?.string ?? ""
        let upload = extra["upload"]?.string ?? ""
        let owner = record["target"]?.string ?? ""
        let ok = record["ok"] == .bool(true)
        let argv = record["argv"]?.array?.compactMap(\.string) ?? []
        return SheetMade(
            id: index, when: record["ts"]?.string ?? "", domain: PythonText.lower(extra[AuditLog.domainKey]?.string ?? ""),
            command: extra["command"]?.string ?? "", argv: argv.count == record["argv"]?.array?.count ? argv : [],
            owner: owner, sensitive: sensitive,
            // What became of the file is what the record kept from the upload's own lines, never its error summary.
            outcome: SheetExport.outcome(ok: ok, url: SheetExport.isGoogleLink(url) ? url : "",
                                         upload: SheetExport.Upload(rawValue: upload) == nil ? "" : upload,
                                         owner: owner == "(admin Drive)" ? "" : owner, error: ok ? "" : extra["error"]?.string ?? ""))
    }
}
