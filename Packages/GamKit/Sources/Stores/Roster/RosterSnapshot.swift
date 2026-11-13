import GamEngine

/// What a SIS export holds, in one model every reader fills (GamGUI's `Snapshot`): schools, terms, courses, classes,
/// people and enrolments, in the export's order, with the rows it left out counted by kind (`issueCounts`) and a sample
/// of each (`issueSample`). Student data: `RosterStore` keeps it `0600`, for `RosterStore.keepDays`.
public struct RosterSnapshot: Sendable, Equatable, Codable {
    public struct School: Sendable, Equatable, Codable {
        public let id: String
        public let name: String
    }

    public struct Term: Sendable, Equatable, Codable {
        public let id: String
        public let title: String
        public let kind: String
        public let start: String
        public let end: String
    }

    public struct Course: Sendable, Equatable, Codable {
        public let id: String
        public let title: String
        public let code: String
        public let schoolID: String
    }

    public struct Class: Sendable, Equatable, Codable {
        public let id: String
        public let title: String
        public let courseID: String
        public let schoolID: String
        public let termIDs: [String]
        public let code: String
        public let location: String
    }

    public struct Person: Sendable, Equatable, Codable {
        public let id: String
        /// "teacher" or "student", lowercased.
        public let role: String
        /// Lowercased.
        public let email: String
        public let given: String
        public let family: String
    }

    public struct Enrollment: Sendable, Equatable, Codable {
        public let classID: String
        public let personID: String
        /// "teacher" or "student".
        public let role: String
        public let primary: Bool
    }

    /// A row left out or questioned, for the SIS team.
    public struct Issue: Sendable, Equatable, Codable {
        public let code: String
        public let file: String
        /// The CSV line its record starts on, counting the header as line 1.
        public let row: Int
        public let sourceID: String
        public let detail: String

        public init(code: String, file: String, row: Int, sourceID: String, detail: String) {
            (self.code, self.file, self.row, self.sourceID, self.detail) = (code, file, row, sourceID, detail)
        }
    }

    /// One kind of issue and how many rows had it: the count is always whole, whatever the sample kept.
    public struct IssueCount: Sendable, Equatable, Codable {
        public let code: String
        public let count: Int

        public init(code: String, count: Int) {
            self.code = code
            self.count = count
        }
    }

    /// What the roster holds, as GamGUI's `counts` names it, in its order.
    public struct Counts: Sendable, Equatable, Codable {
        public var schools = 0, terms = 0, courses = 0, classes = 0, teachers = 0, students = 0, enrollments = 0

        public init() {}

        /// GamGUI's keys and labels, in its order.
        public static let names: [(key: String, label: String)] = [
            ("schools", "Schools"), ("terms", "Terms"), ("courses", "Courses"), ("classes", "Classes"),
            ("teachers", "Teachers"), ("students", "Students"), ("enrollments", "Enrolments"),
        ]

        public var ordered: [(key: String, value: Int)] {
            [("schools", schools), ("terms", terms), ("courses", courses), ("classes", classes), ("teachers", teachers),
             ("students", students), ("enrollments", enrollments)]
        }
    }

    /// The format it came from, e.g. "OneRoster 1.1 CSV".
    public var source: String
    public var schools: [School] = []
    public var terms: [Term] = []
    public var courses: [Course] = []
    public var classes: [Class] = []
    public var people: [Person] = []
    public var enrollments: [Enrollment] = []
    /// In the order each kind was first met.
    public var issueCounts: [IssueCount] = []
    public var issueSample: [Issue] = []
    /// People in roles a class's roster doesn't hold (aides, guardians…), counted only.
    public var others = 0

    public init(source: String) { self.source = source }

    public var counts: Counts {
        var counts = Counts()
        counts.schools = schools.count
        counts.terms = terms.count
        counts.courses = courses.count
        counts.classes = classes.count
        counts.teachers = people.reduce(0) { $0 + ($1.role == "teacher" ? 1 : 0) }
        counts.students = people.count - counts.teachers
        counts.enrollments = enrollments.count
        return counts
    }

    /// A snapshot being read: each kind's IDs held for the lookups a reader makes, exactly as spelled.
    struct Builder {
        private(set) var snapshot: RosterSnapshot
        private let sample: Int
        private var schoolIDs: Set<ExactKey> = [], termIDs: Set<ExactKey> = [], courseIDs: Set<ExactKey> = []
        private var classIDs: Set<ExactKey> = [], personIDs: Set<ExactKey> = []
        private var countAt: [String: Int] = [:]

