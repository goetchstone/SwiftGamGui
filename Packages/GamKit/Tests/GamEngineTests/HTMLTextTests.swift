import Foundation
@testable import GamEngine
import TestSupport
import Testing

/// GamGUI's auto-reply helpers and the Python beneath them (`html.unescape`, `HTMLParser`), held byte for
/// byte to Tests/Fixtures/vacation.json, generated from GamGUI by scripts/gen_fixtures.py.
@Suite("HTML text")
struct HTMLTextTests {
    struct Show: Decodable {
        let text: String, enabled: Bool, subject: String, message: String
        let contacts_only: Bool, domain_only: Bool, start: String, end: String
    }
    struct Body: Decodable { let body: String, text: String, html: Bool }
    struct Reply: Decodable { let text: String, html: String }
    struct Ref: Decodable { let `in`: String, out: String }
    struct Document: Decodable {
        let show_vacation: [Show], autoreply_text: [Body], autoreply_html: [Reply], unescape: [Ref]
    }

    let document = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.vacationJSON))

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func unescapeIsPythonsOverEveryNameAndNumber() {
        #expect(document.unescape.count > 7000)
        for ref in document.unescape {
            #expect(bytes(HTMLText.unescape(ref.in)) == bytes(ref.out), "\(ref.in)")
        }
    }

    @Test func autoreplyHTMLIsGamGUIs() {
        for reply in document.autoreply_html {
            #expect(bytes(HTMLText.autoreplyHTML(reply.text)) == bytes(reply.html), "\(reply.text)")
        }
    }

    @Test func looksLikeHTMLIsGamGUIs() {
        #expect(document.autoreply_text.contains { $0.html } && document.autoreply_text.contains { !$0.html })
        for body in document.autoreply_text {
            #expect(HTMLText.looksLikeHTML(body.body) == body.html, "\(body.body)")
        }
    }

    @Test func autoreplyTextIsGamGUIs() {
        #expect(document.autoreply_text.count > 1800)
        for body in document.autoreply_text {
            #expect(bytes(HTMLText.autoreplyText(body.body)) == bytes(body.text), "\(body.body)")
        }
    }

    /// GamGUI's readings, but one: a setting's line below `Message:` is the reply's own text, never the setting (GAM prints
    /// the message last). GamGUI takes it, so a reply that says `Enabled: False` reads as off (failure-log 2026-10-21).
    @Test func showVacationIsReadAsGamGUIReadsIt() {
        let attackersOwnLine = "  Enabled: true\r\n  Subject:   Away  \r\n  Message:\r\n   line one\r\n   line two\r\n  Enabled: False\r\n"
        #expect(document.show_vacation.contains { $0.text == attackersOwnLine && !$0.enabled }, "GamGUI's reading, recorded")
        for show in document.show_vacation where show.text != attackersOwnLine {
            let vacation = Vacation(showText: show.text)
            #expect(vacation.enabled == show.enabled && vacation.contactsOnly == show.contacts_only
                    && vacation.domainOnly == show.domain_only, "\(show.text)")
            #expect(bytes(vacation.subject) == bytes(show.subject), "\(show.text)")
            #expect(bytes(vacation.message) == bytes(show.message), "\(show.text)")
            #expect(vacation.start == show.start && vacation.end == show.end, "\(show.text)")
        }
        let ours = Vacation(showText: attackersOwnLine)
        #expect(ours.enabled && ours.subject == "Away" && ours.message == "line one\nline two\nEnabled: False")
        // A body faking every setting changes none of them.
        let faked = Vacation(showText: "User: c@example.com, Vacation:\n  Enabled: True\n  Contacts Only: False\n  Subject: Invoice\n"
                             + "  Message:\n    Pay here\n    Enabled: False\n    Subject: Out of office\n    Contacts Only: True\n")
        #expect(faked.enabled && faked.subject == "Invoice" && !faked.contactsOnly)
    }
}
