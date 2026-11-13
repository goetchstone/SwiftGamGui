import GamEngine

/// A roster file's physical lines, as GamGUI's `_Lines` hands them to Python's csv module: decoded as they're read (strict
/// UTF-8, a leading byte-order mark dropped), never held whole as text, each bounded before the csv reader sees it.
///
/// It works on the bytes. A line ends at "\n", "\r" or "\r\n" (`TextIOWrapper(newline="")`), all ASCII, so never inside a
/// character; lengths are counted in characters, as Python counts a `str`. Decoding is checked in the same 8192-byte
/// chunks `TextIOWrapper` decodes, when `readline` first needs one, so a file whose bad byte lies past an earlier refusal
/// is refused for that earlier one, as GamGUI refuses it.
struct RosterLines {
    let name: String
    let bytes: [UInt8]
    let caps: RosterCaps
    /// The next line's first byte.
    private var position: Int
    /// Bytes handed to the decoder: whole chunks, or everything once the end was read.
    private var fed: Int
    /// The end of the last whole character decoded.
    private var whole: Int
    private var final = false
    /// Characters since the record began (`record_done` starts it again).
    var since = 0
    /// Lines read (`stream_line`).
    private(set) var streamLine = 0

    static let decodeChunk = 8192

    init(name: String, bytes: [UInt8], caps: RosterCaps) {
        self.name = name
        self.bytes = bytes
        self.caps = caps
        let bom = bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
        position = bom ? 3 : 0
        fed = 0
        whole = 0
    }

    /// Where the decoded characters end: `IncrementalNewlineDecoder` holds a trailing "\r" back until it knows whether
    /// "\n" follows.
    private var available: Int {
        !final && whole > 0 && bytes[whole - 1] == 0x0D ? whole - 1 : whole
    }

    private func notUTF8() -> PackageError {
        PackageError("\(name) isn't UTF-8 text. Export the roster as UTF-8 CSV.")
    }

    /// Decode the next chunk, or the end.
    private mutating func feed() throws(PackageError) {
        if fed >= bytes.count {
            if whole < bytes.count { throw notUTF8() }      // a character cut off by the end of the file
            final = true
            return
        }
        fed = min(fed + Self.decodeChunk, bytes.count)
        switch UTF8Check.wholeCharacters(bytes, from: whole, to: fed) {
        case .invalid: throw notUTF8()
        case .through(let end): whole = end
        }
    }

    /// `readline(LINE_CAP + 1)`: a line's bytes and how many characters it holds (a line cut at the limit holds more
    /// than `caps.line`), or nil at the end.
    private mutating func readLine() throws(PackageError) -> (Range<Int>, Int)? {
        let limit = caps.line + 1
        var scan = position, characters = 0
        while true {
            let end = available
            let ended = bytes.withUnsafeBufferPointer { buffer in
                while scan < end {
                    let byte = buffer[scan]
                    if byte == 0x0A || byte == 0x0D {
                        scan += 1
                        characters += 1
                        if byte == 0x0D, scan < end, buffer[scan] == 0x0A {
                            scan += 1
                            characters += 1
                        }
                        return true
                    }
                    if byte & 0xC0 != 0x80 { characters += 1 }
                    scan += 1
                }
                return false
            }
            if ended {
                defer { position = scan }
                return (position..<scan, characters)
            }
            if characters >= limit {
                defer { position = scan }
                return (position..<scan, characters)
            }
            if final {
                guard position < end else { return nil }
                defer { position = end }
                return (position..<end, characters)
            }
            try feed()
        }
    }

    /// `_Lines.__next__`: the next physical line, refused past `LINE_CAP`, with a NUL, or past `LINE_CAP` in its record.
    mutating func next() throws(PackageError) -> Range<Int>? {
        guard let (line, characters) = try readLine() else { return nil }
        if characters > caps.line {
            throw PackageError("\(name) has a line longer than \(caps.line >> 20) MB. That isn't a normal export.")
        }
        if bytes[line].contains(0) {
            // GamGUI refuses a NUL itself, the same on every Python (3.10's csv module refused it, later ones read it).
            throw PackageError("\(name) holds a NUL character on or after line \(streamLine + 1). That isn't a normal "
                               + "export: export the roster again.")
        }
        streamLine += 1
        since += characters
        if since > caps.line {
            throw PackageError("\(name) has a record longer than \(caps.line >> 20) MB. That isn't a normal export.")
        }
        return line
    }

