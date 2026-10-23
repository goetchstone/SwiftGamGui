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

    /// The export's dialect reads a backslash as data; GAM's reads it as an escape.
    @Test func theExportsDialectHasNoEscape() {
        #expect(CSVReader.records("a\\,b\n", escaping: false) == [["a\\", "b"]])
        #expect(CSVReader.records("a\\,b\n") == [["a,b"]])
    }
}
