import Foundation

/// Google Classroom, read only: classes and who is in them (plan 2026-11-11, C1; GamGUI's `core/classroom.py` at 07c505d).
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

    /// A Classroom read GAM couldn't be run for (its credentials or its private folder), in fixed words: never an error's
    /// own text.
    public static let notRun = "Couldn't read Classroom: GAM couldn't be run for this domain. Check access on Setup, then try again."

    public static func needsScope(_ error: GamError) -> Bool {
        error.exitCode == 15 || error.kind == .scopeMissing
    }

    /// The states a person's classes are read in: last year's archived ones too (a deleted owner loses those as well), never
    /// declined or suspended ones (GamGUI's `PERSON_STATES`).
    public static let personStates: [GamCommands.CourseState] = [.active, .provisioned, .archived]

    /// The classes `email` owns, from a read with `owneremail` (a class can have several teachers, one owner): GamGUI's
    /// `owned_by`, `email.strip().lower()` against the owner's address.
    public static func owned(_ courses: [Course], by email: String) -> [Course] {
        let who = PythonText.lower(PythonText.strip(email))
        return courses.filter { $0.ownerEmail.unicodeScalars.elementsEqual(who.unicodeScalars) }
    }

    /// The owned-classes list offboarding hands over (GamGUI's `/classroom/owned.csv`): its header, then a row per class.
    /// Each cell is made formula-safe where it's written (`AuditExport.csv`, GamGUI's `csv_safe`).
    public static func ownedRows(_ courses: [Course]) -> [[String]] {
        [["courseId", "name", "section", "state", "owner", "link"]]
            + courses.map { [$0.id, $0.name, $0.section, $0.stateWords, $0.ownerEmail, $0.link] }
    }

    /// The list's file name: `classes-owned-by-<local part>.csv`, keeping only ASCII letters, digits and `._-` of the
    /// address's local part (it may hold `\`, `;` or `/`), "person" when nothing is left. GamGUI's filename rule.
    public static func ownedFileName(_ email: String) -> String {
        let localPart = PythonText.strip(email).split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let kept = String(String.UnicodeScalarView(localPart.unicodeScalars.filter { scalar in
            scalar.isASCII && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                               || "._-".unicodeScalars.contains(scalar))
        }))
        return "classes-owned-by-\(kept.isEmpty ? "person" : kept).csv"
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
        // A class whose owner GAM can't look up (a deleted account) is a warning and exit 56 after every class was printed:
        // read as an error, one deleted owner hid every class, and offboarding said the leaver owned none (GamGUI failure
        // log 2026-11-11, #113). Accepted only when every line GAM reported is that warning (`onlyUnknownOwners`). With no
        // table it is `Incomplete` below, never GAM's not-found: GamGUI raises the 56 there, which its offboarding read
        // would take as "owns none" (a listed deviation; GAM prints its header whenever it prints the table).
        let ownersUnknown = result.exitCode == 56 && GamError.onlyUnknownOwners(result.stderr)
        guard result.exitCode == 0 || ownersUnknown else {
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
