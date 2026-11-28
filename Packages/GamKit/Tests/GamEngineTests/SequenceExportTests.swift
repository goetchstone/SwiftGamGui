import Foundation
@testable import GamEngine
import TestSupport
import Testing

/// A sequence as a batch file (roadmap 5.3): GamGUI's `tests/test_sequence_export.py`. The fixture is GamGUI's own bytes.
@Suite("Sequence export")
struct SequenceExportTests {
    /// The steps `Tests/Fixtures/sequence_export.txt` was written from (GamGUI's `FIXTURE_STEPS`).
    static let steps: [(label: String, argv: [String])] = [
        ("Reset password (random)", ["update", "user", "alice@example.com", "password", "random", "changepassword", "off"]),
        ("Rename a shared drive", ["update", "shareddrive", "shareddriveid", "0AFINANCEuk9PVA", "name", "Finance — 2027 'Q1' $budget"]),
        ("Delete a group", ["delete", "group", "old-team@example.com", "noactionifalias"]),
    ]

    @Test func theFileMatchesGamGUIsByteForByte() throws {
        let fixture = try Data(contentsOf: Fixtures.repoRoot.appending(path: "Tests/Fixtures/sequence_export.txt"))
        #expect(Array(try #require(SequenceExport.file(Self.steps)).utf8) == Array(fixture))
    }

    /// Python's `shlex.quote`, value by value (worked out with CPython for GamGUI's hard values).
    @Test func eachValueIsQuotedAsPythonQuotesIt() {
        let expected: [(String, String)] = [
            ("Finance — 2027 'Q1' $budget", "'Finance — 2027 '\"'\"'Q1'\"'\"' $budget'"), ("say \"hi\"", "'say \"hi\"'"),
            ("a\\b", "'a\\b'"), ("`whoami`", "'`whoami`'"), ("$(rm -rf /)", "'$(rm -rf /)'"), ("50%datetime%", "50%datetime%"),
            ("# not a comment", "'# not a comment'"), ("tab\there", "'tab\there'"), ("", "''"),
            (" leading and trailing ", "' leading and trailing '"), ("Café", "'Café'"), ("a;b|c&d>e", "'a;b|c&d>e'"),
            ("*?[]{}~", "'*?[]{}~'"), ("alice@example.com", "alice@example.com"), ("a_b-c.d/e:f,g+h=i%j", "a_b-c.d/e:f,g+h=i%j"),
        ]
        for (value, quoted) in expected { #expect(SequenceExport.quote(value) == quoted, "\(value)") }
    }

    @Test(arguments: ["\n", "\r", "\r\n", "\0"])
    func aValueWithALineBreakIsRefused(_ brk: String) {
        let why = SequenceExport.whyNot([("Rename", ["update", "shareddrive", "shareddriveid", "0AX", "name", "a\(brk)gam delete user bob"])])
        #expect(why?.hasPrefix("Step 1 (Rename)") == true && why?.contains("line break") == true)
    }

    @Test func aPasswordIsRefusedNotWritten() {
        for argv in [["update", "user", "a@example.com", "password", "Hunter2!", "changepassword", "on"],
                     ["create", "user", "a@example.com", "firstname", "A", "lastname", "B", "PASSWORD", "s3cret"],
                     ["update", "user", "a@example.com", "password"]] {
            #expect(SequenceExport.whyNot([("Set password", argv)] + Self.steps)?.contains("password") == true, "\(argv)")
        }
        for word in ["random", "uniquerandom", "blocklogin"] {
            #expect(SequenceExport.whyNot([("Reset", ["update", "user", "a@example.com", "password", word])]) == nil)
        }
        #expect(SequenceExport.whyNot([]) == "The sequence is empty.")
    }
}
