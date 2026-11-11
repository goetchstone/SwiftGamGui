import Foundation
@testable import Directory
import GamEngine
import Setup
import Stores
import TestSupport
import Testing
import Vault

/// The Classroom screen's reads against the strict mock (plan 2026-11-11 C1.3; GamGUI's `tests/test_classroom_web.py` at
/// 3c8d909): the index once per tenant, a failed one said again for a minute rather than re-run, a teacher's classes only
/// when asked, a class's card with its roster. Nothing here writes.
@MainActor
@Suite("Classroom reads", .serialized)
final class ClassroomReadsTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-classroom-\(UUID().uuidString)")
    let setup: SetupModel
    let access: UserAccess
    let state: URL
    let argvLog: URL
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    lazy var reads = ClassroomReads(setup: setup, access: access, now: { [unowned self] in self.clock })

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let vault = Vault(store: MemoryStore())
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        state = scratch.appending(path: "mock-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        argvLog = scratch.appending(path: "argv.log")
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": state.path, "GAM_MOCK_ARGV_LOG": argvLog.path]
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect() async throws {
        let folder = scratch.appending(path: "config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: "admin@example.com").write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
    }

    /// The courses reads the mock was asked for, in order.
    private func courseReads() throws -> [[String]] {
        guard let data = FileManager.default.contents(atPath: argvLog.path) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first), fields.count > count {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.count > 1 && $0[0] == "print" && ($0[1] == "courses" || $0[1] == "course-participants") }
    }

    @Test func theIndexIsTheOpenClassesReadOncePerTenantWithoutOwnerAddresses() async throws {
        try await connect()
        await reads.loadIndex()
        let index = try #require(reads.indexState?.value)
        #expect(index.map(\.name) == ["Algebra", "Biology", "Chemistry, \"Honors\""], "the archived class isn't open")
        #expect(index.allSatisfy { $0.ownerEmail.isEmpty }, "owners come from the directory cache, by ID")
        await reads.loadIndex()
        #expect(try courseReads().count == 1, "in hand: not read again")
        #expect(try courseReads().first?.contains("owneremail") == false)
        #expect(reads.indexed(matching: "  CHEM ")?.map(\.id) == ["500000000002"])
        #expect(reads.indexed(matching: "period 1")?.map(\.name) == ["Algebra"], "the section is searched too")
        #expect(reads.indexed(matching: "C3")?.map(\.name) == ["Chemistry, \"Honors\""], "and the room")
    }

    @Test func aFailedIndexIsSaidAgainForAMinuteNotReadAgain() async throws {
        try await connect()
        FileManager.default.createFile(atPath: state.appending(path: "noclassroom").path, contents: Data())
        await reads.loadIndex()
        #expect(reads.indexState?.problem?.summary == Classroom.scopeNote)
        clock += 59
        await reads.loadIndex()
        #expect(try courseReads().count == 1, "a minute isn't up: said again, not re-run")
        await reads.loadIndex(force: true)
        #expect(try courseReads().count == 2, "Refresh reads at once")
        clock += 61
        try FileManager.default.removeItem(at: state.appending(path: "noclassroom"))
        await reads.loadIndex()
        #expect(try courseReads().count == 3 && reads.indexState?.value?.count == 3)
    }

    @Test func aTeachersClassesIncludeArchivedOnesWithOwners() async throws {
        try await connect()
        await reads.readTeacher("Alice@Example.com")
        let classes = try #require(reads.teacher("alice@example.com")?.value)
        #expect(classes.map(\.name) == ["Algebra", "Biology", "Chemistry, \"Honors\""])
        await reads.readTeacher("nobody@example.com")
        #expect(reads.teacher("nobody@example.com")?.problem?.summary == "Classroom doesn't know “nobody@example.com”.")
        await reads.readTeacher("carol@example.com")
        #expect(reads.teacher("carol@example.com")?.value?.isEmpty == true, "a student teaches nothing: none, not a failure")
        #expect(try courseReads().allSatisfy { !$0.contains("teacher") || $0.contains("active,provisioned,archived") })
    }

    @Test func aClassCardHasItsRecordAndRoster() async throws {
        try await connect()
        await reads.readCard("500000000002")
        let card = try #require(reads.card("500000000002"))
        #expect(card.course.value?.ownerEmail == "alice@example.com")
        #expect(card.roster.value?.students.map(\.name) == ["Bob Brown", "Carol Clark"])
        await reads.readCard("999999")
        #expect(reads.card("999999")?.course.problem?.summary == "Classroom doesn't know class 999999.")
        await reads.readCard("12a")
        #expect(reads.card("12a")?.course.problem?.summary == "“12a” isn't a Classroom class ID: it's digits only.")
        #expect(try courseReads().allSatisfy { $0.allSatisfy { $0 != "12a" } }, "refused before GAM")
    }

    @Test func aTenantSwitchShowsNoneOfTheOldReads() async throws {
        try await connect()
        await reads.loadIndex()
        await reads.readCard("500000000002")
        #expect(reads.indexState != nil && reads.card("500000000002") != nil)
        await setup.remove(Domain("example.com")!)
        #expect(reads.indexState == nil && reads.card("500000000002") == nil && reads.indexReadAt == nil)
    }

    /// Leaving the screen mid-read stops it: nothing is kept, so the next look reads again, and no Swift error's text is
    /// ever said (review 2026-11-11).
    @Test func aStoppedReadIsNeverKeptAsAFailure() async throws {
        try await connect()
        let index = Task { await reads.loadIndex() }
        index.cancel()
        await index.value
        #expect(reads.indexState == nil)
        let card = Task { await reads.readCard("500000000002") }
        card.cancel()
        await card.value
        #expect(reads.card("500000000002") == nil)
        await reads.loadIndex()
        #expect(reads.indexState?.value?.count == 3, "read again at once: no minute's hold")
    }

    /// A Refresh stopped mid-read leaves the classes already read in hand, never a cold screen (review 2026-11-11).
    @Test func aStoppedRefreshKeepsTheIndexInHand() async throws {
        try await connect()
        await reads.loadIndex()
        let refresh = Task { await reads.loadIndex(force: true) }
        refresh.cancel()
        await refresh.value
        #expect(reads.indexState?.value?.count == 3)
    }

    /// A class's card is read each time it's opened, as GamGUI's is: a failure or a changed roster is read again.
    @Test func aCardIsReadAgainWhenOpenedAgain() async throws {
        try await connect()
        await reads.readCard("500000000002")
        await reads.readCard("500000000002")
        #expect(try courseReads().filter { $0.contains("500000000002") }.count == 4, "the record and the roster, twice")
    }

    @Test func onlyTheLastFewCardsAreKept() async throws {
        try await connect()
        let small = ClassroomReads(setup: setup, access: access, keep: 2)
        for id in ["500000000001", "500000000002", "500000000003"] { await small.readCard(id) }
        #expect(small.card("500000000001") == nil && small.card("500000000003") != nil)
    }
}
