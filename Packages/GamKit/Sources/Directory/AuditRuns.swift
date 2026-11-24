import Foundation
import GamEngine

/// Audit runs (plan F3, GamGUI #171's and #172's `core/audit_runs.py`): ready-made lists of reads, started by the operator, with Stop
/// between steps. Pure: what each run reads and what its tables say. `AuditRunner` runs each step's read and leaves its read
/// record (origin `audit_run`); a run never writes. Inactive users' Suspend these… is a write of its own (`InactiveSuspend`),
/// which reads the directory again. Held to GamGUI's by `Tests/Fixtures/audit_runs.json` (`AuditRunsTests`).
///
/// A step that failed, stopped short or never ran is unknown, never "none" (invariant 10), and so is every table built on it.
/// A step that read nothing where something must be (no account, no seat) is unknown too.
///
/// Google's fields each join or flag reads, from Google's reference:
/// - Directory `users` (developers.google.com/workspace/admin/directory/reference/rest/v1/users): `primaryEmail` "The user's
///   primary email address."; `suspended` "Indicates if user is suspended."; `lastLoginTime` "The last time the user logged
///   into the user's account."; `creationTime` "The time the user's account was created."; `isAdmin` "Indicates a user with
///   super administrator privileges."; `isDelegatedAdmin` "Indicates if the user is a delegated administrator." GAM prints a
///   time as YYYY-MM-DDThh:mm:ssZ and Google's never (1970-01-01T00:00:00.000Z) as `Never` (formatLocalTime, NEVER_TIME, the
///   7.52.04 tag).
/// - Licensing `licenseAssignments` (developers.google.com/workspace/admin/licensing/reference/rest/v1/licenseAssignments):
///   `userId` "The user's current primary email address." (GAM lowercases it); `productId`, `skuId` the product's and SKU's
///   identifiers. GAM adds `productDisplay` and `skuDisplay` from its own table, the ID itself for one it doesn't know.
/// - Drive `permissions` (developers.google.com/workspace/drive/api/reference/rest/v3/permissions): `type` "The type of the
///   grantee."; `role` (organizer, fileOrganizer, writer, commenter, reader); `emailAddress` "The email address of the user or
///   group to which this permission refers."; `domain` "The domain to which this permission refers." (GAM also sets it from
///   emailAddress, _mapDrivePermissionNames); `deleted`. A shared drive's own permissions are its members: Google's sharing
///   guide (…/drive/api/guides/manage-sharing, the Membership row) says "Applies to `user` or `group` only (not domains)".
/// - Classroom `courses` (developers.google.com/workspace/classroom/reference/rest/v1/courses): `ownerId` "The identifier of
///   the owner of a course." (joined to the directory's `id`, "The unique ID for the user."); `courseState` ACTIVE, ARCHIVED,
///   PROVISIONED, DECLINED, SUSPENDED; `updateTime` "Time of the most recent update to this course." GAM adds `teachers` and
///   `students` counts with `show all countsonly`, and counts a roster it couldn't read as 0.
/// - Directory `roleAssignments` (…/admin/directory/reference/rest/v1/roleAssignments): `assignedTo` "The unique ID of the
///   entity this role is assigned to"; GAM adds `assignedToUser`, `assignedToGroup`, `assignedToUnknown` and `role`. Directory
///   `tokens` (…/tokens): `clientId`; `displayText` "The displayable name of the application the token is issued to.";
///   `scopes` "A list of authorization scopes the application is granted." (GAM joins them with spaces).
public enum AuditRuns {
    /// Rows a finished table draws; its count and its CSV are the whole of it (invariant 9).
    public static let rowsShown = 100
    /// The inactive run's window choices, in days.
    public static let windows = [30, 60, 90, 180, 365]

    /// One read of a run.
    public struct Step: Sendable, Hashable, Identifiable {
        public let key: String
        /// What the step reads, as the run's progress names it.
        public let title: String
        /// The column the step's joins read: output without it isn't the table asked for.
        public let keyColumn: String
        /// The exits that are the step's whole answer (60 is GAM's "none", the titles written).
        public let okCodes: [Int32]
        /// The exits whose rows stand, with accounts GAM named as unread (entityUnknownWarning).
        public let partialCodes: [Int32]
        /// The exits at which no row at all is an answer (GAM's own "none"); nil: any of `okCodes`. GamGUI #176's `empty_rcs`.
        public let emptyCodes: [Int32]?
        public var id: String { key }

        init(key: String, title: String, keyColumn: String, okCodes: [Int32] = [0], partialCodes: [Int32] = [],
             emptyCodes: [Int32]? = nil) {
            self.key = key
            self.title = title
            self.keyColumn = keyColumn
            self.okCodes = okCodes
            self.partialCodes = partialCodes
            self.emptyCodes = emptyCodes
        }
    }

    /// GAM's own "none", the titles written (NO_ENTITIES_FOUND_RC: no shared drive at all).
    public static let noEntitiesFound: Int32 = 60
    /// entityUnknownWarning: an account GAM couldn't read, in the domain (56) or outside it (73).
    public static let accountWarnings: [Int32] = [56, 73]

    /// A fixed list of reads.
    public struct Run: Sendable, Hashable, Identifiable {
        public let key: String
        public let title: String
        public let what: String
        public let steps: [Step]
        public var id: String { key }

        /// What a step's read record names as its `command`: the run and the step, e.g. `license_usage/licenses`.
        public func command(_ step: Step) -> String { "\(key)/\(step.key)" }
    }

    public static let directory = Step(key: "directory", title: "The directory, suspended accounts included", keyColumn: "primaryEmail")
    public static let licenses = Step(key: "licenses", title: "Every license seat", keyColumn: "userId")
    // No row is "no drive" only with GAM's 60: a service-account token Google refuses silently (REFRESH_PERM_ERRORS) makes both
    // reads skip the admin, titles alone, exit 0 (buildGAPIServiceObject -> handleOAuthTokenError, then `continue` before the
    // none check, printShowSharedDrives / printShowSharedDriveACLs at the 7.52.04 tag; GamGUI #176).
    public static let drives = Step(key: "drives", title: "Every shared drive", keyColumn: "id", okCodes: [0, noEntitiesFound],
                                    emptyCodes: [noEntitiesFound])
    public static let driveACLs = Step(key: "drive_acls", title: "Every shared drive's members", keyColumn: "id",
                                       okCodes: [0, noEntitiesFound], emptyCodes: [noEntitiesFound])
    public static let domains = Step(key: "domains", title: "The domain's own domains and aliases", keyColumn: "domainName")
    public static let courses = Step(key: "courses", title: "Every Classroom class, with its counts", keyColumn: "id")
    public static let admins = Step(key: "admins", title: "Every admin role, a group's members included", keyColumn: "roleAssignmentId")
    public static let adminTokens = Step(key: "admin_tokens", title: "Each admin's connected apps, suspended admins included",
                                         keyColumn: "user", partialCodes: accountWarnings)

