import Foundation

/// Google Classroom, read only: classes and who is in them (plan 2026-11-11, C1; GamGUI's `core/classroom.py` at 3c8d909).
/// The app never writes to Classroom: the operator has no Workspace for Education domain to prove a write on, and this repo
/// relies on no write that hasn't run live. These reads have only run against the mock; their shapes were read from the
/// vendored GAM build (doPrintCourses, doPrintCourseParticipants), not captured from a tenant.
public enum Classroom {
    /// The admin token's Classroom scopes, as GAM's own table names them (gamlib glapi `_CLIENT_SCOPES`, 7.51.00), each with
    /// what it lets the app see. GAM reads Classroom with the admin token, so these are picked when that token is made, not
    /// delegated. The scope or its `.readonly` form will do for a read.
    public static let scopes: [(scope: String, name: String, why: String)] = [
        ("https://www.googleapis.com/auth/classroom.courses", "Classroom API - Courses", "See classes"),
        ("https://www.googleapis.com/auth/classroom.rosters", "Classroom API - Rosters", "See who is in each class"),
        ("https://www.googleapis.com/auth/classroom.profile.emails", "Classroom API - Profile Emails", "See each person's address"),
    ]

    /// The Classroom scopes the admin token lacks, by GAM's name for each, or nil when its scopes can't be read (then a read
    /// is tried: an unread record is never taken for a missing scope).
    public static func scopesMissing(granted: [String]?) -> [String]? {
        guard let granted else { return nil }
        let have = Set(granted)
        return scopes.filter { !have.contains($0.scope) && !have.contains($0.scope + ".readonly") }.map(\.name)
    }

    /// What to do when a read failed for want of a scope (exit 15, or Google's refusal of a scope).
    public static let scopeNote = "This domain's GAM authorization needs the Classroom scopes (“Classroom API - Courses”, “- Rosters” "
        + "and “- Profile Emails”; read-only is enough): authorize again from Setup's fresh setup with them ticked."

    public static func needsScope(_ error: GamError) -> Bool {
        error.exitCode == 15 || error.kind == .scopeMissing
    }

    /// The Classroom API's course states, as people say them.
    public static func stateWords(_ state: String) -> String {
        switch state {
        case "ACTIVE": "Active"
        case "ARCHIVED": "Archived"
        case "PROVISIONED": "Not yet accepted"
        case "DECLINED": "Declined"
        case "SUSPENDED": "Suspended"
        case "COURSE_STATE_UNSPECIFIED", "": "Unknown"
        default: state.capitalized
        }
    }

    /// A link to the class only when it is Classroom's own (`alternateLink`, as Google gives it).
    public static func classLink(_ link: String) -> URL? {
        link.hasPrefix("https://classroom.google.com/") ? URL(string: link) : nil
    }

    public struct Course: Sendable, Equatable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let section: String
        public let room: String
        public let state: String
        public let ownerID: String
        /// Only when the read asked for it (`owneremail`): one Directory read per owner.
        public let ownerEmail: String
        public let created: String
        public let updated: String
        public let link: String

        public var stateWords: String { Classroom.stateWords(state) }

        /// A course record from `print courses … formatjson`, or nil for one with no ID.
        public init?(record: GamOutput.Record) {
            func text(_ key: String) -> String { Classroom.text(record[key]) }
            id = text("id")
            guard !id.isEmpty else { return nil }
            name = text("name"); section = text("section"); room = text("room"); state = text("courseState")
            // GAM writes "Unknown user" for an owner it couldn't look up: never an address, so the screen names the owner from
            // the directory by ID instead (GamGUI keeps the words; review 2026-11-11).
            let owner = PythonText.lower(text("ownerEmail"))
            ownerID = text("ownerId"); ownerEmail = owner.contains("@") ? owner : ""
            created = text("creationTime"); updated = text("updateTime"); link = text("alternateLink")
        }

