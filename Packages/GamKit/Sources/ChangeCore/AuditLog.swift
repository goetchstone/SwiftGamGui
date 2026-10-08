import Darwin
import Foundation
import GamEngine
import Synchronization

/// The append-only audit log, GamGUI's `core/audit.py` in its format: one JSON object per line with
/// `ts`, `connector`, `action`, `target`, the redacted `argv`, `exit_code`, `ok`, `actor` and an optional
/// `extra`, written as Python's `json.dumps` writes it, so the Audit screen reads GamGUI's log and this
/// one alike. Held to `Tests/Fixtures/audit.json` by `AuditLogTests`.
///
/// A record never carries a secret: the value after a sensitive keyword is masked
/// (`ArgvRedaction`), then every occurrence of each secret the caller sent, anywhere in the record.
/// The second layer exists because the first can be shifted: a hire surnamed "Password" took the
/// mask meant for the real password (GamGUI failure-log 2026-09-23).
public final class AuditLog: Sendable {
    /// Roll the log past this size: rolling is the one moment history can be lost, so it sits well
    /// above normal use (about 100,000 records).
    public static let defaultMaxBytes = 16 * 1024 * 1024
    /// Generations kept behind the live file (`audit.jsonl.1` … `.10`): the trail's retention bound.
    public static let retainedGenerations = 10

    public let url: URL
    private let maxBytes: Int
    private let lock = Mutex(())

    public init(url: URL, maxBytes: Int = AuditLog.defaultMaxBytes) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// Appends one record and returns it as written. `now` is for tests.
    @discardableResult
    public func record(
        _ action: String, connector: String = "google_workspace", target: String? = nil, argv: [String]? = nil,
        exitCode: Int32? = nil, ok: Bool? = nil, actor: String? = nil, extra: JSONObject? = nil,
        secrets: [String] = [], now: Date = Date()
    ) throws -> JSONObject {
        var entry: JSONObject = [:]
        entry["ts"] = .string(Self.timestamp(now))
        entry["connector"] = .string(connector)
        entry["action"] = .string(action)
        entry["target"] = target.map(JSONValue.string) ?? .null
        entry["argv"] = argv.map { .array(ArgvRedaction.redact($0).map(JSONValue.string)) } ?? .null
        entry["exit_code"] = exitCode.map { .number(String($0)) } ?? .null
        entry["ok"] = ok.map(JSONValue.bool) ?? .null
        entry["actor"] = actor.map(JSONValue.string) ?? .null
        if let extra, !extra.isEmpty { entry["extra"] = .object(extra) }
        guard case .object(let redacted) = Self.redact(.object(entry), secrets: secrets) else { return entry }
        let line = Self.dumps(.object(redacted)) + "\n"
        try lock.withLock { _ in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            rollIfLarge()
            // 0600, and never through a link: the log can reveal who was changed, even without secrets.
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            let bytes = Array(line.utf8)
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == bytes.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return redacted
    }

    /// Moves the log aside once it passes `maxBytes`, oldest generation first, so a roll never
    /// overwrites history still inside the retention bound. A failed roll keeps appending to the
    /// live file rather than dropping the record.
    private func rollIfLarge() {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_size >= maxBytes else { return }
        for generation in stride(from: Self.retainedGenerations - 1, through: 1, by: -1) {
            let source = Self.rolled(url, generation)
            if FileManager.default.fileExists(atPath: source.path) {
                guard rename(source.path, Self.rolled(url, generation + 1).path) == 0 else { return }
            }
        }
        let first = Self.rolled(url, 1)
        guard rename(url.path, first.path) == 0 else { return }
        chmod(first.path, 0o600)
    }

    static func rolled(_ url: URL, _ generation: Int) -> URL {
        URL(filePath: url.path + ".\(generation)")
    }

    // MARK: reading

    /// The records newest-first, across every kept generation, skipping blank and malformed lines.
    /// Every generation is opened before any is read: a roll landing mid-read renames them all, and a
    /// reader resolving paths lazily would read one twice and skip another.
    public static func records(at url: URL, limit: Int? = nil) -> [JSONObject] {
        var handles: [Int32] = [], seen: Set<[UInt64]> = []
        defer { handles.forEach { close($0) } }
        for candidate in [url] + (1...retainedGenerations).map({ rolled(url, $0) }) {
            let fd = open(candidate.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            var info = stat()
            guard fstat(fd, &info) == 0, seen.insert([UInt64(info.st_dev), UInt64(info.st_ino)]).inserted else {
                close(fd)
                continue
            }
            handles.append(fd)
        }
        var found: [JSONObject] = []
        for fd in handles {
            for line in linesBackwards(fd) {
                guard let record = decode(line) else { continue }
                found.append(record)
                if let limit, found.count >= limit { return found }
            }
        }
        return found
    }

    /// A record, or nil for a blank or malformed line.
    static func decode(_ line: String) -> JSONObject? {
        let text = PythonText.strip(line)
        guard !text.isEmpty else { return nil }
        return JSONValue.parse(text)?.object
    }

    /// The file's lines, last first, read backwards from the end in chunks: readers want the newest few.
    static func linesBackwards(_ fd: Int32, chunk: Int = 64 * 1024) -> [String] {
        var lines: [String] = [], head: [UInt8] = []
        var position = Int(lseek(fd, 0, SEEK_END))
        while position > 0 {
            let step = min(chunk, position)
            position -= step
            var buffer = [UInt8](repeating: 0, count: step)
            let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, step, off_t(position)) }
            guard got == step else { break }
            var parts = (buffer + head).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            head = Array(parts.removeFirst())
            for part in parts.reversed() { lines.append(String(decoding: part, as: UTF8.self)) }
        }
        if !head.isEmpty { lines.append(String(decoding: head, as: UTF8.self)) }
        return lines
    }

