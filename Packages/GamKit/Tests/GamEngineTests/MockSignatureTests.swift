import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock sets, shows and prints signatures the way GAM does (7.48.22; `print signature` 7.52.04): GAM changes
/// the body as it stores it, `show signature` prints the one address asked about, `print signature` gives it back byte for
/// byte as CSV, an address that isn't a user fails on its
/// token, Gmail off is refused, and a body GAM reads as a file keyword never sets anything. Each once
/// passed here and would have broken live: the mock answered any address and showed canned text whatever
/// was set.
@Suite("Mock signatures")
struct MockSignatureTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    /// A scratch folder for the mock's kept state, removed afterwards.
    private func withState(_ body: (URL) async throws -> Void) async throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try await body(state)
    }

    private func run(_ argv: [String], state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        return try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
    }

    private func shown(_ email: String, state: URL? = nil) async throws -> String {
        let result = try await run(GamCommands.showSignature(email: email).argv, state: state)
        #expect(result.exitCode == 0, "\(result.stderr)")
        return Signature.parseShown(result.stdout)
    }

    /// PR #218's review: GAM's `csv -` reads its options in `openCSVFileReader`'s order, each once, so GamGUI's order (`quotechar`
    /// before `noescapechar`) leaves `noescapechar` for the required `gam` and exits 2 before any row. The mock once took it.
    @Test func aCSVLoopWithItsOptionsOutOfOrderFailsLikeGam() async throws {
        try await withState { state in
            let config = try Fixtures.placeholderConfigDirectory()
            defer { try? FileManager.default.removeItem(at: config) }
            var environment = Fixtures.mockEnvironment
            environment["GAM_MOCK_STATE"] = state.path
            let rows = Data(SignaturesFast.rowsCSV([("alice@example.com", "A")]).utf8)
            let gamgui = ["csv", "-", "columndelimiter", ",", "quotechar", "\"", "noescapechar", "true",
                          "gam", "user", "~User", "signature", "~signature", "html"]
            let refused = try await mock.runRaw(gamgui, configDirectory: config, extraEnvironment: environment, input: rows)
            #expect(refused.exitCode == 2 && refused.stderr.contains("Invalid choice (noescapechar)"), "\(refused.stderr)")
            let write = GamCommands.setSignaturesCSV(rows: [("alice@example.com", "A")])
            let ran = try await mock.runRaw(write.argv, configDirectory: config, extraEnvironment: environment, input: write.input)
            #expect(ran.exitCode == 0 && SignaturesFast.updated(stdout: ran.stdout) == ["alice@example.com"], "\(ran.stderr)")
        }
    }

    @Test func aSetForANonUserFailsLikeGam() async throws {
        let result = try await run(GamCommands.setSignature(email: "nobody@example.com", signature: "Hi").argv)
        #expect(result.exitCode == 50)
        #expect(GamError(exitCode: result.exitCode, stderr: result.stderr).kind == .notFound, "\(result.stderr)")
    }

    @Test func setThenShowRoundTripsInGamsStoredForm() async throws {
        try await withState { state in
            let body = "<div>Al Ant</div>\r\n<div>Line\\nTwo</div>"
            let set = try await run(GamCommands.setSignature(email: "bob@example.com", signature: body).argv, state: state)
            #expect(set.exitCode == 0, "\(set.stderr)")
            #expect(try await shown("bob@example.com", state: state) == Signature.stored(body))
            #expect(Signature.stored(body) == "<div>Al Ant</div>\n<div>Line<br/>Two</div>")
        }
    }

    @Test func anEmptyBodyClearsTheSignature() async throws {
        try await withState { state in
            #expect(try await shown("alice@example.com", state: state) == "Best,<br>Alice")
            let set = try await run(GamCommands.setSignature(email: "alice@example.com", signature: "").argv, state: state)
            #expect(set.exitCode == 0, "\(set.stderr)")
            #expect(try await shown("alice@example.com", state: state) == "")
        }
    }

    /// GAM shows the address asked about, so each person reads back their own (GamGUI F20: one person's
    /// signature once showed for everyone).
    @Test func eachPersonGetsTheirOwnSignature() async throws {
        try await withState { state in
            _ = try await run(GamCommands.setSignature(email: "carol@example.com", signature: "Carol, Ops").argv, state: state)
            #expect(try await shown("carol@example.com", state: state) == "Carol, Ops")
            #expect(try await shown("alice@example.com", state: state) == "Best,<br>Alice")
            #expect(try await shown("bob@example.com", state: state) == "")
        }
    }

    @Test(arguments: ["file", "File", " htmlfile ", "text_file", "gdoc", "GHTML", "gcsdoc", "gcs_html"])
    func aKeywordBodyFailsLikeGam(body: String) async throws {
        try await withState { state in
            let result = try await run(GamCommands.setSignature(email: "alice@example.com", signature: body).argv, state: state)
            #expect(result.exitCode != 0, "\(body) was taken as the signature")
            #expect(result.exitCode == (body.lowercased().contains("file") ? 6 : 2), "\(result.stderr)")
            #expect(try await shown("alice@example.com", state: state) == "Best,<br>Alice")
        }
    }

    @Test func gmailOffRefusesTheSignature() async throws {
        try await withState { state in
            try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
            try Data().write(to: state.appending(path: "nogmail/bob@example.com"))
            let set = try await run(GamCommands.setSignature(email: "bob@example.com", signature: "x").argv, state: state)
            #expect(GamError(exitCode: set.exitCode, stderr: set.stderr).kind == .serviceNotEnabled, "\(set.stderr)")
            let show = try await run(GamCommands.showSignature(email: "bob@example.com").argv, state: state)
            #expect(GamError(exitCode: show.exitCode, stderr: show.stderr).kind == .serviceNotEnabled, "\(show.stderr)")
        }
    }

    /// A body over several lines comes back as GAM prints it: each line indented, read back stripped.
    @Test func aSeveralLineSignatureReadsBackLineByLine() async throws {
        try await withState { state in
            let body = "<table>\n  <tr><td>Al</td></tr>\n\n</table>\n"
            _ = try await run(GamCommands.setSignature(email: "alice@example.com", signature: body).argv, state: state)
            #expect(try await shown("alice@example.com", state: state) == "<table>\n<tr><td>Al</td></tr>\n\n</table>")
        }
    }

    // MARK: `print signature`, the exact read (printShowSignature's print mode, 7.52.04)

    static let titles = "User,displayName,sendAsEmail,replyToAddress,isPrimary,isDefault,treatAsAlias,verificationStatus"

    /// `print signature` as the authenticated runner hands it on: without GAM's first-run banner naming the config folder.
    private func printed(_ email: String, state: URL? = nil, extra: [String] = []) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        let raw = try await mock.runRaw(GamCommands.printSignature(email: email).argv + extra, configDirectory: config,
                                        extraEnvironment: environment)
        return GamResult(exitCode: raw.exitCode, stdout: AuthenticatedRunner.withoutConfigNoise(raw.stdout, configDirectory: config),
                         stderr: raw.stderr, stdoutTruncated: raw.stdoutTruncated, stderrTruncated: raw.stderrTruncated)
    }

    /// GAM's titles first, `signature` after them; the getting line on stderr; the cell quoted for its comma.
    @Test func printSignatureIsGamsCSV() async throws {
        let read = try await printed("Alice@example.com")
        #expect(read.exitCode == 0 && read.stderr == "Getting Signatures for alice@example.com\n", "\(read.stderr)")
        #expect(read.stdout == "\(Self.titles),signature\nalice@example.com,,alice@example.com,,True,True,,,\"Best,<br>Alice\"\n")
        #expect(try Signature.exact(read, for: "alice@example.com") == "Best,<br>Alice")
    }

    /// Gmail leaves an empty signature out of its reply, so GAM prints no `signature` column: the reader takes that as none.
    @Test func noSignatureIsNoColumn() async throws {
        let read = try await printed("dana@example.com")
        #expect(read.stdout == "\(Self.titles)\ndana@example.com,,dana@example.com,,True,True,,\n")
        #expect(try Signature.exact(read, for: "dana@example.com") == "")
    }

    /// What the mock set comes back from `print signature` byte for byte, in GAM's stored form, its line breaks written in a
    /// quoted cell as GAM's CSV writer writes them (the bytes CPython's csv module writes in GAM's dialect for this row).
    @Test func setThenPrintRoundTripsByteForByte() async throws {
        try await withState { state in
            let body = "<div>Al \"Ant\",</div>\n\t\\ back\n\n"
            let set = try await run(GamCommands.setSignature(email: "bob@example.com", signature: body).argv, state: state)
            #expect(set.exitCode == 0, "\(set.stderr)")
            let read = try await printed("bob@example.com", state: state)
            #expect(Array(read.stdout.utf8) == Array(("\(Self.titles),signature\nbob@example.com,,bob@example.com,,True,True,,,"
                                                         + "\"<div>Al \"\"Ant\"\",</div>\n\t\\\\ back\n\n\"\n").utf8))
            #expect(Array(try Signature.exact(read, for: "bob@example.com").utf8) == Array(body.utf8))
            // GAM's stored form, not the body sent: its CRs gone and each backslash-n a <br/>.
            let sent = "One\r\nTwo\\nThree "
            _ = try await run(GamCommands.setSignature(email: "bob@example.com", signature: sent).argv, state: state)
            let again = try await printed("bob@example.com", state: state)
            #expect(Array(try Signature.exact(again, for: "bob@example.com").utf8) == Array(Signature.stored(sent).utf8))
        }
    }

    /// A refused token GAM skips without a word (the titles alone, exit 0), Gmail off (exit 73, the titles alone), and an
    /// address that isn't a user (its token): the reader takes none of them as "no signature".
    @Test func whatGamCantReadIsNeverNone() async throws {
        try await withState { state in
            for (folder, user) in [("quiet", "alice@example.com"), ("nogmail", "carol@example.com")] {
                try FileManager.default.createDirectory(at: state.appending(path: folder), withIntermediateDirectories: true)
                try Data().write(to: state.appending(path: "\(folder)/\(user)"))
            }
            let quiet = try await printed("alice@example.com", state: state)
            #expect(quiet.exitCode == 0 && quiet.stdout == "\(Self.titles)\n" && quiet.stderr.isEmpty)
            #expect(throws: Signature.Unread.self) { try Signature.exact(quiet, for: "alice@example.com") }
            let off = try await printed("carol@example.com", state: state)
            #expect(off.exitCode == 73 && off.stdout == "\(Self.titles)\n" && off.stderr.hasPrefix("Getting Signatures for carol@example.com\n"))
            #expect(GamError(exitCode: off.exitCode, stderr: off.stderr).kind == .serviceNotEnabled, "\(off.stderr)")
            let nobody = try await printed("nobody@example.com", state: state)
            #expect(nobody.exitCode == 50 && GamError(exitCode: nobody.exitCode, stderr: nobody.stderr).kind == .notFound)
            // An account `create user` made is a user while the mock keeps state.
            try FileManager.default.createDirectory(at: state.appending(path: "created"), withIntermediateDirectories: true)
            try Data().write(to: state.appending(path: "created/new.hire@example.com"))
            let hire = try await printed("new.hire@example.com", state: state)
            #expect(try Signature.exact(hire, for: "new.hire@example.com") == "")
        }
    }

    /// Only the arguments the app sends: GAM's other options change the answer, so the mock refuses them.
    @Test func otherOptionsAreNotModelled() async throws {
        let compact = try await printed("alice@example.com", extra: ["compact"])
        #expect(compact.exitCode == 2 && compact.stderr.contains("isn't modelled"))
    }
}