        public init(id: String, name: String, section: String = "", room: String = "", state: String = "", ownerID: String = "",
                    ownerEmail: String = "", created: String = "", updated: String = "", link: String = "") {
            self.id = id; self.name = name; self.section = section; self.room = room; self.state = state; self.ownerID = ownerID
            self.ownerEmail = ownerEmail; self.created = created; self.updated = updated; self.link = link
        }
    }

    /// One person in a class. Not `Identifiable`: two listed without an ID or an address are alike, so a list keys by position.
    public struct Participant: Sendable, Equatable, Hashable {
        public enum Role: String, Sendable { case teacher = "TEACHER", student = "STUDENT" }
        public let role: Role
        public let userID: String
        public let email: String
        public let name: String
    }

    public struct Roster: Sendable, Equatable {
        public let courseID: String
        public var courseName: String
        public var teachers: [Participant] = []
        public var students: [Participant] = []
        /// A cell GAM printed that couldn't be read: the roster says so rather than reading as complete.
        public var unreadable: [String] = []
        /// Someone listed without an address: Classroom leaves addresses out without the "Profile Emails" scope.
        public var emailsHidden = false
    }

    /// Courses from a `print courses` read, each once, by name (case aside), then section, then ID.
    public static func courses(_ records: [GamOutput.Record]) -> [Course] {
        var seen: [String: Course] = [:], order: [String] = []
        for record in records {
            guard let course = Course(record: record), seen[course.id] == nil else { continue }
            seen[course.id] = course
            order.append(course.id)
        }
        return order.compactMap { seen[$0] }.sorted { a, b in
            precedes([PythonText.lower(a.name), PythonText.lower(a.section), a.id],
                     [PythonText.lower(b.name), PythonText.lower(b.section), b.id])
        }
    }

    /// One class's roster from `print course-participants course <id> show all formatjson`: its one row, `JSON-teachers` and
    /// `JSON-students` each a list of people. GAM prints the row even for an empty class, so a missing row is a read that fell
    /// short, never an empty class.
    public static func roster(_ records: [GamOutput.Record], courseID: String) -> Roster {
        for record in records where text(record["courseId"]) == courseID {
            var roster = Roster(courseID: courseID, courseName: text(record["courseName"]))
            roster.teachers = people(record["JSON-teachers"], role: .teacher, column: "JSON-teachers", into: &roster)
            roster.students = people(record["JSON-students"], role: .student, column: "JSON-students", into: &roster)
            return roster
        }
        return Roster(courseID: courseID, courseName: "", unreadable: ["the class's row"])
    }

    /// A finished read's records. Throws the `GamError` when GAM failed (15: no Classroom scope; 56: a class, teacher or
    /// student Classroom doesn't know), and `Incomplete` when GAM answered nothing at all (it prints its CSV header even when
    /// nothing matches, so silence is never "no classes") or its output passed the runner's cap.
    public static func records(_ result: GamResult, argv: [String]) throws -> [GamOutput.Record] {
        guard result.exitCode == 0 || ownersUnknownOnly(result) else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        guard !result.stdoutTruncated else {
            throw MessageCopies.Incomplete(reason: "GAM printed more than \(GamRunner.outputCap / 1_048_576) MiB, so the classes weren't all read.")
        }
        guard !PythonText.strip(result.stdout).isEmpty else {
            throw MessageCopies.Incomplete(reason: "GAM exited without an answer, so the classes can't be told. Its sign-in may have "
                                           + "been refused: check the admin token on Setup.")
        }
        return GamOutput.records(result.stdout)
    }

    /// The classes whose name, section or room holds `text`, case aside, as GamGUI's index search (`ql in c.name.lower()`,
    /// by code point); every class for none.
    public static func matching(_ courses: [Course], _ text: String) -> [Course] {
        let needle = Array(PythonText.lower(PythonText.strip(text)).unicodeScalars)
        guard !needle.isEmpty else { return courses }
        func holds(_ value: String) -> Bool {
            let hay = Array(PythonText.lower(value).unicodeScalars)
            guard hay.count >= needle.count else { return false }
            return (0...(hay.count - needle.count)).contains { start in hay[start..<(start + needle.count)].elementsEqual(needle) }
        }
        return courses.filter { holds($0.name) || holds($0.section) || holds($0.room) }
    }

    // MARK: reading

    /// GAM couldn't look up a class's owner (`owneremail`; doPrintCourses → _convertCourseUserIdToEmailName, 7.51.00): an owner
    /// deleted or out of reach. It still prints the whole table, that owner's address as "Unknown user", but writes
    /// `Course: <id>, Owner ID: <id>, Does not exist (i/n)` (entityDoesNotHaveItemWarning) and exits 56. Every class is there,
    /// so the table is read, never "Classroom doesn't know" the teacher or the class. Only when each of GAM's lines is such a
    /// warning: any other line keeps the failure. A deviation from GamGUI at 3c8d909, which fails the read (review 2026-11-11).
    static func ownersUnknownOnly(_ result: GamResult) -> Bool {
        guard result.exitCode == 56, !result.stdoutTruncated else { return false }
        let lines = PythonText.lines(result.stderr).map { PythonText.strip($0) }
            .filter { !$0.isEmpty && !GamError.isProgress($0) && !GamError.isFraming($0) }
        return !lines.isEmpty && lines.allSatisfy { line in
            let text = EntityCount.removed(from: line)
            guard text.hasPrefix("Course: "), text.hasSuffix(", Does not exist"), let owner = text.range(of: ", Owner ID: ") else { return false }
            let course = text[text.index(text.startIndex, offsetBy: 8)..<owner.lowerBound]
            return GamCommands.isCourseID(String(course))
        }
    }

    /// Python's `value.strip()` of a string, empty for anything else (`_text`).
    static func text(_ value: JSONValue?) -> String {
        if case .string(let text)? = value { PythonText.strip(text) } else { "" }
    }

    /// Python's ordering of tuples of strings: by code point, as `sorted` compares them.
    static func precedes(_ a: [String], _ b: [String]) -> Bool {
        for (x, y) in zip(a, b) where !x.unicodeScalars.elementsEqual(y.unicodeScalars) {
            return x.unicodeScalars.lexicographicallyPrecedes(y.unicodeScalars)
        }
        return a.count < b.count
    }

    /// One `JSON-` cell's people. A missing column, a cell that isn't a list, or an item that isn't an object is unreadable,
    /// never no one.
    static func people(_ cell: JSONValue?, role: Participant.Role, column: String, into roster: inout Roster) -> [Participant] {
        let items: [JSONValue]
        switch cell {
        case nil:
            roster.unreadable.append(column)
            return []
        case .string(let text)? where text.isEmpty:
            return []
        case .string(let text)?:
            guard let parsed = JSONValue.parse(text), let list = parsed.array else {
                roster.unreadable.append(column)
                return []
            }
            items = list
        case .array(let list)?:
            items = list
        default:
            roster.unreadable.append(column)
            return []
        }
        var found: [Participant] = []
        for item in items {
            guard let object = item.object else {
                roster.unreadable.append(column)
                continue
            }
            let profile = object["profile"]?.object ?? [:]
            let name = profile["name"]?.object ?? [:]
            let userID = text(object["userId"]).isEmpty ? text(profile["id"]) : text(object["userId"])
            let email = PythonText.lower(text(profile["emailAddress"]))
            if email.isEmpty { roster.emailsHidden = true }
            found.append(Participant(role: role, userID: userID, email: email, name: text(name["fullName"])))
        }
        return found.sorted { a, b in
            let ka = PythonText.lower(a.name), kb = PythonText.lower(b.name)
            return precedes([ka.isEmpty ? a.email : ka, a.email], [kb.isEmpty ? b.email : kb, b.email])
        }
    }
}
