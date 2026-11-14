import CryptoKit
import Foundation
import GamEngine

/// Compare a kept SIS roster with Classroom into one change list (plan 2026-11-11 C3; GamGUI's `core/roster_plan.py` at
/// 07c505d, held to `Tests/Fixtures/roster_plan.json`).
///
/// Pure: a snapshot (what the SIS says) and the Classroom classes as read (`Classroom.Managed`) go in, a `ChangeList` comes
/// out. No GAM call, nothing written. The app never applies it: the change list is handed over as files GAM runs outside the
/// app (`RosterHandover`, C4).
///
/// **Which classes are the app's to plan.** A SIS class is tied to one Classroom class by a domain alias, `d:gg-<sourcedId>`
/// (`alias(for:)`): the SIS's own ID when it's plain, a hash of it otherwise. Only classes carrying one of these aliases are
/// compared, updated or archived; a class someone made by hand in Classroom is never touched, only counted.
///
/// **Risk.** Removals and archives past a built-in count *and* share are flagged with the reason in a sentence; a flagged
/// kind is left out of the hand-over unless ticked (C4). Thresholds are fixed defaults, not a settings table (C3.3).
///
/// Text is compared, hashed and sorted by its exact code points, as Python's `str` is (`ExactKey`): a Swift `String` would
/// take "é" and "e" + U+0301 for one address.
public enum RosterPlan {
    /// The kinds of change, in the order GAM must run them, each with the words the screen names it by (GamGUI's `KINDS`).
    public enum Kind: String, CaseIterable, Sendable, Hashable, Identifiable {
        case create
        case rename
        case addTeacher = "add_teacher"
        case addStudent = "add_student"
        case owner
        case removeTeacher = "remove_teacher"
        case removeStudent = "remove_student"
        case archive

        public var id: String { rawValue }

        public var words: String {
            switch self {
            case .create: "Classes to create"
            case .rename: "Classes to rename"
            case .addTeacher: "Teachers to add"
            case .addStudent: "Students to add"
            case .owner: "Owners to change"
            case .removeTeacher: "Teachers to remove"
            case .removeStudent: "Students to remove"
            case .archive: "Classes to archive"
            }
        }

        public var isDestructive: Bool { self == .removeTeacher || self == .removeStudent || self == .archive }

        /// Its place in the run order.
        var order: Double { Double(Self.allCases.firstIndex(of: self) ?? 0) }
    }

    /// A destructive kind is flagged past both: a count, and a share of what's there now (people enrolled in the classes
    /// the app manages, or those classes).
    public struct Limit: Sendable, Equatable {
        public let count: Int
        public let share: Double

        public init(count: Int, share: Double) {
            self.count = count
            self.share = share
        }
    }

    /// GamGUI's `LIMITS`, in its order (the order flags are said in).
    public static let limits: [(kind: Kind, limit: Limit)] = [
        (.removeTeacher, Limit(count: 25, share: 0.05)),
        (.removeStudent, Limit(count: 500, share: 0.05)),
        (.archive, Limit(count: 25, share: 0.10)),
    ]

    /// The prefix of the app's aliases.
    public static let aliasPrefix = "gg-"

    public struct Change: Sendable, Equatable, Hashable {
        public let kind: Kind
        /// The class, by its alias (GAM takes `d:…` as a course ID).
        public let alias: String
        /// The class as the screen names it.
        public let title: String
        /// The address added or removed, or the new owner.
        public var person = ""
        /// What Classroom has now (a name, an owner).
        public var before = ""
        /// What the SIS says.
        public var after = ""
        /// Classroom's ID, when the class exists.
        public var courseID = ""
        /// A removal that must run before the adds: the person changes role in this class (teacher ↔ student), and
        /// Classroom refuses to add someone already in it, so add-then-remove would leave them out of the class altogether.
        public var swap = false
        /// A student add that must wait for the teacher removals: the class's outgoing owner becomes a student, and
        /// Classroom won't remove an owner until the owner change has run.
        public var late = false
        /// A create's or rename's new name and section, as their own fields (a name may hold " · ").
        public var name = ""
        public var section = ""

