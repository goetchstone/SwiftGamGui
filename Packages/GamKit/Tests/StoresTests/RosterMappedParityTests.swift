import Foundation
import GamEngine
@testable import Stores
import Testing
import TestSupport

/// Clever's reader and the column map read as GamGUI's do (invariant 11), over `Tests/Fixtures/roster_mapped.json`: every
/// call GamGUI's own tests/test_roster_clever.py and test_roster_mapped.py make, recorded by `scripts/gen_fixtures.py` with
/// its result or its words, and the map step's readers (`header_of`, the form's role words, a saved map's name). The
/// uploads those tests read are held by `RosterParityTests`. Each comparison is by exact text (`JSONValue`).
@Suite("Clever and column-map parity")
struct RosterMappedParityTests {
    nonisolated(unsafe) static let root: JSONValue = {
        guard let data = try? Data(contentsOf: Fixtures.directory.appending(path: "roster_mapped.json")) else { return .null }
        return JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null
    }()

    static func cases(_ key: String) -> [JSONValue] { root[key]?.array ?? [] }
    static func names(_ key: String) -> [String] { cases(key).map { $0["name"]?.string ?? "" } }
    static func item(_ key: String, _ name: String) throws -> JSONValue {
        try #require(cases(key).first { $0["name"]?.string == name })
    }

    static func bytes(_ value: JSONValue?) -> [UInt8] {
        Array(Data(base64Encoded: value?.string ?? "") ?? Data())
    }

    /// A map as GamGUI's test built it: its fields and words exactly, never through `init(json:)` (which would turn an
    /// empty word list into the default, as `from_json` does, where a test built one empty on purpose).
    static func map(_ value: JSONValue?) -> RosterColumnMap {
        var map = RosterColumnMap()
        for field in RosterColumnMap.Field.allCases { map[field] = value?[field.rawValue]?.string ?? "" }
        map.teacherWords = (value?["teacher_words"]?.array ?? []).compactMap(\.string)
        map.studentWords = (value?["student_words"]?.array ?? []).compactMap(\.string)
        return map
    }

    static func strings(_ value: JSONValue?) -> [String] { (value?.array ?? []).compactMap(\.string) }

    @Test func theFixtureIsThere() {
        #expect(Self.cases("read_clever").count >= 20)
        #expect(Self.cases("read_mapped").count >= 10)
        #expect(Self.cases("problem").count >= 20)
        for key in ["guess", "from_json", "preview", "header_of", "typed_words", "name_problem"] {
            #expect(!Self.cases(key).isEmpty, "\(key)")
        }
    }

    /// The refusal's words or the snapshot, as the fixture keeps them.
    static func check(_ name: String, _ result: Result<RosterSnapshot, Roster.Refusal>, _ expect: JSONValue?) {
        if let error = expect?["error"]?.string {
            guard case .package(let words) = result.refusal else { Issue.record("\(name): \(result) vs \(error)"); return }
            #expect(JSONValue.string(words) == .string(error), "\(name): \(words) vs \(error)")
            return
        }
        guard let expected = expect?["snapshot"]?.object else { Issue.record("\(name): no expectation"); return }
        guard case .success(let snapshot) = result else {
            Issue.record("\(name): refused, \(result.refusal?.message ?? "")")
            return
        }
        let got = RosterParityTests.form(snapshot)
        for key in expected.keys.sorted() {
            #expect(got[key] == expected[key], "\(name) \(key): \(String(describing: got[key])) vs \(String(describing: expected[key]))")
        }
    }

    // MARK: Clever

    @Test(arguments: names("read_clever"))
    func readsCleverAsGamGUIReadsIt(_ name: String) throws {
        let item = try Self.item("read_clever", name)
        var files: [String: [UInt8]] = [:]
        for pair in item["files"]?.array ?? [] { files[pair.array?[0].string ?? ""] = Self.bytes(pair.array?[1]) }
        let result = Result { () throws(Roster.Refusal) in
            do { return try RosterClever.read(&files, caps: .standard) } catch let error as PackageError { throw .package(error.message) } catch {
                throw .package("\(error)")
            }
        }
        Self.check(name, result, item["expect"])
        // Each file is taken out as it's read: what GamGUI left, this leaves.
        #expect(Set(files.keys) == Set(Self.strings(item["left"])), "\(name)")
    }

