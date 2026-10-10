import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock prints each `formatjson` read it models as GAM 7.48.22 prints it: GAM's header, then a
/// row per record in its data file, written in GAM's CSV dialect (`GamOutputTests.gamRow`). So a quote, a
/// backslash or a newline in a value reaches the reader escaped as GAM escapes it. The mock once printed
/// NDJSON and left backslashes single, and a reader that dropped such rows passed (failure-log 2026-10-10,
/// "GAM's CSV escapes"). A read whose shape it doesn't model is refused, not answered in a guessed shape.
@Suite("Mock CSV")
struct MockCSVTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    /// One call of the mock, with GAM's first-run banner (the lines naming the config folder) dropped.
    private func run(_ argv: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        let result = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: Fixtures.mockEnvironment)
        let data = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(config.lastPathComponent) }.joined(separator: "\n")
        return (result.exitCode, data, result.stderr)
    }

    /// A data file's records, one JSON line each, as GAM prints them in the `JSON` cell.
    private func lines(_ name: String) throws -> [String] {
        try String(contentsOf: Fixtures.mockGamData.appending(path: name), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    private func value(_ key: String, in line: String) throws -> String {
        try #require(JSONValue.parse(line)?.object?[key]?.string, "\(key) in \(line)")
    }

    @Test(arguments: [
        (GamCommands.printUsers(fields: GamCommands.cacheFields).argv, "primaryEmail", "print_users.json", ""),
        (GamCommands.printGroups().argv, "email", "groups.json", ""),
        (GamCommands.printGroupMembers(group: "STAFF@example.com").argv, "group", "group_members.json", "staff@example.com"),
        (GamCommands.printGroupMembers(group: "empty-group@example.com").argv, "group", "group_members.json",
         "empty-group@example.com"),
        (GamCommands.printDomains().argv, "domainName", "domains.json", ""),
        (GamCommands.printCros().argv, "deviceId", "cros.json", ""),
    ])
    func aFormatjsonReadPrintsGamsBytes(argv: [String], key: String, file: String, group: String) async throws {
        var expected = GamOutputTests.gamRow([key, "JSON"])
        for line in try lines(file) where try group.isEmpty || value("group", in: line) == group {
            expected += GamOutputTests.gamRow([try value(key, in: line), line])
        }
        let read = try await run(argv)
        #expect(read.exitCode == 0, "\(read.stderr)")
        #expect(Array(read.stdout.utf8) == Array(expected.utf8), "\(argv.joined(separator: " "))")
    }

    /// The values GAM escapes come back whole: Dana's quoted name, emoji, backslash, comma and newline, and
    /// the IT group's description.
    @Test func theValuesGamEscapesReachTheReaderWhole() async throws {
        let users = try await run(GamCommands.printUsers(fields: GamCommands.cacheFields).argv)
        #expect(users.stdout.contains(#"Dana \\""DJ\\"""#), "escaped as GAM escapes it")
        let dana = try #require(GamOutput.records(users.stdout).map(GamUser.init(record:)).first { $0.primaryEmail == "dana@example.com" })
        let organization = try #require(dana.record["organizations"]?.array?.first?.object)
        #expect(Array(dana.givenName.utf8) == Array("Dana \"DJ\"".utf8) && Array(dana.familyName.utf8) == Array("Zoë 😀".utf8))
        #expect(Array(dana.title.utf8) == Array("R&D\\Ops".utf8) && Array(dana.department.utf8) == Array("Sales, EMEA".utf8))
        #expect(organization["description"]?.string.map { Array($0.utf8) } == Array("line1\nline2\tend".utf8))

        let groups = try await run(GamCommands.printGroups().argv)
        let it = try #require(GamOutput.records(groups.stdout).map(GamGroup.init(record:)).first { $0.email == "it@example.com" })
        #expect(Array(it.description.utf8) == Array("The \"IT\" team\nC:\\Support, Zoë".utf8))
    }

    /// Reads whose GAM shape the mock doesn't model fail, as the mock fails an unhandled command.
    @Test(arguments: [
        GamCommands.printUsers().argv.filter { $0 != "formatjson" },
        GamCommands.printCros().argv.filter { $0 != "formatjson" },
        GamCommands.printFileList(email: "alice@example.com").argv,
        GamCommands.printResources().argv,
        GamCommands.printUserCalendars(email: "alice@example.com").argv,
        GamCommands.printAllCalendars().argv,
        GamCommands.printCalendarACLs(email: "alice@example.com").argv,
        GamCommands.printCalendarACLs(calendarID: "c_team@group.calendar.google.com").argv,
        GamCommands.printEvents(calendarID: "c_team@group.calendar.google.com").argv,
        GamCommands.getEvent(calendarID: "c_team@group.calendar.google.com", eventID: "evt-1").argv,
        ["print", "groups", "fields", "email,name", "formatjson"],
    ])
    func aReadWhoseShapeIsNotModelledIsRefused(argv: [String]) async throws {
        let read = try await run(argv)
        #expect(read.exitCode == 2 && read.stderr.contains("isn't modelled"), "\(argv.joined(separator: " ")): \(read.stderr)")
    }
}
