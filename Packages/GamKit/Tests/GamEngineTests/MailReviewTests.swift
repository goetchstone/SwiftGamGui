@testable import GamEngine
import Testing

/// Reports' mail review, GAM's lines read (GamGUI's `tests/test_mail_review.py`, "reading GAM's lines").
@Suite("Mail review")
struct MailReviewTests {
    @Test func everyAccountAnnouncedIsRead() throws {
        let a = try #require(MailReview.accountFor("Got 2 Users...\r\nGetting Forward Enabled for a@x.com (1/2)\nGetting Forward Enabled for b@x.com (2/2)\n"))
        #expect(a.listed == 2 && a.read == 2 && a.unread.isEmpty && a.skipped == 0 && a.complete)
    }

    @Test func anAccountGamWarnedAboutIsUnreadWithItsReason() throws {
        let a = try #require(MailReview.accountFor("Getting all Delegates for a@x.com (1/2)\nUser: a@x.com, Gmail Service/App not enabled (1/2)\n"
                                                   + "Getting all Delegates for b@x.com (2/2)\nUser: b@x.com, Delegate Failed: boom (2/2)\n"))
        #expect(a.read == 0 && !a.complete)
        #expect(a.unread == [MailReview.Unread(user: "a@x.com", why: MailReview.gmailOff), MailReview.Unread(user: "b@x.com", why: MailReview.notRead)])
    }

    @Test func anAccountSkippedWithoutAWordIsCountedNeverRead() throws {
        let a = try #require(MailReview.accountFor("Got 3 Users...\nGetting Forward Enabled for a@x.com (1/3)\n"))
        #expect(a.listed == 3 && a.read == 1 && a.skipped == 2 && !a.complete)
    }

    @Test func aRunThatAnnouncedNothingIsNoAnswer() {
        #expect(MailReview.accountFor("") == nil && MailReview.accountFor("ERROR: something\n") == nil)
    }

    @Test func onlyForwardingThatIsOnIsListed() {
        let rows: [GamOutput.Record] = [
            ["User": .string("b@x.com"), "forwardEnabled": .string("True"), "forwardTo": .string("t@y.org"), "disposition": .string("archive")],
            ["User": .string("a@x.com"), "forwardEnabled": .string("False"), "forwardTo": .string(""), "disposition": .string("")],
        ]
        #expect(MailReview.forwarding(rows) == [MailReview.Forwarding(user: "b@x.com", to: "t@y.org", disposition: "archive")])
    }
}
