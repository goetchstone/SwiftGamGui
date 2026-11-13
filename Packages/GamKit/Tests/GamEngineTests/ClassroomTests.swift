import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// Google Classroom, read only (plan 2026-11-11 C1), against the strict mock: GamGUI's `tests/test_classroom_reads.py` at
/// 3c8d909, case for case. The argv is held to GamGUI's builders by `GoldenArgvTests`; these hold the reader and the mock,
/// which answers as the 7.51.00 build's doPrintCourses and doPrintCourseParticipants do. Never run live: no Education domain.
@Suite("Classroom")
struct ClassroomTests {
    let mock = GamRunner(binary: Fixtures.mockGam)
    static let chemistry = "500000000002"

    private func run(_ read: GamRead, state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        let result = try await mock.runRaw(read.argv, configDirectory: config, extraEnvironment: environment)
        let stdout = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.hasPrefix("Created: ") && !$0.hasPrefix("Config File: ") }.joined(separator: "\n")
        return GamResult(exitCode: result.exitCode, stdout: stdout, stderr: result.stderr, stdoutTruncated: result.stdoutTruncated,
                         stderrTruncated: result.stderrTruncated)
    }

    private func records(_ read: GamRead, state: URL? = nil) async throws -> [GamOutput.Record] {
        try Classroom.records(try await run(read, state: state), argv: read.argv)
    }

    private func state(_ marker: String) throws -> URL {
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-classroom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: marker).path, contents: Data())
        return state
    }

    // MARK: the builders' refusals

    @Test func aClassIsNeverReadWithItsJoinCode() {
        #expect(!GamCommands.courseFields.contains("enrollmentcode"))
    }

    @Test func aCourseIDIsDigitsOnly() {
        for bad in ["", "12a", "1,2", "d:alias", " 1", "١٢", "１２", String(repeating: "1", count: 31), "-1"] {
            #expect(!GamCommands.isCourseID(bad), "\(bad)")
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.printCourseParticipants(courseID: bad) }
        }
        #expect(GamCommands.isCourseID(String(repeating: "9", count: 30)))
    }

    @Test func aTeacherOrStudentIsOneAddress() {
        for bad in ["a@example.com,b@example.com", "all", "Name <a@example.com>", " a@example.com", "noat", "id:123"] {
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.printCourses(teacher: bad) }
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.printCourses(student: bad) }
        }
    }

    @Test func anIDReadTakesNoFilterAndStatesAreSaidOnce() throws {
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.printCourses(teacher: "a@example.com", courseIDs: ["1"]) }
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.printCourses(states: [.active], courseIDs: ["1"]) }
        #expect(try GamCommands.printCourses(states: [.active, .provisioned, .active]).argv.contains("active,provisioned"))
        #expect(!(try GamCommands.printCourses(ownerEmail: false).argv.contains("owneremail")))
    }

    // MARK: against the mock

    @Test func aTeachersClassesInTheStatesAsked() async throws {
        let courses = Classroom.courses(try await records(try GamCommands.printCourses(teacher: "alice@example.com",
                                                                                         states: [.active, .provisioned])))
        #expect(courses.map(\.name) == ["Algebra", "Biology", "Chemistry, \"Honors\""])
        #expect(courses.map(\.state) == ["PROVISIONED", "ACTIVE", "ACTIVE"])
        #expect(courses[0].stateWords == "Not yet accepted" && courses.allSatisfy { $0.ownerEmail == "alice@example.com" })
    }

    @Test func aStudentsClassesIncludeAnArchivedOneWhenNoStateIsAsked() async throws {
        let courses = Classroom.courses(try await records(try GamCommands.printCourses(student: "carol@example.com")))
        #expect(courses.map(\.name) == ["Biology", "Chemistry, \"Honors\"", "World History 2025"])
    }

    @Test func oneClassByIDReadsItsQuotedNameBack() async throws {
        let course = try #require(Classroom.courses(try await records(try GamCommands.printCourses(courseIDs: [Self.chemistry]))).first)
        #expect([course.name, course.section, course.room, course.stateWords] == ["Chemistry, \"Honors\"", "Period 4", "C3", "Active"])
        #expect(Classroom.classLink(course.link)?.absoluteString == "https://classroom.google.com/c/NTAwMDAwMDAwMDAy")
        #expect(Classroom.classLink("https://evil.example/c/1") == nil && Classroom.classLink("http://classroom.google.com/c/1") == nil)
    }

    @Test func aClassOrTeacherClassroomDoesNotKnowIsNotFound() async throws {
        for read in [try GamCommands.printCourses(courseIDs: ["999999"]), try GamCommands.printCourseParticipants(courseID: "999999"),
                     try GamCommands.printCourses(teacher: "nobody@example.com")] {
            let error = try #require(await #expect(throws: GamError.self) { try await records(read) })
            #expect(error.exitCode == 56 && error.kind == .notFound, "\(read.argv)")
        }
    }

    @Test func anAdminTokenWithoutClassroomScopesSaysSo() async throws {
        let state = try state("noclassroom")
        defer { try? FileManager.default.removeItem(at: state) }
        let error = try #require(await #expect(throws: GamError.self) {
            try await records(try GamCommands.printCourses(teacher: "alice@example.com"), state: state)
        })
        #expect(error.exitCode == 15 && error.kind == .scopeMissing && Classroom.needsScope(error))
    }

    @Test func aRosterHasItsTeachersAndStudents() async throws {
        let roster = Classroom.roster(try await records(try GamCommands.printCourseParticipants(courseID: Self.chemistry)),
                                      courseID: Self.chemistry)
        #expect(roster.courseName == "Chemistry, \"Honors\"" && roster.unreadable.isEmpty && !roster.emailsHidden)
        #expect(roster.teachers.map(\.email) == ["alice@example.com"] && roster.teachers.map(\.name) == ["Alice Anders"])
        #expect(roster.students.map(\.name) == ["Bob Brown", "Carol Clark"], "by name")
    }

    @Test func anEmptyClassReadsAsEmptyNotUnreadable() async throws {
        let roster = Classroom.roster(try await records(try GamCommands.printCourseParticipants(courseID: "500000000003")),
                                      courseID: "500000000003")
        #expect(roster.students.isEmpty && roster.teachers.count == 1 && roster.unreadable.isEmpty)
    }

    @Test func gamAnsweringNothingIsNeverNoClasses() async throws {
        let state = try state("classroom_silent")
        defer { try? FileManager.default.removeItem(at: state) }
        for read in [try GamCommands.printCourses(teacher: "alice@example.com"), try GamCommands.printCourses(courseIDs: [Self.chemistry]),
                     try GamCommands.printCourseParticipants(courseID: Self.chemistry)] {
            await #expect(throws: MessageCopies.Incomplete.self, "\(read.argv)") { try await records(read, state: state) }
        }
    }

    /// "1" once matched "500000000001\t" and came back as Biology's roster: GAM says the class doesn't exist.
    @Test func theMockNeverAnswersAShortCourseIDWithALongerOnesRoster() async throws {
        let error = try #require(await #expect(throws: GamError.self) {
            try await records(try GamCommands.printCourseParticipants(courseID: "1"))
        })
        #expect(error.exitCode == 56)
    }

    /// The grammar's <CourseStateList> takes `all` only on its own.
    @Test func theMockTakesAllOnlyOnItsOwn() async throws {
        for states in ["all,active", "active,all", "bogus"] {
            let result = try await run(GamRead(["print", "courses", "states", states, "formatjson"]))
            #expect(result.exitCode == 2 && result.stderr.contains("Invalid choice"), "\(states)")
        }
        #expect(try await run(GamRead(["print", "courses", "states", "all", "formatjson"])).exitCode == 0)
    }

    @Test func withoutOwnerEmailGamNamesNoOwnerAddress() async throws {
        let courses = Classroom.courses(try await records(try GamCommands.printCourses(teacher: "alice@example.com", ownerEmail: false)))
        #expect(!courses.isEmpty && Set(courses.map(\.ownerEmail)) == [""] && Set(courses.map(\.ownerID)) == ["100000000000000000001"])
    }

    /// An owner GAM can't look up (deleted, or out of reach): GAM prints every class, the owner "Unknown user", warns
    /// `Course: <id>, Owner ID: <id>, Does not exist (i/n)` and exits 56. The classes are read, the owner left for the
    /// directory to name; a deviation from GamGUI, which fails the read (review 2026-11-11, GAM 7.51.00's
    /// _convertCourseUserIdToEmailName).
    @Test func anOwnerGAMCantLookUpLeavesEveryClassRead() async throws {
        let state = try state("ownergone")
        defer { try? FileManager.default.removeItem(at: state) }
        try FileManager.default.removeItem(at: state.appending(path: "ownergone"))
        try FileManager.default.createDirectory(at: state.appending(path: "ownergone"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "ownergone/100000000000000000001").path, contents: Data())
        let read = try GamCommands.printCourses(teacher: "alice@example.com")
        let raw = try await run(read, state: state)
        #expect(raw.exitCode == 56 && raw.stderr.hasPrefix("Course: 5000000000"), "GAM's warning, once per owner")
        #expect(raw.stderr.components(separatedBy: "Owner ID:").count == 2)
        let courses = Classroom.courses(try Classroom.records(raw, argv: read.argv))
        #expect(courses.map(\.name) == ["Algebra", "Biology", "Chemistry, \"Honors\""])
        #expect(courses.allSatisfy { $0.ownerEmail.isEmpty && $0.ownerID == "100000000000000000001" }, "never “unknown user”")
        // Beside a class that doesn't exist, the read still fails: only owner warnings are let through.
        let mixed = try GamCommands.printCourses(courseIDs: ["999999", "500000000001"])
        await #expect(throws: GamError.self) { try await records(mixed, state: state) }
    }

    /// GamGUI's `test_only_an_unknown_owner_warning_lets_the_table_stand` (#113), and what `records` adds: exit 56 only, and
    /// a table that came back.
    @Test func onlyOwnerWarningsAreLetThrough() throws {
        let warn = "Course: 500000000004, Owner ID: 100000000000000000009, Does not exist"
        #expect(GamError.onlyUnknownOwners(warn))
        #expect(GamError.onlyUnknownOwners("Getting all Courses that match query ()\n\(warn) (1/2)\n"))
        #expect(!GamError.onlyUnknownOwners(""))
        #expect(!GamError.onlyUnknownOwners("\(warn)\nTeacher: nobody@example.com, Does not exist"))
        #expect(!GamError.onlyUnknownOwners("Course: 999, Does not exist"))
        #expect(!GamError.onlyUnknownOwners("\(warn) (1/2) extra"))
        func result(_ stderr: String, _ code: Int32 = 56, stdout: String = "id,JSON\n") -> GamResult {
            GamResult(exitCode: code, stdout: stdout, stderr: stderr, stdoutTruncated: false, stderrTruncated: false)
        }
        #expect((try? Classroom.records(result(warn), argv: [])) != nil)
        #expect(throws: GamError.self) { try Classroom.records(result(warn, 50), argv: []) }
        // No table: a shortfall, never GAM's not-found, which offboarding would read as "owns none" (GamGUI raises the 56).
        #expect(throws: MessageCopies.Incomplete.self) { try Classroom.records(result(warn, stdout: " \n"), argv: []) }
    }

    // MARK: the domain-wide reads GamGUI's roster compare makes (#112): their shapes, as GAM prints them

    @Test func aliasesComeAsGamPrintsThemObjectsNotStrings() async throws {
        let read = try GamCommands.printCourses(states: Classroom.personStates, ownerEmail: false, aliases: true)
        #expect(read.argv == ["print", "courses", "states", "active,provisioned,archived", "aliases", "fields",
                              GamCommands.courseFields, "formatjson"])
        let raw = try await run(read)
        #expect(raw.exitCode == 0 && raw.stdout.hasPrefix("id,JSON,JSON-aliases\n"))
        let rows = try Classroom.records(raw, argv: read.argv)
        #expect(rows.count == 4)
        let chemistry = try #require(rows.first { Classroom.text($0["id"]) == Self.chemistry })
        guard case .string(let cell)? = chemistry["JSON-aliases"], let items = JSONValue.parse(cell)?.array else {
            Issue.record("JSON-aliases isn't a list"); return
        }
        #expect(items.compactMap { $0.object?["alias"] } == [.string("d:gg-C2"), .string("d:chem-honors")], "objects, as the API gives")
    }

    @Test func everyClassesPeopleIsOneRowAClassInThoseStates() async throws {
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.printAllCourseParticipants(states: []) }
        let read = try GamCommands.printAllCourseParticipants(states: [.active, .active, .provisioned])
        #expect(read.argv == ["print", "course-participants", "states", "active,provisioned", "show", "all", "formatjson"])
        let rows = try await records(read)
        #expect(rows.map { Classroom.text($0["courseId"]) } == ["500000000001", "500000000002", "500000000003"], "not the archived one")
        let all = try await records(try GamCommands.printAllCourseParticipants(states: Classroom.personStates))
        #expect(all.count == 4 && all.allSatisfy { $0["JSON-teachers"] != nil && $0["JSON-students"] != nil })
    }

    // MARK: the classes someone owns (C1.5)

    @Test func theClassesSomeoneOwnsAreByTheirAddressCaseAside() async throws {
        let courses = Classroom.courses(try await records(try GamCommands.printCourses(teacher: "alice@example.com")))
        #expect(Set(Classroom.owned(courses, by: "  ALICE@example.com ").map(\.name)) == ["Algebra", "Biology", "Chemistry, \"Honors\""])
        #expect(Classroom.owned(courses, by: "carol@example.com").isEmpty)
    }

    @Test func theOwnedListIsGamGUIsColumnsFormulaSafeWhereWritten() {
        let course = Classroom.Course(id: "1", name: "=HYPERLINK(\"x\")", section: "-2", state: "ARCHIVED",
                                      ownerEmail: "a@example.com", link: "https://classroom.google.com/c/1")
        let rows = Classroom.ownedRows([course])
        #expect(rows == [["courseId", "name", "section", "state", "owner", "link"],
                         ["1", "=HYPERLINK(\"x\")", "-2", "Archived", "a@example.com", "https://classroom.google.com/c/1"]])
        #expect(Classroom.ownedFileName("o'neil.a-b_c@example.com") == "classes-owned-by-oneil.a-b_c.csv")
        #expect(Classroom.ownedFileName("alice@example.com") == "classes-owned-by-alice.csv")
        #expect(Classroom.ownedFileName("é/;\\@example.com") == "classes-owned-by-person.csv")
    }

    // MARK: the reader's shortfalls

    @Test func aMissingRowOrColumnIsUnreadableNotAnEmptyClass() {
        let roster = Classroom.roster([["courseId": .string("1"), "courseName": .string("X"), "JSON-teachers": .string("[]")]], courseID: "1")
        #expect(roster.students.isEmpty && roster.unreadable == ["JSON-students"])
        #expect(Classroom.roster([], courseID: "1").unreadable == ["the class's row"])
        let notAList = Classroom.roster([["courseId": .string("1"), "JSON-teachers": .string("{}"), "JSON-students": .string("[1]")]],
                                        courseID: "1")
        #expect(notAList.unreadable == ["JSON-teachers", "JSON-students"])
    }

    @Test func aPersonListedWithoutAnAddressSaysAddressesAreHidden() {
        let cell = #"[{"userId": "9", "profile": {"id": "9", "name": {"fullName": "No Mail"}}}]"#
        let roster = Classroom.roster([["courseId": .string("1"), "courseName": .string("X"), "JSON-teachers": .string(cell),
                                        "JSON-students": .string("[]")]], courseID: "1")
        #expect(roster.emailsHidden && roster.teachers.first?.name == "No Mail" && roster.unreadable.isEmpty)
    }

    /// GAM's "no scopes" words read as a missing scope, for any API (GamGUI's errors.py, 3c8d909).
    @Test func noScopesForTheAPIIsAMissingScope() {
        let error = GamError(exitCode: 15, stderr: "\nERROR: There are no scopes authorized for the API(s): Classroom API\n")
        #expect(error.kind == .scopeMissing)
    }

    @Test func theScopesMissingAreNamedOrUnknown() {
        #expect(Classroom.scopesMissing(granted: nil) == nil)
        #expect(Classroom.scopesMissing(granted: []) == Classroom.scopes.map(\.name))
        #expect(Classroom.scopesMissing(granted: Classroom.scopes.map { $0.scope + ".readonly" }) == [])
        #expect(Classroom.scopesMissing(granted: [Classroom.scopes[0].scope]) == ["Classroom API - Rosters", "Classroom API - Profile Emails"])
    }
}