    /// The shared fixture (`Tests/Fixtures/roster/clever`, GamGUI's own files byte for byte) is what GamGUI's whole-snapshot
    /// test read, and reads, picked as a folder, into that snapshot: no password, guardian contact or birth date in it.
    @Test func theSharedCleverFixtureReadsAsGamGUIsTestReadsIt() throws {
        let folder = Fixtures.directory.appending(path: "roster/clever")
        let item = try Self.item("read_clever", "test_roster_clever.test_the_fixture_reads_into_this_whole_snapshot #1")
        let recorded = Dictionary(uniqueKeysWithValues: (item["files"]?.array ?? []).map {
            ($0.array?[0].string ?? "", Self.bytes($0.array?[1]))
        })
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == recorded.keys.sorted())
        for name in names { #expect(Array(try Data(contentsOf: folder.appending(path: name))) == recorded[name], "\(name)") }
        let picked = try RosterImport.readPicked([folder])
        let result = Result { () throws(Roster.Refusal) in try Roster.read(picked) }
        Self.check("the shared fixture", result, item["expect"])
        let snapshot = try result.get()
        let text = String(describing: snapshot)
        for secret in ["CleverTeacherPw", "CleverStudentPw", "alee", "home.example.com", "04/02/2011", "Mia Ng", "555-01"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }

    // MARK: the column map

    @Test(arguments: names("guess"))
    func guessesAsGamGUIGuesses(_ name: String) throws {
        let item = try Self.item("guess", name)
        let got = RosterColumnMap.guess(Self.strings(item["header"]))
        #expect(JSONValue.object(got.json) == item["expect"], "\(name)")
    }

    @Test(arguments: names("problem"))
    func saysTheMapsProblemInGamGUIsWords(_ name: String) throws {
        let item = try Self.item("problem", name)
        let got = Self.map(item["map"]).problem(Self.strings(item["header"]))
        #expect(JSONValue.string(got) == item["expect"], "\(name): \(got)")
    }

    @Test(arguments: names("from_json"))
    func readsAStoredMapAsGamGUIReadsIt(_ name: String) throws {
        let item = try Self.item("from_json", name)
        let got = RosterColumnMap(json: item["json"])
        #expect(JSONValue.object(got.json) == item["expect"], "\(name)")
    }

    @Test(arguments: names("preview"))
    func previewsAsGamGUIPreviews(_ name: String) throws {
        let item = try Self.item("preview", name)
        let result = Result { () throws(Roster.Refusal) in
            try RosterMapped.preview(name: item["file"]?.string ?? "", bytes: Self.bytes(item["body"]), map: Self.map(item["map"]),
                                     count: item["n"]?.int ?? 3)
        }
        if let error = item["expect"]?["error"]?.string {
            guard case .package(let words) = result.refusal else { Issue.record("\(name): \(result) vs \(error)"); return }
            #expect(JSONValue.string(words) == .string(error), "\(name)")
            return
        }
        let rows = try result.get()
        let expected = item["expect"]?["rows"]?.array ?? []
        #expect(rows.count == expected.count, "\(name)")
        for (row, want) in zip(rows, expected) {
            var got = JSONObject()
            for field in RosterColumnMap.Field.allCases { got[field.rawValue] = .string(row[field]) }
            got["as"] = .string(row.readAs)
            #expect(JSONValue.object(got) == want, "\(name): \(got) vs \(want)")
        }
    }

    @Test(arguments: names("read_mapped"))
    func readsASpreadsheetAsGamGUIReadsIt(_ name: String) throws {
        let item = try Self.item("read_mapped", name)
        let result = Result { () throws(Roster.Refusal) in
            try RosterMapped.read(name: item["file"]?.string ?? "", bytes: Self.bytes(item["body"]), map: Self.map(item["map"]))
        }
        Self.check(name, result, item["expect"])
    }

    @Test(arguments: names("header_of"))
    func readsTheHeaderAsGamGUIReadsIt(_ name: String) throws {
        let item = try Self.item("header_of", name)
        let result = Result { () throws(Roster.Refusal) in
            try RosterMapped.header(name: item["file"]?.string ?? "", bytes: Self.bytes(item["body"]))
        }
        if let error = item["expect"]?["error"]?.string {
            guard case .package(let words) = result.refusal else { Issue.record("\(name): \(result) vs \(error)"); return }
            #expect(JSONValue.string(words) == .string(error), "\(name): \(words)")
        } else {
            #expect(JSONValue.array(try result.get().map(JSONValue.string)) == item["expect"]?["header"], "\(name)")
        }
    }

    @Test func readsTypedRoleWordsAsTheFormDoes() {
        for item in Self.cases("typed_words") {
            let typed = item["typed"]?.string ?? ""
            let got = RosterColumnMap.words(typed: typed, default: ["teacher"])
            #expect(JSONValue.array(got.map(JSONValue.string)) == item["expect"], "\(typed)")
        }
    }

    @Test func refusesAMapNameAsGamGUIDoes() {
        for item in Self.cases("name_problem") {
            let name = item["name"]?.string ?? ""
            let got = RosterMapStore.nameProblem(name) ?? ""
            #expect(JSONValue.string(got) == item["expect"], "\(name.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }
}
