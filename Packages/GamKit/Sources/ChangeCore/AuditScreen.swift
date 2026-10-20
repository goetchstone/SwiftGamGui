import Darwin
import Foundation
import GamEngine

/// What the Audit screen narrows the log to: GamGUI's search box and its "Failures only" (`web/routes/audit.py`,
/// `_keep`). GamGUI offers no other filter. Held to `Tests/Fixtures/audit_screen.json` by `AuditScreenTests`.
public struct AuditFilter: Sendable, Hashable {
    /// Searched for in the action, the target, the error, the detail and the command.
    public var text: String
    /// Only records whose `ok` is `false`.
    public var failuresOnly: Bool

    public init(text: String = "", failuresOnly: Bool = false) {
        self.text = text
        self.failuresOnly = failuresOnly
    }

    /// Something narrows the log (a search of only spaces doesn't).
    public var isActive: Bool { failuresOnly || !needle.isEmpty }

    /// The search as GamGUI compares it: stripped, then lowercased as Python's `str.lower()` does.
    var needle: [Unicode.Scalar] { Array(PythonText.lower(PythonText.strip(text)).unicodeScalars) }

    /// `_keep`: a failure is `ok` exactly `false`; the search is a substring, scalar by scalar, of any of the five
    /// fields lowercased, each read as `str(field or "")`.
    func keeps(_ record: JSONObject, needle: [Unicode.Scalar]) -> Bool {
        if failuresOnly, record["ok"] != .bool(false) { return false }
        guard !needle.isEmpty else { return true }
        let extra = record["extra"]?.object
        let fields = [AuditText.truthy(record["action"]), AuditText.truthy(record["target"]),
                      AuditText.truthy(extra?["error"]), AuditText.truthy(extra?["detail"]), AuditText.argv(record["argv"])]
        return fields.contains { AuditText.contains(Array(PythonText.lower($0).unicodeScalars), needle) }
    }
}

/// One record as the Audit screen shows it. Its fields are the log's, already masked when they were written.
public struct AuditEntry: Sendable, Identifiable {
    /// What became of the record's change, in words.
    public enum Outcome: Sendable, Equatable {
        case succeeded, failed
        /// This app's begin record: its result is the end record after it.
        case started
        /// A begin record with no end: the app stopped mid-call. Home lists it too, and Mark as Checked acknowledges it.
        case unknown(Executor.Unfinished)
        /// The operator's acknowledgement of an outcome unknown.
        case checked
        /// No result in the record (GamGUI's "Unknown").
        case notRecorded

        public var words: String {
            switch self {
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .started: "Started"
            case .unknown: "Outcome unknown — check"
            case .checked: "Marked as checked"
            case .notRecorded: "No result recorded"
            }
        }
    }

    /// A labelled field of the record, for the details behind the disclosure.
    public struct Detail: Sendable, Identifiable, Equatable {
        public let label: String
        public let value: String
        public var id: String { label }
    }

    /// The record's place in the log, newest first: 0 is the newest.
    public let id: Int
    public let outcome: Outcome
    /// `ts` as written, or "" when there is none.
    public let time: String
    /// `ts` read as an instant, when it is one.
    public let date: Date?
    /// The action as recorded, and in words.
    public let action: String
    public let actionName: String
    public let target: String
    /// Who ran it (the connected admin), or "".
    public let actor: String
    /// GamGUI's Detail column: the error, else the command, else the detail, cut at 160 characters.
    public let summary: String
    /// Every field of the record, the long ones cut at `detailLimit` characters.
    public let details: [Detail]

    public static let summaryLimit = 160
    public static let detailLimit = 4_000

    init(place: Int, record: JSONObject, unfinished: [String: Executor.Unfinished]) {
        id = place
        let extra = record["extra"]?.object
        switch record["ok"] {
        case .bool(true): outcome = .succeeded
        case .bool(false): outcome = .failed
        default:
            if extra?["phase"]?.string == "begin" {
                outcome = Self.key(extra).flatMap { unfinished[$0] }.map(Outcome.unknown) ?? .started
            } else {
                outcome = extra?["acknowledged"] == .bool(true) ? .checked : .notRecorded
            }
        }
        time = AuditText.truthy(record["ts"])
        date = Self.instant(time)
        action = AuditText.truthy(record["action"])
        actionName = WriteAction(rawValue: action)?.displayName ?? Self.words(action)
        target = AuditText.truthy(record["target"])
        actor = AuditText.truthy(record["actor"])

        let error = extra?["error"], detail = extra?["detail"], argv = record["argv"]
        func cut(_ text: String, ellipsis: Bool) -> String {
            let scalars = text.unicodeScalars
            guard scalars.count > Self.summaryLimit else { return text }
            return String(String.UnicodeScalarView(scalars.prefix(Self.summaryLimit))) + (ellipsis ? "…" : "")
        }
        if error?.truthy == true {
            summary = cut(error!.pythonText, ellipsis: true)
        } else if argv?.truthy == true {
            summary = cut(AuditText.argv(argv), ellipsis: true)
        } else if detail?.truthy == true {
            summary = cut(detail!.pythonText, ellipsis: false)
        } else {
            summary = ""
        }

        var details: [Detail] = []
        func add(_ label: String, _ value: JSONValue?) {
            guard let value, value != .null else { return }
            let text = value.pythonText
            let scalars = text.unicodeScalars
            details.append(Detail(label: label, value: scalars.count > Self.detailLimit
                ? String(String.UnicodeScalarView(scalars.prefix(Self.detailLimit))) + "… (\(scalars.count - Self.detailLimit) more characters)"
                : text))
        }
        add("Time", record["ts"])
        add("Action", record["action"])
        add("Target", record["target"])
        add("Exit code", record["exit_code"])
        if argv?.truthy == true { add("Command", .string(AuditText.argv(argv))) }
        add("Error", error)
        add("Detail", detail)
        add("Run by", record["actor"])
        add("Connector", record["connector"])
        if let extra {
            for member in extra where member.key != "error" && member.key != "detail" { add(member.key, member.value) }
        } else {
            add("extra", record["extra"])
        }
        self.details = details
    }

