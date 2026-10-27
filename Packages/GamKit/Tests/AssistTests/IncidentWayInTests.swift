import Foundation
import Testing
@testable import Assist

/// Where it started (2026-10-27: a vendor's email to the operator's designer gave the attacker the account): the emails the
/// first account the attacker got into received from outside in the 72 hours before its attack began, the one the operator
/// picks, and everyone here who received it. On the log reader's own made-up incident (`LogReadingTests`), where Chrome saw
/// carol@ type her password on a phishing site at minute 8 and the attacker signed in at minute 11.
@Suite("Where it started")
struct IncidentWayInTests {
    typealias Reading = LogReadingTests

    /// A Gmail receipt in `who`'s mailbox, its sender as Google's log nests it (`message_info.source`).
    static func received(_ who: String, _ id: String, at minute: Int, from sender: String?, subject: String = "Invoice 4471",
                         success: String? = nil) -> LogReading.Event {
        var parameters = ["event_info.mail_event_type": "2", "message_info.rfc2822_message_id": id, "message_info.subject": subject]
        if let sender { parameters["message_info.source.address"] = sender }
        if let success { parameters["event_info.success"] = success }
        return Reading.event("gmail", who, "delivery", at: minute, parameters)
    }

    static let events = Reading.incident + [
        received("carol@example.com", "<inv-1@mail.vendor.example>", at: -30, from: "billing@vendor.example"),
        received("alice@example.com", "<inv-1@mail.vendor.example>", at: -29, from: "billing@vendor.example"),
        received("carol@example.com", "<weekly@news.example.org>", at: -600, from: "News@News.example.org", subject: "This week"),
        received("carol@example.com", "<lunch@mail.example.com>", at: -100, from: "bob@example.com", subject: "Lunch?"),
        received("carol@example.com", "<old@mail.vendor.example>", at: -5_000, from: "sales@vendor.example", subject: "Quote"),
        received("carol@example.com", "<later@mail.vendor.example>", at: 30, from: "sales@vendor.example", subject: "After"),
        received("carol@example.com", "<bounced@mail.vendor.example>", at: -40, from: "sales@vendor.example", success: "false"),
        received("carol@example.com", "<nameless@mail.vendor.example>", at: -50, from: nil, subject: "Unnamed"),
    ]

    static func wayIn(phish: String? = nil) throws -> LogReading.WayIn {
        try #require(LogReading.read(events, context: LogReading.Context(domains: ["example.com"], people: Reading.people, phish: phish)).wayIn)
    }

    /// The first account the attacker got into, and its emails from outside in the 72 hours before its attack began, newest
    /// first: never one from inside, after the attack, before the window, or that Google marked failed; one with no sender
    /// counted, never listed.
    @Test func theEmailsFromOutsideBeforeTheAttack() throws {
        let wayIn = try Self.wayIn()
        #expect(wayIn.account == "carol@example.com" && wayIn.attackedAt == Reading.event("x", "", "", at: 8).time)
        #expect(wayIn.candidates.map(\.messageID) == ["inv-1@mail.vendor.example", "weekly@news.example.org"])
        #expect(wayIn.candidates.map(\.sender) == ["billing@vendor.example", "news@news.example.org"], "addresses read loosely")
        #expect(wayIn.candidates.first?.receivedBy == ["carol@example.com", "alice@example.com"], "everyone here who got it, the first first")
        #expect(wayIn.unnamed == 1 && wayIn.picked == nil && wayIn.pickedUnread == nil)
    }

