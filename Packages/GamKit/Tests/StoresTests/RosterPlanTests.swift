import Foundation
import GamEngine
@testable import Stores
import Testing
import TestSupport

/// The change list plans every case as GamGUI's `roster_plan.plan` plans it (invariant 11): `Tests/Fixtures/roster_plan.json`
/// is every `plan` call GamGUI's `tests/test_roster_plan.py` makes, and the compare its web tests make through its mock,
/// recorded by `scripts/gen_fixtures.py` with the ChangeList (changes in run order, counts, flags, notes, summary) and what
/// `roster_handover` hands over for it. Then the planner's own cases, as GamGUI's tests say them.
@Suite("Roster change list")
struct RosterPlanTests {
    struct Case: Sendable {
        let name: String
        let snapshot: RosterSnapshot
        let classroom: [Classroom.Managed]
        let directory: [String]?
        let unread: Int
        let limits: [(kind: RosterPlan.Kind, limit: RosterPlan.Limit)]
        let expect: JSONObject
    }

    nonisolated(unsafe) static let root: JSONValue? = {
        guard let data = try? Data(contentsOf: Fixtures.directory.appending(path: "roster_plan.json")) else { return nil }
        return JSONValue.parse(String(decoding: data, as: UTF8.self))
    }()

    static func managed(_ item: JSONValue) -> Classroom.Managed {
        let course = item["course"] ?? .null
        func s(_ value: JSONValue?) -> String { value?.string ?? "" }
        return Classroom.Managed(
            course: Classroom.Course(id: s(course["id"]), name: s(course["name"]), section: s(course["section"]),
                                     state: s(course["state"]), ownerEmail: s(course["owner_email"])),
            aliases: (item["aliases"]?.array ?? []).map { s($0) }, teachers: (item["teachers"]?.array ?? []).map { s($0) },
            students: (item["students"]?.array ?? []).map { s($0) })
    }

    nonisolated(unsafe) static let cases: [Case] = (root?["cases"]?.array ?? []).map { item in
        func s(_ value: JSONValue?) -> String { value?.string ?? "" }
        func rows(_ key: String) -> [[JSONValue]] { (item["snapshot"]?[key]?.array ?? []).map { $0.array ?? [] } }
        var snapshot = RosterSnapshot(source: "test")
        snapshot.terms = rows("terms").map { .init(id: s($0[0]), title: s($0[1]), kind: "term", start: "", end: "") }
        snapshot.classes = rows("classes").map {
            .init(id: s($0[0]), title: s($0[1]), courseID: "CO1", schoolID: "S1", termIDs: ($0[2].array ?? []).map { s($0) },
                  code: "", location: "")
        }
        snapshot.people = rows("people").map { .init(id: s($0[0]), role: s($0[1]), email: s($0[2]), given: "", family: "") }
        snapshot.enrollments = rows("enrollments").map {
            .init(classID: s($0[0]), personID: s($0[1]), role: s($0[2]), primary: $0[3].bool ?? false)
        }
        let limits = RosterPlan.Kind.allCases.compactMap { kind -> (kind: RosterPlan.Kind, limit: RosterPlan.Limit)? in
            guard let pair = item["limits"]?[kind.rawValue]?.array, pair.count == 2 else { return nil }
            return (kind, RosterPlan.Limit(count: pair[0].int ?? 0, share: pair[1].double ?? 0))
        }
        return Case(name: s(item["name"]), snapshot: snapshot, classroom: (item["classroom"]?.array ?? []).map(managed),
                    directory: item["directory"]?.array.map { $0.map { s($0) } }, unread: item["unread"]?.int ?? 0,
                    limits: limits, expect: item["expect"]?.object ?? [:])
    }

    @Test func theFixtureIsThere() {
        #expect(Self.cases.count >= 27)
        #expect(Self.cases.contains { $0.name == "test_roster_web compare" })
        #expect(Self.cases.allSatisfy { $0.limits.count == 3 }, "GamGUI's LIMITS: three kinds, in its order")
    }

    @Test func theDefaultLimitsAreGamGUIs() throws {
        let plain = try #require(Self.cases.first { $0.name.hasPrefix("test_a_few_removals") })
        #expect(plain.limits.map(\.kind) == RosterPlan.limits.map(\.kind))
        #expect(plain.limits.map(\.limit) == RosterPlan.limits.map(\.limit))
    }

