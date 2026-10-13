import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock's `report users` takes only GamGUI's shape, as doReport reads it at 7.48.22 (`gam/__init__.py`
/// :14363-14381): `date <Date> parameters <service:parameter,…>`, each service one of USER_REPORT_SERVICES
/// (:13582-13590). It once took any words after `report users` and answered every one, so a typo'd parameter or a
/// dropped `date` passed green (GamGUI's reports runbook names the trap). A usage error comes before GAM's progress
/// line: doReport reads its arguments first.
@Suite("Mock report")
struct MockReportTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    /// One call, with GAM's first-run banner (the lines naming the config folder) dropped from stdout.
    private func run(_ argv: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        let result = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: Fixtures.mockEnvironment)
        let data = result.stdout.split(separator: "\n").filter { !$0.contains(config.lastPathComponent) }.joined(separator: "\n")
        return (result.exitCode, data, result.stderr)
    }

    /// GamGUI's own call (`usage_report`'s first), from the parity fixture.
    static let gamgui: [String] = {
        let fixture = JSONValue.parse(try! String(contentsOf: Fixtures.directory.appending(path: "usage_report.json"), encoding: .utf8))!
        return fixture["walks"]!.array![0]["argv"]!.array![0].array!.map { $0.string! }
    }()

    @Test func gamGUIsCallIsAnswered() async throws {
        let read = try await run(Self.gamgui)
        #expect(read.exitCode == 0)
        #expect(read.stdout.contains("bob@example.com,2026-06-16,1048576,0,5,0"))
    }

    /// A malformed call fails as a GAM usage error, before the progress line: doReport reads its arguments first.
    /// The date's words are the mock's (`need_date`), approximate: GAM reads `date` as a time or a delta.
    @Test func aMalformedCallFailsAsGamFails() async throws {
        let date = Self.gamgui[3], parameters = Self.gamgui[5]
        let choices = "accounts|chat|classroom|docs|drive|gmail|gplus"
        let refused: [([String], String)] = [
            (["report", "users", "date", date, "parameters", "used_quota_in_mb"], "Invalid argument: Expected <service:parameter>"),
            (["report", "users", "date", date, "parameters", "meet:num_calls"], "Invalid choice (meet): Expected <\(choices)>"),
            (["report", "users", "date", date, "parameters", "accounts:used_quota_in_mb,,Gmail:x"],
             "Invalid choice (Gmail): Expected <\(choices)>"),
            (["report", "users", "date", "10/06/2026", "parameters", parameters], "Invalid date (10/06/2026)"),
            (["report", "users", "date", "", "parameters", parameters], "Missing argument: Expected <Date>"),
            (["report", "users", "date", date, "parameters"], "Missing argument: Expected <String>"),
        ]
        for (argv, words) in refused {
            let read = try await run(argv)
            #expect(read.exitCode == 2, "\(argv)")
            #expect(read.stderr.contains(words), "\(argv): \(read.stderr)")
            #expect(!read.stderr.contains("Getting Reports"), "\(argv): the arguments are read before GAM says what it's getting")
            #expect(read.stdout.isEmpty, "\(argv)")
        }
    }

    /// Other shapes GAM takes (no date, no parameters, more options) aren't modelled: refused, never answered.
    @Test func anotherShapeIsNotModelled() async throws {
        let date = Self.gamgui[3], parameters = Self.gamgui[5]
        for argv in [["report", "users"], ["report", "users", "date", date], ["report", "users", "parameters", parameters],
                     ["report", "users", "date", date, "parameters", parameters, "convertmbtogb"]] {
            let read = try await run(argv)
            #expect(read.exitCode == 2 && read.stderr.contains("isn't modelled"), "\(argv): \(read.stderr)")
            #expect(read.stdout.isEmpty, "\(argv)")
        }
    }
}
