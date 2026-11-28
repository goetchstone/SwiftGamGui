import Foundation
@testable import GamEngine
import TestSupport
import Testing

/// Roadmap 5.4 (GamGUI's `tests/test_signatures_fast.py`): the rows GAM's `csv -` reads, the refusals, and the two readers.
/// `Tests/Fixtures/signatures_fast.csv` is the exact bytes GamGUI sends for the same rows.
@Suite("Signatures in one GAM call")
struct SignaturesFastTests {
    static let alice = "alice@example.com", carol = "carol@example.com"

    @Test func theRowsMatchGamGUIsFixtureByteForByte() throws {
        let rows = [(Self.alice, "<div dir=\"ltr\">Alice \u{201C}A\u{201D} Anders, Caf\u{E9} \u{2014} Sales\r\n\\o/ 100% ~~User~~</div>"),
                    (Self.carol, "Carol, \"Ops\"\rline two\n")]
        let fixture = try Data(contentsOf: Fixtures.repoRoot.appending(path: "Tests/Fixtures/signatures_fast.csv"))
        #expect(Array(SignaturesFast.rowsCSV(rows).utf8) == Array(fixture))
        // And the builder sends exactly those bytes on standard input, never in the argv.
        let write = GamCommands.setSignaturesCSV(rows: rows)
        #expect(write.input == fixture && !write.argv.contains { $0.contains("Anders") })
    }

    @Test func whatIsSentIsASCIIWithPlainLineBreaks() {
        let sent = SignaturesFast.asSent("Caf\u{E9}\r\nline \u{2014} two\rthree")
        #expect(sent == "Caf&#233;\nline &#8212; two\nthree" && sent.unicodeScalars.allSatisfy(\.isASCII))
        #expect(SignaturesFast.asSent("\u{1F600}") == "&#128512;", "one reference per code point, as Python's xmlcharrefreplace")
    }

    @Test(arguments: [(String(repeating: "\u{E9}", count: 25_000), "Too long"), ("", "empty"), ("   \n", "empty"),
                      ("file", "as a file"), ("  HTML_File ", "as a file"), ("a\0b", "one row")])
    func aRowGamsCSVWouldMishandleIsRefused(body: String, why: String) {
        #expect(SignaturesFast.refusal(email: Self.alice, body: body)?.contains(why) == true)
    }

    @Test func theFieldLimitIsCountedAsSent() {
        // 131,071 characters as sent goes; one more doesn't (Python's csv.field_size_limit, which GAM never raises).
        #expect(SignaturesFast.refusal(email: Self.alice, body: String(repeating: "x", count: 131_071)) == nil)
        #expect(SignaturesFast.refusal(email: Self.alice, body: String(repeating: "x", count: 131_072)) != nil)
        #expect(SignaturesFast.refusal(email: "a,b@example.com", body: "x") != nil)
        #expect(SignaturesFast.refusal(email: Self.alice, body: "Best,\n\"Alice\"") == nil)
    }

    @Test func onlyGamsOwnSetLineCounts() {
        let out = "User: alice@example.com, Signature: alice@example.com, Set\n"
            + "User: carol@example.com, Signature: carol@example.com, Set (2/2)\n"
            + "User: erin@example.com, Signature: frank@example.com, Set\n"
            + "User: erin@example.com, SendAs Address: <erin@example.com>, Updated\n"
        #expect(SignaturesFast.updated(stdout: out) == [Self.alice, Self.carol])
        #expect(SignaturesFast.updated(stdout: "User: Alice@Example.com, Signature: alice@example.com, Set\r\n") == [Self.alice])
    }

    @Test func aReadIsOnlyWhoCameBackWhole() {
        let out = "User,displayName,isDefault,isPrimary,replyToAddress,sendAsEmail,signature,treatAsAlias,verificationStatus\n"
            + "alice@example.com,,True,True,,alice@example.com,\"Best,<br>Alice\",False,accepted\n"
            + "carol@example.com,,True,True,,carol@example.com,Carol,False,accepted\n"
        // Carol's row came without GAM saying it read her; dan has no row.
        let err = "Getting Signature for alice@example.com (1/3)\n"
        #expect(SignaturesFast.readSignatures(stdout: out, stderr: err, emails: [Self.alice, Self.carol, "dan@example.com"])
                == [Self.alice: "Best,<br>Alice"])
        // GAM's own word is the plural (printGettingEntityItemForWhom with Ent.SIGNATURE): read too.
        #expect(SignaturesFast.readSignatures(stdout: out, stderr: "Getting Signatures for carol@example.com (2/3)\n",
                                              emails: [Self.carol]) == [Self.carol: "Carol"])
    }

    @Test func theAddressesGoOneALine() {
        let read = GamCommands.printSignaturesFromStdin(emails: [Self.alice, Self.carol])
        #expect(read.argv == ["file", "-", "print", "signature"])
        #expect(read.input == Data("alice@example.com\ncarol@example.com\n".utf8))
    }
}
