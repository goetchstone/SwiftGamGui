import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// GamGUI parity for reading GAM's output (invariant 11): every case in `Tests/Fixtures/gam_output.json`,
/// generated from frozen GamGUI's `parse_records` reading CSV in GAM's dialect, gives the same records.
/// Strings compare as bytes, numbers by value (Python reads `1E2` as 100.0 and writes it back as `100.0`).
/// Where frozen GamGUI's reader, which lacks GAM's escape character, reads a case differently, the case
/// also holds its records (`gamgui`): the documented deviation, held narrow below.
@Suite("GAM output")
struct GamOutputTests {
    struct Case: Decodable {
        let stdout: String
        let records: String
        let gamgui: String?
    }

    struct Dialect: Decodable {
        let delimiter, quotechar, escapechar, lineterminator, quoting: String
        let doublequote, skipinitialspace, strict: Bool
    }

    struct Document: Decodable {
        let dialect: Dialect
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

    @Test func everyCaseReadsAsGamWritesIt() throws {
        var deeper = 0, deviations = 0
        for item in document.cases {
            let actual = JSONValue.array(GamOutput.records(item.stdout).map(JSONValue.object))
            guard let expected = JSONValue.parse(item.records) else {
                // A deliberate difference: GamGUI's records nest past `maximumDepth`, which this refuses,
                // so the text reads as CSV with no rows.
                #expect(actual == .array([]), "\(item.stdout.prefix(80).debugDescription)")
                deeper += 1
                continue
            }
            #expect(Self.same(actual, expected), "\(item.stdout.prefix(160).debugDescription)")
            guard let gamgui = item.gamgui else { continue }
            // The deviation from frozen GamGUI: only its reader lacks the escape character, so a listed
            // case holds a backslash, reads as CSV, and GamGUI's records really differ.
            deviations += 1
            let csv = JSONValue.array(GamOutput.csvRecords(PythonText.strip(item.stdout)).map(JSONValue.object))
            #expect(item.stdout.unicodeScalars.contains("\\") && Self.same(actual, csv),
                    "\(item.stdout.prefix(160).debugDescription)")
            #expect(!Self.same(try #require(JSONValue.parse(gamgui)), expected))
        }
        #expect(deeper <= 1)
        #expect(deviations > 0 && deviations < document.cases.count / 4)
        #expect(document.cases.count > 500)
    }

    /// The fixture was written in the dialect this reader reads: GAM 7.48.22's, which the generator reads
    /// from the vendored build and refuses to regenerate past if it moves.
    @Test func theFixtureIsInGamsDialect() {
        let dialect = document.dialect
        #expect([dialect.delimiter, dialect.quotechar, dialect.escapechar, dialect.lineterminator, dialect.quoting]
                == [",", "\"", "\\", "\n", "QUOTE_MINIMAL"])
        #expect(dialect.doublequote && !dialect.skipinitialspace && !dialect.strict)
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