        init(source: String, sample: Int) {
            snapshot = RosterSnapshot(source: source)
            self.sample = sample
        }

        var others: Int {
            get { snapshot.others }
            set { snapshot.others = newValue }
        }

        /// Count one issue, and keep it while its kind has fewer than `sample` kept (#9).
        mutating func issue(_ code: String, _ file: String, _ row: Int, _ sourceID: String = "", _ detail: String = "") {
            let count: Int
            if let at = countAt[code] {
                count = snapshot.issueCounts[at].count + 1
                snapshot.issueCounts[at] = IssueCount(code: code, count: count)
            } else {
                countAt[code] = snapshot.issueCounts.count
                snapshot.issueCounts.append(IssueCount(code: code, count: 1))
                count = 1
            }
            if count <= sample {
                snapshot.issueSample.append(Issue(code: code, file: file, row: row, sourceID: sourceID,
                                                  detail: PythonText.string(detail.unicodeScalars.prefix(200))))
            }
        }

        func hasSchool(_ id: String) -> Bool { schoolIDs.contains(ExactKey(id)) }
        func hasTerm(_ id: String) -> Bool { termIDs.contains(ExactKey(id)) }
        func hasCourse(_ id: String) -> Bool { courseIDs.contains(ExactKey(id)) }
        func hasClass(_ id: String) -> Bool { classIDs.contains(ExactKey(id)) }
        func hasPerson(_ id: String) -> Bool { personIDs.contains(ExactKey(id)) }

        /// Each adds one not held yet; false when its ID is held already (the first is kept).
        mutating func add(school: School) -> Bool {
            guard schoolIDs.insert(ExactKey(school.id)).inserted else { return false }
            snapshot.schools.append(school)
            return true
        }

        mutating func add(term: Term) -> Bool {
            guard termIDs.insert(ExactKey(term.id)).inserted else { return false }
            snapshot.terms.append(term)
            return true
        }

        mutating func add(course: Course) -> Bool {
            guard courseIDs.insert(ExactKey(course.id)).inserted else { return false }
            snapshot.courses.append(course)
            return true
        }

        mutating func add(class item: Class) -> Bool {
            guard classIDs.insert(ExactKey(item.id)).inserted else { return false }
            snapshot.classes.append(item)
            return true
        }

        mutating func add(person: Person) -> Bool {
            guard personIDs.insert(ExactKey(person.id)).inserted else { return false }
            snapshot.people.append(person)
            return true
        }

        mutating func enroll(_ enrollment: Enrollment) { snapshot.enrollments.append(enrollment) }
    }

    /// Each kind's cause and fix, in the SIS team's words (GamGUI's `ISSUE_WORDS`).
    public static let issueWords: [String: (cause: String, fix: String)] = [
        "skipped": ("Marked to be deleted in the export, so left out.", "Nothing to do, unless it should still be there."),
        "no_id": ("A row has no ID.", "Every row needs the SIS's ID for it (sourcedId, or the file's _id column)."),
        "duplicate_id": ("Two rows share one ID; the first is kept.", "Each ID must be unique in its file."),
        "no_email": ("A teacher or student has no email address.",
                     "Give them their Google Workspace address in the export's email column."),
        "bad_email": ("An email address isn't one address.", "Fix the email column: one plain address, no spaces."),
        "duplicate_email": ("Two people share one email address; the first is kept.", "Each person needs their own address."),
        "unknown_class": ("An enrolment names a class that isn't in the export.", "Include the class, or drop the enrolment."),
        "unknown_person": ("An enrolment names a person who isn't in the export (or has no address).",
                           "Include the person with their address, or drop the enrolment."),
        "role_mismatch": ("An enrolment's role isn't a role the person has in the export.", "Make the roles agree."),
        "unknown_course": ("A class names a course that isn't in the export.", "Include the course."),
        "unknown_school": ("A class names a school that isn't in the export.", "Include the school."),
        "unknown_term": ("A class names a term that isn't in the export.", "Include the term."),
        "no_title": ("A class or course has no title.", "Give it a title; it becomes the class's name in Classroom."),
        "conflict": ("Rows for one ID disagree (a name, a title or an address); the first is kept.", "Make the rows agree."),
        "duplicate_row": ("The same person is listed in the same class twice; the first is kept.",
                          "Nothing to do, unless the two rows should differ."),
        "unknown_role": ("A row's role isn't one of the words the column map gives for a teacher or a student.",
                         "Add the word to the map, or fix the role in the spreadsheet."),
    ]
}
