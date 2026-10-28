import Foundation
import Testing
@testable import GamEngine

/// A Builder read's output as the screen shows it (GamGUI's `_render_read`, `cell`, `_columns_and_texts`, the CSV export): a table
/// when GAM printed one, else its words; every column any row has; a filter over every row, finding what's shown and a field's
/// raw form; and a CSV of the rows kept.
@Suite("Catalog result")
struct CatalogResultTests {
    /// GAM's CSV and JSON read as tables, the columns in the order first seen (ragged rows too); an `info` or a `show`, which is
    /// words, as the text.
    @Test func aTableWhenGamPrintsOne() {
        let csv = CatalogResult(argv: ["print", "users"], stdout: "primaryEmail,suspended\nalice@example.com,False\nbob@example.com,True\n")
        #expect(csv.isTable && csv.columns == ["primaryEmail", "suspended"] && csv.rows.count == 2 && csv.text.isEmpty)
        let json = CatalogResult(argv: [], stdout: #"[{"email": "a@x.example", "name": {"fullName": "Alice Anders"}}, {"email": "b@x.example", "aliases": ["b1", "b2"]}]"#)
        #expect(json.columns == ["email", "name", "aliases"])
        let info = CatalogResult(argv: ["info", "user", "alice@example.com"], stdout: "User: alice@example.com\n  Full Name: Alice Anders\n")
        #expect(!info.isTable && info.text.hasPrefix("User: alice@example.com") && info.columns.isEmpty)
        #expect(!CatalogResult(argv: [], stdout: "").isTable)
    }

    /// GamGUI's `cell`: a list joined, a name as the name, any other object as "key: value", nothing for none.
    @Test func aValueAsAPersonReadsIt() {
        #expect(CatalogResult.cell(.array([.string("b1"), .string("b2")])) == "b1, b2")
        #expect(CatalogResult.cell(.object(["fullName": .string("Alice Anders"), "givenName": .string("Alice")])) == "Alice Anders")
        #expect(CatalogResult.cell(.object(["givenName": .string("Alice"), "familyName": .string("Anders")])) == "Alice Anders")
        #expect(CatalogResult.cell(.object(["type": .string("work"), "primary": .bool(true)])) == "type: work · primary: True")
        #expect(CatalogResult.cell(nil) == "" && CatalogResult.cell(.null) == "" && CatalogResult.cell(.number("3")) == "3")
    }

    /// The filter covers every row (GamGUI plan U1: a filter over the first hundred once hid row 181), finding what's on screen and
    /// a structured value's raw form; the CSV is the rows kept, each value its text, a structured one as JSON.
    @Test func theFilterCoversEveryRowAndTheCSVTakesIt() {
        let rows = (1...250).map { "user\($0)@example.com,\($0 == 181 ? "outside@vendor.example" : "")" }
        let result = CatalogResult(argv: [], stdout: "email,sharedWith\n" + rows.joined(separator: "\n"))
        #expect(result.matching("VENDOR") == [180] && result.matching("").count == 250)
        #expect(result.csv([180]) == [["email", "sharedWith"], ["user181@example.com", "outside@vendor.example"]])
        let named = CatalogResult(argv: [], stdout: #"[{"name": {"fullName": "Alice Anders"}, "aliases": ["a@x.example"]}]"#)
        #expect(named.matching("alice anders") == [0] && named.matching("fullname") == [0], "shown, and the field's raw form")
        #expect(named.csv([0])[1] == [#"{"fullName": "Alice Anders"}"#, #"["a@x.example"]"#])
    }
}