    /// The escape character, as CPython 3.14.6's `csv.reader(io.StringIO(text, newline=""),
    /// escapechar="\\")` reads each input (printed by that Python), including inputs GAM's writer never
    /// makes: an escape at the end of the input or of a line, before CR, LF or CRLF, a delimiter or a
    /// quote, and after a closing quote.
    @Test func csvReadsEscapesAsCPythonDoes() {
        let table: [(String, [[String]])] = [
            (#"a\"#, [["a\n"]]), ("a\\\nb\n", [["a\nb"]]), (#""a\"#, [["a\n"]]), (#""a\"b""#, [["a\"b"]]),
            (#"\"x,y"#, [["\"x", "y"]]), (#"a\,b"#, [["a,b"]]), (#""x"\y"#, [["x\\y"]]),
            ("a\\\r\nb", [["a\r"], ["b"]]), ("a\\\rb", [["a\rb"]]), (#"\"#, [["\n"]]), (#"\\"#, [["\\"]]),
            (#""\\""#, [["\\"]]), ("a,\\\n", [["a", "\n"]]), ("\"a\\\nb\"", [["a\nb"]]), ("x\\\r", [["x\r"]]),
            ("\\\n", [["\n"]]), ("\"\\\r\n\"", [["\r\n"]]), ("a\\\\b,\"c\\\\d\"\n", [["a\\b", "c\\d"]]),
            (#""a""b\"c""#, [["a\"b\"c"]]), (#"\a\b"#, [["ab"]]), (",\\,\n", [["", ","]]),
            ("\"\" \\\n", [[" \n"]]), ("a\\\rb,c\nd\n", [["a\rb", "c"], ["d"]]), ("a\\\r\r\nb", [["a\r"], ["b"]]),
        ]
        for (text, expected) in table {
            #expect(Self.bytes(CSVReader.records(text)) == Self.bytes(expected), "\(text.debugDescription)")
        }
    }

    /// `print users … formatjson` as GAM 7.48.22 prints it (bytes from CPython 3.14.6's writer in GAM's
    /// dialect): a quote, a backslash, a newline and non-ASCII in the JSON cell. All four come back whole;
    /// a reader without the escape character dropped the first, doubled the second's backslash and
    /// turned the third's newline into "\n".
    @Test func aFormatjsonListReadsAsGamWroteIt() throws {
        let stdout = #"""
            primaryEmail,JSON
            u0@example.com,"{""name"": {""fullName"": ""Ann \\""Q\\"" Lee""}, ""primaryEmail"": ""u0@example.com""}"
            u1@example.com,"{""name"": {""fullName"": ""C:\\\\dir""}, ""primaryEmail"": ""u1@example.com""}"
            u2@example.com,"{""name"": {""fullName"": ""l1\\nl2""}, ""primaryEmail"": ""u2@example.com""}"
            u3@example.com,"{""name"": {""fullName"": ""Zoë 😀""}, ""primaryEmail"": ""u3@example.com""}"

            """#
        let names = GamOutput.records(stdout).map { $0["name"]?.object?["fullName"]?.string ?? "" }
        #expect(names.map { Array($0.utf8) } == ["Ann \"Q\" Lee", "C:\\dir", "l1\nl2", "Zoë 😀"].map { Array($0.utf8) })
    }

    /// Rows written as GAM writes them read back byte for byte: seeded draws of quotes, backslashes, CR,
    /// LF, commas, tabs, NUL, non-ASCII, combining marks and emoji.
    @Test func csvReadsBackWhatGamsWriterWrote() {
        var random = Seeded(state: 20_261_010), failures: [String] = []
        for _ in 0..<3000 {
            let rows = (0..<Int.random(in: 1...4, using: &random)).map { _ in
                (0..<Int.random(in: 1...4, using: &random)).map { _ in Self.text(&random) }
            }
            let written = rows.map(Self.gamRow).joined()
            if Self.bytes(CSVReader.records(written)) != Self.bytes(rows) { failures.append(written.debugDescription) }
        }
        #expect(failures.isEmpty, "\(failures.count) tables, the first \(failures.first ?? "")")
    }

    /// The same through `GamOutput.records`: a `primaryEmail,JSON` table of seeded records, each JSON cell
    /// written by `JSONSerialization` and then GAM's writer, reads back as the records.
    @Test func formatjsonReadsBackWhatGamWrote() throws {
        var random = Seeded(state: 20_261_011), failures: [String] = []
        for _ in 0..<500 {
            var written = Self.gamRow(["primaryEmail", "JSON"]), expected: [JSONValue] = []
            for number in 0..<Int.random(in: 1...4, using: &random) {
                let record: [String: Any] = ["primaryEmail": "u\(number)@example.com",
                                             "name": ["fullName": Self.text(&random)], "notes": Self.text(&random)]
                let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
                written += Self.gamRow(["u\(number)@example.com", String(decoding: json, as: UTF8.self)])
                expected.append(try #require(JSONValue.parse(String(decoding: json, as: UTF8.self))))
            }
            let read = JSONValue.array(GamOutput.records(written).map(JSONValue.object))
            if !Self.same(read, .array(expected)) { failures.append(written.debugDescription) }
        }
        #expect(failures.isEmpty, "\(failures.count) tables, the first \(failures.first ?? "")")
    }

    static func bytes(_ table: [[String]]) -> [[[UInt8]]] { table.map { $0.map { Array($0.utf8) } } }

    /// A row as GAM writes it: CPython 3.14's `csv.writer` in GAM's dialect (`gam/__init__.py:8830-8839` at
    /// 7.48.22: comma, double quote, quotes doubled, backslash escape, QUOTE_MINIMAL, "\n" on stdout). Every
    /// backslash is escaped; a field holding a comma, quote, CR or LF is quoted; a lone empty field is `""`.
    static func gamRow(_ fields: [String]) -> String {
        guard fields != [""] else { return "\"\"\n" }
        return fields.map { field in
            var cell = String.UnicodeScalarView(), quoted = false
            for scalar in field.unicodeScalars {
                if scalar == "\\" || scalar == "\"" { cell.append(scalar) }
                quoted = quoted || [",", "\"", "\r", "\n"].contains(scalar)
                cell.append(scalar)
            }
            return quoted ? "\"" + String(cell) + "\"" : String(cell)
        }.joined(separator: ",") + "\n"
    }

    /// Text made mostly of what GAM's dialect treats specially.
    static func text(_ random: inout Seeded) -> String {
        let pieces = ["\\", "\"", ",", "\r", "\n", "\r\n", " ", "\t", "\0", "a", "Zoë", "e\u{301}", "😀", "\u{2028}",
                      "\\n", "\"\"", "\\\""]
        return (0..<Int.random(in: 0...8, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
    }

    /// SplitMix64: the same draws on every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }
}
