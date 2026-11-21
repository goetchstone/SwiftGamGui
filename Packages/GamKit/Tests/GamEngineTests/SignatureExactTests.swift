import Foundation
@testable import GamEngine
import Testing

/// The exact read (GamGUI's `signature_exact`, #163): what ChangeCore keeps before a signature is replaced, from `print
/// signature` as GAM 7.52.04's printShowSignature and CSV writer print it (read to the end of the function): the getting
/// line on stderr, its eight titles then `signature` when Gmail gave one, each cell quoted only when it holds a comma, a
/// quote or a line break, a quote doubled and a backslash doubled. A signature is the person's one whole row's cell, byte
/// for byte, or "" when the column isn't there; anything else is unknown, never "".
@Suite("Signature exact read")
struct SignatureExactTests {
    static let alice = "alice@example.com"
    static let titles = "User,displayName,sendAsEmail,replyToAddress,isPrimary,isDefault,treatAsAlias,verificationStatus"
    static let getting = "Getting Signatures for alice@example.com\n"

    static func result(_ stdout: String, stderr: String = getting, exit: Int32 = 0, truncated: Bool = false) -> GamResult {
        GamResult(exitCode: exit, stdout: stdout, stderr: stderr, stdoutTruncated: truncated, stderrTruncated: false)
    }

    /// Quoted, with GAM's doubled quote and doubled backslash, a CRLF and a trailing space, all given back.
    @Test func aQuotedSignatureComesBackByteForByte() throws {
        let stdout = "\(Self.titles),signature\n\(Self.alice),Alice Anders,\(Self.alice),,True,True,,,"
            + "\"<div>Best,\n\"\"Alice\"\" \\\\ Anders</div>\r\n \"\n"
        let read = try Signature.exact(Self.result(stdout), for: Self.alice)
        #expect(read.utf8.elementsEqual("<div>Best,\n\"Alice\" \\ Anders</div>\r\n ".utf8))
    }

    /// The last cell of the last line, unquoted: its trailing whitespace is the signature's, never stripped (GamGUI's
    /// `parse_records` strips the whole text, so it would lose it).
    @Test func anUnquotedSignatureKeepsItsTrailingWhitespace() throws {
        let stdout = "\(Self.titles),signature\n\(Self.alice),,\(Self.alice),,True,True,,,<b>Alice</b> \t \n"
        #expect(try Signature.exact(Self.result(stdout), for: Self.alice) == "<b>Alice</b> \t ")
    }

    /// Gmail leaves an empty signature out, so GAM prints no `signature` column: with the person's whole row, that's none.
    @Test func noSignatureColumnIsNoSignature() throws {
        let stdout = "\(Self.titles)\n\(Self.alice),,\(Self.alice),,True,True,,\n"
        #expect(try Signature.exact(Self.result(stdout), for: "  ALICE@example.com ") == "")
    }

    /// Each of these is unknown, never "": GAM skipped a refused token (titles alone, no getting line), only GamGUI's mock's
    /// wording on stderr, no row, a row cut short, two rows, another person's row, an answer cut at the cap, or no header.
    @Test(arguments: [
        result("\(titles)\n", stderr: ""),
        result("\(titles)\n\(alice),,\(alice),,True,True,,\n", stderr: "Getting Signature for alice@example.com\n"),
        result("\(titles)\n"),
        result("\(titles),signature\n\(alice),,\(alice),,True,True,,\n"),
        result("\(titles),signature\n\(alice),,\(alice),,True,True,,,a\n\(alice),,\(alice),,True,True,,,b\n"),
        result("\(titles),signature\nbob@example.com,,bob@example.com,,True,True,,,b\n"),
        result("\(titles),signature\n\(alice),,\(alice),,True,True,,,a\n", truncated: true),
        result(""),
        result("User,User,signature\n\(alice),\(alice),a\n"),
    ])
    func anythingElseIsUnknown(_ result: GamResult) {
        #expect(throws: Signature.Unread.self) { try Signature.exact(result, for: Self.alice) }
    }

    /// A failed run is GAM's error, for its kind: an expired sign-in stops a run, Gmail off for one person doesn't.
    @Test func aFailedReadIsGamsError() {
        let failed = Self.result("", stderr: "ERROR: invalid_grant: Token has been expired or revoked.\n", exit: 50)
        #expect(throws: GamError.self) { try Signature.exact(failed, for: Self.alice) }
        do {
            _ = try Signature.exact(failed, for: Self.alice)
        } catch let error as GamError {
            #expect(error.kind == .authExpired)
        } catch {
            Issue.record("\(error)")
        }
    }
}
