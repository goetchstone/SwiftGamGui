@testable import ChangeCore
import Foundation
@testable import Directory
import GamEngine
import Setup
@testable import Stores
import TestSupport
import Testing
import Vault

/// Compare with Classroom and hand it over (plan 2026-11-11 C3, C4; GamGUI's `tests/test_roster_web.py` at 07c505d), end
/// to end through the strict mock: the web test's roster kept, Classroom and the directory read (reads only), the change list
/// GamGUI planned for it, held per tenant and per kept roster, and the hand-over saved 0600 and audited without rows.
@MainActor
@Suite("Roster compare", .serialized)
final class RosterCompareTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-compare-\(UUID().uuidString)")
    let setup: SetupModel
    let access: UserAccess
    let store: RosterStore
    let auditURL: URL
    let state: URL
    let argvLog: URL
    let compare: RosterCompare

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
        store = RosterStore(root: scratch.appending(path: "roster"))
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        compare = RosterCompare(setup: setup, access: access, store: store, auditURL: auditURL,
                                now: { Date(timeIntervalSince1970: 1_794_420_000) })   // 2026-11-11 18:00 UTC
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect(_ domain: String = "example.com") async throws {
        let folder = scratch.appending(path: "config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: "admin@\(domain)").write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: domain)
        await setup.checkAccess(Domain(domain)!)
    }

    /// The web test's case from `roster_plan.json`: its roster and what GamGUI planned.
    static func webCase() throws -> (snapshot: RosterSnapshot, expect: JSONObject) {
        let data = try Data(contentsOf: Fixtures.directory.appending(path: "roster_plan.json"))
        let root = try #require(JSONValue.parse(String(decoding: data, as: UTF8.self)))
        let item = try #require(root["cases"]?.array?.first { $0["name"]?.string == "test_roster_web compare" })
        func s(_ value: JSONValue?) -> String { value?.string ?? "" }
        func rows(_ key: String) -> [[JSONValue]] { (item["snapshot"]?[key]?.array ?? []).map { $0.array ?? [] } }
        var snapshot = RosterSnapshot(source: "OneRoster 1.1 CSV")
        snapshot.terms = rows("terms").map { .init(id: s($0[0]), title: s($0[1]), kind: "term", start: "", end: "") }
        snapshot.classes = rows("classes").map {
            .init(id: s($0[0]), title: s($0[1]), courseID: "CO1", schoolID: "S1", termIDs: ($0[2].array ?? []).map { s($0) },
                  code: "", location: "")
        }
        snapshot.people = rows("people").map { .init(id: s($0[0]), role: s($0[1]), email: s($0[2]), given: "", family: "") }
        snapshot.enrollments = rows("enrollments").map {
            .init(classID: s($0[0]), personID: s($0[1]), role: s($0[2]), primary: $0[3].bool ?? false)
        }
        return (snapshot, item["expect"]?.object ?? [:])
    }

    private func keep(_ snapshot: RosterSnapshot, sha256: String = "a1") throws -> RosterStore.Meta {
        try store.save(snapshot, domain: "example.com", label: "export.zip", sha256: sha256)
    }

    private func calls() -> [[String]] {
        guard let data = FileManager.default.contents(atPath: argvLog.path) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var out: [[String]] = []
        while let first = fields.first, let count = Int(first), fields.count > count {
            out.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return out
    }

    private func audited() -> [JSONValue] {
        guard let text = try? String(contentsOf: auditURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
    }

    @Test func comparePlansOnlyTheAppsClassesWithReadsOnly() async throws {
        try await connect()
        let (snapshot, expect) = try Self.webCase()
        let meta = try keep(snapshot)
        await compare.compare()
        let held = try #require(compare.held(for: meta.sha256))
        #expect(held.when == "2026-11-11 18:00 UTC")
        #expect(held.plan.summary == "Would remove 1 person; would create 1 class, add 1 person and rename 2 classes.")
        #expect(JSONValue.array(held.plan.changes.map(Self.row)) == expect["changes"], "GamGUI's change list for the same roster")
        #expect(held.plan.unmanagedIgnored == 1 && !held.plan.incomplete && held.plan.notes.isEmpty)
        let reads = calls().map { Array($0.prefix(2)) }
        #expect(reads.filter { $0 == ["print", "courses"] }.count == 1 && reads.filter { $0 == ["print", "course-participants"] }.count == 1)
        #expect(reads.allSatisfy { [["print", "courses"], ["print", "course-participants"], ["print", "users"]].contains($0) },
                "reads only: \(reads)")
        let record = try #require(audited().last)
        #expect(record["action"]?.string == "roster_compare" && record["extra"]?["counts"]?["create"]?.int == 1)
        #expect(!String(describing: record).contains("bob@example.com"), "never a row")
    }

    @Test func aNewRosterOrAPurgeDropsTheCompareAndATenantSwitchToo() async throws {
        try await connect()
        let meta = try keep(try Self.webCase().snapshot)
        await compare.compare()
        #expect(compare.held(for: meta.sha256) != nil)
        #expect(compare.held(for: "another roster") == nil, "a new upload is another roster")
        #expect(compare.held(for: nil) == nil, "purged: no roster")
        try await connect("example.org")
        try await connect("example.com")
        #expect(compare.held(for: meta.sha256) == nil, "a switch dropped it")
    }

    @Test func aCompareThatCantReadClassroomSaysSoAndNothingIsHeld() async throws {
        try await connect()
        let meta = try keep(try Self.webCase().snapshot)
        FileManager.default.createFile(atPath: state.appending(path: "noclassroom").path, contents: Data())
        await compare.compare()
        #expect(compare.problem == Classroom.scopeNote)
        #expect(compare.held(for: meta.sha256) == nil && !compare.isRunning)
        try FileManager.default.removeItem(at: state.appending(path: "noclassroom"))
        await compare.compare()
        #expect(compare.problem == nil && compare.held(for: meta.sha256) != nil, "Try Again reads again")
    }

    /// A new roster, a purge or a tenant switch drops the compare reading (`drop()`, what each calls): it stores nothing,
    /// neither a change list nor a failure, and the next ask starts at once instead of being ignored behind it.
    @Test func aCompareDroppedWhileReadingStoresNothingAndTheNextOneStarts() async throws {
        try await connect()
        let snapshot = try Self.webCase().snapshot
        let first = try keep(snapshot, sha256: "a1")
        let reading = Task { await compare.compare() }
        while !compare.isRunning { await Task.yield() }
        compare.drop()
        #expect(!compare.isRunning, "the dropped compare is no longer this screen's")
        let second = try keep(snapshot, sha256: "b2")
        let next = await compare.compare()
        guard case .compared(let held) = next else { Issue.record("the new ask ran: \(next)"); return }
        #expect(held.sha256 == second.sha256 && compare.held(for: second.sha256)?.id == held.id)
        guard case .dropped = await reading.value else { Issue.record("the dropped compare says so"); return }
        #expect(compare.held(for: second.sha256)?.id == held.id && compare.held(for: first.sha256) == nil, "the dropped one stored nothing")
        #expect(audited().filter { $0["action"]?.string == "roster_compare" }.count == 1, "nor audited a compare nobody sees")
    }

    @Test func anAskWhileOneReadsForThisTenantIsBusy() async throws {
        try await connect()
        _ = try keep(try Self.webCase().snapshot)
        let reading = Task { await compare.compare() }
        while !compare.isRunning { await Task.yield() }
        guard case .busy = await compare.compare() else { Issue.record("said, not silently ignored"); return }
        guard case .compared = await reading.value else { Issue.record("the first one finishes"); return }
    }

    /// Two compares in one minute share `when`; the screen resets on `id`, which is each compare's own.
    @Test func eachCompareIsItsOwnEvenInTheSameMinute() async throws {
        try await connect()
        let meta = try keep(try Self.webCase().snapshot)
        let first = try #require(await { if case .compared(let held) = await compare.compare() { held } else { nil } }())
        let second = try #require(await { if case .compared(let held) = await compare.compare() { held } else { nil } }())
        #expect(first.when == second.when && first.id != second.id)
        #expect(compare.held(for: meta.sha256)?.id == second.id)
    }

    /// The hand-over's bytes are made off the main actor (a district's list is tens of thousands of changes): `package` is
    /// nonisolated, so this compiles, and it is what `handOver` saves.
    @Test func theHandOverIsMadeOffTheMainActor() async throws {
        let changes = (0..<20_000).map { RosterPlan.Change(.addStudent, "d:gg-C\($0 % 400)", "Class \($0 % 400)", person: "s\($0)@example.com") }
        let plan = RosterPlan.ChangeList(changes: changes)
        let made = try await Task.detached {
            try RosterCompare.package(plan, domain: "example.com", when: "2026-11-11 18:00 UTC", including: [])
        }.value
        #expect(made.bytes == RosterHandover.zip(try RosterHandover.build(plan, domain: "example.com", when: "2026-11-11 18:00 UTC"),
                                                 when: "2026-11-11 18:00 UTC"))
        #expect(made.counts["add_student"]?.int == 20_000)
    }

    @Test func aDroppedCompareThatFailsSaysNothingOfTheNextRoster() async throws {
        try await connect()
        _ = try keep(try Self.webCase().snapshot)
        FileManager.default.createFile(atPath: state.appending(path: "noclassroom").path, contents: Data())
        let reading = Task { await compare.compare() }
        while !compare.isRunning { await Task.yield() }
        compare.drop()
        guard case .dropped = await reading.value else { Issue.record("dropped, not failed"); return }
        #expect(compare.problem == nil, "the dropped compare's failure isn't the new roster's")
    }

    @Test func noRosterKeptIsSaid() async throws {
        try await connect()
        await compare.compare()
        #expect(compare.problem == RosterCompare.noRoster)
        #expect(calls().isEmpty, "nothing read from Google without a roster")
    }

    @Test func theHandOverIsAPrivateZipAuditedWithoutRows() async throws {
        try await connect()
        let meta = try keep(try Self.webCase().snapshot)
        await compare.compare()
        let held = try #require(compare.held(for: meta.sha256))
        let before = calls().count
        let destination = scratch.appending(path: RosterHandover.zipName(domain: "example.com", when: held.when))
        let said = await compare.handOver(held, including: [], to: destination)
        #expect(said == "Saved the hand-over to classroom-changes-example.com-202611111800.zip.")
        #expect(calls().count == before, "no GAM: it hands over, it never runs")
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let bytes = try [UInt8](Data(contentsOf: destination))
        let names = try RosterZip.open(bytes, caps: RosterCaps()).entries.map(\.name)
        #expect(Set(["README.txt", "review.csv", "03-create-classes.csv", "06-add-students.csv", "10-remove-students.csv"]).isSubset(of: names))
        #expect(bytes == RosterHandover.zip(try RosterHandover.build(held.plan, domain: "example.com", when: held.when), when: held.when),
                "one compare, one set of bytes")
        let record = try #require(audited().last)
        #expect(record["action"]?.string == "roster_handover" && record["extra"]?["counts"]?["create"]?.int == 1)
        #expect(record["extra"]?["included_flagged"] == .array([]))
        #expect(!String(describing: record).contains("bob@example.com"), "never a row")
    }

    @Test func aFlaggedKindNeedsItsTickAndAnUnflaggedTickChangesNothing() async throws {
        let (snapshot, _) = try Self.webCase()
        try await connect()
        let state = try Classroom.State(classes: Self.webClassroom(), unread: [])
        let plan = RosterPlan.plan(snapshot, classroom: state.classes, limits: [(.removeStudent, .init(count: 0, share: 0))])
        let held = RosterCompare.Held(domain: "example.com", generation: setup.generation, sha256: "a1", when: "2026-11-11 18:00 UTC", plan: plan)
        func names(_ flagged: [RosterPlan.Kind]) async throws -> [String] {
            let destination = scratch.appending(path: "\(UUID().uuidString).zip")
            _ = await compare.handOver(held, including: flagged, to: destination)
            return try RosterZip.open([UInt8](Data(contentsOf: destination)), caps: RosterCaps()).entries.map(\.name)
        }
        let left = try await names([])
        #expect(!left.contains("10-remove-students.csv"))
        #expect(try await names([.removeStudent]).contains("10-remove-students.csv"))
        #expect(try await names([.archive]) == left, "not flagged: no effect")
        #expect(audited().last?["extra"]?["included_flagged"] == .array([]))
    }

    @Test func anIncompleteListHandsNothingOver() async throws {
        try await connect()
        var plan = RosterPlan.ChangeList(changes: [.init(.archive, "d:gg-OLD", "Old")])
        plan.incomplete = true
        let held = RosterCompare.Held(domain: "example.com", generation: setup.generation, sha256: "a1", when: "2026-11-11 18:00 UTC", plan: plan)
        let destination = scratch.appending(path: "x.zip")
        #expect(await compare.handOver(held, including: [], to: destination) == RosterHandover.Refusal.incomplete.message)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func theReviewSheetsRuleIsTheAuditExportsRule() {
        for text in ["", "a", "=1", "+1", "-1", "@a", "\tx", "\rx", "'x", " =x", "\u{FF1D}x", "é"] {
            #expect(RosterHandover.csvSafe(text) == AuditExport.safe(.string(text)), "\(text.debugDescription)")
        }
    }

    @Test func theCompareTimeIsGamGUIsClockText() {
        #expect(RosterCompare.clock(Date(timeIntervalSince1970: 1_794_420_000)) == "2026-11-11 18:00 UTC")
        #expect(RosterCompare.clock(Date(timeIntervalSince1970: 1_794_420_059)) == "2026-11-11 18:00 UTC")
    }

    static func webClassroom() throws -> [Classroom.Managed] {
        let data = try Data(contentsOf: Fixtures.directory.appending(path: "roster_plan.json"))
        let root = try #require(JSONValue.parse(String(decoding: data, as: UTF8.self)))
        let item = try #require(root["cases"]?.array?.first { $0["name"]?.string == "test_roster_web compare" })
        return (item["classroom"]?.array ?? []).map { m in
            let c = m["course"] ?? .null
            return Classroom.Managed(course: Classroom.Course(id: c["id"]?.string ?? "", name: c["name"]?.string ?? "",
                                                              section: c["section"]?.string ?? "", state: c["state"]?.string ?? "",
                                                              ownerEmail: c["owner_email"]?.string ?? ""),
                                     aliases: (m["aliases"]?.array ?? []).compactMap(\.string),
                                     teachers: (m["teachers"]?.array ?? []).compactMap(\.string),
                                     students: (m["students"]?.array ?? []).compactMap(\.string))
        }
    }

    static func row(_ c: RosterPlan.Change) -> JSONValue {
        .array([.string(c.kind.rawValue), .string(c.alias), .string(c.title), .string(c.person), .string(c.before),
                .string(c.after), .string(c.courseID), .bool(c.swap), .bool(c.late), .string(c.name), .string(c.section)])
    }
}