    // MARK: Python's forms

    /// `datetime.now(timezone.utc).isoformat()`: microseconds, left out when they are zero.
    static func timestamp(_ date: Date) -> String {
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        let seconds = micros >= 0 ? micros / 1_000_000 : (micros - 999_999) / 1_000_000
        let fraction = micros - seconds * 1_000_000
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let clock = seconds - days * 86_400
        let (year, month, day) = civil(fromDays: days)
        func pad(_ value: Int64, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        var text = "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(clock / 3600, 2)):\(pad(clock / 60 % 60, 2)):\(pad(clock % 60, 2))"
        if fraction != 0 { text += "." + pad(fraction, 6) }
        return text + "+00:00"
    }

    /// The civil date `days` after 1970-01-01 (Howard Hinnant's algorithm).
    static func civil(fromDays days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// GamGUI's `redact_secrets`: every occurrence of each secret masked in every string value (keys
    /// are kept), the longest secret first where two start at the same place, an empty one ignored.
    static func redact(_ value: JSONValue, secrets: [String]) -> JSONValue {
        var needles: [[Unicode.Scalar]] = []
        for secret in secrets where !secret.isEmpty {
            let scalars = Array(secret.unicodeScalars)
            if !needles.contains(scalars) { needles.append(scalars) }
        }
        guard !needles.isEmpty else { return value }
        // Python sorts by length, stably: equal lengths keep their order of first appearance.
        needles = needles.enumerated().sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }.map(\.element)
        let mask = Array(ArgvRedaction.mask.unicodeScalars)
        func scrub(_ text: String) -> String {
            let scalars = Array(text.unicodeScalars)
            var out: [Unicode.Scalar] = [], index = 0
            while index < scalars.count {
                if let needle = needles.first(where: { scalars.count - index >= $0.count && scalars[index..<(index + $0.count)].elementsEqual($0) }) {
                    out += mask
                    index += needle.count
                } else {
                    out.append(scalars[index])
                    index += 1
                }
            }
            return PythonText.string(out)
        }
        func walk(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text): .string(scrub(text))
            case .array(let items): .array(items.map(walk))
            case .object(let members):
                .object(members.reduce(into: JSONObject()) { $0[$1.key] = walk($1.value) })
            default: value
            }
        }
        return walk(value)
    }

    /// `json.dumps(value, ensure_ascii=False)`: `", "` and `": "` separators, non-ASCII kept as it is,
    /// and only `"`, `\` and the C0 controls escaped.
    static func dumps(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let text): return text
        case .string(let text): return quoted(text)
        case .array(let items): return "[" + items.map(dumps).joined(separator: ", ") + "]"
        case .object(let members):
            return "{" + members.map { quoted($0.key) + ": " + dumps($0.value) }.joined(separator: ", ") + "}"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