    @Test(arguments: Self.cases.map(\.name))
    func plansAsGamGUIPlansIt(_ name: String) throws {
        let item = try #require(Self.cases.first { $0.name == name })
        let out = RosterPlan.plan(item.snapshot, classroom: item.classroom, directory: item.directory, unread: item.unread,
                                  limits: item.limits)
        let got = Self.form(out)
        for key in item.expect.keys.sorted() {
            #expect(got[key] == item.expect[key], "\(name) \(key):\n\(String(describing: got[key]))\nvs\n\(String(describing: item.expect[key]))")
        }
    }

    @Test func anAliasIsGamGUIs() throws {
        let pairs = try #require(Self.root?["alias_for"]?.array)
        #expect(pairs.count >= 10)
        for pair in pairs {
            let id = pair.array?[0].string ?? "", alias = pair.array?[1].string ?? ""
            #expect(JSONValue.string(RosterPlan.alias(for: id)) == .string(alias), "\(id.debugDescription)")
        }
    }

    /// The ChangeList in the fixture's form.
    static func form(_ out: RosterPlan.ChangeList) -> JSONObject {
        func n(_ value: Int) -> JSONValue { .number(String(value)) }
        func handed(_ flagged: [RosterPlan.Kind]) -> JSONValue {
            do {
                let files = try RosterHandover.build(out, domain: "example.com", when: "2026-11-11 18:00 UTC", including: flagged)
                var named = JSONObject()
                for (name, body) in files { named[name] = .string(String(decoding: body, as: UTF8.self)) }
                return .object(["files": .object(named)])
            } catch {
                return .object(["error": .string(error.message)])
            }
        }
        func indexes(_ kept: [RosterPlan.Change]) -> JSONValue {
            .array(kept.compactMap { change in out.changes.firstIndex(of: change).map(n) })
        }
        var counts = JSONObject(), flags = JSONObject()
        for (kind, count) in out.counts { counts[kind.rawValue] = n(count) }
        for flag in out.flags { flags[flag.kind.rawValue] = .string(flag.why) }
        let all = out.flags.map(\.kind)
        return [
            "changes": .array(out.changes.map(Self.row)),
            "counts": .object(counts), "flags": .object(flags), "notes": .array(out.notes.map(JSONValue.string)),
            "summary": .string(out.summary), "managed": n(out.managed), "enrolled": n(out.enrolled),
            "unmanaged_ignored": n(out.unmanagedIgnored), "incomplete": .bool(out.incomplete),
            "kept": indexes(RosterHandover.kept(out)), "kept_with_flagged": indexes(RosterHandover.kept(out, including: all)),
            "handover": handed([]), "handover_with_flagged": handed(all),
        ]
    }

    static func row(_ c: RosterPlan.Change) -> JSONValue {
        .array([.string(c.kind.rawValue), .string(c.alias), .string(c.title), .string(c.person), .string(c.before),
                .string(c.after), .string(c.courseID), .bool(c.swap), .bool(c.late), .string(c.name), .string(c.section)])
    }

    // MARK: GamGUI's cases, said in Swift (tests/test_roster_plan.py)

    static let people = [("U1", "teacher", "ann@x.com"), ("U2", "teacher", "ben@x.com"), ("U3", "student", "cy@x.com"),
                         ("U4", "student", "di@x.com")]

    static func snap(_ classes: [(String, String)], people: [(String, String, String)] = people,
                     _ enrollments: [(String, String, String, Bool)]) -> RosterSnapshot {
        var snap = RosterSnapshot(source: "test")
        snap.terms = [.init(id: "T1", title: "Fall 2026", kind: "term", start: "", end: "")]
        snap.classes = classes.map { .init(id: $0.0, title: $0.1, courseID: "CO1", schoolID: "S1", termIDs: ["T1"], code: "", location: "") }
        snap.people = people.map { .init(id: $0.0, role: $0.1, email: $0.2, given: "", family: "") }
        snap.enrollments = enrollments.map { .init(classID: $0.0, personID: $0.1, role: $0.2, primary: $0.3) }
        return snap
    }

