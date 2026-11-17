import GamEngine

/// Which column of a spreadsheet holds each field, and the role column's words for a teacher and a student (GamGUI's
/// `ColumnMap`, `core/roster_mapped.py` at 07c505d, plan 2026-11-11 C5.3). A column is a header cell's text; "" is not
/// used. A map holds column names and words only, never a row's data, so it is what a saved map keeps (`RosterMapStore`).
public struct RosterColumnMap: Sendable, Equatable {
    /// The map's fields, in the order the screen shows them.
    public enum Field: String, CaseIterable, Sendable {
        case classID = "class_id", className = "class_name", section, email, role, primary

        public var label: String {
            switch self {
            case .classID: "Class ID"
            case .className: "Class name"
            case .section: "Section or term"
            case .email: "Email address"
            case .role: "Role"
            case .primary: "Primary teacher"
            }
        }

        /// Class ID, class name, email and role are needed; section and primary teacher are optional.
        public var isRequired: Bool { self != .section && self != .primary }
    }

    public static let textCap = 200
    public static let wordsCap = 20
    static let truthy: Set<String> = ["true", "yes", "y", "1", "x", "primary"]

    /// Header spellings each field is guessed from, best first. Compared with case, spaces, underscores, hyphens and tabs
    /// ignored.
    static let synonyms: [Field: [String]] = [
        .classID: ["class id", "section id", "course section id", "class code", "classid", "class sourcedid"],
        .className: ["class name", "class", "course name", "course title", "section name", "title", "class title"],
        .section: ["section", "term", "period", "semester"],
        .email: ["email", "email address", "e-mail", "student email", "user email", "mail", "person email"],
        .role: ["role", "type", "user type", "person type", "user role"],
        .primary: ["primary", "primary teacher", "lead", "is primary", "lead teacher"],
    ]

    public var classID = "", className = "", section = "", email = "", role = "", primary = ""
    public var teacherWords = ["teacher"]
    public var studentWords = ["student"]

    public init(classID: String = "", className: String = "", section: String = "", email: String = "", role: String = "",
                primary: String = "", teacherWords: [String] = ["teacher"], studentWords: [String] = ["student"]) {
        (self.classID, self.className, self.section, self.email, self.role, self.primary) = (classID, className, section, email, role, primary)
        (self.teacherWords, self.studentWords) = (teacherWords, studentWords)
    }

