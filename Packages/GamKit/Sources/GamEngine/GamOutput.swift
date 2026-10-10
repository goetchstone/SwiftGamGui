/// GAM's output read into records, as GamGUI's `core/gam/parser.py` reads it. GAM prints, depending on
/// the command: one JSON value (`info user … formatjson`), newline-delimited JSON, a CSV whose `JSON`
/// column holds each record (`print … formatjson`), or plain CSV. Held to
/// `Tests/Fixtures/gam_output.json` (GamGUI's `parse_records` over the mock's output for every read and
/// its property tests' shapes) by `GamOutputTests`. One deliberate difference: GAM escapes its CSV with a
/// backslash, which GamGUI's reader doesn't know (see `CSVReader`); the fixture lists where they differ.
public enum GamOutput {
    public typealias Record = JSONObject

    /// Never fails on shape: text that is none of the above reads as CSV, and empty text as no records.
    public static func records(_ stdout: String) -> [Record] {
        let text = PythonText.strip(stdout)
        guard !text.isEmpty else { return [] }
        if let value = json(text) { return records(in: value) }
        // Newline-delimited JSON, when the first non-blank line is JSON. Split on "\n" only: a name
        // holding U+2028 (left raw by GAM's JSON) once became a bogus record (GamGUI failure-log
        // 2026-09-30).
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map(PythonText.string).filter { !PythonText.strip($0).isEmpty }
        if let first = lines.first, json(first) != nil {
            var found: [Record] = []
            for line in lines {
                guard let value = json(line) else { return csvRecords(text) }
                found += records(in: value)
            }
            return found
        }
        return csvRecords(text)
    }

    /// The first record, or none.
    public static func one(_ stdout: String) -> Record {
        records(stdout).first ?? [:]
    }

    /// GamGUI's `_try_json`, whose `None` also stands for JSON's `null`: a `null` is "not JSON" there.
    static func json(_ text: String) -> JSONValue? {
        guard let value = JSONValue.parse(text), value != .null else { return nil }
        return value
    }

    static func records(in value: JSONValue) -> [Record] {
        switch value {
        case .object(let record): [record]
        case .array(let values): values.compactMap(\.object)
        default: []
        }
    }

    /// `csv.DictReader` over the text. With a `JSON` column, each row's JSON is the record, with the
    /// row's other non-blank columns beside it (for multi-entity output they name the owning user or
    /// key, which the JSON often omits); the JSON wins a conflict. Otherwise each row is a record of
    /// strings, and a column the row stops short of is `null`, as DictReader's `restval`.
    static func csvRecords(_ text: String) -> [Record] {
        var table = CSVReader.records(text)
        guard !table.isEmpty else { return [] }
        let header = table.removeFirst()
        let rows = table.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return [] }
        // dict(zip(header, row)) and then restval for the header past the row leaves each distinct
        // column (by exact text) holding the cell at its LAST position in the header, or null when the
        // row stops before that position. Computed once per column, not once per header cell per row:
        // a wide header of repeated names once took 13 GB (PR #7's review).
        var columns: [(key: String, last: Int)] = [], seen: [[UInt8]: Int] = [:]
        for (position, key) in header.enumerated() {
            if let slot = seen[Array(key.utf8)] {
                columns[slot].last = position
            } else {
                seen[Array(key.utf8)] = columns.count
                columns.append((key, position))
            }
        }
        func cell(_ column: (key: String, last: Int), in row: [String]) -> String? {
            column.last < row.count ? row[column.last] : nil
        }
        if let json = columns.first(where: { $0.key.utf8.elementsEqual("JSON".utf8) }) {
            let siblings = columns.filter { !$0.key.utf8.elementsEqual("JSON".utf8) }
            return rows.flatMap { row -> [Record] in
                guard let value = self.json(cell(json, in: row) ?? "") else { return [] }
                var known = Record()
                for column in siblings {
                    if let text = cell(column, in: row), !text.isEmpty { known[column.key] = .string(text) }
                }
                return records(in: value).map { known.merging($0) }
            }
        }
        return rows.map { row in
            var record = Record()
            for column in columns { record[column.key] = cell(column, in: row).map(JSONValue.string) ?? .null }
            return record
        }
    }
}

