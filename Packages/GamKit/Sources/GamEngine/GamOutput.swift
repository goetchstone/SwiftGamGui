/// GAM's output read into records, as GamGUI's `core/gam/parser.py` reads it. GAM prints, depending on
/// the command: one JSON value (`info user … formatjson`), newline-delimited JSON, a CSV whose `JSON`
/// column holds each record (`print … formatjson`), or plain CSV. Held to
/// `Tests/Fixtures/gam_output.json` (GamGUI's `parse_records` over the mock's output for every read and
/// its property tests' shapes) by `GamOutputTests`.
public enum GamOutput {
    public typealias Record = [String: JSONValue]

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
        let rows: [[(key: String, value: String?)]] = table.filter { !$0.isEmpty }.map { row in
            // dict(zip(fieldnames, row)), then restval for the fieldnames past the row. Fields past
            // the header go under DictReader's None key, which GamGUI drops.
            var pairs = zip(header, row).map { (key: $0, value: Optional($1)) }
            pairs += header.dropFirst(row.count).map { (key: $0, value: nil) }
            return pairs
        }
        guard !rows.isEmpty else { return [] }
        if header.contains(where: { $0.utf8.elementsEqual("JSON".utf8) }) {
            return rows.flatMap { row -> [Record] in
                let cell = lastValue(of: "JSON", in: row) ?? nil
                guard let value = json(cell ?? "") else { return [] }
                var siblings: Record = [:]
                for (key, value) in row where !key.utf8.elementsEqual("JSON".utf8) {
                    siblings[key] = nil
                    if let value, !value.isEmpty { siblings[key] = .string(value) }
                }
                return records(in: value).map { siblings.merging($0) { _, json in json } }
            }
        }
        return rows.map { row in
            var record: Record = [:]
            for (key, value) in row { record[key] = value.map(JSONValue.string) ?? .null }
            return record
        }
    }

    /// The value a dict built from `pairs` holds for `key`: the last pair's.
    private static func lastValue(of key: String, in pairs: [(key: String, value: String?)]) -> String?? {
        pairs.last { $0.key.utf8.elementsEqual(key.utf8) }.map(\.value)
    }
}

/// Python's `csv.reader` in its default dialect (comma, double quote, quotes doubled, not strict) over
/// `io.StringIO(text, newline="")`: lines end at "\n", "\r" or "\r\n", a quoted field may span them,
/// a stray quote inside an unquoted field is data, and text after a closing quote joins the field.
/// Never fails: an unterminated quote ends with the input.
enum CSVReader {
    private enum State { case startRecord, startField, inField, inQuotedField, quoteInQuotedField, eatCRNL }

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
                } else if scalar == "," {
                    save()
                } else {
                    field.append(scalar!)
                    state = .inField
                }
            case .inField:
                if isBreak || scalar == nil {
                    save()
                    state = scalar == nil ? .startRecord : .eatCRNL
                } else if scalar == "," {
                    save()
                    state = .startField
                } else {
                    field.append(scalar!)
                }
            case .inQuotedField:
                if let scalar {
                    if scalar == "\"" { state = .quoteInQuotedField } else { field.append(scalar) }
                }
            case .quoteInQuotedField:
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
