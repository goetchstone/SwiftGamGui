import Foundation

/// A Builder read's output as the screen shows it (GamGUI's `_render_read`): a table when GAM printed one (JSON, or CSV: a first
/// line holding a comma) and it reads as records, else the text as GAM printed it (an `info` or a `show` is words, which a table
/// would garble). Every row is kept: the filter and the CSV cover the whole result, never only the rows drawn (GamGUI plan U1:
/// a filter over the first hundred once hid row 181). Bounded by the runner's output cap (invariant 9).
public struct CatalogResult: Sendable, Equatable {
    public let argv: [String]
    /// Every column any row has, the first row's first (GamGUI's `_columns_and_texts`).
    public let columns: [String]
    public let rows: [GamOutput.Record]
    /// GAM's output, when it isn't a table.
    public let text: String
    /// Each row's text to filter on, lowercased: what the table shows, and a structured value's raw form too (GamGUI's
    /// `_filter_text`), so a search finds what's on screen and still matches a field's name.
    private let searchable: [String]

    public init(argv: [String], stdout: String) {
        self.argv = argv
        let text = PythonText.strip(stdout)
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let tabular = text.hasPrefix("[") || text.hasPrefix("{") || first.contains(",")
        let rows = tabular ? GamOutput.records(stdout) : []
        var seen: Set<String> = [], columns: [String] = []
        for row in rows {
            for key in row.keys where seen.insert(key).inserted { columns.append(key) }
        }
        self.rows = rows
        self.columns = columns
        self.text = rows.isEmpty ? stdout : ""
        searchable = rows.map { row in
            columns.map { column in
                guard let value = row[column] else { return "" }
                let shown = Self.cell(value)
                if case .string = value { return shown }
                return value.pythonText == shown ? shown : "\(shown)\t\(value.pythonText)"
            }.joined(separator: "\n").lowercased()
        }
    }

    public var isTable: Bool { !rows.isEmpty }

    /// A value as a person reads it (GamGUI's `cell`): a list joined with ", ", a name as the name (`fullName`, else the given and
    /// family names), any other object "key: value · key: value", nothing for none.
    public static func cell(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: return ""
        case .array(let values)?: return values.map { cell($0) }.joined(separator: ", ")
        case .object(let fields)?:
            if let full = fields["fullName"], !cell(full).isEmpty, full != .bool(false) { return full.pythonText }
            let names = ["givenName", "familyName"].compactMap { fields[$0] }.filter { !cell($0).isEmpty && $0 != .bool(false) }
            if !names.isEmpty { return names.map(\.pythonText).joined(separator: " ") }
            return fields.map { "\($0.key): \(cell($0.value))" }.joined(separator: " · ")
        case let value?: return value.pythonText
        }
    }

    /// The rows whose text holds `text`, case aside (every row for none), by index: the filter covers the whole result.
    public func matching(_ text: String) -> [Int] {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return wanted.isEmpty ? Array(rows.indices) : rows.indices.filter { searchable[$0].contains(wanted) }
    }

    /// `rows` as a CSV's rows, the header first, each value as GamGUI's export writes it (its text; a structured value as JSON),
    /// for `AuditExport.csv`, which makes each cell safe from a spreadsheet reading it as a formula.
    public func csv(_ rows: [Int]) -> [[String]] {
        [columns] + rows.map { index in columns.map { self.rows[index][$0].map { $0 == .null ? "" : $0.pythonText } ?? "" } }
    }
}
