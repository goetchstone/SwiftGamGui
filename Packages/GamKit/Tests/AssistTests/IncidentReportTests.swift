import Foundation
import Testing
@testable import Assist

/// The incident report (docs/plans/2026-10-22-incidents.md, slice 4): each number with the list behind it, every step taken
/// with what shows it, who each recipient was contacted by after the phish, and the plain text the PDF is drawn from. On the
/// log reader's own made-up incident (`LogReadingTests`).
@Suite("Incident report")
struct IncidentReportTests {
    typealias Reading = LogReadingTests

    static func at(_ minute: Int) -> Date { Date(timeIntervalSince1970: 1_792_400_000 + Double(minute) * 60) }
    static let when: @Sendable (Date) -> String = { Reading.minute($0) }

    /// carol@ locked by alice@ at minute 40 (a reset, then a sign-out), dana@ only reset, erin@ never: on the reader's incident
    /// with the phish and bob@'s warning picked.
    static func reading() -> LogReading.Reading {
        let events = Reading.reachEvents + [Reading.done("CHANGE_PASSWORD", at: 40), Reading.done("RESET_SIGNIN_COOKIES", at: 41),
                                            Reading.done("CHANGE_PASSWORD", to: "dana@example.com", at: 42)]
        return LogReading.read(events, context: LogReading.Context(domains: ["example.com"], people: Reading.people,
                                                                   warnings: ["phish-1@mail.example.com": ["warn-1@mail.example.com"]]))
    }

    static let record = IncidentReport.Record(title: "Carol's account taken over", domain: "example.com", opened: at(90), openedBy: "Pat",
                                              reported: "A Google alert", notes: [IncidentReport.Note(at: at(95), text: "Called the bank.")],
                                              review: IncidentReport.Review())

    static func report(changes: [IncidentReport.Change] = [], no2SV: Set<String>? = ["dana@example.com", "alice@example.com"]) -> IncidentReport {
        IncidentReport.make(reading(), record: record, changes: changes,
                            evidence: [IncidentReport.Evidence(name: "Incident logs 2026-10-19 1500", about: "Over the last 3 days.")],
                            no2SV: no2SV, made: at(120), madeBy: "pat@example.com", when: when)
    }

