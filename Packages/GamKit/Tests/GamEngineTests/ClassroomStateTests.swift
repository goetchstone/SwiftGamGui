import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The compare's read of Classroom (plan 2026-11-11 C3; GamGUI's `managed_from` and `classroom_state` at 07c505d): every
/// pairing `Tests/Fixtures/roster_plan.json` recorded from GamGUI (`managed_from`), and the two reads through the strict
/// mock, which give the classes GamGUI's mock gave its web test.
@Suite("Classroom state")
struct ClassroomStateTests {
    nonisolated(unsafe) static let root: JSONValue? = {
        guard let data = try? Data(contentsOf: Fixtures.directory.appending(path: "roster_plan.json")) else { return nil }
        return JSONValue.parse(String(decoding: data, as: UTF8.self))
    }()

    static func form(_ managed: Classroom.Managed) -> JSONValue {
        let c = managed.course
        return .object(["course": .object(["id": .string(c.id), "name": .string(c.name), "section": .string(c.section),
                                           "state": .string(c.state), "owner_email": .string(c.ownerEmail)]),
                        "aliases": .array(managed.aliases.map(JSONValue.string)),
                        "teachers": .array(managed.teachers.map(JSONValue.string)),
                        "students": .array(managed.students.map(JSONValue.string))])
    }

    @Test func pairsAsGamGUIPairs() throws {
        let cases = try #require(Self.root?["managed_from"]?.array)
        #expect(cases.count >= 40)
        for item in cases {
            let courses = (item["courses"]?.array ?? []).compactMap(\.object)
            let participants = (item["participants"]?.array ?? []).compactMap(\.object)
            let state = Classroom.state(courses: courses, participants: participants)
            #expect(JSONValue.array(state.classes.map(Self.form)) == item["managed"], "\(courses) \(participants)")
            #expect(JSONValue.array(state.unread.map(JSONValue.string)) == item["unread"], "\(courses) \(participants)")
        }
    }

    @Test func aliasesAreReadAsGamPrintsThemObjectsAndAll() {
        #expect(Classroom.aliases(.string(#"[{"alias": "d:gg-C9"}, {"alias": "d:other"}]"#)) == ["d:gg-C9", "d:other"])
        #expect(Classroom.aliases(.string(#"[{"etag": "x"}]"#)) == nil, "an item it can't read: unread, never an alias")
        #expect(Classroom.aliases(.string("{oops")) == nil)
        #expect(Classroom.aliases(nil) == [], "no cell: no alias (GAM swallowed the alias read)")
    }

    /// The two reads, through the strict mock, as the compare makes them: the classes are GamGUI's mock's, as its web test
    /// read them (`roster_plan.json`'s web case).
    @Test func theMockGivesTheClassesGamGUIsMockGave() async throws {
        let mock = GamRunner(binary: Fixtures.mockGam)
        func records(_ read: GamRead) async throws -> [GamOutput.Record] {
            let config = try Fixtures.placeholderConfigDirectory()
            defer { try? FileManager.default.removeItem(at: config) }
            let result = try await mock.runRaw(read.argv, configDirectory: config, extraEnvironment: Fixtures.mockEnvironment)
            let stdout = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.hasPrefix("Created: ") && !$0.hasPrefix("Config File: ") }.joined(separator: "\n")
            return try Classroom.records(GamResult(exitCode: result.exitCode, stdout: stdout, stderr: result.stderr,
                                                   stdoutTruncated: false, stderrTruncated: false), argv: read.argv)
        }
        let courses = try GamCommands.printCourses(states: Classroom.compareStates, aliases: true)
        #expect(courses.argv.contains("aliases") && courses.argv.contains("owneremail"))
        let state = Classroom.state(courses: try await records(courses),
                                    participants: try await records(try GamCommands.printAllCourseParticipants(states: Classroom.compareStates)))
        let web = try #require(Self.root?["cases"]?.array?.first { $0["name"]?.string == "test_roster_web compare" })
        #expect(state.unread.isEmpty)
        #expect(JSONValue.array(state.classes.map(Self.form)) == web["classroom"])
        let chemistry = try #require(state.classes.first { $0.course.id == "500000000002" })
        #expect(chemistry.aliases == ["d:gg-C2", "d:chem-honors"] && chemistry.students == ["bob@example.com", "carol@example.com"])
    }
}
