import Foundation
import GamEngine
@testable import Stores
import Testing
import TestSupport

/// The roster reader reads every package as GamGUI's `read_upload` reads it (invariant 11): the same refusal in the same
/// words, or the same snapshot and issues, over `Tests/Fixtures/roster.json` (`scripts/gen_fixtures.py`: every package
/// GamGUI's tests build, and the ZIP and CSV shapes behind them), and over every upload GamGUI's Clever and column-map tests
/// read (`roster_mapped.json`'s `uploads`). A case the generator marks `swift` is a listed deviation the Swift reader
/// refuses (docs/domains/classroom.md).
@Suite("Roster reader parity")
struct RosterParityTests {
    struct Case {
        let name: String
        let uploads: [Roster.Upload]
        let caps: RosterCaps
        let expect: JSONValue
        let swift: String?
    }

    /// Read with GamEngine's `JSONValue` (Python's `json.loads`), whose strings compare by their exact UTF-8: Foundation's
    /// JSONSerialization drops a string's leading U+FEFF, and NSString's equality ignores one, so a reader that wrongly
    /// stripped it would pass.
    nonisolated(unsafe) static let cases: [Case] = {
        func load(_ file: String, _ key: String) -> [JSONValue] {
            guard let data = try? Data(contentsOf: Fixtures.directory.appending(path: file)),
                  let root = JSONValue.parse(String(decoding: data, as: UTF8.self))
            else { return [] }
            return root[key]?.array ?? []
        }
        return (load("roster.json", "cases") + load("roster_mapped.json", "uploads")).map { item in
            let uploads = (item["uploads"]?.array ?? []).map {
                Roster.Upload(name: $0.array?[0].string ?? "",
                              bytes: Array(Data(base64Encoded: $0.array?[1].string ?? "") ?? Data()))
            }
            var caps = RosterCaps()
            for (key, raw) in item["caps"]?.object ?? [:] {
                let value = raw.int ?? 0
                switch key {
                case "upload": caps.upload = value
                case "member": caps.member = value
                case "total": caps.total = value
                case "ratio": caps.ratio = value
                case "members": caps.members = value
                case "centralDirectory": caps.centralDirectory = value
                case "manifest": caps.manifest = value
                case "columns": caps.columns = value
                case "line": caps.line = value
                case "rows": caps.rows = value
                case "field": caps.field = value
                case "issueSample": caps.issueSample = value
                default: Issue.record("an unknown cap \(key)")
                }
            }
            return Case(name: item["name"]?.string ?? "", uploads: uploads, caps: caps,
                        expect: item["expect"] ?? .null, swift: item["swift"]?.string)
        }
    }()

    @Test func theFixtureIsThere() {
        #expect(Self.cases.count >= 165)
        #expect(Set(Self.cases.map(\.name)).count == Self.cases.count)
    }

    /// The comparison itself keeps a leading U+FEFF, and tells "é" from "e" + U+0301.
    @Test func theComparisonIsByExactText() {
        #expect(JSONValue.string("\u{FEFF}a@example.com") != .string("a@example.com"))
        #expect(JSONValue.parse(#"["\ufeffa@example.com"]"#)?.array?.first == .string("\u{FEFF}a@example.com"))
        #expect(JSONValue.string("\u{E9}") != .string("e\u{301}"))
    }

    @Test(arguments: Self.cases.map(\.name))
    func readsAsGamGUIReadsIt(_ name: String) throws {
        let item = try #require(Self.cases.first { $0.name == name })
        let result = Result { () throws(Roster.Refusal) in try Roster.read(item.uploads, caps: item.caps) }
        if item.swift == "refused" {
            guard case .failure = result else { Issue.record("\(name): GamGUI reads it; this reader must refuse it"); return }
            return
        }
        if let error = item.expect["error"]?.string {
            guard case .package(let words) = result.refusal else { Issue.record("\(name): \(result) vs \(error)"); return }
            #expect(JSONValue.string(words) == .string(error), "\(name): \(words) vs \(error)")
        } else if let map = item.expect["needs_map"]?.string {
            guard case .needsMap(let named, _) = result.refusal else { Issue.record("\(name): \(result) vs \(map)"); return }
            #expect(JSONValue.string(named) == .string(map), "\(name)")
        } else {
            let expected = try #require(item.expect["snapshot"]?.object)
            guard case .success(let snapshot) = result else {
                Issue.record("\(name): refused, \(result.refusal?.message ?? "")")
                return
            }
            let got = Self.form(snapshot)
            for key in expected.keys.sorted() {
                #expect(got[key] == expected[key],
                        "\(name) \(key): \(String(describing: got[key])) vs \(String(describing: expected[key]))")
            }
        }
    }

    /// The snapshot in the fixture's form (GamGUI's dataclasses, as lists).
    static func form(_ snapshot: RosterSnapshot) -> JSONObject {
        func s(_ text: String) -> JSONValue { .string(text) }
        func n(_ number: Int) -> JSONValue { .number(String(number)) }
        var counts = JSONObject()
        for (key, value) in snapshot.counts.ordered { counts[key] = n(value) }
        return [
            "source": s(snapshot.source),
            "schools": .array(snapshot.schools.map { .array([s($0.id), s($0.name)]) }),
            "terms": .array(snapshot.terms.map { .array([s($0.id), s($0.title), s($0.kind), s($0.start), s($0.end)]) }),
            "courses": .array(snapshot.courses.map { .array([s($0.id), s($0.title), s($0.code), s($0.schoolID)]) }),
            "classes": .array(snapshot.classes.map {
                .array([s($0.id), s($0.title), s($0.courseID), s($0.schoolID), .array($0.termIDs.map(s)), s($0.code),
                        s($0.location)])
            }),
            "people": .array(snapshot.people.map { .array([s($0.id), s($0.role), s($0.email), s($0.given), s($0.family)]) }),
            "enrollments": .array(snapshot.enrollments.map { .array([s($0.classID), s($0.personID), s($0.role), .bool($0.primary)]) }),
            "issue_counts": .array(snapshot.issueCounts.map { .array([s($0.code), n($0.count)]) }),
            "issue_sample": .array(snapshot.issueSample.map { .array([s($0.code), s($0.file), n($0.row), s($0.sourceID), s($0.detail)]) }),
            "others": n(snapshot.others),
            "counts": .object(counts),
        ]
    }
}

extension Result where Failure == Roster.Refusal {
    var refusal: Roster.Refusal? {
        if case .failure(let refusal) = self { refusal } else { nil }
    }
}