        public init(_ kind: Kind, _ alias: String, _ title: String, person: String = "", before: String = "", after: String = "",
                    courseID: String = "", swap: Bool = false, late: Bool = false, name: String = "", section: String = "") {
            self.kind = kind
            self.alias = alias
            self.title = title
            self.person = person
            self.before = before
            self.after = after
            self.courseID = courseID
            self.swap = swap
            self.late = late
            self.name = name
            self.section = section
        }
    }

    /// A kind held back by the risk check, and why, in a sentence.
    public struct Flag: Sendable, Equatable {
        public let kind: Kind
        public let why: String
    }

    public struct ChangeList: Sendable, Equatable {
        /// In run order.
        public var changes: [Change] = []
        public var counts: [Kind: Int] = [:]
        /// In `limits`' order.
        public var flags: [Flag] = []
        /// What can't be planned, said once each kind.
        public var notes: [String] = []
        /// Classroom classes the app manages.
        public var managed = 0
        /// People in them now.
        public var enrolled = 0
        /// Classroom classes without the app's alias: left alone.
        public var unmanagedIgnored = 0
        /// A class couldn't be read: never handed over.
        public var incomplete = false

        public init(changes: [Change] = []) {
            self.changes = changes
            for change in changes { counts[change.kind, default: 0] += 1 }
        }

        public func count(_ kind: Kind) -> Int { counts[kind] ?? 0 }

        public func flag(_ kind: Kind) -> String? { flags.first { $0.kind == kind }?.why }

        /// The size in one sentence, destructive parts first (C3.2), GamGUI's words.
        public var summary: String {
            let removed = count(.removeTeacher) + count(.removeStudent)
            let added = count(.addTeacher) + count(.addStudent)
            let destructive = [("archive", count(.archive), "class", "classes"), ("remove", removed, "person", "people")]
                .filter { $0.1 != 0 }.map { "\($0.0) \(plural($0.1, $0.2, $0.3))" }
            let rest = [("create", count(.create), "class", "classes"), ("add", added, "person", "people"),
                        ("rename", count(.rename), "class", "classes"), ("change the owner of", count(.owner), "class", "classes")]
                .filter { $0.1 != 0 }.map { "\($0.0) \(plural($0.1, $0.2, $0.3))" }
            if destructive.isEmpty, rest.isEmpty {
                if incomplete { return "Nothing could be planned: part of Classroom couldn't be read. Compare again." }
                if !notes.isEmpty { return "Nothing GamGUI can plan; the notes below need attention." }
                return "Classroom already matches the roster: nothing to change."
            }
            func listed(_ items: [String]) -> String {
                items.count == 1 ? items[0] : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
            }
            return "Would " + [destructive, rest].filter { !$0.isEmpty }.map(listed).joined(separator: "; would ") + "."
        }
    }

    // MARK: the alias