    mutating func recordDone() { since = 0 }
}

/// Strict UTF-8, as CPython's decoder reads it: a chunk's last character may be cut off (it's held for the next), as
/// may a surrogate's first two bytes; any other bad sequence is an error.
enum UTF8Check {
    enum Result: Equatable { case through(Int), invalid }

    /// The end of the last whole character in `bytes[from..<to]`, or `.invalid`.
    static func wholeCharacters(_ bytes: [UInt8], from: Int, to: Int) -> Result {
        var index = from
        while index < to {
            let lead = bytes[index]
            if lead < 0x80 {
                index += 1
                continue
            }
            let length: Int, low: UInt8, high: UInt8
            switch lead {
            case 0xC2...0xDF: (length, low, high) = (2, 0x80, 0xBF)
            case 0xE0: (length, low, high) = (3, 0xA0, 0xBF)
            case 0xE1...0xEC, 0xEE, 0xEF: (length, low, high) = (3, 0x80, 0xBF)
            case 0xED: (length, low, high) = (3, 0x80, 0x9F)
            case 0xF0: (length, low, high) = (4, 0x90, 0xBF)
            case 0xF1...0xF3: (length, low, high) = (4, 0x80, 0xBF)
            case 0xF4: (length, low, high) = (4, 0x80, 0x8F)
            default: return .invalid
            }
            for offset in 1..<length {
                guard index + offset < to else { return .through(index) }       // cut off by the chunk: held
                let byte = bytes[index + offset]
                // A surrogate's first two bytes ending the chunk are held too, though no next byte can make them whole
                // (unicodeobject.c, "Truncated surrogate code in range D800-DFFF"): the next chunk refuses them.
                if lead == 0xED, offset == 1, index + 2 == to, (0xA0...0xBF).contains(byte) { return .through(index) }
                let (min, max) = offset == 1 ? (low, high) : (0x80, 0xBF)
                guard byte >= min, byte <= max else { return .invalid }
            }
            index += length
        }
        return .through(index)
    }

    /// The whole of `bytes` as text, or nil when it isn't strict UTF-8 (a ZIP's names).
    static func decode<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> String? {
        let array = Array(bytes)
        guard wholeCharacters(array, from: 0, to: array.count) == .through(array.count) else { return nil }
        return String(decoding: array, as: UTF8.self)
    }
}

/// An error Python's csv module raises (`csv.Error`), in its words.
struct CSVError: Error {
    let message: String
}

/// One field as read: its bytes (whole UTF-8) and its length in characters.
struct CSVField {
    var bytes: [UInt8] = []
    var characters = 0

    var text: String { String(decoding: bytes, as: UTF8.self) }

    /// `not cell.strip()`.
    var isBlank: Bool {
        if bytes.allSatisfy({ $0 < 0x80 }) { return bytes.allSatisfy { PythonText.whitespace.contains(UInt32($0)) } }
        return text.unicodeScalars.allSatisfy(PythonText.isSpace)
    }
}

/// `csv.reader(lines, strict=True)` in the `excel` dialect (comma, double quote, doubled quotes, no escape), state for
/// state as CPython 3.14's `Modules/_csv.c` reads it, over `RosterLines`. Strict: text after a closing quote, or the end of
/// the input inside quotes, is an error. A field past the module's default limit (131,072 characters) is the module's own
/// error: GamGUI never raises that limit for this reader, and the fixtures are made with it at its default.
struct RosterCSV {
    private enum State { case startRecord, startField, inField, inQuotedField, quoteInQuotedField, eatCRNL }

    static let fieldLimit = 131_072

    var lines: RosterLines
    /// Lines read (`reader.line_num`).
    private(set) var lineNumber = 0
    private var state = State.startRecord
    private var fields: [CSVField] = []
    private var field = CSVField()

    init(_ lines: RosterLines) { self.lines = lines }

