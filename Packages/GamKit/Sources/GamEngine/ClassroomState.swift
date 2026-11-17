import Foundation

/// Every Classroom class with its aliases and its people, for the roster compare (plan 2026-11-11 C3; GamGUI's
/// `roster_plan.managed_from` and `GAMConnector.classroom_state` at 07c505d). Two GAM reads, each a shape read from the
/// 7.51.00 build: `print courses states active,provisioned,archived owneremail aliases … formatjson` (a `JSON-aliases`
/// column after `JSON`) and `print course-participants states … show all formatjson` (one row per class). Archived classes
/// are read so a GamGUI class Classroom archived is never planned as new. Read only.
extension Classroom {
    /// The states the compare reads, GamGUI's order.
    public static let compareStates: [GamCommands.CourseState] = [.active, .provisioned, .archived]

    /// A Classroom class as read: the class, its aliases, and who is in it (addresses, lowercased, sorted by code point).
    public struct Managed: Sendable, Equatable {
        public let course: Course
        public let aliases: [String]
        public let teachers: [String]
        public let students: [String]

        public init(course: Course, aliases: [String], teachers: [String], students: [String]) {
            self.course = course
            self.aliases = aliases
            self.teachers = teachers
            self.students = students
        }

        /// GamGUI's `Managed.from_read`: the people with an address, each side sorted.
        public init(course: Course, aliases: [String], roster: Roster) {
            func sorted(_ people: [Participant]) -> [String] {
                people.map(\.email).filter { !$0.isEmpty }.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            }
            self.init(course: course, aliases: aliases, teachers: sorted(roster.teachers), students: sorted(roster.students))
        }
    }

    /// What the two reads found: every class read whole, and the IDs of the classes whose aliases or roster couldn't be
    /// (never compared as if empty: any of them makes the change list incomplete).
    public struct State: Sendable, Equatable {
        public let classes: [Managed]
        public let unread: [String]

        public init(classes: [Managed], unread: [String]) {
            self.classes = classes
            self.unread = unread
        }
    }

    /// GamGUI's `managed_from`: the classes from the course read, in its order (each record as read, none merged), paired by
    /// course ID with the participants read (a later row for an ID replaces an earlier one). A class whose aliases can't be
    /// read, whose row is missing, or whose roster is unreadable or hides an address is unread.
    public static func state(courses: [GamOutput.Record], participants: [GamOutput.Record]) -> State {
        var rosters: [String: Roster] = [:]
        for record in participants {
            let courseID = text(record["courseId"])
            if !courseID.isEmpty { rosters[courseID] = roster([record], courseID: courseID) }
        }
        var classes: [Managed] = [], unread: [String] = []
        for record in courses {
            guard let course = Course(record: record) else { continue }
            guard let aliases = aliases(record["JSON-aliases"]), let roster = rosters[course.id],
                  roster.unreadable.isEmpty, !roster.emailsHidden else {
                unread.append(course.id)
                continue
            }
            classes.append(Managed(course: course, aliases: aliases, roster: roster))
        }
        return State(classes: classes, unread: unread)
    }

    /// A class's aliases from its `JSON-aliases` cell, or nil when the cell can't be read (GamGUI's `_aliases`). GAM dumps the
    /// Classroom API's items as they come, each an object, `[{"alias": "d:gg-C1"}]` (doPrintCourses' formatjson branch, the
    /// 7.51.00 build): reading them as strings once made every GamGUI class look hand-made, and the mock had agreed. A bare
    /// string item is read too; any other item makes the cell unread, never an alias. No cell (GAM prints none for a class
    /// whose alias read it swallowed) is no alias.
    static func aliases(_ cell: JSONValue?) -> [String]? {
        guard case .string(let raw)? = cell, !raw.isEmpty else { return [] }
        guard let items = JSONValue.parse(raw)?.array else { return nil }
        var out: [String] = []
        for item in items {
            let value: JSONValue? = item.object == nil ? item : item.object?["alias"]
            guard case .string(let alias)? = value, !alias.isEmpty else { return nil }
            out.append(alias)
        }
        return out
    }
}
