import Foundation
import GamEngine

/// Audit runs (plan F3, GamGUI #171's `core/audit_runs.py`): ready-made lists of reads, started by the operator, with Stop
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
        public var id: String { key }
    }

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

    public static let inactiveUsers = Run(
        key: "inactive_users", title: "Inactive users",
        what: "Active accounts with no sign-in inside a window you pick; accounts made inside it are flagged.", steps: [directory])
    public static let licenseUsage = Run(
        key: "license_usage", title: "License usage",
        what: "Every license seat against the directory: seats per license, and seats on suspended accounts.",
        steps: [licenses, directory])
    /// Every run, in GamGUI's order.
    public static let all = [inactiveUsers, licenseUsage]

    /// The GAM read a step runs, from its builder. The directory is the cache's own read (`cacheFields`, suspended accounts
    /// included); the seats are `print licenses` with no product named.
    public static func read(_ step: Step) -> GamRead {
        switch step.key {
        case licenses.key: GamCommands.printLicenses()
        default: GamCommands.printUsers(fields: GamCommands.cacheFields)
        }
    }

    // MARK: a step's read

    /// How a step ended, once the run is over.
    public enum State: String, Sendable {
        /// Its table is kept.
        case read
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

        public init(step: Step, state: State, why: String = "", rows: Int = 0, detail: String = "") {
            self.step = step
            self.state = state
            self.why = why
            self.rows = rows
            self.detail = detail
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
        default: return ""
        }
    }

    /// Why a table needing `needed` is unknown, in words, or "" when every one was read.
    public static func unknownBecause(_ reads: [StepRead], _ needed: Step...) -> String {
        for read in reads where needed.contains(read.step) && read.state != .read {
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
        public var id: String { key }

        init(_ key: String, _ title: String, _ summary: String, _ columns: [String], _ rows: [[String]] = [], known: Bool = true,
             why: String = "", note: String = "", links: Bool = false) {
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

        /// Every step was read.
        public var complete: Bool { reads.allSatisfy { $0.state == .read } }

        public func finding(_ key: String) -> Finding? { findings.first { $0.key == key } }
    }

    /// The run's tables, from its step reads and their kept tables. A table whose step is unknown says so.
    public static func findings(for run: Run, reads: [StepRead], tables: Tables, now: Date, days: Int) -> [Finding] {
        let users = unknownBecause(reads, directory).isEmpty ? tables.users : nil
        switch run.key {
        case inactiveUsers.key:
            let why = unknownBecause(reads, directory)
            guard why.isEmpty, let users else {
                return [Finding("inactive", "Inactive \(days)+ days", why, inactiveColumns, known: false, why: why)]
            }
            return [inactiveFinding(users, days: days, now: now)]
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
        return [
            Finding("per_sku", "Seats per license",
                    "\(seatsWord) across \(perSKU.count) license\(perSKU.count == 1 ? "" : "s").",
                    perSKUColumns, skuRows, known: seatsWhy.isEmpty, why: seatsWhy,
                    note: gamNote + (joined ? "" : " The directory couldn't be read, so the last two columns are unknown.")),
            Finding("on_suspended", "Seats on suspended accounts",
                    nSuspended > 0
                        ? "\(nSuspended) seat\(nSuspended == 1 ? "" : "s") \(nSuspended == 1 ? "is" : "are") held by a suspended account."
                        : "No suspended account holds any of the \(seatsWord) read.",
                    suspendedSeatColumns, suspendedRows, known: joinWhy.isEmpty, why: joinWhy,
                    note: "A suspended account keeps its seat until the license is removed. " + skipped, links: true),
            Finding("not_in_directory", "Seats on an address the directory read doesn't list",
                    nStray > 0
                        ? "\(nStray) seat\(nStray == 1 ? "" : "s") \(nStray == 1 ? "is" : "are") on an address the directory read didn't list."
                        : "Every seat read is on an account the directory read listed.",
                    straySeatColumns, strayRows, known: joinWhy.isEmpty, why: joinWhy,
                    note: "An account made, renamed or deleted between the two reads shows here too. " + skipped),
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