    public static let inactiveUsers = Run(
        key: "inactive_users", title: "Inactive users",
        what: "Active accounts with no sign-in inside a window you pick; accounts made inside it are flagged.", steps: [directory])
    public static let sharedDrives = Run(
        key: "shared_drive_permissions", title: "Shared drive permissions",
        what: "Every shared drive's members, outside members first, and drives no active organizer looks after.",
        steps: [drives, driveACLs, domains, directory])
    public static let licenseUsage = Run(
        key: "license_usage", title: "License usage",
        what: "Every license seat against the directory: seats per license, and seats on suspended accounts.",
        steps: [licenses, directory])
    public static let classroom = Run(
        key: "classroom_courses", title: "Classroom",
        what: "Every class with its owner, state and counts; classes owned by suspended accounts; stale classes.",
        steps: [courses, directory])
    public static let adminTokenReview = Run(
        key: "admin_tokens", title: "Admin token review",
        what: "Every admin's connected apps, suspended admins included, AI and broad access flagged.",
        steps: [admins, directory, adminTokens])
    /// Every run, in GamGUI's order.
    public static let all = [inactiveUsers, sharedDrives, licenseUsage, classroom, adminTokenReview]

    /// The GAM read a step runs, from its builder. The directory is the cache's own read (`cacheFields`, suspended accounts
    /// included); the seats are `print licenses` with no product named. The admins' apps are read for the people the admins
    /// step found, so nil when that step has no table: the step can't run, and is unknown.
    public static func read(_ step: Step, tables: Tables = Tables()) -> GamRead? {
        switch step.key {
        case licenses.key: return GamCommands.printLicenses()
        case drives.key: return GamCommands.printSharedDrives()
        case driveACLs.key: return GamCommands.printSharedDriveACLs()
        case domains.key: return GamCommands.printDomains()
        case courses.key: return try? GamCommands.printCourses(states: GamCommands.CourseState.allCases, ownerEmail: false, counts: true)
        case admins.key: return GamCommands.printAllAdmins()
        case adminTokens.key:
            let people = adminAddresses(tables.rows[admins.key] ?? [], users: tables.users)
            return people.isEmpty ? nil : try? GamCommands.printTokens(users: people)
        default: return GamCommands.printUsers(fields: GamCommands.cacheFields)
        }
    }

    // MARK: a step's read

    /// How a step ended, once the run is over.
    public enum State: String, Sendable {
        /// Its table is kept.
        case read
        /// GAM read all but some accounts it named (an account warning exit): its rows stand, and what it couldn't read is
        /// unknown, never "none".
        case partial
        /// It failed, or read nothing where something must be: why is said.
        case unknown
        /// A Stop came before it.
        case notRun = "not_run"
    }

    public struct StepRead: Sendable, Equatable {
        public let step: Step
        public let state: State
        /// Why it's unknown or not run, in words.
        public let why: String
        public let rows: Int
        /// GAM's own error, for a collapsed "GAM's error".
        public let detail: String
        /// Partial: the accounts GAM named as not read.
        public let unread: [String]

        public init(step: Step, state: State, why: String = "", rows: Int = 0, detail: String = "", unread: [String] = []) {
            self.step = step
            self.state = state
            self.why = why
            self.rows = rows
            self.detail = detail
            self.unread = unread
        }
    }

    /// Why GAM's output isn't the step's table: its titles (the first line, as `str.splitlines()` ends it, split at commas,
    /// each stripped) don't name the column the step joins on. GAM writes the titles even with no row, so a missing table is
    /// never "none" (invariant 10).
    public struct Incomplete: Error, Sendable, Equatable {
        public let reason: String
    }

    /// The records of a step's output, or why it isn't the step's table (GamGUI's `audit_read`, after GAM answered 0).
    public static func table(_ stdout: String, keyColumn: String) -> Result<[GamOutput.Record], Incomplete> {
        let text = PythonText.strip(stdout)
        let first = text.isEmpty ? "" : (PythonText.lines(text).first ?? "")
        let titles = first.unicodeScalars.split(separator: ",", omittingEmptySubsequences: false)
            .map { PythonText.strip(PythonText.string($0)) }
        guard titles.contains(where: { $0.utf8.elementsEqual(keyColumn.utf8) }) else {
            return .failure(Incomplete(reason: "GAM ended without writing the \(keyColumn) table"))
        }
        return .success(GamOutput.records(stdout))
    }

    /// How GAM's answer to a step's read failed: GAM's error (an exit that is neither the step's answer nor a partial one), or
    /// output that isn't the step's table, or a warning exit that names nobody.
    public enum Failure: Error, Sendable {
        case gam(GamError)
        case incomplete(Incomplete)
    }

    /// GamGUI's `audit_read` once GAM ended: an exit in `okCodes` is the whole answer, one in `partialCodes` keeps the rows and
    /// names who wasn't read (and one that names nobody is unknown whole: who wasn't read can't be told), any other is GAM's
    /// failure; and output whose titles don't name the step's key column is never "none". With `emptyCodes`, no row at all is
    /// an answer only at one of those exits (GAM's own "none"): a read that skipped silently writes the same titles alone.
    public static func answer(_ result: GamResult, step: Step, argv: [String]) -> Result<(records: [GamOutput.Record], unread: [String]), Failure> {
        let code = result.exitCode
        guard step.okCodes.contains(code) || step.partialCodes.contains(code) else {
            return .failure(.gam(GamError(exitCode: code, stderr: result.stderr, argv: argv, stdout: result.stdout)))
        }
        let records: [GamOutput.Record]
        switch table(result.stdout, keyColumn: step.keyColumn) {
        case .failure(let incomplete): return .failure(.incomplete(incomplete))
        case .success(let found): records = found
        }
        if records.isEmpty, let empty = step.emptyCodes, !empty.contains(code) {
            return .failure(.incomplete(Incomplete(reason: "\(noRowUnsaid) \(code), which isn't how it says there are none")))
        }
        guard step.partialCodes.contains(code) else { return .success((records, [])) }
        let unread = unreadAccounts(result.stderr)
        guard !unread.isEmpty else {
            return .failure(.incomplete(Incomplete(reason: "GAM exited \(code) without naming the account it couldn't read")))
        }
        return .success((records, unread))
    }

