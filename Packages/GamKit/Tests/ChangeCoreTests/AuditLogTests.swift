@testable import ChangeCore
import Darwin
import Foundation
import GamEngine
import TestSupport
import Testing

/// GamGUI parity for the audit log (invariant 11): `Tests/Fixtures/audit.json` holds the exact line
/// GamGUI's `AuditLog.record` wrote for each call, and what its reader found across generations. The
/// fixture is read through `JSONValue`, so a number keeps the text Python wrote (`1e+16`).
@Suite("Audit log")
struct AuditLogTests {
    let fixture = JSONValue.parse(try! String(contentsOf: Fixtures.auditJSON, encoding: .utf8))!
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    func lastLine(_ url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().last.map(String.init) ?? ""
    }

    @Test func everyRecordIsWrittenAsGamGUIWritesIt() throws {
        let log = AuditLog(url: folder.appending(path: "audit.jsonl"))
        for item in fixture["written"]!.array! {
            let call = item["call"]!.object!
            let at = AuditLogTests.date(call["ts"]!.string!)
            try log.record(call["action"]!.string!, connector: call["connector"]?.string ?? "google_workspace",
                           target: call["target"]?.string, argv: call["argv"]?.array?.compactMap(\.string),
                           exitCode: call["exit_code"]?.int.map(Int32.init), ok: call["ok"]?.bool,
                           actor: call["actor"]?.string, extra: call["extra"]?.object,
                           secrets: call["secrets"]?.array?.compactMap(\.string) ?? [], now: at)
            let line = try lastLine(log.url)
            #expect(Array(line.utf8) == Array(item["line"]!.string!.utf8), "\(call["action"]!)")
        }
        var info = stat()
        #expect(lstat(log.url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }

    @Test func theReaderFindsWhatGamGUIsFinds() throws {
        let reader = folder.appending(path: "reader")
        try FileManager.default.createDirectory(at: reader, withIntermediateDirectories: false)
        for member in fixture["files"]!.object! {
            try Data(member.value.string!.utf8).write(to: reader.appending(path: member.key))
        }
        let url = reader.appending(path: "audit.jsonl")
        #expect(AuditLog.records(at: url).map(JSONValue.object) == fixture["records"]!.array!)
        #expect(AuditLog.records(at: url, limit: 3).map(JSONValue.object) == fixture["limited"]!.array!)
    }

    @Test func rollingKeepsTenGenerationsAndDropsOnlyTheOldest() throws {
        #expect(AuditLog.defaultMaxBytes == fixture["constants"]!["MAX_LOG_BYTES"]!.int)
        #expect(AuditLog.retainedGenerations == fixture["constants"]!["RETENTION_GENERATIONS"]!.int)
        let log = AuditLog(url: folder.appending(path: "audit.jsonl"), maxBytes: 1)
        for number in 0..<13 { try log.record("n\(number)") }
        let actions = AuditLog.records(at: log.url).compactMap { $0["action"]?.string }
        #expect(actions == (2..<13).reversed().map { "n\($0)" }, "the live file and ten generations, newest first")
        var info = stat()
        #expect(lstat(AuditLog.rolled(log.url, 10).path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }

    @Test func theLogIsNeverWrittenThroughALink() throws {
        let elsewhere = folder.appending(path: "elsewhere")
        try Data().write(to: elsewhere)
        let url = folder.appending(path: "audit.jsonl")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try AuditLog(url: url).record("x") }
        #expect(try Data(contentsOf: elsewhere).isEmpty)
    }

    static func date(_ iso: String) -> Date {
        // "YYYY-MM-DDTHH:MM:SS[.ffffff]+00:00", exactly as the fixture writes it.
        let parts = iso.dropLast(6).split(separator: "T")
        let day = parts[0].split(separator: "-").compactMap { Int64($0) }
        let time = parts[1].split(separator: ".")
        let clock = time[0].split(separator: ":").compactMap { Int64($0) }
        let micros = time.count == 2 ? Int64(time[1])! : 0
        var days: Int64 = 0
        var year: Int64 = 1970
        while year < day[0] { days += isLeap(year) ? 366 : 365; year += 1 }
        while year > day[0] { year -= 1; days -= isLeap(year) ? 366 : 365 }
        let lengths: [Int64] = [31, isLeap(day[0]) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        days += lengths.prefix(Int(day[1] - 1)).reduce(0, +) + day[2] - 1
        let seconds = days * 86_400 + clock[0] * 3600 + clock[1] * 60 + clock[2]
        return Date(timeIntervalSince1970: Double(seconds) + Double(micros) / 1_000_000)
    }

    static func isLeap(_ year: Int64) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }
}