    /// The domain alias that ties a SIS class to its Classroom class: `d:gg-<id>`, the SIS's ID when it's plain (so the SIS
    /// team can read it), else `h` and the first 24 hex digits of its UTF-8's SHA-256 (an alias is one GAM argument and
    /// Classroom limits its characters).
    public static func alias(for sourceID: String) -> String {
        let scalars = sourceID.unicodeScalars
        let plain = (1...80).contains(scalars.count) && scalars.allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || "._-".unicodeScalars.contains(scalar)
        }
        if plain { return "d:\(aliasPrefix)\(sourceID)" }
        let digest = SHA256.hash(data: Array(sourceID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "d:\(aliasPrefix)h\(digest.prefix(24))"
    }

    /// The app's alias among a class's aliases, as `d:gg-…` (GAM may print it with or without the `d:` scope).
    static func managedAlias(_ aliases: [String]) -> String? {
        for alias in aliases {
            let bare = alias.hasPrefix("d:") ? String(alias.unicodeScalars.dropFirst(2)) : alias
            if bare.unicodeScalars.starts(with: aliasPrefix.unicodeScalars) { return "d:" + bare }
        }
        return nil
    }

    // MARK: the plan

    /// The change list that would make Classroom match `snapshot`. `directory` is the domain's addresses (lowercased), read
    /// fresh, when known: a SIS person who isn't a Workspace account can't be *added*, and is noted instead. It never causes
    /// a removal: someone the SIS lists is never removed from a class because the directory didn't name them. `unread` is
    /// how many Classroom classes couldn't be read whole: any makes the list incomplete.
    public static func plan(_ snapshot: RosterSnapshot, classroom: [Classroom.Managed], directory: [String]? = nil, unread: Int = 0,
                            limits: [(kind: Kind, limit: Limit)] = RosterPlan.limits) -> ChangeList {
        var out = ChangeList()
        var byAlias: [ExactKey: Classroom.Managed] = [:]
        var unmanaged: [[ExactKey]: Int] = [:]
        for managed in classroom {
            guard let alias = managedAlias(managed.aliases) else {
                out.unmanagedIgnored += 1
                unmanaged[[ExactKey(lowered(managed.course.name)), ExactKey(lowered(managed.course.section))], default: 0] += 1
                continue
            }
            if byAlias[ExactKey(alias)] == nil { byAlias[ExactKey(alias)] = managed }
        }
        out.managed = byAlias.count
        out.enrolled = byAlias.values.reduce(0) { $0 + $1.teachers.count + $1.students.count }

        var people: [ExactKey: RosterSnapshot.Person] = [:]
        for person in snapshot.people where people[ExactKey(person.id)] == nil { people[ExactKey(person.id)] = person }
        var terms: [ExactKey: String] = [:]
        for term in snapshot.terms where terms[ExactKey(term.id)] == nil { terms[ExactKey(term.id)] = term.title }
        // Each class's teachers and students from the SIS, as (address, primary), in the export's order.
        var roster: [ExactKey: (teachers: [(String, Bool)], students: [(String, Bool)])] = [:]
        for enrollment in snapshot.enrollments {
            guard let person = people[ExactKey(enrollment.personID)] else { continue }
            let key = ExactKey(enrollment.classID)
            var members = roster[key] ?? ([], [])
            switch enrollment.role {
            case "teacher": members.teachers.append((person.email, enrollment.primary))
            case "student": members.students.append((person.email, enrollment.primary))
            default: continue
            }
            roster[key] = members
        }
        let known = directory.map { Set($0.map(ExactKey.init)) }
        func addable(_ email: ExactKey) -> Bool { known?.contains(email) ?? true }

        var noTeacher = 0, noAccountTeacher = 0, archivedWanted = 0, maybeExisting = 0, ownerUnread = 0, staysTeacher = 0
        var notAccounts: Set<ExactKey> = []
        var wanted: Set<ExactKey> = []
        var classes: [ExactKey: RosterSnapshot.Class] = [:]
        for item in snapshot.classes where classes[ExactKey(item.id)] == nil { classes[ExactKey(item.id)] = item }
        for classKey in classes.keys.sorted() {
            let item = classes[classKey]!
            let classID = item.id
            let alias = Self.alias(for: classID)
            wanted.insert(ExactKey(alias))
            let members = roster[classKey] ?? ([], [])
            // Who the SIS has: what a removal is measured against, whatever the directory says.
            let sisTeachers = Set(members.teachers.map { ExactKey($0.0) })
            let sisStudents = Set(members.students.map { ExactKey($0.0) }).subtracting(sisTeachers)
            // Who can be added: a Workspace account, when the directory is known.
            notAccounts.formUnion(sisTeachers.union(sisStudents).filter { !addable($0) })
            let teacherRows = members.teachers.filter { addable(ExactKey($0.0)) }
            let teachers = Set(teacherRows.map { ExactKey($0.0) }).sorted()
            let students = sisStudents.filter(addable).sorted()
            let owner = ownerOf(teacherRows)
            let section = item.termIDs.first.flatMap { terms[ExactKey($0)] } ?? ""
            let title = item.title.isEmpty ? classID : item.title
            guard let current = byAlias[ExactKey(alias)] else {
                guard let owner else {
                    if sisTeachers.isEmpty { noTeacher += 1 } else { noAccountTeacher += 1 }
                    continue
                }
                if unmanaged[[ExactKey(lowered(title)), ExactKey(lowered(section))], default: 0] > 0 {
                    // Classroom has a class by this name and section without the app's alias. GAM prints [] for a class
                    // whose alias read failed (it swallows the error, exit 0), so this may be the class itself: never a
                    // duplicate.
                    maybeExisting += 1
                    continue
                }
                out.changes.append(Change(.create, alias, title, person: owner, after: joined(title, section), name: title,
                                          section: section))
                out.changes += teachers.filter { $0 != ExactKey(owner) }.map { Change(.addTeacher, alias, title, person: $0.text) }
                out.changes += students.map { Change(.addStudent, alias, title, person: $0.text) }
                continue
            }
            let course = current.course
            if course.state == "ARCHIVED" {     // the SIS still has it: reactivating is Classroom's to do, never planned here
                archivedWanted += 1
                continue
            }
            if ExactKey(course.name) != ExactKey(title) || ExactKey(course.section) != ExactKey(section) {
                out.changes.append(Change(.rename, alias, title, before: joined(course.name, course.section),
                                          after: joined(title, section), courseID: course.id, name: title, section: section))
            }
            let haveTeachers = Set(current.teachers.map(ExactKey.init)), haveStudents = Set(current.students.map(ExactKey.init))
            let courseOwner = ExactKey(course.ownerEmail)
            var goneTeachers: Set<ExactKey> = []
            if course.ownerEmail.isEmpty {
                // The owner's address wasn't read: an owner change can't be planned, and a teacher removal might be the owner.
                ownerUnread += 1
            } else {
                let handedOn = owner.map { !$0.isEmpty && ExactKey($0) != courseOwner } ?? false
                if handedOn, let owner {
                    out.changes.append(Change(.owner, alias, title, person: owner, before: course.ownerEmail, after: owner,
                                              courseID: course.id))
                }
                // The owner stays unless the owner change above hands the class on: then the former one goes, after it.
                let keep: ExactKey = handedOn ? ExactKey(owner!) : courseOwner
                goneTeachers = haveTeachers.subtracting(sisTeachers).subtracting([keep])
            }
            let studentSet = Set(students), teacherSet = Set(teachers)
            // A teacher who becomes a student is removed before the adds (a swap), except the outgoing owner: Classroom won't
            // remove an owner, so that removal waits for the owner change and their student add waits for it (`late`).
            out.changes += goneTeachers.sorted().map {
                Change(.removeTeacher, alias, title, person: $0.text, courseID: course.id,
                       swap: studentSet.contains($0) && $0 != courseOwner)
            }
            out.changes += teachers.filter { !haveTeachers.contains($0) }
                .map { Change(.addTeacher, alias, title, person: $0.text, courseID: course.id) }
            for student in students where !haveStudents.contains(student) {
                if haveTeachers.contains(student), !goneTeachers.contains(student) {
                    staysTeacher += 1        // still a teacher here (the owner, or their removal can't be planned)
                    continue
                }
                out.changes.append(Change(.addStudent, alias, title, person: student.text, courseID: course.id,
                                          late: student == courseOwner))
            }
            out.changes += haveStudents.subtracting(sisStudents).sorted().map {
                Change(.removeStudent, alias, title, person: $0.text, courseID: course.id, swap: teacherSet.contains($0))
            }
        }
        for alias in byAlias.keys.sorted() where !wanted.contains(alias) {
            let course = byAlias[alias]!.course
            guard course.state != "ARCHIVED" else { continue }
            out.changes.append(Change(.archive, alias.text, course.name.isEmpty ? course.id : course.name, before: course.stateWords,
                                      courseID: course.id))
        }

        // Run order: a role swap's removal first (Classroom refuses to add someone already in the class), then the kinds in
        // order; an outgoing owner's student add (`late`) after the teacher removals. Python's sort is stable: the position
        // breaks a tie.
        func rank(_ change: Change) -> Double {
            change.swap ? -1 : change.late ? Kind.removeTeacher.order + 0.5 : change.kind.order
        }
        out.changes = out.changes.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            for (p, q) in [(lowered(x.title, strip: false), lowered(y.title, strip: false)), (x.alias, y.alias), (x.person, y.person)]
                where ExactKey(p) != ExactKey(q) {
                return ExactKey(p) < ExactKey(q)
            }
            return a.offset < b.offset
        }.map(\.element)
        for change in out.changes { out.counts[change.kind, default: 0] += 1 }

        if noTeacher > 0 {
            out.notes.append("\(plural(noTeacher, "SIS class has", "SIS classes have")) no teacher, so "
                + "\(noTeacher == 1 ? "it" : "they") can't be created: Classroom needs an owner. Add a teacher in the SIS.")
        }
        if noAccountTeacher > 0 {
            out.notes.append("\(plural(noAccountTeacher, "SIS class", "SIS classes")) can't be created: no teacher of "
                + "\(noAccountTeacher == 1 ? "it" : "theirs") has a Google Workspace account here.")
        }
        if !notAccounts.isEmpty {
            let n = notAccounts.count
            out.notes.append("\(plural(n, "person", "people")) in the roster \(n == 1 ? "has" : "have") no Google Workspace "
                + "account here, so they aren't added (nor removed). Check their addresses in users.csv, or create their accounts.")
        }
        if maybeExisting > 0 {
            out.notes.append("\(plural(maybeExisting, "SIS class matches", "SIS classes match")) a Classroom class by name "
                + "and section that doesn't carry GamGUI's alias (or whose aliases couldn't be read), so nothing is "
                + "planned for them rather than a second copy. Check them in Classroom.")
        }
        if staysTeacher > 0 {
            out.notes.append("\(plural(staysTeacher, "person is a student", "people are students")) in the SIS but still "
                + "\(staysTeacher == 1 ? "a teacher" : "teachers") in Classroom (the class's owner, or in a class "
                + "whose owner couldn't be read), so they aren't added as students there. Change the owner in the "
                + "SIS or in Classroom first.")
        }
        if ownerUnread > 0 {
            out.notes.append("\(plural(ownerUnread, "class", "classes"))' owner couldn't be read, so no teacher is removed from "
                + "\(ownerUnread == 1 ? "it" : "them") and no owner change is planned.")
        }
        if archivedWanted > 0 {
            let it = archivedWanted == 1 ? "it" : "them"
            out.notes.append("\(plural(archivedWanted, "class", "classes")) the SIS still has "
                + "\(archivedWanted == 1 ? "is" : "are") archived in Classroom, so nothing is planned for \(it). "
                + "Restore \(it) in Classroom if the SIS is right.")
        }
        if unread > 0 {
            out.incomplete = true
            out.notes.insert("\(plural(unread, "Classroom class", "Classroom classes")) couldn't be read whole, so this "
                             + "change list may be incomplete and isn't handed over. Compare again.", at: 0)
        }
        out.flags = flags(out, limits)
        return out
    }

