import Foundation
import GamEngine

/// Schedules (plan F7a, GamGUI #176's `core/schedules.py`): an audit run that says when it's due, run on the operator's click.
/// The pure half: the cadence, when a run is due and the words it says it in, and what changed in a table since the last kept
/// run that read it whole. `AuditScheduleStore` keeps the schedules and the kept runs on this Mac. Held to GamGUI's by
/// `Tests/Fixtures/schedules.json` (`AuditSchedulesTests`).
///
/// **Nothing here runs anything.** A cadence only decides when a run says it is due, on Home and on its own pane; the run is the
/// operator's Run (⌘R), the same audit run as ever (`AuditRunner`), whose reads are recorded as usual. There is no background
/// runner, timer or notification, no write, no sensitive read and no Sheet export (`WriteRouteTests.aScheduleRunsNothing`).
///
/// - **The cadence** is daily, weekly or monthly, per domain and per run.
/// - **Due.** A run *counts* when every step has an answer, at most with some accounts GAM named as unread: a run stopped, or
///   with a step that failed, doesn't. Never counted since the cadence was set: due now. Otherwise it is due from the local day
///   one day, seven days or one calendar month after the day it last counted (the 31st into a shorter month is that month's
///   last day), and stays due until a run counts again. A last count dated after now (the clock was ahead then, or is behind
///   now) is due, and says to check the Mac's clock.
/// - **Changed since.** Each table of a finished scheduled run is compared with the same table in the newest earlier kept run
///   that read it whole, with the same window (Inactive users). A row is its cells: one with any cell changed is gone and new.
///   A table unknown or partly unknown, now or then, is never compared (invariant 10): no change is said only of two whole
///   tables. A kept run that can't be read, met first, stops the walk: it may be the run to compare with.
public enum AuditSchedules {
    public enum Cadence: String, CaseIterable, Sendable, Identifiable {
        case daily, weekly, monthly
        public var id: String { rawValue }
        /// GamGUI's `CADENCE_WORDS`.
        public var word: String {
            switch self {
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            }
        }
    }

    /// Runs kept when the operator doesn't say (GamGUI's `KEEP_DEFAULT`).
    public static let keepDefault = 5
    /// At most: a year of monthly runs (`KEEP_CAP`).
    public static let keepCap = 12
    /// Rows a kept table may hold; a larger one isn't kept, and can't be compared with later (`KEEP_ROWS_CAP`).
    public static let keepRowsCap = 50_000
    public static let fileVersion = 1
    /// Seconds since 1970 a stored time may be (the year 5138): past it, the file isn't a store (`_MAX_TIME`).
    static let maxTime = 1e11
    /// A kept run's window, in days (`_MAX_DAYS`).
    static let maxDays = 10_000

    /// A stored time: a finite number of seconds from 1970 that a date can be made of.
    static func isTime(_ value: Double) -> Bool { value.isFinite && value >= 0 && value < maxTime }