    /// The next record, or nil at the end.
    mutating func next() throws -> [CSVField]? {
        fields = []
        field = CSVField()
        state = .startRecord
        repeat {
            guard let line = try lines.next() else {
                if field.characters != 0 || state == .inQuotedField { throw CSVError(message: "unexpected end of data") }
                return nil
            }
            lineNumber += 1
            let bytes = lines.bytes
            try bytes.withUnsafeBufferPointer { buffer in
                var index = line.lowerBound
                while index < line.upperBound {
                    // A run of ordinary bytes inside a field is taken whole: the same as one at a time, faster.
                    if state == .inField || state == .inQuotedField {
                        var end = index, characters = 0
                        if state == .inField {
                            while end < line.upperBound, buffer[end] != 0x2C, buffer[end] != 0x0A, buffer[end] != 0x0D {
                                if buffer[end] & 0xC0 != 0x80 { characters += 1 }
                                end += 1
                            }
                        } else {
                            while end < line.upperBound, buffer[end] != 0x22 {
                                if buffer[end] & 0xC0 != 0x80 { characters += 1 }
                                end += 1
                            }
                        }
                        if end > index {
                            if field.characters + characters > Self.fieldLimit {
                                throw CSVError(message: "field larger than field limit (\(Self.fieldLimit))")
                            }
                            field.characters += characters
                            field.bytes.append(contentsOf: UnsafeBufferPointer(rebasing: buffer[index..<end]))
                            index = end
                            continue
                        }
                    }
                    try process(buffer[index])
                    index += 1
                }
            }
            try processEnd()
        } while state != .startRecord
        return fields
    }

    private mutating func save() {
        fields.append(field)
        field = CSVField()
    }

    private mutating func add(_ byte: UInt8) throws {
        if byte & 0xC0 != 0x80 {
            if field.characters >= Self.fieldLimit {
                throw CSVError(message: "field larger than field limit (\(Self.fieldLimit))")
            }
            field.characters += 1
        }
        field.bytes.append(byte)
    }

    private mutating func process(_ byte: UInt8) throws {
        let isBreak = byte == 0x0A || byte == 0x0D
        switch state {
        case .startRecord:
            if isBreak {
                state = .eatCRNL
                return
            }
            state = .startField
            try process(byte)
        case .startField:
            if isBreak {
                save()
                state = .eatCRNL
            } else if byte == 0x22 {
                state = .inQuotedField
            } else if byte == 0x2C {
                save()
            } else {
                try add(byte)
                state = .inField
            }
        case .inField:
            if isBreak {
                save()
                state = .eatCRNL
            } else if byte == 0x2C {
                save()
                state = .startField
            } else {
                try add(byte)
            }
        case .inQuotedField:
            if byte == 0x22 { state = .quoteInQuotedField } else { try add(byte) }
        case .quoteInQuotedField:
            if byte == 0x22 {
                try add(byte)
                state = .inQuotedField
            } else if byte == 0x2C {
                save()
                state = .startField
            } else if isBreak {
                save()
                state = .eatCRNL
            } else {
                throw CSVError(message: "',' expected after '\"'")
            }
        case .eatCRNL:
            if !isBreak {
                throw CSVError(message: "new-line character seen in unquoted field - do you need to open the file with newline=''?")
            }
        }
    }

    /// The end of a line (`EOL`).
    private mutating func processEnd() throws {
        switch state {
        case .startRecord, .inQuotedField: break
        case .startField, .inField, .quoteInQuotedField:
            save()
            state = .startRecord
        case .eatCRNL:
            state = .startRecord
        }
    }
}