    /// Who each recipient was contacted by after the phish: the first email from an account here that reached them, picked as
    /// the warning or not, and how many; never one from before it, nor the attacker's own; one that bounced outside, none.
    @Test func eachRecipientsFirstContactFromHere() throws {
        let reach = try #require(Reading.reaching().reaches.first { $0.messageID == "phish-1@mail.example.com" })
        let contacts = Dictionary(uniqueKeysWithValues: reach.recipients.map { ($0.address, $0.contacted) })
        #expect(contacts["pat@partner.example"]??.messageID == "warn-1@mail.example.com" && contacts["pat@partner.example"]??.emails == 1,
                "the attacker's Re after it and dana@'s from before it don't count")
        #expect(contacts["dana@example.com"]??.messageID == "warn-1@mail.example.com" && contacts["dana@example.com"]??.emails == 2,
                "the warning sent to her, then the lunch she received: the first, and both counted")
        #expect(contacts["alice@example.com"]??.sender == "bob@example.com" && contacts["alice@example.com"]??.at == Self.at(60))
        #expect(contacts["ap&ar@vendor.example"]??.messageID == "allhands@mail.example.com" && contacts["ap&ar@vendor.example"]??.subject == "All hands")
        #expect(contacts["team@example.com"]??.messageID == "allhands@mail.example.com")
        #expect(contacts["guest@example.org"] == .some(nil), "it bounced, and nothing from here went to it")
        #expect(reach.rows.first?.suffix(4) == ["2026-10-19T09:53:20Z", "bob@example.com", "Don't open “Shared file”", "1"])
        #expect(LogReading.Reach.columns.count == reach.rows.first?.count)
    }

    /// Each number with its list: the accounts and where they stand, who has 2-Step Verification off (only with the directory
    /// read), each recipient by what came of it, and the steps taken.
    @Test func eachNumberHasTheListBehindIt() throws {
        let report = Self.report()
        func number(_ id: String) -> Int? { report.count(id)?.number }
        #expect(report.counts.map(\.id) == ["accounts", "notLocked", "accounts2SV", "emails", "addresses", "received", "outside", "bounced",
                                            "blocked", "toWarn", "warned", "contacted", "notContacted", "reached2SV", "pulled", "actions", "toDo"])
        let accounts = try #require(report.count("accounts"))
        #expect(accounts.table.rows.map { $0[0] } == [.text("carol@example.com"), .text("dana@example.com"), .text("erin@example.com")])
        #expect(accounts.table.rows.map { $0[1] } == [.text("locked"), .text("partly locked"), .text("not locked")])
        #expect(accounts.table.rows.map { $0[5] } == [.text("on"), .text("off"), .text("on")])
        #expect(number("notLocked") == 2 && number("accounts2SV") == 1)
        #expect(number("emails") == 2 && number("addresses") == 7, "the phish and the attacker's Re to pat@")
        #expect(report.count("outside")?.table.rows.count == 3 && number("outside") == 2, "a row each email, a number each address")
        #expect(number("received") == 2 && number("outside") == 2 && number("bounced") == 1 && number("blocked") == 0)
        #expect(number("warned") == 2 && number("toWarn") == 5, "the pick reached alice@ and pat@; pat@ is still to warn of the Re")
        #expect(number("contacted") == 6 && number("notContacted") == 1, "nothing from here reached pat@ after the Re")
        #expect(number("reached2SV") == 2, "alice@ and dana@, people here it reached")
        let bounced = try #require(report.count("bounced"))
        #expect(bounced.table.rows.map { $0[2] } == [.text("guest@example.org")] && bounced.table.columns.count == bounced.table.rows[0].count)
        // The directory not read: nothing is said of 2-Step Verification.
        let unread = Self.report(no2SV: nil)
        #expect(unread.count("accounts2SV") == nil && unread.count("reached2SV") == nil)
        #expect(unread.count("accounts")?.table.rows.map { $0[5] } == [.text(""), .text(""), .text("")])
    }

    /// Every step taken, oldest first, each with what shows it: what Google's Admin log shows done to each account, what this
    /// app's audit log shows it ran to an account touched or a person here reached (never to anyone else, nor before the
    /// attack), each warning that counted, and the notes.
    @Test func everyStepTakenSaysWhatShowsIt() throws {
        let changes = [
            IncidentReport.Change(at: Self.at(40), what: "Reset password", target: "carol@example.com", by: "alice@example.com", ok: true),
            IncidentReport.Change(at: Self.at(44), what: "Sign out", target: "Dana@Example.com", by: "alice@example.com", ok: false),
            IncidentReport.Change(at: Self.at(45), what: "Suspend user", target: "zed@example.com", by: "alice@example.com", ok: true),
            IncidentReport.Change(at: Self.at(-60), what: "Reset password", target: "carol@example.com", by: "alice@example.com", ok: true),
        ]
        let report = Self.report(changes: changes)
        #expect(report.actions.map(\.at) == report.actions.map(\.at).sorted())
        #expect(report.actions.contains { $0.what == "Password reset by alice@example.com" && $0.account == "carol@example.com" && $0.source == "Google's Admin log" })
        #expect(report.actions.contains { $0.what == "Reset password by alice@example.com" && $0.source == "This app's audit log" })
        #expect(report.actions.contains { $0.what == "Sign out (failed) by alice@example.com" && $0.account == "Dana@Example.com" })
        #expect(!report.actions.contains { $0.account == "zed@example.com" }, "zed@ isn't in the incident")
        #expect(report.actions.filter { $0.source == "This app's audit log" }.count == 2, "never one from before the attack")
        #expect(report.actions.contains { $0.source == "Google's Gmail log" && $0.what.hasPrefix("Warning “Don't open “Shared file”” sent by bob@example.com: 2 of those") })
        #expect(report.actions.last == IncidentReport.Action(at: Self.at(95), what: "Called the bank.", account: "", source: "A note on the incident"))
        #expect(report.count("actions")?.number == report.actions.count)
    }

    /// The times: the first sign of the attacker, detected when opened, contained only once every account touched is locked.
    @Test func theTimesToDetectAndContain() {
        let report = Self.report()
        #expect(report.times.firstSign == Self.at(8) && report.times.opened == Self.at(90))
        #expect(report.times.contained == nil, "dana@ is only partly locked and erin@ not at all")
        #expect(IncidentReport.span(82 * 60) == "1 hour 22 minutes" && IncidentReport.span(3 * 86_400 + 7_200 + 59) == "3 days 2 hours"
                && IncidentReport.span(20) == "under a minute")
    }

    /// The report as plain text, in its order, with the review's agenda filled from its numbers and each evidence file's
    /// SHA-256 when the export has them; the review once written goes in as typed.
    @Test func theReportAsText() {
        var report = Self.report()
        let text = report.text(Self.when, zone: "America/New_York", hashes: [("evidence/Incident logs 2026-10-19 1500/about.txt", "ab12")])
        let headings = ["AT A GLANCE", "WHAT WAS DONE", "THE ATTACKER'S EMAILS, AND WHO THEY REACHED", "WHERE EACH ACCOUNT STANDS", "STILL TO DO",
                        "TIMELINE", "NOTES", "POST-INCIDENT REVIEW: LESSONS LEARNED AND THE PLAN GOING FORWARD", "EVIDENCE"]
        let places = headings.compactMap { text.range(of: "\n" + $0 + "\n")?.lowerBound }
        #expect(places.count == headings.count && places == places.sorted())
        #expect(text.hasPrefix("INCIDENT REPORT: Carol's account taken over\nDomain: example.com\n"))
        #expect(text.contains("Times are in America/New_York.") && text.contains("Time to detect (first sign to opened): 1 hour 22 minutes"))
        #expect(text.contains("Contained: not yet") && text.contains("Received it here: 2\n"))
        #expect(text.contains("Not written yet. For the review meeting, go through:\n1. What happened"))
        #expect(text.contains("4. Who was reached and whether they were warned: 7 addresses, 5 still to warn, 6 contacted from here after."))
        #expect(text.contains("ab12  evidence/Incident logs 2026-10-19 1500/about.txt") && text.contains("• Incident logs 2026-10-19 1500: Over the last 3 days."))

        report = IncidentReport.make(Self.reading(), record: IncidentReport.Record(
            title: "T", domain: "example.com", opened: Self.at(90), openedBy: "", reported: "", notes: [],
            review: IncidentReport.Review(severity: "High", meeting: Self.at(200), cause: "A phishing page.", plan: "Enforce 2SV — Pat\n\n Train — Sam ")),
            changes: [], evidence: [], no2SV: nil, made: Self.at(120), madeBy: "", when: Self.when)
        let reviewed = report.text(Self.when)
        #expect(reviewed.contains("Severity: High") && reviewed.contains("Review meeting: minute 200") && reviewed.contains("How they got in: A phishing page."))
        #expect(reviewed.contains("The plan going forward:\n• Enforce 2SV — Pat\n• Train — Sam\n"))
        #expect(reviewed.contains("The review meeting's agenda:\n1. What happened"))
    }
}
