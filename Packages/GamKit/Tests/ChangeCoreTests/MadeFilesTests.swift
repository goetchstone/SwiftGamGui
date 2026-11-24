@testable import ChangeCore
import Darwin
import Foundation
import GamEngine
import Testing

/// Files' Google Sheets (plan F4, GamGUI #174's `core/files.py` `sheets_made`): the exports read back from this app's audit log,
/// newest first and bounded; only an export's own end record (never a begin, a Mark as Checked or another action); each one's
/// link only when it's a Google file's; what became of it from the upload's own lines; the log and its generations read only
/// through descriptors that are regular files, and one that isn't said, never read as none.
@Suite("Made files")
struct MadeFilesTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-made-files-\(UUID().uuidString)")
    var log: URL { folder.appending(path: "audit.jsonl") }
    static let admin = "admin@example.com"
    static let argv = GamCommands.printDelegates(email: "alice@example.com").argv
        + GamCommands.todriveArgs(title: "example.com - List mailbox delegates")
    static let start = 1_795_000_000.0

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func record(_ log: AuditLog, action: String = "export_to_sheet", ok: Bool = true, phase: String = "end",
                        extra: JSONObject, at: Int) throws {
        var extra = extra
        extra["phase"] = .string(phase)
        try log.record(action, target: Self.admin, argv: Self.argv, ok: ok, extra: extra, domain: "Example.COM",
                       now: Date(timeIntervalSince1970: Self.start + Double(at)))
    }

    @Test func theNewestExportsAreListedBounded() throws {
        let audit = AuditLog(url: log)
        for i in 0..<(MadeFiles.sheetsShown + 5) {
            try record(audit, phase: "begin", extra: ["command": .string("build.print_delegates")], at: i * 2)
            try record(audit, extra: ["command": .string("build.print_delegates"),
                                      "url": .string("https://docs.google.com/spreadsheets/d/\(i)/edit")], at: i * 2 + 1)
        }
        try audit.record("read", target: "", argv: ["print", "users"], ok: true, domain: "example.com")
        let sheets = MadeFiles.sheets(in: log)
        #expect(sheets.made.count == MadeFiles.sheetsShown && sheets.more && sheets.scannedAll && sheets.problem.isEmpty)
        let newest = sheets.made[0]
        #expect(newest.outcome.url.hasSuffix("/\(MadeFiles.sheetsShown + 4)/edit") && newest.domain == "example.com")
        #expect(newest.outcome.made == .yes && newest.ok && newest.command == "build.print_delegates" && newest.owner == Self.admin)
        #expect(newest.at == Date(timeIntervalSince1970: Self.start + Double((MadeFiles.sheetsShown + 4) * 2 + 1)), "the instant, any zone")
        #expect(newest.commandLine.hasSuffix("todrive tdtitle 'example.com - List mailbox delegates' tdnobrowser true tdnoemail true"))
    }

    /// Only an export's own end record: a link that isn't a Google file's is no link, and another action, a begin, a record
    /// without an `ok` (GamGUI's `sensitive_export`, which this app never writes, is another action) are passed over.
    @Test func onlyAnExportsOwnEndRecordIsListed() throws {
        let audit = AuditLog(url: log)
        try record(audit, extra: ["url": .string("https://evil.example/d/1")], at: 1)
        try record(audit, action: "sensitive_export", extra: ["url": .string("https://docs.google.com/spreadsheets/d/2/edit")], at: 2)
        try record(audit, phase: "begin", extra: [:], at: 3)
        let made = MadeFiles.sheets(in: log).made
        #expect(made.count == 1 && made[0].outcome.url.isEmpty, "not a Google link: no link")
    }

    /// The review of F4: Home's and Audit's Mark as Checked writes an end record of the same action (`acknowledged`, no `ok`, no
    /// argv) for an export the app quit in the middle of. It's a check, not an export: Files never lists it.
    @Test func aMarkAsCheckedIsNoExport() throws {
        let audit = AuditLog(url: log)
        try record(audit, phase: "begin", extra: ["preview": .string(UUID().uuidString), "step": .number("0")], at: 1)
        let unfinished = Executor.unfinished(in: log)
        #expect(unfinished.count == 1)
        try Executor.acknowledge(unfinished, in: log)
        #expect(Executor.unfinished(in: log).isEmpty)
        let sheets = MadeFiles.sheets(in: log)
        #expect(sheets.made.isEmpty && sheets.problem.isEmpty, "\(sheets.made.map(\.outcome.said))")
    }

    /// An export GAM never launched (its Vault read or its launch failed after the begin record: `started: false`) made
    /// nothing, and is said so, never as "can't be told" (review of #199).
    @Test func anExportGamNeverLaunchedMadeNothing() throws {
        let audit = AuditLog(url: log)
        try record(audit, ok: false, extra: ["started": .bool(false), "error": .string("The Keychain refused.")], at: 1)
        let made = try #require(MadeFiles.sheets(in: log).made.first)
        #expect(made.outcome.made == .no && made.outcome.said.hasPrefix("Nothing was made: GAM didn't run."))
    }

    /// What became of a failed export is the upload's own line its record kept, never the error summary.
    @Test func aFailedExportIsSaidFromItsUploadLine() throws {
        let audit = AuditLog(url: log)
        try record(audit, ok: false, extra: ["upload": .string("drive_refused"),
                                             "error": .string("User: bob@example.com, Drive Service/App not enabled")], at: 1)
        try record(audit, ok: false, extra: ["upload": .string("sheets_refused")], at: 2)
        try record(audit, ok: false, extra: ["upload": .string("not a code"), "error": .string("whatever")], at: 3)
        let made = MadeFiles.sheets(in: log).made
        #expect(made.map(\.outcome.made) == [.unknown, .yes, .no] && made.allSatisfy { !$0.ok })
    }

    /// No log yet is nothing exported; a log that can't be read (a folder in its place, a link, a FIFO) is unknown, said with
    /// why, and its descriptor is the one checked: a FIFO is never waited on, a rolled generation included.
    @Test(.timeLimit(.minutes(1))) func anUnreadableLogIsUnknownNeverNone() async throws {
        let none = MadeFiles.sheets(in: folder.appending(path: "none.jsonl"))
        #expect(none.made.isEmpty && !none.more && none.scannedAll && none.problem.isEmpty)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: false)
        #expect(MadeFiles.sheets(in: log).problem == MadeFiles.unreadable(EISDIR))
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: folder.appending(path: "elsewhere"))
        #expect(MadeFiles.sheets(in: log).problem.hasPrefix("The audit log couldn't be read"))
        try FileManager.default.removeItem(at: log)
        #expect(mkfifo(log.path, 0o600) == 0)
        #expect(MadeFiles.sheets(in: log).problem == MadeFiles.unreadable(EFTYPE), "a FIFO isn't a folder")
        try FileManager.default.removeItem(at: log)
        // A good log, and a FIFO where its first rolled generation goes: said, never waited on.
        try record(AuditLog(url: log), extra: ["url": .string("https://docs.google.com/spreadsheets/d/1/edit")], at: 1)
        #expect(mkfifo(log.path + ".1", 0o600) == 0)
        let rolled = await Task.detached { MadeFiles.sheets(in: log) }.value
        #expect(rolled.problem == MadeFiles.unreadable(EFTYPE) && rolled.made.isEmpty)
    }
}