    /// A run's key as a schedule names it (`^[a-z][a-z_]{0,39}$`): it names a folder, so nothing else is one.
    static func isRunKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard (1...40).contains(scalars.count), ("a"..."z").contains(scalars[0]) else { return false }
        return scalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
    }

    // MARK: the cadence and "due"

    /// One run's schedule on one domain.
    public struct Schedule: Sendable, Equatable {
        public let run: String
        public let cadence: Cadence
        /// How many of its last runs are kept, 1 to `keepCap`.
        public let keep: Int
        /// When the cadence was set (seconds since 1970).
        public let since: Double
        /// When a run that counts last finished; 0: none since it was set.
        public let done: Double

        public init(run: String, cadence: Cadence, keep: Int, since: Double, done: Double = 0) {
            self.run = run
            self.cadence = cadence
            self.keep = keep
            self.since = since
            self.done = done
        }
    }

    /// A local day.
    public struct Day: Sendable, Hashable, Comparable, CustomStringConvertible {
        public let year: Int, month: Int, day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        public static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

        /// `2026-11-18`, as Python's `date.isoformat()`.
        public var description: String {
            func pad(_ value: Int, _ width: Int) -> String {
                let text = String(value)
                return String(repeating: "0", count: max(0, width - text.count)) + text
            }
            return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
        }

        static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

        static func days(in month: Int, of year: Int) -> Int {
            switch month {
            case 2: isLeap(year) ? 29 : 28
            case 4, 6, 9, 11: 30
            default: 31
            }
        }

        /// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`): day arithmetic with no time zone or summer time in it.
        var ordinal: Int {
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146_097 + doe - 719_468
        }

        init(ordinal: Int) {
            let z = ordinal + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let doe = z - era * 146_097
            let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            let mp = (5 * doy + 2) / 153
            let day = doy - (153 * mp + 2) / 5 + 1
            let month = mp < 10 ? mp + 3 : mp - 9
            self.init(year: yoe + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
        }

        func adding(days: Int) -> Day { Day(ordinal: ordinal + days) }

        /// Monday is 0, as Python's `date.weekday()`.
        var weekday: Int { ((ordinal % 7) + 7 + 3) % 7 }
    }

    /// The local day a run is due again after it counted on `last` (GamGUI's `next_day`).
    public static func nextDay(_ last: Day, _ cadence: Cadence) -> Day {
        switch cadence {
        case .daily: return last.adding(days: 1)
        case .weekly: return last.adding(days: 7)
        case .monthly:
            let (year, month) = last.month == 12 ? (last.year + 1, 1) : (last.year, last.month + 1)
            return Day(year: year, month: month, day: min(last.day, Day.days(in: month, of: year)))
        }
    }

    /// The Mac's time zone, which days and times are said in (GamGUI's `TZ`; tests set one).
    public struct Clock: Sendable {
        public let timeZone: TimeZone

        public init(timeZone: TimeZone = .current) {
            self.timeZone = timeZone
        }

        private var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar
        }

        /// The local day `when` falls on.
        public func day(_ when: Double) -> Day {
            let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: when))
            return Day(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
        }

        /// The local day `schedule` is next due; nil when no run has counted since it was set, so it is due now.
        public func dueDay(_ schedule: Schedule) -> Day? {
            schedule.done > 0 ? AuditSchedules.nextDay(day(schedule.done), schedule.cadence) : nil
        }

        public func isDue(_ schedule: Schedule, now: Double) -> Bool {
            guard let next = dueDay(schedule) else { return true }
            return day(now) >= next
        }

        /// "Wed 18 Nov 2026": the day, as every schedule line says it (Python's `%a`, the day, `%b %Y`).
        public static func words(_ day: Day) -> String {
            let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            return "\(weekdays[day.weekday]) \(day.day) \(months[day.month - 1]) \(day.year)"
        }

        /// "Wed 18 Nov 2026, 09:14": a kept run, by when it finished (local time).
        public func words(at when: Double) -> String {
            let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: when))
            func pad(_ value: Int?) -> String {
                let text = String(value ?? 0)
                return text.count < 2 ? "0" + text : text
            }
            return "\(Self.words(day(when))), \(pad(parts.hour)):\(pad(parts.minute))"
        }

        /// Whether `schedule` is due at `now`, in the words Home and the run's own pane say it (GamGUI's `due_words`).
        public func due(_ title: String, _ schedule: Schedule, now: Double) -> Due {
            let cadence = schedule.cadence.word
            if schedule.done > now {   // counted at a time still to come: the Mac's clock was ahead then, or is behind now
                return Due(due: true, headline: "\(title) is due",
                           detail: "\(cadence); its last run is dated after now, so when it's next due can't be told. Check the Mac's clock.")
            }
            guard let next = dueDay(schedule) else {
                return Due(due: true, headline: "\(title) is due",
                           detail: "\(cadence); no run of it has read every step since it was scheduled.")
            }
            if day(now) >= next {
                return Due(due: true, headline: "\(title) is due",
                           detail: "\(cadence); its last run that read every step was on \(Self.words(day(schedule.done))).")
            }
            return Due(due: false, headline: "\(cadence), next due \(Self.words(next))")
        }
    }

    /// Whether a run is due, in words.
    public struct Due: Sendable, Equatable {
        public let due: Bool
        /// "License usage is due", or "Weekly, next due Wed 25 Nov 2026".
        public let headline: String
        /// Why it's due, a sentence; "" when it isn't.
        public let detail: String

        public init(due: Bool, headline: String, detail: String = "") {
            self.due = due
            self.headline = headline
            self.detail = detail
        }

        public var line: String { PythonText.strip("\(headline). \(detail)") }
    }

    // MARK: tables and what changed

    /// A finished run's table, as a schedule keeps and compares it: the findings a pane shows, never the steps' raw reads.
    public struct Table: Sendable {
        public let key: String
        public let title: String
        public let columns: [String]
        public let rows: [[String]]
        public let known: Bool
        public let partial: Bool

        public init(key: String, title: String, columns: [String], rows: [[String]], known: Bool, partial: Bool) {
            self.key = key
            self.title = title
            self.columns = columns
            self.rows = rows
            self.known = known
            self.partial = partial
        }
    }

    /// One table of a kept run: its header, and (loaded whole) its rows.
    public struct KeptTable: Sendable, Equatable {
        public let key: String
        public let title: String
        public let columns: [String]
        public let known: Bool
        public let partial: Bool
        /// Rows it had.
        public let count: Int
        /// False: over `keepRowsCap`, so its rows weren't kept.
        public let kept: Bool
        /// Its rows, when loaded whole.
        public var rows: [[String]]?

        public init(key: String, title: String, columns: [String], known: Bool, partial: Bool, count: Int, kept: Bool,
                    rows: [[String]]? = nil) {
            self.key = key
            self.title = title
            self.columns = columns
            self.known = known
            self.partial = partial
            self.count = count
            self.kept = kept
            self.rows = rows
        }
    }

    /// A kept run, or why it can't be read (`problem`: then nothing else here is known). Never dropped from a listing: it may
    /// be the run to compare with.
    public struct KeptRun: Sendable, Identifiable, Equatable {
        public let id: String
        /// When it finished (seconds since 1970).
        public let when: Double
        /// Inactive users: its window; 0 for every other run.
        public let days: Int
        public var tables: [KeptTable]
        public let problem: String

        public init(id: String, when: Double = 0, days: Int = 0, tables: [KeptTable] = [], problem: String = "") {
            self.id = id
            self.when = when
            self.days = days
            self.tables = tables
            self.problem = problem
        }

        public func table(_ key: String) -> KeptTable? { tables.first { $0.key == key } }
    }

    /// What one table holds that the same table in an earlier kept run didn't (`new`), and the other way (`gone`). `why` says, in
    /// words, why it wasn't compared: then `new` and `gone` say nothing.
    public struct Change: Sendable, Equatable {
        public let key: String
        /// When the run it was compared with finished; 0 when not compared.
        public let since: Double
        public let new: [[String]]
        public let gone: [[String]]
        public let why: String

        public init(key: String, since: Double = 0, new: [[String]] = [], gone: [[String]] = [], why: String = "") {
            self.key = key
            self.since = since
            self.new = new
            self.gone = gone
            self.why = why
        }

        public var compared: Bool { why.isEmpty }
    }

    public static let notKnownNow = "Unknown this time, so it isn't compared."
    public static let partUnknownNow = "Part of this table is unknown this time, so what's new or gone can't be told."
    public static let nothingBefore = "No earlier run that read this table whole is kept, so there's nothing to compare it with yet."
    public static let keptRunUnread = "A run kept before couldn't be read, so this table isn't compared. Delete the kept runs if it "
        + "stays that way."
    public static let notAnswered = "A step of this run has no answer, so its tables aren't compared: one may hold \"unknown\" where "
        + "it had a value."
    public static let keptUnread = "The runs kept before couldn't be read just now, so this table isn't compared."

    /// `rows` not in `minus`, as a multiset, in `rows`' order.
    static func difference(_ rows: [[String]], _ minus: [[String]]) -> [[String]] {
        var left: [[String]: Int] = [:]
        for row in minus { left[row, default: 0] += 1 }
        var out: [[String]] = []
        for row in rows {
            if let count = left[row], count > 0 {
                left[row] = count - 1
            } else {
                out.append(row)
            }
        }
        return out
    }

    /// Each known, whole table in `tables` against the newest of `earlier` (newest first, headers) that kept the same table
    /// whole, read with the same window `days`. `load` reads a kept run's rows; one that can't be read stops the walk and says
    /// so. Each kept run is loaded at most once.
    public static func changesSince(_ tables: [Table], days: Int, earlier: [KeptRun], clock: Clock,
                                    load: (String) -> KeptRun) -> [String: Change] {
        var loaded: [String: KeptRun] = [:]
        var out: [String: Change] = [:]
        for table in tables {
            guard table.known else {
                out[table.key] = Change(key: table.key, why: notKnownNow)
                continue
            }
            guard !table.partial else {
                out[table.key] = Change(key: table.key, why: partUnknownNow)
                continue
            }
            var change = Change(key: table.key, why: nothingBefore)
            for head in earlier {
                if !head.problem.isEmpty {   // what it held can't be told: it may be the run to compare with
                    change = Change(key: table.key, why: keptRunUnread)
                    break
                }
                guard head.days == days, let then = head.table(table.key), then.known, !then.partial, then.kept else { continue }
                if loaded[head.id] == nil { loaded[head.id] = load(head.id) }
                let whole = loaded[head.id]!
                guard whole.problem.isEmpty, let rows = whole.table(table.key)?.rows else {
                    change = Change(key: table.key, why: "The run kept on \(clock.words(at: head.when)) couldn't be read whole, so "
                                    + "this table isn't compared.")
                    break
                }
                change = Change(key: table.key, since: head.when, new: difference(table.rows, rows), gone: difference(rows, table.rows))
                break
            }
            out[table.key] = change
        }
        return out
    }

    /// What a finished run's keep did: each table against the last kept run, and what happened to this run's keep, in words.
    public struct AfterRun: Sendable {
        public let changes: [String: Change]
        /// "" when the run isn't scheduled.
        public var note: String
        /// The note says something went wrong.
        public var problem: Bool

        public init(changes: [String: Change], note: String = "", problem: Bool = false) {
            self.changes = changes
            self.note = note
            self.problem = problem
        }
    }

    /// A schedule or a kept run couldn't be read or kept, in words.
    public struct Problem: Error, Sendable, Equatable, CustomStringConvertible {
        public let reason: String
        init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }
}
