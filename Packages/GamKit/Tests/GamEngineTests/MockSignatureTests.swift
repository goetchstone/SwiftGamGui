import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock sets and shows signatures the way GAM 7.48.22 does: GAM changes the body as it stores
/// it, `show signature` prints the one address asked about, an address that isn't a user fails on its
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
}
