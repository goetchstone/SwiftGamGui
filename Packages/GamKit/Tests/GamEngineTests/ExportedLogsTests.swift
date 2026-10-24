import Foundation
import Testing
@testable import GamEngine

/// This app's export of the logs read back (`ActivityLogs.rows(exported:)`), for an incident's saved evidence: every cell
/// as written, in the export's own CSV dialect, with what the export changed to make a cell safe undone.
@Suite("Exported logs read back")
struct ExportedLogsTests {
    static let header = "log,time,actor,event,ip_address,flagged,via,parameters\r\n"

    /// Each column back as it was: flagged from "yes", the agent and the app out of `via`, a backslash kept (the export's
    /// dialect has no escape, unlike GAM's), and a value holding " | " joined back.
    @Test func anExportReadsBackCellForCell() throws {
        let text = Self.header
            + "gmail,2026-10-19T14:02:11Z,carol@example.com,delivery,198.51.100.23,yes,through Mail Sync Pro (acting as the person),"
            + "\"message_info.subject: Invoice | Due today | message_info.source.address: billing@example.org\"\r\n"
            + "drive,2026-10-19T14:01:00Z,dana@example.com,download,,,\"by the AI agent Inbox Helper (assistant), made by dana@example.com; "
            + "through Gemini\",doc_title: C:\\temp\\notes\r\n"
            + "login,2026-10-19T14:00:00Z,carol@example.com,login_success,198.51.100.23,,by an AI agent,\r\n"
        let gmail = try #require(ActivityLogs.rows(exported: text.components(separatedBy: "\r\n").prefix(2).joined(separator: "\r\n"),
                                                   application: .gmail))
        #expect(gmail.count == 1)
        let row = try #require(gmail.first)
        #expect(row.time == "2026-10-19T14:02:11Z" && row.date != nil && row.who == "carol@example.com" && row.event == "delivery")
        #expect(row.ip == "198.51.100.23" && row.flagged && row.agent.isEmpty && row.app == "Mail Sync Pro (acting as the person)")
        #expect(row.parameters.map(\.name) == ["message_info.subject", "message_info.source.address"])
        #expect(row.parameters.first?.value == "Invoice | Due today", "a subject holding \" | \" is joined back")
        #expect(row.via == "through Mail Sync Pro (acting as the person)", "written again, it's the same cell")

        let drive = try #require(ActivityLogs.rows(exported: Self.header + text.components(separatedBy: "\r\n")[2], application: .drive))
        #expect(drive.first?.agent == "the AI agent Inbox Helper (assistant), made by dana@example.com" && drive.first?.app == "Gemini")
        #expect(drive.first?.parameters == [ActivityLogs.Parameter(name: "doc_title", value: "C:\\temp\\notes")])
        #expect(drive.first?.flagged == false && drive.first?.ip == "")
        let login = try #require(ActivityLogs.rows(exported: Self.header + text.components(separatedBy: "\r\n")[3], application: .login))
        #expect(login.first?.agent == "an AI agent" && login.first?.app == "" && login.first?.parameters.isEmpty == true)
    }

    /// Only the export's own table is read: another header, or a row of another log, is no export of this one.
    @Test func onlyTheExportsOwnTableIsRead() {
        #expect(ActivityLogs.rows(exported: "name,actor.email\nlogin_success,carol@example.com\n", application: .login) == nil)
        #expect(ActivityLogs.rows(exported: Self.header + "token,2026-10-19T14:00:00Z,a@example.com,authorize,,,,\r\n", application: .login) == nil)
        #expect(ActivityLogs.rows(exported: Self.header + "login,2026-10-19T14:00:00Z,a@example.com\r\n", application: .login) == nil, "a short row")
        #expect(ActivityLogs.rows(exported: Self.header, application: .login)?.isEmpty == true, "an export with no events")
        #expect(ActivityLogs.rows(exported: "", application: .login) == nil)
    }

    /// The `'` the export puts before a spreadsheet formula's lead comes off; any other `'` stays.
    @Test func aSafeCellIsUndone() {
        #expect(ActivityLogs.unsafe("'=HYPERLINK(1)") == "=HYPERLINK(1)" && ActivityLogs.unsafe("'-1") == "-1" && ActivityLogs.unsafe("'@x") == "@x")
        #expect(ActivityLogs.unsafe("'quoted") == "'quoted" && ActivityLogs.unsafe("'") == "'" && ActivityLogs.unsafe("plain") == "plain")
    }

    /// An exported row's identity is its content: the same event in two exports is one, a different one isn't.
    @Test func anExportedRowIsKnownByItsContent() throws {
        let one = Self.header + "login,2026-10-19T14:00:00Z,carol@example.com,login_success,198.51.100.23,,,login_type: google_password\r\n"
        let a = try #require(ActivityLogs.rows(exported: one, application: .login)?.first)
        let b = try #require(ActivityLogs.rows(exported: one + "", application: .login)?.first)
        let other = try #require(ActivityLogs.rows(exported: one.replacingOccurrences(of: "google_password", with: "passkey"), application: .login)?.first)
        #expect(a.identity == b.identity && a.identity != other.identity)
    }

    /// The parameters cell read on its bytes (2026-10-24, for speed) splits as the Foundation reading it replaced, kept here
    /// as the reference: names in any script, ": " and " | " inside values, empty pieces, a leading piece with no name.
    /// Where they differ, the bytes are what the export wrote: a value beginning with a combining mark, whose ": " Foundation
    /// matched as a character and so missed, folding the parameter into the one before it.
    @Test func theParametersCellReadsAsBefore() {
        func before(_ cell: String) -> [ActivityLogs.Parameter] {
            guard !cell.isEmpty else { return [] }
            var parameters: [ActivityLogs.Parameter] = []
            for piece in cell.components(separatedBy: " | ") {
                if let colon = piece.range(of: ": "), !piece[..<colon.lowerBound].isEmpty,
                   piece[..<colon.lowerBound].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0) }) {
                    parameters.append(ActivityLogs.Parameter(name: String(piece[..<colon.lowerBound]), value: String(piece[colon.upperBound...])))
                } else if let last = parameters.popLast() {
                    parameters.append(ActivityLogs.Parameter(name: last.name, value: last.value + " | " + piece))
                }
            }
            return parameters
        }
        // By their bytes: `String ==` takes "é" and "e" + U+0301 as equal.
        func bytes(_ parameters: [ActivityLogs.Parameter]) -> [[UInt8]] { parameters.map { Array($0.name.utf8) + [0] + Array($0.value.utf8) } }
        let cells = ["", " | ", " | | ", "a: b", "a:b", ": b", "a: ", "a: b | c: d", "lead | a: b", "a: b | rest", "a: b |  | c: d",
                     "message_info.subject: Invoice | Due today | message_info.source.address: billing@example.org",
                     "x-y_z.0: v: w | n: ", "nom_é: café | 名前: 値 | ключ: значение", "a b: c | d: e", "a: 🚀 | 🚀: b | c: d 🚀",
                     "a: one |two | b: x", "a: |", "| a: b", "a: b | ", " | a: b"]
        for cell in cells { #expect(bytes(ActivityLogs.parameters(exported: cell)) == bytes(before(cell)), "\(cell)") }
        // Every mix of the pieces a cell is made of, in a fixed order.
        let parts = ["a: b", " | ", ": ", "name_1.x-y", "é", "名", " ", "|", "🚀", "v", ":"]
        var seed: UInt64 = 0x2026_1024, compared = 0
        for _ in 0..<4_000 {
            var cell = ""
            for _ in 0..<12 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                cell += parts[Int(seed >> 33) % parts.count]
            }
            if bytes(ActivityLogs.parameters(exported: cell)) == bytes(before(cell)) { compared += 1 } else { Issue.record("\(cell)") }
        }
        #expect(compared == 4_000)
        let accented = [ActivityLogs.Parameter(name: "message_info.subject", value: "\u{301}tude"),
                        ActivityLogs.Parameter(name: "message_info.source.address", value: "a@example.org")]
        let written = accented.map { "\($0.name): \($0.value)" }.joined(separator: " | ")
        #expect(bytes(ActivityLogs.parameters(exported: written)) == bytes(accented) && bytes(before(written)) != bytes(accented))
    }

    /// The export's dialect reads a backslash as data; GAM's reads it as an escape.
    @Test func theExportsDialectHasNoEscape() {
        #expect(CSVReader.records("a\\,b\n", escaping: false) == [["a\\", "b"]])
        #expect(CSVReader.records("a\\,b\n") == [["a,b"]])
    }
}