    /// The start of an `Incomplete`'s reason when GAM wrote no row at an exit that isn't its "none" (GamGUI's `NoRowUnsaid`).
    public static let noRowUnsaid = "GAM wrote no row and exited"

    /// The accounts GAM couldn't read and carried on past (entityUnknownWarning: "User: <u>, Does not exist (i/N)", or "…,
    /// Service not applicable" outside the domain), lowercased, each once in order: GamGUI's `_UNREAD_ACCOUNT`,
    /// `^\s*User: ([^,\s]+@[^,\s]+), (?:Does not exist|Service not applicable)` over each line.
    static func unreadAccounts(_ stderr: String) -> [String] {
        var found: [String] = [], seen: Set<String> = []
        for line in PythonText.splitLF(stderr) {
            var rest = Substring(line).unicodeScalars.drop { PythonText.isSpace($0) }
            guard rest.starts(with: "User: ".unicodeScalars) else { continue }
            rest = rest.dropFirst(6)
            let account = rest.prefix { $0 != "," && !PythonText.isSpace($0) }
            let after = rest.dropFirst(account.count)
            // `[^,\s]+@[^,\s]+`: an `@` with something on each side of it.
            guard account.dropFirst().dropLast().contains("@"),
                  after.starts(with: ", Does not exist".unicodeScalars) || after.starts(with: ", Service not applicable".unicodeScalars)
            else { continue }
            let address = PythonText.lower(PythonText.string(account))
            if seen.insert(address).inserted { found.append(address) }
        }
        return found
    }

    /// Whether `argv` is a read an audit run may run: a `print` read that never exports. GAM reads an argument lowercased with
    /// its underscores dropped (getArgument), so `to_drive` and `ToDrive` are `todrive`.
    public static func isAuditRead(_ argv: [String]) -> Bool {
        argv.first == "print" && !argv.contains { argument in
            PythonText.lower(argument).replacingOccurrences(of: "_", with: "").utf8.elementsEqual("todrive".utf8)
        }
    }

    /// Why a step that read no row at all can't be an answer, else "". A domain has at least one account, and that account
    /// holds a seat; GAM also passes over a product it can't read without a word, so no seat at all is unknown.
    public static func implausiblyEmpty(_ step: Step, rows: Int) -> String {
        guard rows == 0 else { return "" }
        switch step.key {
        case directory.key: return "GAM listed no account at all, and a domain always has one, so the directory is unknown."
        case licenses.key:
            return "GAM listed no license seat at all. It passes over a product Google won't let it read without saying so, "
                + "so the seats are unknown, not none. Check that the admin token holds the License Manager scope (Setup)."
        case domains.key: return "GAM listed no domain at all, and a Workspace has at least one, so its domains are unknown."
        case admins.key:
            return "GAM listed no admin role at all, and a Workspace always has a super admin, so its admins are unknown."
        default: return ""
        }
    }

    /// Why a table needing `needed` is unknown, in words, or "" when every one was read (a partial read counts: what it
    /// couldn't read is said where it's shown).
    public static func unknownBecause(_ reads: [StepRead], _ needed: Step...) -> String {
        for read in reads where needed.contains(read.step) && read.state != .read && read.state != .partial {
            if read.state == .notRun { return "Not known: the run was stopped before “\(read.step.title)”." }
            return PythonText.strip("Not known: “\(read.step.title)” couldn't be read. \(read.why)")
        }
        return ""
    }

    /// A time as GAM printed it, cut to the day; "never" for Google's never (GAM's `Never`), "" when not there.
    static func shownTime(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        if PythonText.lower(PythonText.strip(value)) == "never" || value.hasPrefix("1970-01-01") { return "never" }
        return PythonText.string(value.unicodeScalars.prefix(10))
    }

    // MARK: tables

    /// A table the run's reads add up to. `known` false: a step it needs is unknown or never ran, said in `why`.
    public struct Finding: Sendable, Identifiable {
        public let key: String
        public let title: String
        public let summary: String
        public let columns: [String]
        public let rows: [[String]]
        public let known: Bool
        public let why: String
        public let note: String
        /// The first column is an account's address in the directory: it opens the person.
        public let links: Bool
        /// Known, but holding something no read could tell (an admin GAM couldn't name or read).
        public let partial: Bool
        /// What no read could tell, in words, when `partial`: its CSV's first line says it.
        public let unknownPart: String
        /// What a change since an earlier run can't tell, said beside it (plan F7a): a read GAM can cut short without a word makes
        /// a row that's gone, or a count that fell, look the same as one it couldn't read this time.
        public let changeNote: String
        public var id: String { key }

        init(_ key: String, _ title: String, _ summary: String, _ columns: [String], _ rows: [[String]] = [], known: Bool = true,
             why: String = "", note: String = "", links: Bool = false, partial: Bool = false, unknownPart: String = "",
             changeNote: String = "") {
            self.partial = partial
            self.unknownPart = unknownPart
            self.changeNote = changeNote
            self.key = key
            self.title = title
            self.summary = summary
            self.columns = columns
            self.rows = rows
            self.known = known
            self.why = why
            self.note = note
            self.links = links
        }
    }

    /// Each step's records, kept for the run: the directory as users, the rest as GAM's rows.
    public struct Tables: Sendable {
        public var users: [GamUser]?
        public var rows: [String: [GamOutput.Record]] = [:]

        public init(users: [GamUser]? = nil, rows: [String: [GamOutput.Record]] = [:]) {
            self.users = users
            self.rows = rows
        }
    }

    /// A finished run: its steps, its tables, when it was read, and Inactive users' window (0 for any other run).
    public struct Outcome: Sendable {
        public let run: Run
        public let reads: [StepRead]
        public let findings: [Finding]
        public let tables: Tables
        public let when: Date
        public let days: Int

        public init(run: Run, reads: [StepRead], findings: [Finding], tables: Tables, when: Date, days: Int) {
            self.run = run
            self.reads = reads
            self.findings = findings
            self.tables = tables
            self.when = when
            self.days = days
        }

        /// Every step was read, and no table holds something no read could tell.
        public var complete: Bool { reads.allSatisfy { $0.state == .read } && !findings.contains(where: \.partial) }

        /// Every step has an answer, at most with accounts GAM named as unread: the run counts for its schedule (plan F7a).
        public var answered: Bool { reads.allSatisfy { $0.state == .read || $0.state == .partial } }

        public func finding(_ key: String) -> Finding? { findings.first { $0.key == key } }
    }