    /// The begin's step, as `Executor.unfinished` keys it.
    static func key(_ extra: JSONObject?) -> String? {
        guard let preview = extra?["preview"]?.string, let step = extra?["step"].flatMap({ $0.int }) else { return nil }
        return "\(preview)/\(step)"
    }

    /// GamGUI's actions are written in snake case (`add_group_member`): said as words, first letter capital.
    static func words(_ action: String) -> String {
        let spaced = action.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// The instant in a timestamp as both apps write it: Python's `isoformat()` of a UTC time,
    /// `YYYY-MM-DDTHH:MM:SS[.ffffff]+HH:MM`. Anything else is shown as written.
    static func instant(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        func number(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[start..<(start + count)] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        func at(_ index: Int, _ character: Character) -> Bool { index < bytes.count && bytes[index] == character.asciiValue }
        guard let year = number(0, 4), at(4, "-"), let month = number(5, 2), at(7, "-"), let day = number(8, 2), at(10, "T"),
              let hour = number(11, 2), at(13, ":"), let minute = number(14, 2), at(16, ":"), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60
        else { return nil }
        var index = 19, micros = 0
        if at(index, ".") {
            var digits = 0
            index += 1
            while let digit = number(index, 1), digits < 6 {
                micros = micros * 10 + digit
                digits += 1
                index += 1
            }
            guard digits > 0 else { return nil }
            for _ in digits..<6 { micros *= 10 }
        }
        guard at(index, "+") || at(index, "-"), let offsetHours = number(index + 1, 2), at(index + 3, ":"),
              let offsetMinutes = number(index + 4, 2), index + 6 == bytes.count
        else { return nil }
        let offset = (offsetHours * 60 + offsetMinutes) * 60 * (at(index, "-") ? -1 : 1)
        // Days since 1970-01-01 (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let days = era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + Double(micros) / 1_000_000)
    }
}

/// One page of the log as GamGUI pages it (`_rows_context`): the whole log filtered, newest first, then 25 a
/// page, a page past either end showing the nearest. One pass over the log, holding only the page asked for
/// and the page being filled (invariant 9): never the log, which can hold a million records.
public struct AuditPage: Sendable {
    /// GamGUI's `PAGE_SIZE`.
    public static let size = 25

    public let entries: [AuditEntry]
    /// The page shown, from 1, and how many there are (at least 1).
    public let page: Int
    public let pages: Int
    /// The records the filter keeps, in the whole log.
    public let matches: Int
    /// Every record in the log, and those whose `ok` is `false` (GamGUI's header).
    public let logged: Int
    public let failures: Int

    /// Reads the log: call it off the main actor. `unfinished` is Home's list (`Executor.unfinished`): a begin
    /// record in it is the outcome unknown. Throws `CancellationError` when the task is cancelled mid-read.
    public static func read(_ requested: Int, at url: URL, filter: AuditFilter,
                            unfinished: [Executor.Unfinished] = []) throws -> AuditPage {
        let wanted = max(1, requested), needle = filter.needle
        var logged = 0, failures = 0, matches = 0
        var kept: [(place: Int, record: JSONObject)] = [], filling: [(place: Int, record: JSONObject)] = []
        try AuditLog.forEachRecord(at: url) { record in
            if logged % 1_024 == 0, Task.isCancelled { throw CancellationError() }
            let place = logged
            logged += 1
            if record["ok"] == .bool(false) { failures += 1 }
            guard filter.keeps(record, needle: needle) else { return true }
            if matches % size == 0 { filling.removeAll(keepingCapacity: true) }
            filling.append((place, record))
            if matches / size + 1 == wanted { kept.append((place, record)) }
            matches += 1
            return true
        }
        let pages = max(1, (matches + size - 1) / size)
        let page = min(wanted, pages)
        let open = Dictionary(unfinished.map { ("\($0.preview)/\($0.step)", $0) }, uniquingKeysWith: { first, _ in first })
        let rows = page == wanted ? kept : filling
        return AuditPage(entries: rows.map { AuditEntry(place: $0.place, record: $0.record, unfinished: open) },
                         page: page, pages: pages, matches: matches, logged: logged, failures: failures)
    }
}

/// The CSV export GamGUI hands an auditor (`_export_csv`): its columns in its order, each cell made inert for a
/// spreadsheet as `csv_safe` makes it, in Python's `csv` dialect (`excel`: a comma, CRLF line ends, a cell quoted
/// only when it holds a comma, a quote, CR or LF, a quote doubled), as UTF-8. Every generation of the log, newest
/// first, streamed: the file is the operator's choice, written beside it and renamed over it once whole.
public enum AuditExport {
    public static let columns = ["ts", "action", "target", "ok", "exit_code", "error", "argv", "detail"]
    /// GamGUI's download name.
    public static let suggestedName = "audit-export.csv"

    /// Writes the records `filter` keeps to `destination` (private, 0600: it says who was changed) and returns
    /// how many. Call it off the main actor; it throws `CancellationError` when the task is cancelled.
    @discardableResult
    public static func write(from url: URL, filter: AuditFilter, to destination: URL) throws -> Int {
        let needle = filter.needle
        var written = 0
        try writePrivately(to: destination) { emit in
            try emit(row(columns))
            try AuditLog.forEachRecord(at: url) { record in
                if written % 1_024 == 0, Task.isCancelled { throw CancellationError() }
                guard filter.keeps(record, needle: needle) else { return true }
                let extra = record["extra"]?.object ?? [:]
                try emit(row([record["ts"], record["action"], record["target"], record["ok"], record["exit_code"],
                              extra["error"], .string(AuditText.argv(record["argv"])), extra["detail"]].map(safe)))
                written += 1
                return true
            }
        }
        return written
    }

    /// `rows` (header first) as a CSV, each cell made safe as `safe` makes the audit's: another export's table.
    public static func csv(_ rows: [[String]]) -> String {
        rows.map { row($0.map { safe(.string($0)) }) }.joined()
    }

    /// Writes `text` to `destination` as the audit export is written: a private (0600) file, whole or not at all.
    public static func writePrivately(_ text: String, to destination: URL) throws {
        try writePrivately(to: destination) { try $0(text) }
    }

    /// The one private writer (the audit export, `IncidentLogs`, the Phishing lists): `body`'s text, appended in 64 KiB
    /// writes to a hidden file beside `destination` (0600, created exclusively and never through a link: these list
    /// people), synced and renamed over it once whole. A failure leaves no partial file. Streamed, so a log of a
    /// million records is never held whole.
    static func writePrivately(to destination: URL, _ body: (_ emit: (String) throws -> Void) throws -> Void) throws {
        let partial = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var finished = false
        defer {
            close(fd)
            if !finished { unlink(partial.path) }
        }
        var pending: [UInt8] = []
        func flush() throws {
            var offset = 0
            while offset < pending.count {
                let wrote = pending[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                guard wrote > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += wrote
            }
            pending.removeAll(keepingCapacity: true)
        }
        try body { text in
            pending += text.utf8
            if pending.count >= 64 * 1_024 { try flush() }
        }
        try flush()
        guard fsync(fd) == 0, rename(partial.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        finished = true
    }

    /// GamGUI's `csv_safe`: nothing for a missing or null value, else its text, with a `'` before a lead a
    /// spreadsheet would read as a formula (`=`, `+`, `-`, `@`, tab, CR).
    static func safe(_ value: JSONValue?) -> String {
        guard let value, value != .null else { return "" }
        let text = value.pythonText
        guard let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) else { return text }
        return "'" + text
    }

    /// One row in Python's `excel` dialect, scalar by scalar (Foundation's search would take a quote and the
    /// combining mark after it as one character).
    static func row(_ cells: [String]) -> String {
        cells.map { cell in
            guard cell.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else { return cell }
            var quoted = String.UnicodeScalarView()
            quoted.append("\"")
            for scalar in cell.unicodeScalars {
                if scalar == "\"" { quoted.append("\"") }
                quoted.append(scalar)
            }
            quoted.append("\"")
            return String(quoted)
        }.joined(separator: ",") + "\r\n"
    }
}

/// Python's readings of a record's fields, as GamGUI's audit route and templates make them.
enum AuditText {
    /// `str(value or "")`.
    static func truthy(_ value: JSONValue?) -> String {
        guard let value, value.truthy else { return "" }
        return value.pythonText
    }

    /// `" ".join(str(a) for a in (argv or []))`: a list's items; a string's characters and an object's keys, as
    /// Python iterates them; a number or `true`, which Python can't iterate, as itself.
    static func argv(_ value: JSONValue?) -> String {
        guard let value, value.truthy else { return "" }
        switch value {
        case .array(let items): return items.map(\.pythonText).joined(separator: " ")
        case .string(let text): return text.unicodeScalars.map { String($0) }.joined(separator: " ")
        case .object(let members): return members.keys.joined(separator: " ")
        default: return value.pythonText
        }
    }

    /// Python's `needle in haystack`: a run of scalars, compared one by one.
    static func contains(_ haystack: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }
}
