import GamEngine

/// Clever's CSV roster export read into the snapshot (plan 2026-11-11 C5.2; GamGUI's `core/roster_clever.py` at 07c505d,
/// held to `Tests/Fixtures/roster.json` and `roster_mapped.json`, and to the shared files in `Tests/Fixtures/roster/clever`).
///
/// Clever's SFTP CSV (spec v2.2.0) is five files with Capitalized_snake_case headers, matched ignoring case. It has no
/// manifest, no status column and no delta: every row is live. It differs from OneRoster in ways that each need a rule:
///
/// - **Students and teachers are separate ID spaces** that may collide, so a person's ID is `student:` or `teacher:` plus
///   Clever's.
/// - **A student repeats once per guardian contact**, and a teacher once per school. The first row is kept, and a repeat is
///   a `conflict` only when its address differs.
/// - **A class's teachers are on its section row** (`Teacher_id` the primary, `Teacher_2_id` to `Teacher_10_id`
///   co-teachers); enrollments.csv holds students only.
/// - **Courses and terms aren't files**: they are columns of a section, and are built from them.
///
/// Clever's files hold far more than a roster needs (passwords, birth dates, guardian contacts, IEP status). Every row goes
/// through `Roster.rows`, which builds a row from the columns named here alone, so `Username`, `Password`, `Contact_email`
/// and the rest are never read into anything; staff.csv and administrators.csv are named and never unpacked (`skip`).
enum RosterClever {
    static let required = ["schools.csv", "students.csv", "teachers.csv", "sections.csv", "enrollments.csv"]
    /// Not on a class's roster; staff.csv and the others hold passwords.
    static let skip = ["staff.csv", "administrators.csv"]
    static let layout = Roster.Layout(
        label: "Clever",
        known: Dictionary(uniqueKeysWithValues: (required + skip).map { (ExactKey(PythonText.lower($0)), $0) }),
        skip: Set(skip))

    static let source = "Clever CSV"
    static let layoutSentence = "That isn't Clever's CSV layout: export Clever's schools, students, teachers, sections and enrollments files."
    static let coTeachers = (2...10).map { "Teacher_\($0)_id" }

    /// The columns each file must have for this reader. Never Username, Password, Contact_email or any other column Clever
    /// puts beside them: a row is built from these (and, for sections, `used`) alone.
    static let columns: [String: [String]] = [
        "schools.csv": ["School_id", "School_name"],
        "teachers.csv": ["Teacher_id", "Teacher_email", "First_name", "Last_name"],
        "students.csv": ["Student_id", "Student_email", "First_name", "Last_name"],
        "sections.csv": ["School_id", "Section_id", "Teacher_id"],
        "enrollments.csv": ["Section_id", "Student_id"],
    ]
    static let used: [String: [String]] = columns.merging([
        "sections.csv": ["School_id", "Section_id", "Teacher_id"] + coTeachers
            + ["Name", "Section_number", "Course_name", "Course_number", "Period", "Term_name", "Term_start", "Term_end"],
    ]) { $1 }
    static let address = ["teachers.csv": "Teacher_email", "students.csv": "Student_email"]

    /// GamGUI's `read_clever`: a Clever CSV export (its files by canonical name, from `Roster.filesFromZip` or
    /// `filesFromCSVs` with `layout`) as a snapshot. Each file is taken out of `files` as it's read. A file missing, or one
    /// missing a column this reader needs, refuses the export.
    static func read(_ files: inout [String: [UInt8]], caps: RosterCaps) throws -> RosterSnapshot {
        if let missing = required.first(where: { files[$0] == nil }) {
            throw PackageError("The export has no \(missing), which a roster needs. " + layoutSentence)
        }
        var snap = RosterSnapshot.Builder(source: source, sample: caps.issueSample)
        func each(_ name: String, raw: Set<String> = [], _ body: (Int, [String: String]) throws -> Void) throws {
            let bytes = files.removeValue(forKey: name) ?? []
            try Roster.rows(name, bytes, required: columns[name]!, used: used[name]!, layout: layoutSentence, raw: raw,
                            foldCase: true, caps: caps, body)
        }
        try each("schools.csv") { line, row in
            let id = row["School_id"] ?? ""
            if id.isEmpty {
                snap.issue("no_id", "schools.csv", line)
                return
            }
            if !snap.add(school: .init(id: id, name: row["School_name"] ?? "")) { snap.issue("duplicate_id", "schools.csv", line, id) }
        }
        var emails: Set<ExactKey> = []       // across teachers and students: one address is one person
        for (name, role) in [("teachers.csv", "teacher"), ("students.csv", "student")] {
            let idColumn = role == "teacher" ? "Teacher_id" : "Student_id", emailColumn = address[name]!
            var first: [ExactKey: String] = [:]      // Clever ID -> the first row's address, lowercased (kept or not)
            try each(name, raw: [emailColumn]) { line, row in
                let id = row[idColumn] ?? ""
                if id.isEmpty {
                    snap.issue("no_id", name, line)
                    return
                }
                let given = row[emailColumn] ?? ""
                let email = Roster.lower(given)
                if let earlier = first[ExactKey(id)] {
                    if !email.isEmpty, !email.utf8.elementsEqual(earlier.utf8) {
                        snap.issue("conflict", name, line, id, "\(email) here, \(earlier.isEmpty ? "no address" : earlier) on its first row")
                    }
                    return
                }
                first[ExactKey(id)] = email
                if email.isEmpty {
                    snap.issue("no_email", name, line, id)
                    return
                }
                // Checked as given: lowercasing first turns a Kelvin sign (U+212A) into an ASCII k.
                guard Roster.isOneAddress(given) else {
                    snap.issue("bad_email", name, line, id, given)
                    return
                }
                guard emails.insert(ExactKey(email)).inserted else {
                    snap.issue("duplicate_email", name, line, id, email)
                    return
                }
                _ = snap.add(person: .init(id: "\(role):\(id)", role: role, email: email, given: row["First_name"] ?? "",
                                           family: row["Last_name"] ?? ""))
            }
        }
        try each("sections.csv") { line, row in
            try section(&snap, line, row)
        }
        var seen: Set<[ExactKey]> = []
        try each("enrollments.csv") { line, row in
            let section = row["Section_id"] ?? "", student = row["Student_id"] ?? ""
            guard snap.hasClass(section) else {
                snap.issue("unknown_class", "enrollments.csv", line, student, section)
                return
            }
            let person = "student:\(student)"
            guard snap.hasPerson(person) else {
                snap.issue("unknown_person", "enrollments.csv", line, section, student)
                return
            }
            guard seen.insert([ExactKey(section), ExactKey(person)]).inserted else {
                snap.issue("duplicate_row", "enrollments.csv", line, section, student)
                return
            }
            snap.enroll(.init(classID: section, personID: person, role: "student", primary: false))
        }
        return snap.snapshot
    }