    /// Compared by exact text, as Python compares a `str`.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        let same = { (a: String, b: String) in a.utf8.elementsEqual(b.utf8) }
        return Field.allCases.allSatisfy { same(lhs[$0], rhs[$0]) }
            && lhs.teacherWords.count == rhs.teacherWords.count && zip(lhs.teacherWords, rhs.teacherWords).allSatisfy(same)
            && lhs.studentWords.count == rhs.studentWords.count && zip(lhs.studentWords, rhs.studentWords).allSatisfy(same)
    }

    /// Two lists of role words compared by exact text, as `==` compares them: Swift's `[String] ==` takes an NFC and an
    /// NFD spelling as one word, which the reader (`role(of:)`) never does.
    public static func sameWords(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    /// Where `name` is in `list` by exact text (a saved map's name, a header's column): `firstIndex(of:)` would find a
    /// canonically equivalent spelling the store and the reader keep apart.
    public static func exactIndex(of name: String, in list: [String]) -> Int? {
        list.firstIndex { $0.utf8.elementsEqual(name.utf8) }
    }

    public subscript(field: Field) -> String {
        get {
            switch field {
            case .classID: classID
            case .className: className
            case .section: section
            case .email: email
            case .role: role
            case .primary: primary
            }
        }
        set {
            switch field {
            case .classID: classID = newValue
            case .className: className = newValue
            case .section: section = newValue
            case .email: email = newValue
            case .role: role = newValue
            case .primary: primary = newValue
            }
        }
    }

    /// The mapped columns, each once (one column may hold two fields), in field order.
    public var columns: [String] {
        var seen: Set<ExactKey> = [], out: [String] = []
        for field in Field.allCases where !self[field].isEmpty && seen.insert(ExactKey(self[field])).inserted {
            out.append(self[field])
        }
        return out
    }

    /// The fields mapped to a column, by name, sorted: what the audit record says of a map (never its column names, which
    /// are the spreadsheet's text).
    public var mappedFields: [String] { Field.allCases.filter { !self[$0].isEmpty }.map(\.rawValue).sorted() }

    /// What a role cell means under this map: "teacher", "student" or "" (neither).
    public func role(of word: String) -> String {
        let word = PythonText.lower(PythonText.strip(word))
        guard !word.isEmpty else { return "" }
        let key = ExactKey(word)
        if teacherWords.contains(where: { ExactKey(PythonText.lower($0)) == key }) { return "teacher" }
        if studentWords.contains(where: { ExactKey(PythonText.lower($0)) == key }) { return "student" }
        return ""
    }

    /// Why this map can't read a file with `header`, in one sentence; "" when it can.
    public func problem(_ header: [String]) -> String {
        let present = Set(header.map { ExactKey(PythonText.strip($0)) })
        for field in Field.allCases where field.isRequired && self[field].isEmpty {
            return "Choose the column that holds the \(PythonText.lower(field.label))."
        }
        for field in Field.allCases where !self[field].isEmpty && !present.contains(ExactKey(self[field])) {
            return "The column “\(PythonText.string(self[field].unicodeScalars.prefix(80)))” (for the \(PythonText.lower(field.label))) "
                + "isn't in the spreadsheet's header."
        }
        func words(_ list: [String]) -> Set<ExactKey> {
            Set(list.compactMap { word in
                let stripped = PythonText.strip(word)
                return stripped.isEmpty ? nil : ExactKey(PythonText.lower(stripped))
            })
        }
        let teachers = words(teacherWords), students = words(studentWords)
        if teachers.isEmpty { return "Give at least one word the role column uses for a teacher." }
        if students.isEmpty { return "Give at least one word the role column uses for a student." }
        if let both = teachers.intersection(students).sorted().first {
            return "“\(PythonText.string(both.text.unicodeScalars.prefix(80)))” can't mean both a teacher and a student."
        }
        return ""
    }

    /// The map as its JSON object (`as_json`): each field's column, and the role words.
    public var json: JSONObject {
        var out = JSONObject()
        for field in Field.allCases { out[field.rawValue] = .string(self[field]) }
        out["teacher_words"] = .array(teacherWords.map(JSONValue.string))
        out["student_words"] = .array(studentWords.map(JSONValue.string))
        return out
    }

    /// A map from stored or posted JSON (`from_json`). Never fails: a field that isn't a string is "" (not used), a word list
    /// that isn't one is the default, and every string is capped.
    public init(json: JSONValue?) {
        let object = json?.object ?? [:]
        self.init()
        for field in Field.allCases {
            if case .string(let text)? = object[field.rawValue] {
                self[field] = PythonText.string(PythonText.strip(text).unicodeScalars.prefix(Self.textCap))
            }
        }
        teacherWords = Self.words(object["teacher_words"], default: ["teacher"])
        studentWords = Self.words(object["student_words"], default: ["student"])
    }

    /// A role's words from stored or posted JSON (`_words`): strings only, stripped and lowercased, each once, at most
    /// `wordsCap`; anything else (or nothing left) is the default, so a junk record never fails.
    static func words(_ raw: JSONValue?, default fallback: [String]) -> [String] {
        guard let list = raw?.array else { return fallback }
        var out: [String] = []
        for item in list {
            if case .string(let text) = item {
                let word = PythonText.string(PythonText.lower(PythonText.strip(text)).unicodeScalars.prefix(textCap))
                if !word.isEmpty, !out.contains(where: { $0.utf8.elementsEqual(word.utf8) }) { out.append(word) }
            }
            if out.count >= wordsCap { break }
        }
        return out.isEmpty ? fallback : out
    }

    /// The role words as the screen's text field gives them (GamGUI's `_map_from`): comma-separated, at most 400 characters
    /// read, each stripped and lowercased, at most `wordsCap`; then as `init(json:)` reads a list, so none left is the
    /// default.
    public static func words(typed text: String, default fallback: [String]) -> [String] {
        let raw = PythonText.string(text.unicodeScalars.prefix(400))
        let typed = raw.unicodeScalars.split(separator: ",", omittingEmptySubsequences: false)
            .map { PythonText.lower(PythonText.strip(PythonText.string($0))) }.filter { !$0.isEmpty }.prefix(wordsCap)
        return words(.array(typed.map(JSONValue.string)), default: fallback)
    }

    /// The map a header's own names suggest (`guess`). A column is guessed for one field at most; a field with no column
    /// named for it is left "" for the operator to choose, never filled with a column another field already took.
    public static func guess(_ header: [String]) -> RosterColumnMap {
        var byNorm: [ExactKey: String] = [:]
        for cell in header {
            let cell = PythonText.strip(cell)
            let key = ExactKey(norm(cell))
            if !cell.isEmpty, byNorm[key] == nil { byNorm[key] = cell }
        }
        var taken: Set<ExactKey> = []
        var map = RosterColumnMap()
        for field in Field.allCases {
            for synonym in synonyms[field] ?? [] {
                if let column = byNorm[ExactKey(norm(synonym))], taken.insert(ExactKey(column)).inserted {
                    map[field] = column
                    break
                }
            }
        }
        return map
    }

    /// `_norm`: lowercased, without spaces, underscores, hyphens or tabs.
    static func norm(_ text: String) -> String {
        PythonText.string(PythonText.lower(text).unicodeScalars.filter { !" _-\t".unicodeScalars.contains($0) })
    }
}