    /// A table as its CSV holds it, whole: its columns, then every row. None for an unknown table: a sheet holding only its
    /// titles would read as "none" (invariant 10); its screen says why instead. A table known only in part starts with a line
    /// saying what wasn't read, so an admin whose apps GAM couldn't read never reads as one with no apps in the file (review of
    /// F3, 2026-11-21; GamGUI's `table_csv` writes the columns and rows alone).
    public static func exportRows(_ finding: Finding) -> [[String]]? {
        guard finding.known else { return nil }
        let note = finding.partial ? [[PythonText.strip("Part of this table is unknown. " + finding.unknownPart)]] : []
        return note + [finding.columns] + finding.rows
    }

    /// The run's tables, from its step reads and their kept tables. A table whose step is unknown says so. `leaving` is who
    /// has an offboarding started in this app (the shared drives' organizers).
    public static func findings(for run: Run, reads: [StepRead], tables: Tables, now: Date, days: Int,
                                leaving: Set<String> = []) -> [Finding] {
        let users = unknownBecause(reads, directory).isEmpty ? tables.users : nil
        switch run.key {
        case inactiveUsers.key:
            let why = unknownBecause(reads, directory)
            guard why.isEmpty, let users else {
                return [Finding("inactive", "Inactive \(days)+ days", why, inactiveColumns, known: false, why: why)]
            }
            return [inactiveFinding(users, days: days, now: now)]
        case sharedDrives.key:
            let known = unknownBecause(reads, domains).isEmpty ? domainsFrom(tables.rows[domains.key] ?? []) : nil
            return sharedDriveFindings(drives: tables.rows[drives.key] ?? [], acls: tables.rows[driveACLs.key] ?? [], domains: known,
                                       users: users, leaving: Set(leaving.map { PythonText.lower(PythonText.strip($0)) }), reads: reads)
        case classroom.key:
            return classroomFindings(courses: tables.rows[courses.key] ?? [], users: users, reads: reads, now: now)
        case adminTokenReview.key:
            return adminTokenFindings(admins: tables.rows[admins.key] ?? [], users: users, tokens: tables.rows[adminTokens.key] ?? [],
                                      reads: reads)
        default:
            return licenseFindings(seats: tables.rows[licenses.key] ?? [], users: users, reads: reads)
        }
    }

    // MARK: 1. Inactive users

    public static let newAccount = "new account", adminFlag = "admin"
    public static let inactiveColumns = ["Email", "Name", "Last sign-in", "Created", "Org unit", "Flags"]

    /// Reports' Inactive bucket for the window as a table: never-signed-in first, then the longest gone. An account made inside
    /// the window, or when isn't known, is flagged new (a new hire who hasn't signed in yet looks inactive); an administrator
    /// is flagged, since suspending one takes their admin work with it.
    public static func inactiveFinding(_ users: [GamUser], days: Int, now: Date) -> Finding {
        let cutoff = micros(now) - Int64(days) * 86_400_000_000
        let bucket = DirectoryReport.build(users, now: now, inactiveDays: days).first { $0.key == "inactive" }?.users ?? []
        var rows: [[String]] = [], new = 0
        for user in bucket {
            var flags: [String] = []
            if isNew(user, cutoff: cutoff) {
                flags.append(newAccount)
                new += 1
            }
            if user.isAdmin || user.isDelegatedAdmin { flags.append(adminFlag) }
            let last = shownTime(user.lastLoginTime)
            rows.append([user.primaryEmail, user.fullName, last.isEmpty ? "never" : last, shownTime(user.creationTime),
                         user.orgUnitPath, flags.joined(separator: ", ")])
        }
        rows = sorted(rows) { [$0[2] == "never" ? "0" : "1", $0[2], PythonText.lower($0[0])] }
        let n = rows.count
        var summary = "\(n) active account\(n == 1 ? "" : "s") \(n == 1 ? "has" : "have") not signed in within \(days) days"
            + (new > 0 ? "; \(new) of them \(new == 1 ? "was" : "were") made inside the window, or when isn't known." : ".")
        if n == 0 { summary = "Every active account has signed in within \(days) days." }
        return Finding("inactive", "Inactive \(days)+ days", summary, inactiveColumns, rows,
                       note: "Suspended accounts are left out. Suspend these… reads the directory again before anything is suspended.",
                       links: true)
    }

    /// An account made at or after the cutoff, or when isn't known.
    static func isNew(_ user: GamUser, cutoff: Int64) -> Bool {
        guard let made = user.creationTime.flatMap(ISOTime.microseconds) else { return true }
        return made >= cutoff
    }