    static func current(_ alias: String?, _ id: String, _ name: String, owner: String, teachers: [String] = [],
                        students: [String] = [], state: String = "ACTIVE", section: String = "Fall 2026") -> Classroom.Managed {
        Classroom.Managed(course: Classroom.Course(id: id, name: name, section: section, state: state, ownerEmail: owner),
                          aliases: alias.map { [$0] } ?? [], teachers: teachers, students: students)
    }

    static func kinds(_ out: RosterPlan.ChangeList) -> [String] { out.changes.map { "\($0.kind.rawValue) \($0.person)" } }

    @Test func anAliasIsTheSISIDWhenPlainAndAHashOtherwise() {
        #expect(RosterPlan.alias(for: "C-101.a_b") == "d:gg-C-101.a_b")
        let weird = RosterPlan.alias(for: "class #1 / ünï")
        #expect(weird.hasPrefix("d:gg-h") && weird.count == "d:gg-h".count + 24)
        #expect(RosterPlan.alias(for: "e\u{301}") != RosterPlan.alias(for: "\u{E9}"), "two spellings, two classes")
    }

    @Test func aNewClassIsCreatedOwnedByItsPrimaryTeacherThenFilled() {
        let out = RosterPlan.plan(Self.snap([("C1", "Biology")], [("C1", "U1", "teacher", false), ("C1", "U2", "teacher", true),
                                                                  ("C1", "U3", "student", false)]), classroom: [])
        #expect(Self.kinds(out) == ["create ben@x.com", "add_teacher ann@x.com", "add_student cy@x.com"])
        #expect(out.changes[0].alias == RosterPlan.alias(for: "C1") && out.changes[0].after == "Biology · Fall 2026")
    }