/// Python's `csv.reader` in GAM's dialect over `io.StringIO(text, newline="")`: comma, double quote,
/// quotes doubled, a backslash escaping the next character, not strict. GAM 7.48.22 writes every CSV so
/// (`gam/__init__.py:8830-8839`; `csv_output_no_escape_char` is off by default): each backslash in a
/// value doubled, a value with a comma, quote, CR or LF quoted. A reader without the escape character,
/// GamGUI's included, drops a JSON cell holding `\"`, doubles each backslash and reads an escaped newline
/// as "\n" (failure-log 2026-10-10, "GAM's CSV escapes"). Lines end at "\n", "\r" or "\r\n", a quoted
/// field may span them, a stray quote inside an unquoted field is data, and text after a closing quote
/// joins the field. Never fails: an unterminated quote or a final escape ends with the input.
///
/// A literal port of CPython 3.14.6's `Modules/_csv.c` reader (`parse_process_char`, `Reader_iternext`),
/// state for state.
enum CSVReader {
    private enum State {
        case startRecord, startField, escapedChar, afterEscapedCRNL, inField, inQuotedField, escapeInQuotedField
        case quoteInQuotedField, eatCRNL
    }

    /// Every record, a blank line as `[]`.
    static func records(_ text: String) -> [[String]] {
        var records: [[String]] = [], fields: [String] = [], field = String.UnicodeScalarView()
        var state = State.startRecord

        func save() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
        }

        /// One character, or nil for the end of a line (`_csv.c`'s EOL).
        func process(_ scalar: Unicode.Scalar?) {
            let isBreak = scalar == "\n" || scalar == "\r"
            switch state {
            case .startRecord:
                if scalar == nil { return }
                if isBreak { state = .eatCRNL; return }
                state = .startField
                process(scalar)
            case .startField:
                if isBreak || scalar == nil {
                    save()
                    state = scalar == nil ? .startRecord : .eatCRNL
                } else if scalar == "\"" {
                    state = .inQuotedField
                } else if scalar == "\\" {
                    state = .escapedChar
                } else if scalar == "," {
                    save()
                } else {
                    field.append(scalar!)
                    state = .inField
                }
            case .escapedChar:
                // An escaped CR or LF is data, and the line it ends doesn't end the record.
                if isBreak {
                    field.append(scalar!)
                    state = .afterEscapedCRNL
                } else {
                    field.append(scalar ?? "\n")
                    state = .inField
                }
            case .afterEscapedCRNL, .inField:
                // As in C: AFTER_ESCAPED_CRNL ignores the line's end, and otherwise follows IN_FIELD without
                // leaving its own state for a plain character.
                if state == .afterEscapedCRNL && scalar == nil { return }
                if isBreak || scalar == nil {
                    save()
                    state = scalar == nil ? .startRecord : .eatCRNL
                } else if scalar == "\\" {
                    state = .escapedChar
                } else if scalar == "," {
                    save()
                    state = .startField
                } else {
                    field.append(scalar!)
                }
            case .inQuotedField:
                if let scalar {
                    if scalar == "\\" {
                        state = .escapeInQuotedField
                    } else if scalar == "\"" {
                        state = .quoteInQuotedField
                    } else {
                        field.append(scalar)
                    }
                }
            case .escapeInQuotedField:
                field.append(scalar ?? "\n")
                state = .inQuotedField
            case .quoteInQuotedField:
                // No escape after a closing quote: C looks for one only inside quotes and in a bare field.
                if scalar == "\"" {
                    field.append("\"")
                    state = .inQuotedField
                } else if scalar == "," {
                    save()
                    state = .startField
                } else if isBreak || scalar == nil {
                    save()
                    state = scalar == nil ? .startRecord : .eatCRNL
                } else {
                    field.append(scalar!)
                    state = .inField
                }
            case .eatCRNL:
                // Only "\n", "\r" or the line's end can follow a break inside one line.
                if scalar == nil { state = .startRecord }
            }
        }

        for line in lines(text) {
            for scalar in line { process(scalar) }
            process(nil)
            if state == .startRecord {
                records.append(fields)
                fields = []
            }
        }
        if state == .inQuotedField || !field.isEmpty {
            save()
            records.append(fields)
        }
        return records
    }

    /// `io.StringIO(text, newline="")`'s lines, each with its line ending.
    private static func lines(_ text: String) -> [ArraySlice<Unicode.Scalar>] {
        let scalars = Array(text.unicodeScalars)
        var lines: [ArraySlice<Unicode.Scalar>] = [], start = 0, index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar == "\n" || (scalar == "\r" && (index == scalars.count || scalars[index] != "\n")) {
                lines.append(scalars[start..<index])
                start = index
            }
        }
        if start < scalars.count { lines.append(scalars[start...]) }
        return lines
    }
}