/// One spreadsheet of any shape read into the roster snapshot by the operator's column map (GamGUI's
/// `core/roster_mapped.py`, plan C5.3): for a SIS that exports neither OneRoster nor Clever, one flat CSV with a row per
/// person in a class.
///
/// The file is hostile until read, as every roster upload is: each row goes through `Roster.rowValues`, so the same caps,
/// the NUL refusal and strict UTF-8 apply, and only the mapped columns are ever built from a row. A person's ID is their
/// address (a flat sheet has no person ID), so an address is checked whole, as given, and only then lowercased; every other
/// field is cleaned by field (`clean`), since one column may be mapped as the address and a class too.
public enum RosterMapped {
    public static let source = "Spreadsheet (column map)"
    static let layout = "Check the column map against the spreadsheet's header."
    /// Rows shown read with the map before anything is read (the screen's map step).
    public static let previewRows = 3

    /// One row as the map reads it, for the map step: each field's text and what the role word means ("teacher",
    /// "student" or "", always "" for a row left out). `isAddress` is false when the address isn't one plain address (or
    /// is empty). `leftOut` is why
    /// the read would leave the row out, by the read's own checks in its order ("no class ID", "no address", "not one
    /// address"), each only once its field is mapped: a half-filled map doesn't flag every row (GamGUI #123,
    /// `_left_out`). The step says it whatever the role reads as.
    public struct PreviewRow: Sendable, Equatable {
        public let fields: [RosterColumnMap.Field: String]
        public let readAs: String
        public let isAddress: Bool
        public var leftOut: String? = nil

        public subscript(field: RosterColumnMap.Field) -> String { fields[field] ?? "" }
    }

    /// GamGUI's `header_of`, for the map step: the picked spreadsheet's header, or its refusal in GamGUI's words.
    public static func header(name: String, bytes: [UInt8], caps: RosterCaps = .standard) throws(Roster.Refusal) -> [String] {
        try refusing { try Roster.headerOf(Roster.base(name), bytes, caps: caps) }
    }

    /// The first `count` non-blank rows as `map` reads them (`preview`). Works on a map still being filled in (an unmapped
    /// or absent column reads as ""), and stops after `count` rows: the rest of the file isn't read.
    public static func preview(name: String, bytes: [UInt8], map: RosterColumnMap, count: Int = previewRows,
                               caps: RosterCaps = .standard) throws(Roster.Refusal) -> [PreviewRow] {
        try refusing {
            var out: [PreviewRow] = []
            guard count > 0 else { return out }
            let columns = map.columns
            try Roster.rowValues(Roster.base(name), bytes, required: [], used: columns, layout: layout,
                                 raw: { $0.utf8.elementsEqual(map.email.utf8) }, caps: caps) { _, values in
                var fields = mapped(map, columns, values)
                // Checked as the read checks it, as given: lowercasing first would show a Kelvin sign (U+212A) as an
                // ASCII k, a valid address the read refuses. Lowercased, and its role read, only for a row the read keeps
                // (GamGUI's `_left_out`, gamgui#123).
                let given = PythonText.strip(fields[.email] ?? "")
                let isAddress = Roster.isOneAddress(given)
                let leftOut: String? = if !map.classID.isEmpty, (fields[.classID] ?? "").isEmpty { "no class ID" }
                    else if map.email.isEmpty { nil }
                    else if given.isEmpty { "no address" }
                    else if !isAddress { "not one address" }
                    else { nil }
                fields[.email] = leftOut == nil ? given.lowercased() : given
                out.append(PreviewRow(fields: fields, readAs: leftOut == nil ? map.role(of: fields[.role] ?? "") : "",
                                      isAddress: isAddress, leftOut: leftOut))
                return out.count < count
            }
            return out
        }
    }

    /// GamGUI's `read_mapped`: the whole spreadsheet as a snapshot. Refused with the map's problem when it can't read this
    /// header; every row-level problem is an issue, the row left out or its first reading kept.
    public static func read(name: String, bytes: [UInt8], map: RosterColumnMap,
                            caps: RosterCaps = .standard) throws(Roster.Refusal) -> RosterSnapshot {
        try refusing { try readMapped(Roster.base(name), bytes, map, caps: caps) }
    }

