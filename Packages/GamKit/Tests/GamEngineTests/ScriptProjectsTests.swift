import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// A person's Apps Script projects (`GamCommands.printScriptProjects`) against the strict mock (docs/domains/compromised-
/// account.md, "Apps Script projects"). The mock's projects: carol has "Inbox Helper", made at the incident's sign-in, an
/// untitled one in the bin and an old timesheet script; alice an expenses script; dana none.
@Suite("Script projects")
struct ScriptProjectsTests {
    let mock = GamRunner(binary: Fixtures.mockGam)
    static let now = try! Date("2026-10-21T12:00:00Z", strategy: .iso8601)

    private func run(_ argv: [String], state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        let raw = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
        // As the app's runner hands it on: without the first-run banner naming this call's config folder.
        return GamResult(exitCode: raw.exitCode, stdout: AuthenticatedRunner.withoutConfigNoise(raw.stdout, configDirectory: config),
                         stderr: raw.stderr, stdoutTruncated: raw.stdoutTruncated, stderrTruncated: raw.stderrTruncated)
    }

    private func run(_ email: String, state: URL? = nil) async throws -> GamResult {
        try await run(try GamCommands.printScriptProjects(user: email).argv, state: state)
    }

    private func scripts(_ email: String, state: URL? = nil) async throws -> (GamResult, [Compromised.ScriptProject]) {
        let result = try await run(email, state: state)
        return (result, try Compromised.ScriptProject.list(result, argv: [], user: email))
    }

    private func state(_ file: String, for user: String) throws -> URL {
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state.appending(path: file), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "\(file)/\(user)").path, contents: Data())
        return state
    }

    /// The person's own projects, the latest changed first, each with when it was made and changed, by whom, and whether
    /// it's in the bin; none is GAM's exit 60 with its own "Got 0", read as no project.
    @Test func aPersonsScriptsAreTheirsLatestChangedFirst() async throws {
        let (result, carol) = try await scripts("carol@example.com")
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(carol.map(\.name) == ["Inbox Helper", "Untitled project", "Timesheet export"])
        #expect(carol.map(\.inTrash) == [false, true, false] && carol.allSatisfy { $0.lastChangedBy == "carol@example.com" })
        #expect(carol.map { $0.isRecent(at: Self.now) } == [true, true, false])
        #expect(carol[0].created == "2026-10-19T14:20:05Z" && carol[0].createdAt != nil && carol[0].modifiedAt != nil)
        #expect(try await scripts("alice@example.com").1.map(\.name) == ["Expense merge"])
        let (none, dana) = try await scripts("dana@example.com")
        #expect(none.exitCode == 60 && dana.isEmpty && none.stderr.contains("Got 0 Drive Files/Folders"), "none is GAM's 60, said")
    }

    /// GAM's exit 60 is every failure too (Drive off, a refused token, a refusal with no word at all): each is the
    /// `GamError`, never "no project", for want of GAM's own "Got 0" for that person.
    @Test func aPersonGamCantReadIsNeverNone() async throws {
        for (file, words) in [("nodrive", "User: carol@example.com, Drive Service/App not enabled"), ("quiet", "")] {
            let state = try state(file, for: "carol@example.com")
            defer { try? FileManager.default.removeItem(at: state) }
            let result = try await run("carol@example.com", state: state)
            // The quiet refusal says nothing at all.
            #expect(result.exitCode == 60 && (words.isEmpty ? result.stderr.isEmpty : result.stderr.contains(words)), "\(file): \(result.stderr)")
            #expect(throws: GamError.self, "\(file)") { try Compromised.ScriptProject.list(result, argv: [], user: "carol@example.com") }
        }
        let nobody = try await run("nobody@example.com")
        #expect(nobody.exitCode == 60 && nobody.stderr.contains("User Print Failed"), "\(nobody.stderr)")
        #expect(throws: GamError.self) { try Compromised.ScriptProject.list(nobody, argv: [], user: "nobody@example.com") }
        // GAM's word for another person, or beside a warning, isn't this person's "none".
        let got = "\rGot 0 Drive Files/Folders that matched query (x) for dana@example.com...\r\n"
        for stderr in [got, got + "WARNING: something GAM said\n", ""] {
            let result = GamResult(exitCode: 60, stdout: "Owner,id,name,owners.emailAddress,JSON\n", stderr: stderr,
                                   stdoutTruncated: false, stderrTruncated: false)
            #expect(throws: GamError.self, "\(stderr)") { try Compromised.ScriptProject.list(result, argv: [], user: "carol@example.com") }
        }
        let theirs = GamResult(exitCode: 60, stdout: "", stderr: got, stdoutTruncated: false, stderrTruncated: false)
        #expect(try Compromised.ScriptProject.list(theirs, argv: [], user: "DANA@example.com").isEmpty, "the address in any case")
    }

    /// The mock answers only the app's one form: another type, a field missing, another option, no formatjson, or any other
    /// file list is refused as not modelled.
    @Test func theMockHoldsTheReadToItsOneForm() async throws {
        let read = try GamCommands.printScriptProjects(user: "carol@example.com").argv
        let fields = try #require(read.firstIndex(of: "fields")), type = try #require(read.firstIndex(of: "gscript"))
        var noTrash = read, other = read
        noTrash[fields + 1] = "id,name,createdtime,modifiedtime,lastmodifyinguser"
        other[type] = "gdoc"
        for argv in [Array(read.dropLast()), other, noTrash, read + ["excludetrashed"],
                     ["user", "carol@example.com", "print", "filelist", "query", "name contains 'x'"]] {
            let refused = try await run(argv)
            #expect(refused.exitCode == 2 && refused.stderr.contains("isn't modelled"), "\(argv): \(refused.stderr)")
        }
        // GAM knows no `filelists` (no such alias): never answered.
        var plural = read
        plural[3] = "filelists"
        #expect(try await run(plural).exitCode == 2)
    }

    /// Check Account's sentence names the projects made or changed in the last two weeks, and says nothing once none is.
    @Test func recentScriptsAreSaidInTheFindings() async throws {
        let carol = try await scripts("carol@example.com").1
        // Enrolled in 2-Step Verification, so the scripts are all there is to say.
        let account = Compromised.Account(GamUser(record: ["primaryEmail": .string("carol@example.com"), "isEnrolledIn2Sv": .bool(true)]))
        let said = Compromised.findings(account: account, forwarding: nil, filters: nil, delegates: nil, sendAs: nil, roles: nil,
                                        scripts: carol, now: Self.now)
        #expect(said == ["2 Apps Script projects in carol@example.com's Drive were made or changed in the last two weeks (“Inbox Helper”, "
                         + "“Untitled project”): a script someone authorized keeps acting for them on its triggers. The sign-out revokes "
                         + "its access; ask carol@example.com whether they wrote them, and delete any they didn't from their Drive."])
        #expect(Compromised.findings(account: account, forwarding: nil, filters: nil, delegates: nil, sendAs: nil, roles: nil,
                                     scripts: carol, now: Self.now.addingTimeInterval(60 * 24 * 60 * 60)).isEmpty, "two months on")
    }
}