    /// The note the compare adds when the directory couldn't be read (GamGUI's route).
    public static let directoryUnread = "The directory couldn't be read, so addresses weren't checked against Workspace accounts."

    /// Each destructive kind past both its count and its share of what's there now, with why, in a sentence.
    static func flags(_ out: ChangeList, _ limits: [(kind: Kind, limit: Limit)]) -> [Flag] {
        limits.compactMap { kind, limit in
            let n = out.count(kind)
            let base = kind == .archive ? out.managed : out.enrolled
            guard n > limit.count, base > 0, Double(n) / Double(base) > limit.share else { return nil }
            let what = kind == .archive ? "archive" : "remove"
            let noun = kind == .archive ? "classes" : kind == .removeTeacher ? "teachers" : "students"
            let whole = kind == .archive ? "of the classes GamGUI manages" : "of the people in them"
            let share = String(format: "%.1f%%", Double(n) / Double(base) * 100)
            let held = String(format: "%.0f%%", limit.share * 100)
            return Flag(kind: kind, why: "Would \(what) \(grouped(n)) \(noun), \(share) \(whole) (held back past "
                        + "\(grouped(limit.count)) and \(held)). Check the export is complete before including it.")
        }
    }

    // MARK: the list on the screen

    /// Changes shown per page (GamGUI's `CHANGES_PAGE`).
    public static let pageSize = 50

