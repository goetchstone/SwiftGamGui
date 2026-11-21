@testable import ChangeCore
import Foundation
import GamEngine
import Testing

/// Files' Google Sheets (plan F4, GamGUI #174's `core/files.py` `sheets_made`): the exports read back from the audit log, newest
/// first and bounded; each one's link only when it's a Google file's; what became of it from the upload's own lines; this app's
/// begin records passed over; a log that can't be read said, never read as none.
@Suite("Made files")
struct MadeFilesTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-made-files-\(UUID().uuidString)")
    var log: URL { folder.appending(path: "audit.jsonl") }
    static let admin = "admin@example.com"
    static let argv = GamCommands.printDelegates(email: "alice@example.com").argv
        + GamCommands.todriveArgs(title: "example.com - List mailbox delegates")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func record(_ log: AuditLog, action: String = "export_to_sheet", ok: Bool = true, phase: String? = "end",
                        extra: JSONObject, domain: String = "example.com", at: Int) throws {
        var extra = extra
        if let phase { extra["phase"] = .string(phase) }
        try log.record(action, target: Self.admin, argv: Self.argv, ok: ok, extra: extra, domain: domain,
                       now: Date(timeIntervalSince1970: 1_795_000_000 + Double(at)))
    }

    @Test func theNewestExportsAreListedBounded() throws {
        let audit = AuditLog(url: log)
        for i in 0..<(MadeFiles.sheetsShown + 5) {
            try record(audit, extra: ["command": .string("build.print_delegates"),
                               "url": .string("https://docs.google.com/spreadsheets/d/\(i)/edit")], at: i * 2)
            try record(audit, phase: "begin", extra: ["command": .string("build.print_delegates")], at: i * 2 + 1)
        }
        try audit.record("read", target: "", argv: ["print", "users"], ok: true, domain: "example.com")
        try record(audit, action: "sensitive_export", phase: nil, extra: ["url": .string("https://evil.example/d/1")], domain: "Other.ORG", at: 999_999)
        let sheets = MadeFiles.sheets(in: log)
        #expect(sheets.made.count == MadeFiles.sheetsShown && sheets.more && sheets.scannedAll && sheets.problem.isEmpty)
        let newest = sheets.made[0]
        #expect(newest.sensitive && newest.domain == "other.org" && newest.outcome.url.isEmpty, "not a Google link: no link")
        #expect(sheets.made[1].outcome.url.hasSuffix("/\(MadeFiles.sheetsShown + 4)/edit"))
        #expect(sheets.made[1].outcome.made == .yes && sheets.made[1].command == "build.print_delegates" && sheets.made[1].owner == Self.admin)
        #expect(sheets.made[1].commandLine.hasSuffix("todrive tdtitle 'example.com - List mailbox delegates' tdnobrowser true tdnoemail true"))
        #expect(!sheets.made.contains { $0.outcome.said.isEmpty })
    }

    /// What became of a failed export is the upload's own line its record kept, never the error summary.
    @Test func aFailedExportIsSaidFromItsUploadLine() throws {
        let audit = AuditLog(url: log)
        try record(audit, ok: false, extra: ["upload": .string("drive_refused"), "error": .string("User: bob@example.com, Drive Service/App not enabled")], at: 1)
        try record(audit, ok: false, extra: ["upload": .string("sheets_refused")], at: 2)
        try record(audit, ok: false, extra: ["upload": .string("not a code"), "error": .string("whatever")], at: 3)
        let made = MadeFiles.sheets(in: log).made.map(\.outcome.made)
        #expect(made == [.unknown, .yes, .no])
    }

    /// No log yet is nothing exported; a log that can't be read (here a folder in its place) is unknown, said.
    @Test func anUnreadableLogIsUnknownNeverNone() throws {
        let none = MadeFiles.sheets(in: folder.appending(path: "none.jsonl"))
        #expect(none.made.isEmpty && !none.more && none.scannedAll && none.problem.isEmpty)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: false)
        let unreadable = MadeFiles.sheets(in: log)
        #expect(unreadable.made.isEmpty && unreadable.problem.hasPrefix("The audit log couldn't be read"))
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: folder.appending(path: "elsewhere"))
        #expect(MadeFiles.sheets(in: log).problem.hasPrefix("The audit log couldn't be read"))
    }
}
