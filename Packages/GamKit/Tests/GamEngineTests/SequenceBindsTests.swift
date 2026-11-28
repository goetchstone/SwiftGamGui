import Foundation
@testable import GamEngine
import Testing

/// Roadmap 5.2's pure part: GamGUI's `tests/test_sequence_binds.py` cases for `parse_bind` and `values_from`, in its words.
@Suite("Sequence binds")
struct SequenceBindsTests {
    @Test func onlyTheBindSyntaxBinds() {
        #expect(SequenceBinds.parse("=step1.primaryEmail").map { [String($0.step), $0.column] } == ["1", "primaryEmail"])
        #expect(SequenceBinds.parse(" =step12.name.fullName ").map { [String($0.step), $0.column] } == ["12", "name.fullName"])
        for value in ["=step1.", "step1.primaryEmail", "=stepx.a", "a@example.com", "=)", "=step1234.a", "=step1. a"] {
            #expect(SequenceBinds.parse(value) == nil, "\(value)")
        }
    }

    @Test func valuesAreDistinctRowsFirstSeenFirst() throws {
        let rows: [GamOutput.Record] = [["e": .string("b@x")], ["e": .string("a@x")], ["e": .string("b@x")]]
        #expect(try SequenceBinds.values(from: rows, columns: ["e"], source: 1, step: 2).get() == [["b@x"], ["a@x"]])
    }

    @Test func aReadThatFellShortIsUnknownNeverNone() {
        let cases: [([GamOutput.Record]?, String)] = [
            (nil, "didn't print a table"),
            ([["e": .string("a@x")], ["f": .string("b@x")]], "a row with no e"),
            ([["e": .string("a@x")], ["e": .string("  ")]], "a row with no e"),
            ([["e": .array([.string("a@x"), .string("b@x")])]], "a row with no e"),   // a list isn't one value
        ]
        for (rows, needle) in cases {
            guard case .failure(let refusal) = SequenceBinds.values(from: rows, columns: ["e"], source: 1, step: 2) else {
                Issue.record("\(needle): read as values")
                continue
            }
            #expect(refusal.message.contains(needle) && refusal.message.contains("Nothing will run"), "\(refusal.message)")
        }
    }

    @Test func anEmptyTableIsNoneSaidAloud() throws {
        #expect(try SequenceBinds.values(from: [], columns: ["e"], source: 1, step: 2).get().isEmpty)
    }
}
