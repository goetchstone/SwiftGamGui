import Foundation
import GamEngine

/// Files (plan F4, GamGUI #174's `core/files.py` `sheets_made`): the Google Sheets this app exported, read back from its own
/// audit log (`AuditLog.defaultURL`; GamGUI keeps a log of its own, which isn't read here). Read only: it runs no `gam` and
/// writes nothing.
///
/// Each export's end record (action `export_to_sheet`, `phase` `end`, an `ok` of its own), newest first, with the link GAM
/// printed (`extra.url`, shown as a link only when it's a Google file's), its domain, the read (`extra.command` and the argv)
/// and whose Drive (the target). What became of the file is what the record kept from the upload's own lines
/// (`extra.upload`), never its error summary. Passed over: every other action, every begin record, and the end record Home's
/// and Audit's Mark as Checked writes (`Executor.acknowledge`: `acknowledged`, no `ok`), which is a check, not an outcome. A
/// begin with no end (the app quit mid-export) isn't listed; Home shows it as an outcome unknown. At most `sheetsShown`, from
/// the newest `recordsScanned` records (invariant 9); the screen says when it stopped at either. The log and each rolled
/// generation are read only through descriptors that are regular files, never through a link and never waiting on a FIFO
/// (`AuditLog.forEachRecord`); one that isn't is said, never read as none.
public enum MadeFiles {
    public static let sheetsShown = 50
    public static let recordsScanned = 50_000
    /// The record an export leaves.
    public static let exportAction = WriteAction.exportToSheet.rawValue

    /// One export, as its record has it.
    public struct SheetMade: Sendable, Identifiable {
        /// Its place in the list, newest first.
        public let id: Int
        /// The record's `ts`, as written.
        public let when: String
        /// That instant, when `when` is one (`AuditEntry.instant`): shown in this Mac's time zone, named.
        public let at: Date?
        /// "" for a record that names none.
        public let domain: String
        /// The catalog id of the read.
        public let command: String
        /// What ran: the read and its todrive options, as the record keeps it.
        public let argv: [String]
        /// Whose Drive: the record's target.
        public let owner: String
        /// Whether the write itself ended well: false for a Sheet made while the read reported a problem, too.
        public let ok: Bool
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

    /// The Sheets the audit log at `log` says this app exported, newest first. No log yet is nothing exported; a log or rolled
    /// generation that can't be read (or isn't a regular file) is said, never read as empty.
    public static func sheets(in log: URL) -> Sheets {
        var made: [SheetMade] = [], scanned = 0, more = false, refused: Int32?
        AuditLog.forEachRecord(at: log, refused: { _, code in refused = refused ?? code }) { record in
            scanned += 1
            let carryOn = scanned < recordsScanned
            guard record["action"]?.string == exportAction else { return carryOn }
            let extra = record["extra"]?.object ?? [:]
            // An export's own end record: never its begin, never a Mark as Checked (no `ok` of its own).
            guard extra["phase"]?.string == "end", extra["acknowledged"]?.bool != true, let ok = record["ok"]?.bool else {
                return carryOn
            }
            guard made.count < sheetsShown else {
                more = true
                return false
            }
            made.append(sheet(record, extra: extra, ok: ok, at: made.count))
            return carryOn
        }
        if let refused { return Sheets(made: [], more: false, scannedAll: false, problem: unreadable(refused)) }
        return Sheets(made: made, more: more, scannedAll: more || scanned < recordsScanned)
    }

    static func unreadable(_ code: Int32) -> String {
        "The audit log couldn't be read (\(String(cString: strerror(code)))), so what was exported can't be told."
    }

    static func sheet(_ record: JSONObject, extra: JSONObject, ok: Bool, at index: Int) -> SheetMade {
        let url = extra["url"]?.string ?? ""
        let upload = extra["upload"]?.string ?? ""
        let owner = record["target"]?.string ?? ""
        let argv = record["argv"]?.array?.compactMap(\.string) ?? []
        let when = record["ts"]?.string ?? ""
        return SheetMade(
            id: index, when: when, at: AuditEntry.instant(when), domain: PythonText.lower(extra[AuditLog.domainKey]?.string ?? ""),
            command: extra["command"]?.string ?? "", argv: argv.count == record["argv"]?.array?.count ? argv : [],
            owner: owner, ok: ok,
            // What became of the file is what the record kept from the upload's own lines, never its error summary.
            outcome: SheetExport.outcome(ok: ok, url: SheetExport.isGoogleLink(url) ? url : "",
                                         upload: SheetExport.Upload(rawValue: upload) == nil ? "" : upload,
                                         owner: owner == "(admin Drive)" ? "" : owner, error: ok ? "" : extra["error"]?.string ?? ""))
    }
}