    /// The pick: as the logs show it, with everyone who got it; one outside the window is still shown; one no one here is
    /// shown receiving is said as not in the logs read, never dropped.
    @Test func thePickAndWhoGotIt() throws {
        let picked = try Self.wayIn(phish: "<inv-1@mail.vendor.example>")
        #expect(picked.picked?.messageID == "inv-1@mail.vendor.example" && picked.picked?.receivedBy == ["carol@example.com", "alice@example.com"])
        let older = try Self.wayIn(phish: "old@mail.vendor.example")
        #expect(older.picked.map { [$0.sender, $0.subject] } == ["sales@vendor.example", "Quote"], "outside the window, still shown")
        let missing = try Self.wayIn(phish: "nowhere@mail.vendor.example")
        #expect(missing.picked == nil && missing.pickedUnread == "nowhere@mail.vendor.example")
    }

    /// In the report: where it started, in words, before what was done; who got the email that started it, the account taken
    /// over among them; and the review's agenda pointing at it. With none picked, what's left to pick it from.
    @Test func theReportSaysWhereItStarted() throws {
        func report(_ phish: String?) -> IncidentReport {
            IncidentReport.make(LogReading.read(Self.events, context: LogReading.Context(domains: ["example.com"], people: Reading.people, phish: phish)),
                                record: IncidentReport.Record(title: "T", domain: "example.com", opened: Reading.event("x", "", "", at: 90).time!,
                                                              openedBy: "", reported: "", notes: [], review: IncidentReport.Review()),
                                changes: [], evidence: [], no2SV: nil, made: Reading.event("x", "", "", at: 120).time!, madeBy: "",
                                when: IncidentReportTests.when)
        }
        let picked = report("inv-1@mail.vendor.example")
        let got = try #require(picked.count("gotPhish"))
        #expect(got.number == 2 && got.table.rows == [[.text("carol@example.com"), .text("yes")], [.text("alice@example.com"), .text("")]])
        let text = picked.text(IncidentReportTests.when)
        #expect(text.contains("\nWHERE IT STARTED\n") && text.range(of: "WHERE IT STARTED")!.lowerBound < text.range(of: "WHAT WAS DONE")!.lowerBound)
        #expect(text.contains("The email that started it: “Invoice 4471” from billing@vendor.example (Message-ID inv-1@mail.vendor.example). "
                              + "First received minute -30, before the attacker's first sign, on carol@example.com at minute 8. "
                              + "carol@example.com received it, and so did alice@example.com: they may have fallen for it too."))
        // The first account taken over isn't among those who got it (the demo's picture, 2026-10-27): never said as having it.
        let elsewhere = try #require(LogReading.read(Self.events, context: LogReading.Context(domains: ["example.com"], people: Reading.people,
                                                                                              phish: "weekly@news.example.org")).wayIn)
        let weekly = try #require(elsewhere.picked)
        let other = LogReading.WayIn.Email(messageID: "x", sender: "s@vendor.example", subject: "", at: nil, receivedBy: ["alice@example.com"])
        #expect(IncidentReport.receivedWords(other, wayIn: elsewhere, when: IncidentReportTests.when)
                == "Before the attacker's first sign, on carol@example.com at minute 8. Received here by alice@example.com: they may have fallen for it too.")
        #expect(IncidentReport.receivedWords(weekly, wayIn: elsewhere, when: IncidentReportTests.when).hasSuffix("Only carol@example.com is shown receiving it."))
        #expect(text.contains("6. How they got in, and why it worked: the logs show it began with “Invoice 4471” from billing@vendor.example."))
        let open = report(nil)
        #expect(open.count("gotPhish") == nil)
        #expect(open.wayInWords(IncidentReportTests.when).hasPrefix("Not picked yet: 2 emails carol@example.com received from outside"))
    }

    /// No account the attacker got into (only a password tried): nothing to trace.
    @Test func nothingWithoutAnAccountTakenOver() {
        let tried = [Reading.event("login", "erin@example.com", "login_failure", ip: Reading.attacker, at: 25),
                     Self.received("erin@example.com", "<inv-1@mail.vendor.example>", at: 20, from: "billing@vendor.example")]
        #expect(LogReading.read(tried, context: LogReading.Context(domains: ["example.com"])).wayIn == nil)
    }
}
