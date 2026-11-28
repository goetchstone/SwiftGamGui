import Foundation

/// Step-to-step dataflow in a Builder sequence (roadmap 5.2, GamGUI's `core/sequence_binds.py`): a later step's field takes
/// its values from an earlier read. The operator types `=step1.primaryEmail` in a field: that step runs once for each value
/// in the `primaryEmail` column of step 1's result. Invariant 2 says a confirm runs what its preview held, and a value a write
/// would produce doesn't exist until it runs, so:
///
/// - **Only reads bind.** Step N is an earlier step whose command only reads, with no bindings of its own.
/// - **One source a step.** Every bound field of a step names the same step; its values are taken row by row.
/// - **Bound reads run at the preview**, and the filled-in steps, one per distinct row (first seen first), are what the
///   preview shows, holds, runs and exports. Each is built by its command's own builder, so each value is checked as typed.
/// - **A read that fell short is unknown, never none** (invariant 10): a failed read, output that isn't a table, or a row
///   without the column (or with it empty) blocks the preview. A read with no rows fills the step in for no one, said aloud.
/// - **Bounded:** at most `maxResolvedSteps` steps once filled in.
///
/// GamGUI's syntax, rules and wording.
public enum SequenceBinds {
    public static let maxResolvedSteps = 500

    /// `(step number, column)` for a `=stepN.Column` value, else nil: anything else is the value itself.
    public static func parse(_ value: String) -> (step: Int, column: String)? {
        let text = PythonText.strip(value)
        guard text.hasPrefix("=step") else { return nil }
        let rest = text.dropFirst("=step".count)
        let digits = rest.prefix { ("0"..."9").contains($0) }
        guard (1...3).contains(digits.count), let number = Int(digits) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard after.first == "." else { return nil }
        let column = String(after.dropFirst())
        // `\S(?:.*\S)?`: no whitespace at either end, and at least one character.
        guard let first = column.unicodeScalars.first, let last = column.unicodeScalars.last,
              !PythonText.whitespace.contains(first.value), !PythonText.whitespace.contains(last.value),
              !column.unicodeScalars.contains(where: { $0 == "\n" }) else { return nil }
        return (number, column)
    }

    /// GamGUI's `_cell`: a value as one string, stripped; a list or record isn't one value, so it reads as empty.
    static func cell(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: ""
        case .string(let text)?: PythonText.strip(text)
        case .number(let text)?: PythonText.strip(text)
        case .bool(let flag)?: flag ? "True" : "False"
        case .array?, .object?: ""
        }
    }

    /// GamGUI's `values_from`: the distinct value tuples (one per row, first seen first) of `columns` in a read's `records`, or
    /// a refusal in fixed words when the read can't say who the step runs for. `records` nil is output that wasn't a table.
    public static func values(from records: [GamOutput.Record]?, columns: [String], source: Int, step: Int)
        -> Result<[[String]], Refusal> {
        guard let records else {
            return .failure(Refusal("Step \(source)'s read didn't print a table, so who step \(step) runs for isn't known. Nothing will run."))
        }
        var seen: [[String]] = [], known: Set<[String]> = []
        for row in records {
            let values = columns.map { cell(row[$0]) }
            if let missing = zip(columns, values).first(where: { $0.1.isEmpty })?.0 {
                let all = Set(records.flatMap { $0.map(\.key) }).sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
                return .failure(Refusal("Step \(source)'s result has a row with no \(missing), so who step \(step) runs for isn't "
                                        + "known. Nothing will run. (Its columns: \(all.prefix(12).joined(separator: ", ")).)"))
            }
            if known.insert(values).inserted { seen.append(values) }
        }
        return .success(seen)
    }

    public struct Refusal: Error, Sendable, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// GamGUI's `_TOO_MANY`.
    public static let tooMany = "That's more than \(maxResolvedSteps) steps once the reads' rows are filled in. For that many people "
        + "at once, use a CSV on Users."
}
