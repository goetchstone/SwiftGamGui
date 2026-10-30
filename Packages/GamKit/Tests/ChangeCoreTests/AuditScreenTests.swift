@testable import ChangeCore
import Darwin
import Foundation
import GamEngine
import TestSupport
import Testing

/// GamGUI parity for the Audit screen (invariant 11): `Tests/Fixtures/audit_screen.json` holds GamGUI's audit
/// route over a two-generation log of odd records: the page `_rows_context` shows for each query (each row by
/// its place in the newest-first log), the header's counts, and the bytes `_export_csv` streams. And the
/// reader's bound (invariant 9): one page is held, never the log, and a line too long to be a record is skipped.
@Suite("Audit screen")
struct AuditScreenTests {
    let fixture = JSONValue.parse(try! String(contentsOf: Fixtures.directory.appending(path: "audit_screen.json"), encoding: .utf8))!
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-audit-screen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    /// The fixture's log, written as GamGUI's generator wrote it.
    private func log() throws -> URL {
        for member in fixture["files"]!.object! {
            try Data(member.value.string!.utf8).write(to: folder.appending(path: member.key))
        }
        return folder.appending(path: "audit.jsonl")
    }

    /// Every write's name in words, as Audit, the jobs tray and a preview's title say it: a run of capitals one word as written,
    /// an acronym said as one (2026-10-30: "Remove all calendar a c ls", read out letter by letter).
    @Test func everyActionIsSaidInWords() {
        #expect(WriteAction.removeAllCalendarACLs.displayName == "Remove all calendar ACLs")
        #expect(WriteAction.addCalendarACL.displayName == "Add calendar ACL")
        #expect(WriteAction.deleteCalendarACL.displayName == "Delete calendar ACL")
        #expect(WriteAction.imapOff.displayName == "IMAP off" && WriteAction.popOff.displayName == "POP off")
        #expect(WriteAction.suspendUser.displayName == "Suspend user" && WriteAction.deleteSendAs.displayName == "Delete send as")
        for action in WriteAction.allCases {
            let words = action.displayName.split(separator: " ")
            #expect(words.first?.first?.isUppercase == true, "\(action)")
            #expect(words.allSatisfy { $0.count > 1 }, "no letter said alone: \(action)")
            #expect(words.dropFirst().allSatisfy { $0 == $0.lowercased() || $0.filter(\.isUppercase).count > 1 }, "\(action)")
        }
    }

    @Test func everyQueryShowsGamGUIsPage() throws {
        let url = try log()
        #expect(AuditPage.size == fixture["constants"]!["PAGE_SIZE"]!.int)
        let header = fixture["header"]!
        for item in fixture["pages"]!.array! {
            let query = item["q"]!.string!, failed = item["failed"]!.bool!, requested = item["page"]!.int!
            let shown = try AuditPage.read(requested, at: url, filter: AuditFilter(text: query, failuresOnly: failed))
            let label = "q=\(query.unicodeScalars.map { String($0.value, radix: 16) }) failed=\(failed) page=\(requested)"
            #expect(shown.entries.map(\.id) == item["rows"]!.array!.map { $0.int! }, "\(label)")
            #expect(shown.page == item["shown_page"]!.int && shown.pages == item["pages"]!.int, "\(label)")
            #expect(shown.matches == item["total"]!.int, "\(label)")
            #expect(shown.logged == header["total"]!.int && shown.failures == header["failures"]!.int, "\(label)")
        }
    }

    @Test func theExportIsGamGUIsBytes() throws {
        let url = try log()
        for item in fixture["exports"]!.array! {
            let query = item["q"]!.string!, failed = item["failed"]!.bool!
            let destination = folder.appending(path: "export-\(UUID().uuidString).csv")
            let written = try AuditExport.write(from: url, filter: AuditFilter(text: query, failuresOnly: failed), to: destination)
            let expected = Array(item["csv"]!.string!.utf8)
            let bytes = try [UInt8](Data(contentsOf: destination))
            #expect(bytes == expected, "q=\(query) failed=\(failed)")
            let matches = fixture["pages"]!.array!.first {
                $0["q"]!.string! == query && $0["failed"]!.bool! == failed && $0["page"]!.int! == 1
            }?["total"]?.int
            #expect(written == matches, "q=\(query) failed=\(failed): the count of records written")
        }
    }

    /// The operator's chosen file is replaced whole, private, and nothing is left beside it.
    @Test func theExportReplacesTheChosenFileWhole() throws {
        let url = try log()
        let destination = folder.appending(path: "chosen.csv")
        try Data("an older export, longer than nothing\n".utf8).write(to: destination)
        chmod(destination.path, 0o644)
        _ = try AuditExport.write(from: url, filter: AuditFilter(text: "nomatch"), to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "ts,action,target,ok,exit_code,error,argv,detail\r\n")
        var info = stat()
        #expect(lstat(destination.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                == ["audit.jsonl", "audit.jsonl.1", "chosen.csv"])
    }

