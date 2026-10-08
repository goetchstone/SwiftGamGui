import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// GamGUI parity for reading GAM's output (invariant 11): every case in `Tests/Fixtures/gam_output.json`,
/// generated from frozen GamGUI's `parse_records`, gives the same records. Strings compare as bytes,
/// numbers by value (Python reads `1E2` as 100.0 and writes it back as `100.0`).
@Suite("GAM output")
struct GamOutputTests {
    struct Case: Decodable {
        let stdout: String
        let records: String
    }

    struct Document: Decodable {
        let cases: [Case]
    }

    let document = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.gamOutputJSON))

    static func same(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number, .number):
            let (x, y) = (a.double!, b.double!)
            return x == y || (x.isNaN && y.isNaN)
        case (.string(let x), .string(let y)): return x.utf8.elementsEqual(y.utf8)
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy(same)
        case (.object(let x), .object(let y)):
            let keys = { (o: JSONObject) in Set(o.keys.map { Array($0.utf8) }) }
            return keys(x) == keys(y) && x.allSatisfy { member in y[member.key].map { same(member.value, $0) } ?? false }
        default: return false
        }
    }

    @Test func everyCaseReadsAsGamGUIReadsIt() throws {
        var deeper = 0
        for item in document.cases {
            let actual = JSONValue.array(GamOutput.records(item.stdout).map(JSONValue.object))
            guard let expected = JSONValue.parse(item.records) else {
                // The one deliberate difference: GamGUI's records nest past `maximumDepth`, which this
                // refuses, so the text reads as CSV with no rows.
                #expect(actual == .array([]), "\(item.stdout.prefix(80).debugDescription)")
                deeper += 1
                continue
            }
            #expect(Self.same(actual, expected), "\(item.stdout.prefix(160).debugDescription)")
        }
        #expect(deeper <= 1)
        #expect(document.cases.count > 500)
    }

    @Test func jsonReadsAsPythonDoes() throws {
        #expect(JSONValue.parse(#"{"a": 1, "a": 2}"#) == .object(["a": .number("2")]), "the last duplicate wins")
        let twoKeys = try #require(JSONValue.parse("{\"\u{E9}\": 1, \"e\u{301}\": 2}")?.object)
        #expect(twoKeys.count == 2, "keys equal only by canonical equivalence stay two, as in Python")
        #expect(JSONValue.parse("[" + String(repeating: "1", count: 4300) + "]") != nil)
        #expect(JSONValue.parse("[" + String(repeating: "1", count: 4301) + "]") == nil, "Python's digit limit")
        #expect(JSONValue.parse("[" + String(repeating: "1", count: 4301) + ".5]") != nil, "a float has none")
        #expect(JSONValue.parse("[NaN, -Infinity, 12345678901234567890123]")
                == .array([.number("NaN"), .number("-Infinity"), .number("12345678901234567890123")]))
        #expect(JSONValue.parse(#""😀\ud800""#) == .string("\u{1F600}\u{FFFD}"))
        for refused in ["{\"a\": 1,}", "[1,]", "\"tab\there\"", "01", "1.", "-", "nul", "\u{FEFF}{}", "{} {}", ""] {
            #expect(JSONValue.parse(refused) == nil, "\(refused.debugDescription)")
        }
        let deep = String(repeating: "[", count: JSONValue.maximumDepth) + String(repeating: "]", count: JSONValue.maximumDepth)
        #expect(JSONValue.parse(deep) != nil)
        #expect(JSONValue.parse("[" + deep + "]") == nil, "past the depth limit")
    }

    /// At the depth limit, parsing, comparing and freeing fit a secondary thread's stack in a debug
    /// build: at about 470, one overflowed (PR #7's review).
    @Test func theDeepestAcceptedValueFitsAThreadStack() async {
        let depth = JSONValue.maximumDepth
        let text = String(repeating: #"{"a":"#, count: depth - 1) + "[]" + String(repeating: "}", count: depth - 1)
        let survived = await Task.detached {
            guard let value = JSONValue.parse(text), let copy = JSONValue.parse(text) else { return false }
            return value == copy
        }.value
        #expect(survived)
    }

    @Test func csvReadsAsPythonsReaderDoes() {
        #expect(CSVReader.records("a,b\r\n\"x,\"\"y\"\"\nz\",2\r\n\n3") == [["a", "b"], ["x,\"y\"\nz", "2"], [], ["3"]])
        #expect(CSVReader.records("a\"b,\"c\"d,\"unterminated") == [["a\"b", "cd", "unterminated"]])
        #expect(CSVReader.records("x\ry") == [["x"], ["y"]])
    }
}