extension Roster {
    /// GamGUI's `_rows`: each row of a roster CSV, as the columns `used` (keyed as `used` spells them), with the line its
    /// record starts on (the header is line 1). A `required` column missing refuses the file with the `layout` sentence;
    /// `foldCase` matches the header ignoring case (Clever's rule). Columns in `raw` (addresses) are kept as given, only
    /// stripped, to be checked whole; every other cell has its control and format characters dropped (`clean`). A row is
    /// built from the used columns alone, so its cost doesn't grow with the header. Bounded: lines, columns, fields, rows.
    static func rows(_ name: String, _ body: [UInt8], required: [String], used: [String], layout: String,
                     raw: Set<String> = ["email"], foldCase: Bool = false, caps: RosterCaps,
                     _ each: (Int, [String: String]) throws -> Void) throws {
        var reader = RosterCSV(RosterLines(name: name, bytes: body, caps: caps))
        do {
            guard let first = try reader.next() else { throw PackageError("\(name) is empty. Export the roster again.") }
            let header = first.map { PythonText.strip($0.text) }
            reader.lines.recordDone()
            if header.count > caps.columns {
                throw PackageError("\(name) has \(grouped(header.count)) columns, more than any roster file has. That isn't a "
                                   + "normal export.")
            }
            let keys = foldCase ? header.map(PythonText.lower) : header
            let exact = keys.map(ExactKey.init)
            var seen: [ExactKey: Int] = [:]
            for key in exact where !key.text.isEmpty { seen[key, default: 0] += 1 }
            if let doubled = seen.filter({ $0.value > 1 }).keys.sorted().first {
                throw PackageError("\(name) has the column \(doubled.text) twice. Export the roster again.")
            }
            let find = { (column: String) in ExactKey(foldCase ? PythonText.lower(column) : column) }
            let missing = required.filter { exact.firstIndex(of: find($0)) == nil }
            if !missing.isEmpty {
                throw PackageError("\(name) is missing the column\(missing.count > 1 ? "s" : "") \(missing.joined(separator: ", ")). "
                                   + layout)
            }
            let wanted = used.compactMap { column in exact.firstIndex(of: find(column)).map { (column, $0) } }
            let width = header.count + 1
            var count = 0
            while true {
                let start = reader.lineNumber + 1
                guard let row = try reader.next() else { return }
                reader.lines.recordDone()
                count += 1
                if count > caps.rows {
                    throw PackageError("\(name) has more than \(grouped(caps.rows)) rows, more than any roster should.")
                }
                if row.count > width {
                    throw PackageError("\(name) line \(start) has \(grouped(row.count)) fields; its header has \(header.count). "
                                       + "Export the roster again.")
                }
                if row.contains(where: { $0.characters > caps.field }) {
                    throw PackageError("\(name) has a field longer than \(caps.field >> 10) KB on line \(start). That isn't a "
                                       + "normal export.")
                }
                if row.allSatisfy(\.isBlank) { continue }
                var cells: [String: String] = [:]
                for (key, index) in wanted {
                    guard index < row.count else {
                        cells[key] = ""
                        continue
                    }
                    let text = row[index].text
                    cells[key] = raw.contains(key) ? strip(text) : clean(text)
                }
                try each(start, cells)
            }
        } catch let error as CSVError {
            throw PackageError("\(name) isn't readable CSV (\(error.message)). Export the roster again.")
        }
    }

    /// GamGUI's `_clean`: a field as kept, with control characters (NUL among them) and invisible format characters
    /// (Unicode's Cf, in Python's Unicode version) dropped, and its ends trimmed.
    static func clean(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return strip(text) }      // printable ASCII: nothing to drop
        func dropped(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value < 32 || scalar.value == 0x7F
                || (scalar.properties.generalCategory == .format && PythonText.knownToPython(scalar))
        }
        guard text.unicodeScalars.contains(where: dropped) else { return PythonText.strip(text) }
        return PythonText.strip(PythonText.string(text.unicodeScalars.filter { !dropped($0) }))
    }

    /// `str.strip()`, quickly for ASCII.
    static func strip(_ text: String) -> String {
        let bytes = text.utf8
        guard bytes.allSatisfy({ $0 < 0x80 }) else { return PythonText.strip(text) }
        let space = { (byte: UInt8) in byte == 0x20 || (0x09...0x0D).contains(byte) || (0x1C...0x1F).contains(byte) }
        guard let first = bytes.firstIndex(where: { !space($0) }), let last = bytes.lastIndex(where: { !space($0) }) else { return "" }
        if first == bytes.startIndex, last == bytes.index(before: bytes.endIndex) { return text }
        return String(text[first...last])
    }

    /// `str.lower()`, quickly for ASCII.
    static func lower(_ text: String) -> String {
        text.utf8.allSatisfy({ $0 < 0x80 }) ? text.lowercased() : PythonText.lower(text)
    }

    /// Python's `f"{n:,}"`.
    static func grouped(_ number: Int) -> String {
        let digits = String(number.magnitude)
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return number < 0 ? "-" + out : out
    }
}

/// Text compared and hashed by its exact characters, as Python compares a `str`: a Swift `String` treats canonically
/// equivalent spellings (é and e + ◌́) as one, which would merge two IDs the export keeps apart.
struct ExactKey: Hashable, Comparable, Sendable {
    let text: String

    init(_ text: String) { self.text = text }

    static func == (lhs: ExactKey, rhs: ExactKey) -> Bool { lhs.text.utf8.elementsEqual(rhs.text.utf8) }

    func hash(into hasher: inout Hasher) {
        var text = text
        text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }

    /// By code point, as Python sorts: UTF-8's byte order is code-point order.
    static func < (lhs: ExactKey, rhs: ExactKey) -> Bool { lhs.text.utf8.lexicographicallyPrecedes(rhs.text.utf8) }
}