    /// One section row into a class, the course it names, and its teachers (the primary, then co-teachers).
    private static func section(_ snap: inout RosterSnapshot.Builder, _ line: Int, _ row: [String: String]) throws {
        let name = "sections.csv"
        let id = row["Section_id"] ?? ""
        if id.isEmpty {
            snap.issue("no_id", name, line)
            return
        }
        if snap.hasClass(id) {
            snap.issue("duplicate_id", name, line, id)
            return
        }
        let school = row["School_id"] ?? "", title = title(row)
        if title.isEmpty { snap.issue("no_title", name, line, id) }
        if !snap.hasSchool(school) { snap.issue("unknown_school", name, line, id, school) }
        var courseID = ""
        if let number = row["Course_number"], !number.isEmpty {
            courseID = "course:\(number)"
            if !snap.hasCourse(courseID) {
                _ = snap.add(course: .init(id: courseID, title: row["Course_name"] ?? "", code: number, schoolID: school))
            }
        }
        _ = snap.add(class: .init(id: id, title: title, courseID: courseID, schoolID: school, termIDs: term(&snap, row),
                                  code: row["Section_number"] ?? "", location: ""))
        var seen: Set<ExactKey> = []
        for column in ["Teacher_id"] + coTeachers {
            let teacher = row[column] ?? ""
            guard !teacher.isEmpty, seen.insert(ExactKey(teacher)).inserted else { continue }
            let person = "teacher:\(teacher)"
            guard snap.hasPerson(person) else {
                snap.issue("unknown_person", name, line, id, teacher)
                continue
            }
            snap.enroll(.init(classID: id, personID: person, role: "teacher", primary: column == "Teacher_id"))
        }
    }

    /// A section's name, else its course's name with its period, else its course's name, else "".
    static func title(_ row: [String: String]) -> String {
        if let name = row["Name"], !name.isEmpty { return name }
        let course = row["Course_name"] ?? "", period = row["Period"] ?? ""
        if !course.isEmpty, !period.isEmpty { return "\(course) - Period \(period)" }
        return course
    }

    /// The section's term, built from its Term_ columns (Clever has no terms file), or [] when it names none. Sections with
    /// the same three values share one term.
    private static func term(_ snap: inout RosterSnapshot.Builder, _ row: [String: String]) -> [String] {
        let name = row["Term_name"] ?? "", start = row["Term_start"] ?? "", end = row["Term_end"] ?? ""
        if name.isEmpty, start.isEmpty, end.isEmpty { return [] }
        let id = "term:\(name)|\(start)|\(end)"
        if !snap.hasTerm(id) {
            let (startISO, endISO) = (iso(start), iso(end))
            _ = snap.add(term: .init(id: id, title: name.isEmpty ? "\(startISO) to \(endISO)" : name, kind: "term",
                                     start: startISO, end: endISO))
        }
        return [id]
    }

    /// Clever's MM/DD/YYYY as YYYY-MM-DD, when it is exactly that and a real date (Python's `date`: years 1 to 9999);
    /// anything else is kept as given, so the operator sees what the export said rather than a guess.
    static func iso(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 10, scalars[2] == "/", scalars[5] == "/",
              [0, 1, 3, 4, 6, 7, 8, 9].allSatisfy({ ("0"..."9").contains(scalars[$0]) })
        else { return text }
        let digits = { (range: Range<Int>) in range.reduce(0) { $0 * 10 + Int(scalars[$1].value - 48) } }
        let (month, day, year) = (digits(0..<2), digits(3..<5), digits(6..<10))
        guard year >= 1, (1...12).contains(month) else { return text }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard (1...days).contains(day) else { return text }
        func pad(_ value: Int, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }
}
