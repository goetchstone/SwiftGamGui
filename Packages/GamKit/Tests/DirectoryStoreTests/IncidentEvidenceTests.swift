import Foundation
@testable import Directory
import GamEngine
import Testing

/// An incident's evidence as one pull (`IncidentLogs.evidence`): what each export's `about.txt` says, and how several
/// exports of the same logs are put together.
@Suite("Incident evidence")
struct IncidentEvidenceTests {
    static let header = "log,time,actor,event,ip_address,flagged,via,parameters\r\n"

    static func export(_ name: String, about: String, login: [String]) -> ActivityLogs.Export {
        ActivityLogs.Export(name: name, about: about, logs: [(.login, header + login.map { $0 + "\r\n" }.joined())])
    }

    static let early = "login,2026-10-19T13:00:00Z,carol@example.com,login_success,198.51.100.23,yes,,"
    static let late = "login,2026-10-22T09:00:00Z,carol@example.com,login_success,192.0.2.10,,,"

    /// The window, the accounts, the address, and each log's own window and cap, as Export All writes them.
    @Test func aboutIsReadBack() {
        let about = IncidentLogs.About("""
            Incident logs exported 2026-10-23 0619 America/New_York.
            Over the last 30 days.
            Accounts: carol@example.com, dana@example.com.
            From IP address: 198.51.100.23.

            login-log.csv: the Sign-ins (user log) log, 12 events.
            gmail-log.csv: the Gmail log, 9890 events, the last 30 days (the most it reads); older events past the cap weren't read.
            """)
        #expect(about.hours == 720 && about.users == ["carol@example.com", "dana@example.com"] && about.ip == "198.51.100.23")
        #expect(about.capped == [.gmail] && about.window == [.gmail: 720])
        let every = IncidentLogs.About("Over the last 12 hours.\nAccounts: every account.\nFrom IP address: any.\n")
        #expect(every.hours == 12 && every.users.isEmpty && every.ip.isEmpty)
    }

    /// Exports put together: rows newest first, an event both saved once, the widest window, every account when any export
    /// was; a log stopped at its cap only while every export of it was (a later read for just the accounts that matter
    /// reaches further back). One that can't be read is named, the rest still read.
    @Test func exportsArePutTogether() {
        let capped = "Over the last 30 days.\nAccounts: every account.\nFrom IP address: any.\nlogin-log.csv: the Sign-ins (user log) log, 1 events; older events past the cap weren't read.\n"
        let whole = "Over the last 7 days.\nAccounts: carol@example.com.\nFrom IP address: any.\nlogin-log.csv: the Sign-ins (user log) log, 2 events.\n"
        let first = Self.export("Incident logs 2026-10-23 0619", about: capped, login: [Self.late])
        let second = Self.export("Incident logs 2026-10-23 0700", about: whole, login: [Self.late, Self.early])
        let together = IncidentLogs.evidence([first, second])
        let rows = (try? together.pull.logs.first?.rows.get()) ?? []
        #expect(rows.map(\.time) == ["2026-10-22T09:00:00Z", "2026-10-19T13:00:00Z"], "the repeat counted once, newest first")
        #expect(together.pull.logs.first?.capped == false && together.pull.query.hours == 720 && together.pull.query.users.isEmpty)
        #expect(IncidentLogs.evidence([first, first]).pull.logs.first?.capped == true, "still at the cap in every export")
        let broken = ActivityLogs.Export(name: "Broken", about: whole, logs: [(.login, "name,actor.email\n")])
        let partly = IncidentLogs.evidence([broken, first])
        #expect(partly.unreadable == ["Broken"] && ((try? partly.pull.logs.first?.rows.get().count) ?? 0) == 1)
    }
}