    /// One page of the change list: the changes of one kind (or all), whose class, alias or person holds the query.
    public struct Page: Sendable, Equatable {
        public let rows: [Change]
        public let total: Int
        public let page: Int
        public let pages: Int
        /// The first row's position in the whole match, from 0.
        public let start: Int
    }

    /// GamGUI's `_changes_ctx`: by kind, then the query stripped and lowercased against the class's title and alias
    /// (lowercased) and the person (as written, lowercase already), by code point; the page clamped to what there is.
    /// `haystack`, made once per list, spares lowering every change again on each keystroke; the answer is the same.
    public static func page(_ list: ChangeList, kind: Kind?, query: String, page: Int = 1, size: Int = pageSize,
                            haystack: Haystack? = nil) -> Page {
        let hay = haystack.flatMap { $0.texts.count == list.changes.count ? $0.texts : nil }
        let needle = Array(lowered(query).unicodeScalars)
        func holds(_ hay: [Unicode.Scalar]) -> Bool {
            guard hay.count >= needle.count else { return false }
            return (0...(hay.count - needle.count)).contains { hay[$0..<($0 + needle.count)].elementsEqual(needle) }
        }
        var rows: [Change] = []
        for (index, change) in list.changes.enumerated() where kind == nil || change.kind == kind {
            if !needle.isEmpty, !(hay?[index] ?? Haystack.texts(change)).contains(where: holds) { continue }
            rows.append(change)
        }
        let pages = max(1, (rows.count + size - 1) / size)
        let page = min(max(1, page), pages)
        let start = (page - 1) * size
        return Page(rows: Array(rows.dropFirst(start).prefix(size)), total: rows.count, page: page, pages: pages, start: start)
    }