    private static func refusing<T>(_ body: () throws -> T) throws(Roster.Refusal) -> T {
        do {
            return try body()
        } catch let error as PackageError {
            throw .package(error.message)
        } catch {
            throw .package("The spreadsheet couldn't be read. Choose it again.")
        }
    }

    /// A row by field, from the values of `columns` (`_mapped`). The address column is kept raw by the row reader (an
    /// address is checked whole, never cleaned), so every other field is cleaned here: one column may be mapped to two
    /// fields, and a control or invisible character must never reach a class's ID or title through it.
    static func mapped(_ map: RosterColumnMap, _ columns: [String], _ values: [String?]) -> [RosterColumnMap.Field: String] {
        var out: [RosterColumnMap.Field: String] = [:]
        for field in RosterColumnMap.Field.allCases {
            let column = map[field]
            var value = ""
            if !column.isEmpty, let at = columns.firstIndex(where: { $0.utf8.elementsEqual(column.utf8) }) {
                value = values[at] ?? ""
            }
            out[field] = field == .email ? value : Roster.clean(value)
        }
        return out
    }

    static func readMapped(_ base: String, _ bytes: [UInt8], _ map: RosterColumnMap, caps: RosterCaps) throws -> RosterSnapshot {
        let header = try Roster.headerOf(base, bytes, caps: caps)
        let problem = map.problem(header)
        if !problem.isEmpty { throw PackageError(problem) }
        var snap = RosterSnapshot.Builder(source: source, sample: caps.issueSample)
        var firstTitle: [ExactKey: String] = [:], firstSection: [ExactKey: String] = [:]   // each class as its first row gave it
        var seen: Set<[ExactKey]> = []                                                    // (class ID, address) enrolled
        let columns = map.columns
        try Roster.rowValues(base, bytes, required: columns, used: columns, layout: layout,
                             raw: { $0.utf8.elementsEqual(map.email.utf8) }, caps: caps) { line, values in
            let row = mapped(map, columns, values)
            let classID = row[.classID] ?? ""
            if classID.isEmpty {
                snap.issue("no_id", base, line)
                return true
            }
            let title = row[.className] ?? "", section = row[.section] ?? ""
            if let known = firstTitle[ExactKey(classID)] {
                // A later row that names the class differently, or gives another section, is a conflict (the first kept).
                if !title.isEmpty, !title.utf8.elementsEqual(known.utf8) {
                    snap.issue("conflict", base, line, classID, "name “\(title)”, first “\(known)”")
                }
                let first = firstSection[ExactKey(classID)] ?? ""
                if !section.isEmpty, !section.utf8.elementsEqual(first.utf8) {
                    snap.issue("conflict", base, line, classID, "section “\(section)”, first “\(first)”")
                }
            } else {
                var termIDs: [String] = []
                if !section.isEmpty {
                    let termID = "section:" + section
                    _ = snap.add(term: .init(id: termID, title: section, kind: "", start: "", end: ""))
                    termIDs = [termID]
                }
                _ = snap.add(class: .init(id: classID, title: title, courseID: "", schoolID: "", termIDs: termIDs, code: "", location: ""))
                (firstTitle[ExactKey(classID)], firstSection[ExactKey(classID)]) = (title, section)
                if title.isEmpty { snap.issue("no_title", base, line, classID) }
            }
            let given = row[.email] ?? ""
            if given.isEmpty {
                snap.issue("no_email", base, line, classID)
                return true
            }
            // Checked as given: lowercasing first turns a Kelvin sign (U+212A) into an ASCII k.
            guard Roster.isOneAddress(given) else {
                snap.issue("bad_email", base, line, classID, given)
                return true
            }
            let email = given.lowercased()       // one plain ASCII address
            let role = map.role(of: row[.role] ?? "")
            if role.isEmpty {
                snap.issue("unknown_role", base, line, email, row[.role] ?? "")
                return true
            }
            guard seen.insert([ExactKey(classID), ExactKey(email)]).inserted else {
                snap.issue("duplicate_row", base, line, email, classID)
                return true
            }
            if !snap.hasPerson(email) { _ = snap.add(person: .init(id: email, role: role, email: email, given: "", family: "")) }
            let primary = role == "teacher" && RosterColumnMap.truthy.contains(PythonText.lower(PythonText.strip(row[.primary] ?? "")))
            snap.enroll(.init(classID: classID, personID: email, role: role, primary: primary))
            return true
        }
        // Someone who teaches one class and is a student in another counts as a teacher (each enrolment keeps its role).
        snap.makeTeachers(Set(snap.snapshot.enrollments.filter { $0.role == "teacher" }.map { ExactKey($0.personID) }))
        return snap.snapshot
    }
}