    @Test func anExportThatCantBeWrittenSaysSoAndLeavesNothing() throws {
        let url = try log()
        let missing = folder.appending(path: "no-such-folder/export.csv")
        #expect(throws: (any Error).self) { try AuditExport.write(from: url, filter: AuditFilter(), to: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    /// This app's begin and end records: a begin whose end came is "started"; one whose end never came, and
    /// that Home lists, is the outcome unknown; the operator's acknowledgement reads as checked.
    @Test func eachRecordSaysItsOutcomeInWords() throws {
        let url = folder.appending(path: "audit.jsonl")
        let audit = AuditLog(url: url)
        func step(_ preview: String, _ phase: String, ok: Bool? = nil, error: String? = nil) throws {
            var extra: JSONObject = ["preview": .string(preview), "step": .number("0"), "phase": .string(phase)]
            if let error { extra["error"] = .string(error) }
            try audit.record("suspendUser", target: "\(preview)@example.com", argv: ["update", "user", "\(preview)@example.com", "suspended", "on"],
                             exitCode: ok.map { $0 ? 0 : 50 }, ok: ok, actor: "admin@example.com", extra: extra)
        }
        try step("done", "begin")
        try step("done", "end", ok: true)
        try step("failed", "begin")
        try step("failed", "end", ok: false, error: "Not Authorized")
        try step("lost", "begin")
        try step("checked", "begin")
        try Executor.acknowledge(Executor.unfinished(in: url).filter { $0.target == "checked@example.com" }, in: url)
        try audit.record("remove_domain", connector: "keychain", target: "example.org", extra: ["detail": .string("Forgot it.")])

        let unfinished = Executor.unfinished(in: url)
        #expect(unfinished.map(\.target) == ["lost@example.com"])
        let shown = try AuditPage.read(1, at: url, filter: AuditFilter(), unfinished: unfinished)
        let outcomes = shown.entries.map { "\($0.target) \($0.outcome.words)" }
        #expect(outcomes == ["example.org No result recorded", "checked@example.com Marked as checked",
                             "checked@example.com Started", "lost@example.com Outcome unknown — check",
                             "failed@example.com Failed", "failed@example.com Started",
                             "done@example.com Succeeded", "done@example.com Started"])
        let lost = try #require(shown.entries.first { $0.target == "lost@example.com" })
        #expect(lost.outcome == .unknown(unfinished[0]), "Mark as Checked acknowledges Home's record of it")
        #expect(lost.actionName == "Suspend user" && lost.actor == "admin@example.com")
        let failed = try #require(shown.entries.first { $0.outcome == .failed })
        #expect(failed.summary == "Not Authorized", "GamGUI's Detail column: the error first")
        #expect(shown.entries.last?.summary == "update user done@example.com suspended on", "then the command")
        #expect(shown.entries.first?.summary == "Forgot it.", "then the detail")
    }

    /// GamGUI's Detail column cuts the error and the command at 160 characters with an ellipsis, the detail without one.
    @Test func theSummaryIsCutAsGamGUICutsIt() throws {
        let url = folder.appending(path: "audit.jsonl")
        let audit = AuditLog(url: url)
        let long = String(repeating: "é", count: 170)
        try audit.record("a", extra: ["detail": .string(long)])
        try audit.record("b", argv: [long])
        try audit.record("c", extra: ["error": .string(long)])
        let entries = try AuditPage.read(1, at: url, filter: AuditFilter()).entries
        #expect(entries.map(\.summary) == [String(repeating: "é", count: 160) + "…", String(repeating: "é", count: 160) + "…",
                                           String(repeating: "é", count: 160)])
    }

    @Test func theTimeIsReadForDisplay() throws {
        let url = folder.appending(path: "audit.jsonl")
        try AuditLog(url: url).record("a", now: Date(timeIntervalSince1970: 1_791_460_800.25))
        try Data(#"{"action": "b", "ts": "yesterday"}"#.utf8 + [0x0A]).write(to: folder.appending(path: "audit.jsonl.1"))
        let entries = try AuditPage.read(1, at: url, filter: AuditFilter()).entries
        #expect(entries.map(\.time) == ["2026-10-08T12:00:00.250000+00:00", "yesterday"])
        #expect(entries.first?.date == Date(timeIntervalSince1970: 1_791_460_800.25))
        #expect(entries.last?.date == nil, "not a time: shown as written")
    }

    /// A line longer than any record either app writes is skipped, not held: a log with no line breaks would
    /// otherwise be read into memory whole.
    @Test func aLineTooLongToBeARecordIsSkipped() throws {
        let url = folder.appending(path: "audit.jsonl")
        let huge = #"{"action": "huge", "x": ""# + String(repeating: "x", count: AuditLog.maximumLineBytes + 70_000) + "\"}\n"
        try Data((#"{"action": "older"}"# + "\n" + huge + #"{"action": "newer"}"# + "\n").utf8).write(to: url)
        #expect(AuditLog.records(at: url).compactMap { $0["action"]?.string } == ["newer", "older"])
        let fits = #"{"action": "fits", "x": ""# + String(repeating: "x", count: 70_000) + "\"}\n"
        try Data(fits.utf8).write(to: url)
        #expect(AuditLog.records(at: url).compactMap { $0["action"]?.string } == ["fits"])
    }

    /// The whole log is filtered, but only the page asked for is kept: reading on stops when the reader is cancelled.
    @Test func aCancelledReadStops() async throws {
        let url = try log()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AuditPage.read(1, at: url, filter: AuditFilter())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aMissingLogIsAnEmptyPage() throws {
        let shown = try AuditPage.read(3, at: folder.appending(path: "audit.jsonl"), filter: AuditFilter(text: "x"))
        #expect(shown.entries.isEmpty && shown.page == 1 && shown.pages == 1 && shown.matches == 0 && shown.logged == 0)
    }
}