    /// The instant as whole microseconds, as Python compares (`DirectoryReport` counts the same way).
    static func micros(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    /// One person a suspend would act on (GamGUI's `InactiveTarget`).
    public struct Target: Sendable, Equatable, Identifiable {
        public let email: String
        public let name: String
        /// As the directory gave it; "" for never.
        public let lastLogin: String
        /// Made inside the window, or when isn't known.
        public let new: Bool
        public var id: String { email }
    }

    /// The Inactive bucket as the people a suspend would act on, from a directory read just now (GamGUI's
    /// `reports.inactive_to_suspend`, roadmap 3.3): the targets in address order, and who was left out. The admin this app signs
    /// in as is left out (suspending it would sign the app out, and ChangeCore refuses it anyway), matched by Google's account ID
    /// as well as by address. Each target says whether it was made inside the window.
    public static func inactiveToSuspend(_ users: [GamUser], admin: String, adminID: String?, days: Int,
                                         now: Date) -> (targets: [Target], leftOut: [String]) {
        let cutoff = micros(now) - Int64(days) * 86_400_000_000
        let bucket = DirectoryReport.build(users, now: now, inactiveDays: days).first { $0.key == "inactive" }?.users ?? []
        let ordered = bucket.enumerated().sorted { a, b in
            pyLess([PythonText.lower(a.element.primaryEmail)], [PythonText.lower(b.element.primaryEmail)], a.offset, b.offset)
        }.map(\.element)
        let own = PythonText.lower(PythonText.strip(admin)), ownID = adminID ?? ""
        var targets: [Target] = [], leftOut: [String] = []
        for user in ordered {
            let id = user.record["id"].map { $0.truthy ? $0.pythonText : "" } ?? ""
            if PythonText.lower(PythonText.strip(user.primaryEmail)) == own || (!ownID.isEmpty && id == ownID) {
                leftOut.append(user.primaryEmail)
                continue
            }
            targets.append(Target(email: user.primaryEmail, name: user.fullName, lastLogin: user.lastLoginTime ?? "",
                                  new: isNew(user, cutoff: cutoff)))
        }
        return (targets, leftOut)
    }

    // MARK: 3. License usage

    public static let perSKUColumns = ["Product", "License", "SKU ID", "Seats", "On suspended accounts", "Not in the directory read"]
    public static let suspendedSeatColumns = ["Email", "Name", "License", "Org unit", "Last sign-in"]
    public static let straySeatColumns = ["Email", "License"]

    /// Seats per license, seats on suspended accounts, and seats on an address the directory read doesn't list. `users` is nil
    /// when the directory is unknown: the counts per license still stand, the joins don't.
    public static func licenseFindings(seats: [GamOutput.Record], users: [GamUser]?, reads: [StepRead]) -> [Finding] {
        let seatsWhy = unknownBecause(reads, licenses), joinWhy = unknownBecause(reads, licenses, directory)
        var byEmail: [String: GamUser] = [:]
        for user in users ?? [] { byEmail[PythonText.lower(PythonText.strip(user.primaryEmail))] = user }
        struct SKU: Hashable { let product: String, sku: String }
        var order: [SKU] = [], perSKU: [SKU: Int] = [:], onSuspended: [SKU: Int] = [:], stray: [SKU: Int] = [:]
        var names: [SKU: (product: String, sku: String)] = [:]
        var suspendedRows: [[String]] = [], strayRows: [[String]] = []
        for seat in seats {
            let email = PythonText.lower(PythonText.strip(text(seat["userId"])))
            let sku = SKU(product: text(seat["productId"]), sku: text(seat["skuId"]))
            if names[sku] == nil {
                let product = text(seat["productDisplay"]), display = text(seat["skuDisplay"])
                names[sku] = (product.isEmpty ? sku.product : product, display.isEmpty ? sku.sku : display)
            }
            if perSKU[sku] == nil { order.append(sku) }
            perSKU[sku, default: 0] += 1
            guard users != nil, !email.isEmpty else { continue }
            guard let holder = byEmail[email] else {
                stray[sku, default: 0] += 1
                strayRows.append([email, names[sku]!.sku])
                continue
            }
            if holder.suspended {
                onSuspended[sku, default: 0] += 1
                let last = shownTime(holder.lastLoginTime)
                suspendedRows.append([holder.primaryEmail, holder.fullName, names[sku]!.sku, holder.orgUnitPath,
                                      last.isEmpty ? "never" : last])
            }
        }
        let joined = users != nil
        let ranked = order.enumerated().sorted { a, b in
            let (x, y) = (perSKU[a.element]!, perSKU[b.element]!)
            if x != y { return x > y }
            return pyLess([PythonText.lower(names[a.element]!.sku)], [PythonText.lower(names[b.element]!.sku)], a.offset, b.offset)
        }.map(\.element)
        let skuRows = ranked.map { sku in
            [names[sku]!.product, names[sku]!.sku, sku.sku, String(perSKU[sku]!),
             joined ? String(onSuspended[sku] ?? 0) : "unknown", joined ? String(stray[sku] ?? 0) : "unknown"]
        }
        suspendedRows = sorted(suspendedRows) { [PythonText.lower($0[2]), PythonText.lower($0[0])] }
        strayRows = sorted(strayRows) { [PythonText.lower($0[1]), PythonText.lower($0[0])] }
        let total = perSKU.values.reduce(0, +), nSuspended = suspendedRows.count, nStray = strayRows.count
        // Every table built on the seats says so: with no product named GAM passes over one Google refuses, exit 0, so even
        // a clean run may be missing a product's seats, and an all-clear covers only the seats read.
        let skipped = "GAM passes over a product Google won't let it read without saying so, so this covers only the seats read."
        let gamNote = "GAM passes over a product Google won't let it read without saying so: a product missing here may be one "
            + "it couldn't read. Check the counts against the Admin console (Billing → Licenses)."
        let seatsWord = "\(total) seat\(total == 1 ? "" : "s")"
        let unsure = "GAM passes over a product it can't read without saying so, so a seat gone since then may be one it couldn't "
            + "read this time."
        return [
            Finding("per_sku", "Seats per license",
                    "\(seatsWord) across \(perSKU.count) license\(perSKU.count == 1 ? "" : "s").",
                    perSKUColumns, skuRows, known: seatsWhy.isEmpty, why: seatsWhy,
                    note: gamNote + (joined ? "" : " The directory couldn't be read, so the last two columns are unknown."),
                    changeNote: unsure),
            Finding("on_suspended", "Seats on suspended accounts",
                    nSuspended > 0
                        ? "\(nSuspended) seat\(nSuspended == 1 ? "" : "s") \(nSuspended == 1 ? "is" : "are") held by a suspended account."
                        : "No suspended account holds any of the \(seatsWord) read.",
                    suspendedSeatColumns, suspendedRows, known: joinWhy.isEmpty, why: joinWhy,
                    note: "A suspended account keeps its seat until the license is removed. " + skipped, links: true,
                    changeNote: unsure),
            Finding("not_in_directory", "Seats on an address the directory read doesn't list",
                    nStray > 0
                        ? "\(nStray) seat\(nStray == 1 ? "" : "s") \(nStray == 1 ? "is" : "are") on an address the directory read didn't list."
                        : "Every seat read is on an account the directory read listed.",
                    straySeatColumns, strayRows, known: joinWhy.isEmpty, why: joinWhy,
                    note: "An account made, renamed or deleted between the two reads shows here too. " + skipped, changeNote: unsure),
        ]
    }

    // MARK: 2. Shared drive permissions
    // `print shareddriveacls` reads each shared drive's OWN permissions: its members, users and groups only (Google's sharing
    // guide). "Anyone with the link" and a whole domain are sharing of the files inside a drive, which this run doesn't read,
    // and no flag here claims to.

    public static let permissionColumns = ["Drive", "Member", "Type", "Role", "Flags"]
    public static let orphanColumns = ["Drive", "Organizers", "Why"]
    public static let unreadDriveColumns = ["Drive", "Drive ID"]
    public static let external = "outside the domain"

    /// Every domain the tenant's addresses can end in, from `print domains formatjson` (GamGUI's `domains_from`): each
    /// `domainName`, `domainAliasName` and `parentDomainName` text, at any depth, stripped and lowercased, sorted, once each.
    public static func domainsFrom(_ records: [GamOutput.Record]) -> [String] {
        var found: [String] = []
        func walk(_ value: JSONValue) {
            switch value {
            case .object(let members):
                for (key, member) in members {
                    let last = key.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? key
                    if ["domainName", "domainAliasName", "parentDomainName"].contains(last), case .string(let name) = member {
                        found.append(PythonText.lower(PythonText.strip(name)))
                    } else {
                        walk(member)
                    }
                }
            case .array(let items): items.forEach(walk)
            default: break
            }
        }
        records.forEach { walk(.object($0)) }
        return Array(Set(found.filter { !$0.isEmpty })).sorted { pyLess([$0], [$1], 0, 0) }
    }

    /// A member whose address isn't in one of the domain's own domains or aliases is from outside it.
    static func permissionFlag(_ permission: GamOutput.Record, domains: [String]) -> String {
        var domain = text(permission["domain"])
        if domain.isEmpty {
            let address = text(permission["emailAddress"])
            domain = address.unicodeScalars.lastIndex(of: "@").map { PythonText.string(address.unicodeScalars[address.unicodeScalars.index(after: $0)...]) } ?? address
        }
        domain = PythonText.lower(PythonText.strip(domain))
        return !domain.isEmpty && !domains.contains(domain) ? external : ""
    }

    /// Every drive's members (outside members first), drives no active organizer looks after, and drives whose members GAM didn't
    /// read: it drops a drive whose permissions Google refused without a word or a code, so a listed drive missing from the
    /// members table is unknown, never "shared with no one".
    public static func sharedDriveFindings(drives: [GamOutput.Record], acls: [GamOutput.Record], domains: [String]?, users: [GamUser]?,
                                           leaving: Set<String>, reads: [StepRead]) -> [Finding] {
        let permsWhy = unknownBecause(reads, driveACLs, AuditRuns.domains), orphanWhy = unknownBecause(reads, driveACLs, directory)
        let unreadWhy = unknownBecause(reads, AuditRuns.drives, driveACLs)
        var rows: [[String]] = [], order: [String] = [], byDrive: [String: [GamOutput.Record]] = [:], names: [String: String] = [:]
        for row in acls {
            let driveID = text(row["id"]), name = text(row["name"])
            names[driveID] = name
            if byDrive[driveID] == nil {
                order.append(driveID)
                byDrive[driveID] = []
            }
            guard case .object(let permission)? = row["permission"] else { continue }   // a drive read with no permission
            byDrive[driveID]!.append(permission)
            let who = text(permission["emailAddress"]).isEmpty ? text(permission["displayName"]) : text(permission["emailAddress"])
            rows.append([name, who, text(permission["type"]), text(permission["role"]), permissionFlag(permission, domains: domains ?? [])])
        }
        rows = sorted(rows) { [$0[4].isEmpty ? "1" : "0", PythonText.lower($0[0]), PythonText.lower($0[1])] }
        let outside = rows.count { !$0[4].isEmpty }
        var status: [String: GamUser] = [:]
        for user in users ?? [] { status[PythonText.lower(PythonText.strip(user.primaryEmail))] = user }
        var orphans: [[String]] = []
        for driveID in order {
            let organizers = byDrive[driveID]!.filter { text($0["role"]) == "organizer" }
            if organizers.contains(where: { text($0["type"]) != "user" }) { continue }   // a group organizer: not flagged
            var whys: [String] = [], looked = true
            for permission in organizers {
                let address = PythonText.lower(PythonText.strip(text(permission["emailAddress"])))
                let holder = status[address]
                if permission["deleted"] == .bool(true) || (holder == nil && !address.isEmpty) {
                    whys.append("\(address.isEmpty ? "an account" : address): not in the directory read")
                } else if let holder, holder.suspended {
                    whys.append("\(address): suspended")
                } else if leaving.contains(address) {
                    whys.append("\(address): being offboarded")
                } else {
                    looked = false
                    break
                }
            }
            guard looked else { continue }
            let listed = organizers.map { text($0["emailAddress"]) }.joined(separator: ", ")
            orphans.append([names[driveID] ?? "", listed.isEmpty ? "none" : listed,
                            whys.isEmpty ? "no organizer at all" : whys.joined(separator: "; ")])
        }
        orphans = sorted(orphans) { [PythonText.lower($0[0])] }
        let readIDs = Set(order)
        let unread = sorted(drives.filter { !readIDs.contains(text($0["id"])) }.map { [text($0["name"]), text($0["id"])] }) {
            [PythonText.lower($0[0])]
        }
        let n = rows.count, nDrives = byDrive.count, nOrphans = orphans.count, nUnread = unread.count
        // A drive whose members weren't read (or whose listing is unknown) is missing from both tables below: each holds something
        // no read could tell, so neither is whole, and neither is compared with an earlier run as if it were (GamGUI #176).
        let leftOut = !unread.isEmpty || !unreadWhy.isEmpty
        let leftOutNote = !unread.isEmpty
            ? " It leaves out the \(nUnread) drive\(nUnread == 1 ? "" : "s") whose members weren't read, listed below."
            : !unreadWhy.isEmpty ? " Whether GAM passed over a drive can't be told: the list of drives wasn't read." : ""
        return [
            Finding("permissions", "Every drive's members",
                    "\(n) member\(n == 1 ? "" : "s") across \(nDrives) drive\(nDrives == 1 ? "" : "s"); \(outside) "
                        + "\(outside == 1 ? "is" : "are") from outside the domain, listed first.",
                    permissionColumns, rows, known: permsWhy.isEmpty, why: permsWhy,
                    note: "A shared drive's members are users and groups only. Outside the domain means an address not in one of "
                        + "the domain's own domains or aliases. Files inside a drive can be shared further (with anyone with the "
                        + "link, say): this run reads each drive's members, not its files' sharing." + leftOutNote,
                    partial: leftOut, unknownPart: PythonText.strip(leftOutNote)),
            Finding("orphaned", "Drives no active organizer looks after",
                    nOrphans > 0 ? "\(nOrphans) drive\(nOrphans == 1 ? "" : "s") \(nOrphans == 1 ? "has" : "have") no organizer who is "
                        + "active here." : "Every drive read has an active organizer, or a group as one.",
                    orphanColumns, orphans, known: orphanWhy.isEmpty, why: orphanWhy,
                    note: "Being offboarded means an offboarding started in GAM GUI since it opened. A group organizer isn't "
                        + "flagged: its members can't be told from here." + leftOutNote,
                    partial: leftOut, unknownPart: PythonText.strip(leftOutNote)),
            Finding("unread", "Drives whose members weren't read",
                    nUnread > 0 ? "GAM listed \(nUnread) drive\(nUnread == 1 ? "" : "s") but didn't read \(nUnread == 1 ? "its" : "their") "
                        + "members: unknown, not shared with no one." : "GAM read every listed drive's members.",
                    unreadDriveColumns, unread, known: unreadWhy.isEmpty, why: unreadWhy,
                    note: "GAM passes over a drive whose permissions Google won't return without a word or a code."),
        ]
    }

    // MARK: 4. Classroom (read only)

    public static let staleDays = 365
    public static let courseColumns = ["Class", "Section", "Owner", "State", "Teachers", "Students", "Updated"]
    public static let ownedColumns = ["Owner", "Class", "State", "Updated"]
    public static let strayOwnerColumns = ["Class", "Owner ID", "State"]

    /// Every class with its owner (joined by `ownerId` to the directory's `id`), state and counts; classes owned by a suspended
    /// account; classes whose owner the directory read doesn't list; and active or provisioned classes not updated in a year.
    public static func classroomFindings(courses: [GamOutput.Record], users: [GamUser]?, reads: [StepRead], now: Date) -> [Finding] {
        let coursesWhy = unknownBecause(reads, AuditRuns.courses), joinWhy = unknownBecause(reads, AuditRuns.courses, directory)
        var byID: [String: GamUser] = [:]
        for user in users ?? [] {
            guard let id = user.record["id"], id.truthy else { continue }
            byID[id.pythonText] = user
        }
        let cutoff = micros(now) - Int64(staleDays) * 86_400_000_000
        var every: [[String]] = [], owned: [[String]] = [], strays: [[String]] = [], stale: [[String]] = []
        for course in courses {
            let ownerID = text(course["ownerId"])
            let owner = byID[ownerID]
            let shown = owner?.primaryEmail ?? (users != nil ? "ID \(course["ownerId"].map { $0.pythonText } ?? "None")" : ownerID)
            let state = text(course["courseState"]), updated = shownTime(text(course["updateTime"])), name = text(course["name"])
            every.append([name, text(course["section"]), shown, state, course["teachers"].map { $0.pythonText } ?? "",
                          course["students"].map { $0.pythonText } ?? "", updated])
            if users != nil, owner == nil {
                strays.append([name, ownerID, state])
            } else if let owner, owner.suspended {
                owned.append([owner.primaryEmail, name, state, updated])
            }
            if ["ACTIVE", "PROVISIONED"].contains(state), let made = ISOTime.microseconds(text(course["updateTime"])), made < cutoff {
                stale.append([name, shown, state, updated])
            }
        }
        every = sorted(every) { [PythonText.lower($0[0]), PythonText.lower($0[1])] }
        owned = sorted(owned) { [PythonText.lower($0[0]), PythonText.lower($0[1])] }
        strays = sorted(strays) { [PythonText.lower($0[0])] }
        stale = sorted(stale) { [$0[3], PythonText.lower($0[0])] }
        let n = every.count, nOwned = owned.count, nStrays = strays.count, nStale = stale.count
        return [
            Finding("courses", "Every class", "\(n) class\(n == 1 ? "" : "es") in every state.", courseColumns, every,
                    known: coursesWhy.isEmpty, why: coursesWhy,
                    note: "GAM counts a class whose roster Google won't return as 0 teachers and 0 students, without a word, so a "
                        + "0 isn't an empty class. Not yet checked on a school domain.",
                    changeNote: "GAM counts a roster Google won't return as 0 without a word, so a class whose count fell to 0 "
                        + "since then may be one it couldn't read this time."),
            Finding("owned_by_suspended", "Classes owned by a suspended account",
                    nOwned > 0 ? "\(nOwned) class\(nOwned == 1 ? "" : "es") \(nOwned == 1 ? "is" : "are") owned by a suspended account."
                        : "No class read is owned by a suspended account.",
                    ownedColumns, owned, known: joinWhy.isEmpty, why: joinWhy,
                    note: "GAM GUI changes nothing in Classroom: hand a class over in Classroom itself.", links: true),
            Finding("owner_not_in_directory", "Classes whose owner the directory read doesn't list",
                    nStrays > 0 ? "\(nStrays) class\(nStrays == 1 ? "" : "es") \(nStrays == 1 ? "has" : "have") an owner the directory "
                        + "read didn't list." : "Every class read has an owner the directory read listed.",
                    strayOwnerColumns, strays, known: joinWhy.isEmpty, why: joinWhy, note: "A deleted account, or one outside the domain."),
            Finding("stale", "Active or provisioned classes not updated in \(staleDays) days",
                    nStale > 0 ? "\(nStale) class\(nStale == 1 ? "" : "es") \(nStale == 1 ? "has" : "have")n't changed in a year."
                        : "Every active or provisioned class read has changed within \(staleDays) days.",
                    ["Class", "Owner", "State", "Updated"], stale, known: coursesWhy.isEmpty, why: coursesWhy),
        ]
    }

    // MARK: 5. Admin token review

    public static let adminColumns = ["Admin", "Roles", "Suspended", "Apps"]
    public static let adminAppColumns = ["Admin", "App", "What it may do", "Flags"]
    public static let aiName = "AI, by its name", broad = "broad access", suspendedAdmin = "suspended admin"

    /// A role holder GAM couldn't name: its lookup of `assignedTo` failed (convertUIDtoEmailAddressWithType returns the bare ID
    /// as type `unknown`), so the row has `assignedToUnknown` True and no address, and GAM exits 0 (doPrintShowAdmins,
    /// _setNamesFromIds, the 7.52.04 tag). A group's member expanded by `recursive` can be one too.
    static func unnamed(_ row: GamOutput.Record) -> Bool {
        PythonText.lower(PythonText.strip(text(row["assignedToUnknown"]))) == "true"
    }

    /// Who holds an admin row: its `assignedToUser`; for a holder GAM couldn't name, the directory account whose `id` is its
    /// `assignedTo`; else "" (a service account, a group with no member, or a holder no read can name).
    public static func holder(of row: GamOutput.Record, users: [GamUser]?) -> String {
        let address = PythonText.lower(PythonText.strip(text(row["assignedToUser"])))
        if GamCommands.isOneAddress(address) { return address }
        if unnamed(row), let users, !users.isEmpty {
            let id = PythonText.strip(text(row["assignedTo"]))
            if !id.isEmpty, let user = users.first(where: { text($0.record["id"]) == id }) {
                return PythonText.lower(PythonText.strip(user.primaryEmail))
            }
        }
        return ""
    }

    /// The IDs of role holders neither GAM nor the directory read could name: unknown admins, never left out.
    public static func unnamedHolders(_ rows: [GamOutput.Record], users: [GamUser]?) -> [String] {
        Array(Set(rows.filter { unnamed($0) && holder(of: $0, users: users).isEmpty }.map { text($0["assignedTo"]) }).subtracting([""]))
            .sorted { pyLess([$0], [$1], 0, 0) }
    }

    /// Every person who holds an admin role, from `print admins recursive` (a group's members each get a row of their own), a
    /// holder GAM couldn't name joined to the directory by ID. A service account's row, or a group with no member, names none.
    public static func adminAddresses(_ rows: [GamOutput.Record], users: [GamUser]? = nil) -> [String] {
        Array(Set(rows.map { holder(of: $0, users: users) }.filter { !$0.isEmpty })).sorted { pyLess([$0], [$1], 0, 0) }
    }

    /// Every admin (suspended ones included) with their roles and how many apps; and every grant those admins gave, suspended
    /// admins, AI by name and broad access flagged, flagged first. An admin whose apps GAM couldn't read, or a holder no read
    /// could name, is unknown, never none, and the run isn't complete.
    public static func adminTokenFindings(admins rows: [GamOutput.Record], users: [GamUser]?, tokens: [GamOutput.Record],
                                          reads: [StepRead]) -> [Finding] {
        let adminsWhy = unknownBecause(reads, admins), appsWhy = unknownBecause(reads, admins, adminTokens)
        let unread = Set(reads.first { $0.step == adminTokens }?.unread ?? [])
        var roles: [String: [String]] = [:]
        for row in rows {
            let via = text(row["assignedToGroup"])
            let role = (text(row["role"]).isEmpty ? text(row["roleId"]) : text(row["role"])) + (via.isEmpty ? "" : " (through \(via))")
            let address = holder(of: row, users: users)
            if !address.isEmpty {
                roles[address, default: []].append(role)
            } else if unnamed(row), row["assignedTo"]?.truthy == true {
                roles["ID \(text(row["assignedTo"]))", default: []].append(role)   // a holder no read could name: unknown
            }
        }
        let nameless = unnamedHolders(rows, users: users)
        var status: [String: GamUser] = [:]
        for user in users ?? [] { status[PythonText.lower(PythonText.strip(user.primaryEmail))] = user }
        let grants = appsWhy.isEmpty ? tokens.map(ConnectedApps.Grant.init(record:)).filter { !$0.clientID.isEmpty } : []
        var appsOf: [String: Int] = [:]
        for grant in grants { appsOf[PythonText.lower(PythonText.strip(grant.user)), default: 0] += 1 }
        var adminRows: [[String]] = []
        for address in roles.keys.sorted(by: { pyLess([$0], [$1], 0, 0) }) {
            let held = Array(Set(roles[address]!)).sorted { pyLess([$0], [$1], 0, 0) }.joined(separator: "; ")
            if address.hasPrefix("ID ") {
                adminRows.append([address, held, "unknown", "unknown"])
                continue
            }
            let suspended = users == nil ? "unknown" : status[address].map { $0.suspended ? "yes" : "no" } ?? "not in the directory read"
            let apps = !appsWhy.isEmpty || unread.contains(address) ? "unknown" : String(appsOf[address] ?? 0)
            adminRows.append([address, held, suspended, apps])
        }
        var appRows: [[String]] = []
        for grant in grants {
            let address = PythonText.lower(PythonText.strip(grant.user))
            let described = grant.scopes.map(ConnectedApps.describe)
            var flags: [String] = []
            if status[address]?.suspended == true { flags.append(suspendedAdmin) }
            if ConnectedApps.looksLikeAI(grant.name) { flags.append(aiName) }
            if described.contains(where: { $0.reach == .broad }) { flags.append(broad) }
            var seenWords: Set<String> = []
            let words = described.enumerated().sorted { ($0.element.reach, $0.offset) < ($1.element.reach, $1.offset) }
                .map(\.element.words).filter { seenWords.insert($0).inserted }
            appRows.append([address, grant.name, words.joined(separator: ", "), flags.joined(separator: ", ")])
        }
        appRows = sorted(appRows) { [$0[3].isEmpty ? "1" : "0", $0[0], PythonText.lower($0[1])] }
        let nAdmins = adminRows.count, nFlagged = appRows.count { !$0[3].isEmpty }
        var partial = unread.isEmpty ? "" : " GAM couldn't read the apps of \(unread.sorted { pyLess([$0], [$1], 0, 0) }.joined(separator: ", ")): unknown, not none."
        if !nameless.isEmpty {
            partial += " GAM couldn't name \(nameless.count) role holder\(nameless.count == 1 ? "" : "s") and the directory read "
                + "has no account with \(nameless.count == 1 ? "that ID" : "those IDs") (\(nameless.joined(separator: ", "))): "
                + "who they are, and their apps, are unknown."
        }
        let someUnknown = !unread.isEmpty || !nameless.isEmpty
        return [
            Finding("admins", "Every admin", "\(nAdmins) role holder\(nAdmins == 1 ? "" : "s"), suspended ones included.",
                    adminColumns, adminRows, known: adminsWhy.isEmpty, why: adminsWhy,
                    note: "A role held through a group counts each member. A holder GAM couldn't name is matched to the directory "
                        + "by ID. A service account's role names no person, so it isn't listed." + partial,
                    links: true, partial: someUnknown, unknownPart: PythonText.strip(partial)),
            Finding("admin_apps", "Admins' connected apps",
                    appRows.isEmpty ? "No admin read has given an app access."
                        : "\(appRows.count) grant\(appRows.count == 1 ? "" : "s") across the admins; \(nFlagged) flagged, listed first.",
                    adminAppColumns, appRows, known: appsWhy.isEmpty, why: appsWhy,
                    note: "An app is called AI by its name alone. To revoke one, open Incident for that admin: its access is "
                        + "taken away there, after a preview." + partial,
                    links: true, partial: someUnknown, unknownPart: PythonText.strip(partial)),
        ]
    }

    // MARK: Python's ways

    /// Python's `str(value or "")`.
    static func text(_ value: JSONValue?) -> String {
        guard let value, value.truthy else { return "" }
        return value.pythonText
    }

    /// Python's `sorted(rows, key=…)`: stable, its keys compared as Python compares text (by code point).
    static func sorted(_ rows: [[String]], by key: ([String]) -> [String]) -> [[String]] {
        let keyed = rows.enumerated().map { (offset: $0.offset, row: $0.element, key: key($0.element)) }
        return keyed.sorted { pyLess($0.key, $1.key, $0.offset, $1.offset) }.map(\.row)
    }

    /// Python's tuple order over text, then the original order (Python's sort is stable).
    static func pyLess(_ a: [String], _ b: [String], _ i: Int, _ j: Int) -> Bool {
        for (x, y) in zip(a, b) where !x.unicodeScalars.elementsEqual(y.unicodeScalars) {
            return x.unicodeScalars.lexicographicallyPrecedes(y.unicodeScalars) { $0.value < $1.value }
        }
        return a.count != b.count ? a.count < b.count : i < j
    }
}
