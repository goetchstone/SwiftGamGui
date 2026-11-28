@testable import GamEngine
import Testing

/// Reports' mail review, GAM's lines read (GamGUI's `tests/test_mail_review.py`, "reading GAM's lines").
@Suite("Mail review")
struct MailReviewTests {
    /// One worker of a parallel read, as GAM's showcmds writes it: Start, the worker's own lines, End with its code.
    private func ran(_ user: String, _ code: Int, _ lines: String...) -> String {
        let cmd = "gam user \(user) print forward enabledonly"
        return "2026-11-28T12:00:00-05:00,1/2,Start,0,\(cmd)\n" + lines.map { $0 + "\n" }.joined()
            + "2026-11-28T12:00:01-05:00,1/2,End,\(code),\(cmd)\n"
    }

    @Test func eachPersonsOwnLinesSayWhetherTheyWereRead() {
        let a = MailReview.accountForParallel(ran("a@x.com", 0, "Getting Forward Enabled for a@x.com")
                                              + ran("b@x.com", 0, "Getting Forward Enabled for b@x.com"), people: ["a@x.com", "B@x.com"])
        #expect(a.listed == 2 && a.read == 2 && a.unread.isEmpty && a.skipped == 0 && a.complete)
    }

    @Test func aPersonGamWarnedAboutOrWhoFailedIsUnreadWithAReason() {
        let a = MailReview.accountForParallel(
            ran("a@x.com", 73, "Getting all Delegates for a@x.com", "User: a@x.com, Gmail Service/App not enabled")
            + ran("b@x.com", 50, "Getting all Delegates for b@x.com"), people: ["a@x.com", "b@x.com"])
        #expect(a.read == 0 && !a.complete)
        #expect(a.unread == [MailReview.Unread(user: "a@x.com", why: MailReview.gmailOff), MailReview.Unread(user: "b@x.com", why: MailReview.notRead)])
    }

    @Test func aPersonNeverFinishedOrPassedOverIsSkippedNeverRead() {
        // c@ has no End line (cut off, or never started); b@ ended 0 without a word (a refused token).
        let a = MailReview.accountForParallel(ran("a@x.com", 0, "Getting Forward Enabled for a@x.com") + ran("b@x.com", 0),
                                              people: ["a@x.com", "b@x.com", "c@x.com"])
        #expect(a.listed == 3 && a.read == 1 && a.skipped == 2 && !a.complete)
    }

    @Test func nobodysLinesIsNobodyRead() {
        let a = MailReview.accountForParallel("ERROR: something\n", people: ["a@x.com", "b@x.com"])
        #expect(a.listed == 2 && a.read == 0 && a.skipped == 2 && !a.complete)
    }

    @Test func theStdinIsAPrimaryEmailColumnAndTheTimeoutGrowsWithThePeople() {
        #expect(MailReview.peopleCSV([" a@x.com ", "", "b@x.com"]) == "primaryEmail\na@x.com\nb@x.com\n")
        #expect(MailReview.parallelTimeout(people: 0) == .seconds(120))
        #expect(MailReview.parallelTimeout(people: 20_000) == .seconds(120 + 6_000))
    }

    @Test func onlyForwardingThatIsOnIsListed() {
        let rows: [GamOutput.Record] = [
            ["User": .string("b@x.com"), "forwardEnabled": .string("True"), "forwardTo": .string("t@y.org"), "disposition": .string("archive")],
            ["User": .string("a@x.com"), "forwardEnabled": .string("False"), "forwardTo": .string(""), "disposition": .string("")],
        ]
        #expect(MailReview.forwarding(rows) == [MailReview.Forwarding(user: "b@x.com", to: "t@y.org", disposition: "archive")])
    }
}