    @Test func anExistingClassIsRenamedFilledEmptiedAndItsOwnerChangedInOrder() {
        let snap = Self.snap([("C1", "Biology II")], [("C1", "U2", "teacher", true), ("C1", "U3", "student", false)])
        let out = RosterPlan.plan(snap, classroom: [Self.current(RosterPlan.alias(for: "C1"), "500", "Biology", owner: "ann@x.com",
                                                                 teachers: ["ann@x.com"], students: ["di@x.com"])])
        #expect(Self.kinds(out) == ["rename ", "add_teacher ben@x.com", "add_student cy@x.com", "owner ben@x.com",
                                    "remove_teacher ann@x.com", "remove_student di@x.com"])
        #expect(out.changes.allSatisfy { $0.courseID == "500" })
    }

    @Test func anOutgoingOwnerWhoBecomesAStudentWaitsForTheOwnerChange() {
        let snap = Self.snap([("C1", "Biology")], people: Self.people + [("U9", "student", "ann@x.com")],
                             [("C1", "U2", "teacher", true), ("C1", "U9", "student", false)])
        let out = RosterPlan.plan(snap, classroom: [Self.current(RosterPlan.alias(for: "C1"), "500", "Biology", owner: "ann@x.com",
                                                                 teachers: ["ann@x.com"])])
        #expect(Self.kinds(out) == ["add_teacher ben@x.com", "owner ben@x.com", "remove_teacher ann@x.com", "add_student ann@x.com"])
        #expect(!out.changes[2].swap && out.changes[3].late)
    }

    @Test func onlyClassesWithTheAliasAreComparedOrArchivedAndALookalikeIsNeverCreatedTwice() {
        let out = RosterPlan.plan(Self.snap([], []), classroom: [
            Self.current("d:something-else", "600", "Art club", owner: "ann@x.com"),
            Self.current(RosterPlan.alias(for: "OLD"), "700", "Old class", owner: "ann@x.com"),
            Self.current(RosterPlan.alias(for: "OLDER"), "800", "Older", owner: "ann@x.com", state: "ARCHIVED"),
        ])
        #expect(Self.kinds(out) == ["archive "] && out.changes[0].courseID == "700")
        #expect(out.unmanagedIgnored == 1 && out.managed == 2)
        let lookalike = RosterPlan.plan(Self.snap([("C1", "Biology")], [("C1", "U1", "teacher", true)]),
                                        classroom: [Self.current(nil, "600", "Biology", owner: "ann@x.com")])
        #expect(lookalike.changes.isEmpty && lookalike.notes[0].contains("1 SIS class matches a Classroom class by name and section"))
    }

    @Test func theDirectoryNeverCausesARemoval() {
        let snap = Self.snap([("C1", "Biology")], [("C1", "U1", "teacher", true), ("C1", "U3", "student", false)])
        let out = RosterPlan.plan(snap, classroom: [Self.current(RosterPlan.alias(for: "C1"), "500", "Biology", owner: "ann@x.com",
                                                                 teachers: ["ann@x.com"], students: ["cy@x.com"])],
                                  directory: ["ann@x.com"])
        #expect(out.changes.isEmpty && out.notes[0].contains("nor removed"))
    }

    @Test func massRemovalsAreFlaggedPastBothLimitsAndTheHeadlineNeverSaysItMatchesWhenItCouldntTell() throws {
        let limit = try #require(RosterPlan.limits.first { $0.kind == .removeStudent }?.limit)
        let students = (0...limit.count).map { "s\($0)@x.com" }
        let out = RosterPlan.plan(Self.snap([("C1", "Biology")], [("C1", "U1", "teacher", true)]),
                                  classroom: [Self.current(RosterPlan.alias(for: "C1"), "500", "Biology", owner: "ann@x.com",
                                                           teachers: ["ann@x.com"], students: students)])
        #expect(out.count(.removeStudent) == limit.count + 1)
        #expect(out.flag(.removeStudent)?.hasPrefix("Would remove 501 students, 99.8% of the people in them") == true)
        #expect(RosterPlan.plan(Self.snap([], []), classroom: [], unread: 1).summary.hasPrefix("Nothing could be planned"))
        #expect(RosterPlan.plan(Self.snap([], []), classroom: []).summary == "Classroom already matches the roster: nothing to change.")
    }

    @Test func numbersAreGroupedAsPythonGroupsThem() {
        #expect([0, 7, 999, 1_000, 12_345, 1_203, 1_000_000, -1_234].map(RosterPlan.grouped)
                == ["0", "7", "999", "1,000", "12,345", "1,203", "1,000,000", "-1,234"])
    }

    /// GamGUI's `_changes_ctx`: by kind, then the query stripped and lowercased in the title or alias (lowercased) or the
    /// person (as written); the page clamped. With the haystack made once per list the answer is the same, query by query.
    @Test func aPageIsGamGUIsChangesContextWithOrWithoutTheHaystack() {
        var changes: [RosterPlan.Change] = (0..<120).map { .init(.addStudent, "d:gg-C\($0 % 3)", "Class \($0 % 3)", person: "s\($0)@example.com") }
        changes.append(.init(.rename, "d:gg-ÉTÉ", "ÉTÉ Art · P1", before: "Old", after: "ÉTÉ Art · P1"))
        changes.append(.init(.removeTeacher, "d:gg-C1", "Class 1", person: "Ann@Example.com"))
        let list = RosterPlan.ChangeList(changes: changes)
        let haystack = RosterPlan.Haystack(list)
        for (kind, query, page) in [(nil, "", 1), (nil, "", 9), (RosterPlan.Kind.addStudent, "", 2), (nil, "  CLASS 2 ", 1),
                                     (nil, "été", 1), (nil, "d:gg-c1", 2), (nil, "ann@", 1), (nil, "Ann@", 1), (.rename, "art", 1),
                                     (nil, "nobody", 1), (nil, "s11", 0)] as [(RosterPlan.Kind?, String, Int)] {
            let plain = RosterPlan.page(list, kind: kind, query: query, page: page)
            #expect(RosterPlan.page(list, kind: kind, query: query, page: page, haystack: haystack) == plain, "\(query) \(page)")
        }
        #expect(RosterPlan.page(list, kind: nil, query: "", page: 9).page == 3, "clamped to the last page")
        #expect(RosterPlan.page(list, kind: nil, query: "", page: 0).page == 1)
        #expect(RosterPlan.page(list, kind: nil, query: "  CLASS 2 ").total == 40)
        #expect(RosterPlan.page(list, kind: nil, query: "été").total == 1, "the title, lowercased")
        #expect(RosterPlan.page(list, kind: nil, query: "Ann@").total == 0, "the query is lowercased; the person is as written")
        #expect(RosterPlan.page(list, kind: nil, query: "s11").total == 11, "s11, s110 to s119")
    }
}