    /// Each change's searched text, lowered once: its class's title and alias (lowercased) and the person (as written).
    public struct Haystack: Sendable {
        let texts: [[[Unicode.Scalar]]]

        public init(_ list: ChangeList) { texts = list.changes.map(Self.texts) }

        static func texts(_ change: Change) -> [[Unicode.Scalar]] {
            [Array(lowered(change.title, strip: false).unicodeScalars), Array(change.person.unicodeScalars),
             Array(lowered(change.alias, strip: false).unicodeScalars)]
        }
    }

    // MARK: helpers

    /// The SIS's primary teacher's address, else the first teacher's by address (code point).
    static func ownerOf(_ teachers: [(String, Bool)]) -> String? {
        if let primary = teachers.filter({ $0.1 }).map({ ExactKey($0.0) }).min() { return primary.text }
        return teachers.map { ExactKey($0.0) }.min()?.text
    }

    /// `f"{a} · {b}".rstrip(" ·")`.
    static func joined(_ a: String, _ b: String) -> String {
        PythonText.rstrip("\(a) · \(b)", of: [0x20, 0xB7])
    }

    /// `text.strip().lower()`, or `text.lower()`.
    static func lowered(_ text: String, strip: Bool = true) -> String {
        PythonText.lower(strip ? PythonText.strip(text) : text)
    }

    /// `f"{n:,}"`.
    public static func grouped(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (i, digit) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return n < 0 ? "-" + out : out
    }

    static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(grouped(n)) \(n == 1 ? one : many)"
    }
}
