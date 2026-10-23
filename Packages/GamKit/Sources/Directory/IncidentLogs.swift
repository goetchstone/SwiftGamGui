import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// "Pull Incident Logs" (docs/plans/2026-10-19-compromised-account.md slice 2): the activity logs an incident needs, read
/// together for a window, some accounts (none: every one) and an attacker's IP address, each in the one row shape and
/// each exportable as a CSV. Reads only. The last pull is kept, for the tenant it was read on.
@MainActor
@Observable
public final class IncidentLogs {
    public struct Query: Equatable, Sendable {
        public let applications: [ActivityLogs.Application]
        /// The accounts; empty for every account.
        public let users: [String]
        public let hours: Int
        public let ip: String
        /// A window from a time to a time instead of the last `hours` (Read the Rest: from where a read stopped to now).
        public let from: Date?
        public let to: Date?

        public init(applications: [ActivityLogs.Application], users: [String], hours: Int, ip: String, from: Date? = nil, to: Date? = nil) {
            self.applications = applications
            self.users = users
            self.hours = hours
            self.ip = ip
            self.from = from
            self.to = to
        }

        /// The accounts as typed, split on commas, spaces and new lines, each once (case aside), as GAM reads a list.
        public static func accounts(_ typed: String) -> [String] {
            var seen: Set<String> = []
            return typed.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
    }

    /// One log's read: its rows, or GAM's words for why not.
    public struct Log: Sendable, Identifiable {
        public let application: ActivityLogs.Application
        public let rows: Result<[ActivityLogs.Row], UserAccess.Problem>
        /// The window it was read for: the query's, or Gmail's at most 30 days.
        public let hours: Int
        /// Not all of the window was read: with `through`, everything up to that time was and the later events weren't (a
        /// whole read stopped at its bound, oldest first); without, the older events weren't (the Chrome and admin logs' reads
        /// for accounts, newest first).
        public let capped: Bool
        /// When capped by a whole read: the time it was read completely through.
        public internal(set) var through: Date? = nil
        public var id: ActivityLogs.Application { application }
    }

    public struct Pull: Sendable {
        public let query: Query
        /// In the query's order, each as it finishes.
        public internal(set) var logs: [Log]
        public internal(set) var ended: Bool
        /// Made from an incident's saved evidence (`evidence(_:)`), not read from Google: never saved to it again.
        public internal(set) var fromEvidence = false

        /// The sign-in log's IP addresses, the flagged ones first: what to filter every log by next.
        public var addresses: [String] {
            ActivityLogs.addresses(in: logs.first { $0.application == .login }.flatMap { try? $0.rows.get() } ?? [])
        }
    }

    /// While a pull reads: each log read whole so far, through when (oldest first, a day at a time).
    public private(set) var readThrough: [ActivityLogs.Application: Date] = [:]

    /// The last pull, while it belongs to the connected tenant.
    public var pull: Pull? {
        guard let kept, kept.domain == setup.active, kept.generation == setup.generation else { return nil }
        return kept.pull
    }
    public var isPulling: Bool { pull.map { !$0.ended } ?? false }

    private var kept: (pull: Pull, domain: Domain, generation: Int)?
    private var asked = 0
    private let setup: SetupModel
    private let access: UserAccess
    /// At most this many `gam` reads at once.
    static let concurrent = 3
    /// Each read's bound (`ActivityLogs.cap`; a test's smaller one pages through the mock's few rows).
    private let cap: Int
    /// Now, when each log's first read fixes its window (a test's own, for the mock's fixed dates).
    private let clock: @Sendable () -> Date

    public convenience init(setup: SetupModel, access: UserAccess) {
        self.init(setup: setup, access: access, cap: ActivityLogs.cap, clock: { .now })
    }

    init(setup: SetupModel, access: UserAccess, cap: Int, clock: @escaping @Sendable () -> Date) {
        self.setup = setup
        self.access = access
        self.cap = cap
        self.clock = clock
    }

    /// Reads each of `query`'s logs, a few at once; a newer pull replaces an older one still reading.
    public func pull(_ query: Query) async {
        guard let tenant = setup.active else { return }
        asked += 1
        let request = asked, generation = setup.generation
        kept = (Pull(query: query, logs: [], ended: false), tenant, generation)
        readThrough = [:]
        var results: [ActivityLogs.Application: Log] = [:]
        let access = access, cap = cap, clock = clock
        let progress: @Sendable (ActivityLogs.Application, Date) async -> Void = { [weak self] application, through in
            await self?.note(application, through: through, request: request)
        }
        await withTaskGroup(of: Log.self) { group in
            var waiting = query.applications.makeIterator()
            for _ in 0..<Self.concurrent {
                guard let application = waiting.next() else { break }
                group.addTask { await Self.read(application, query, cap: cap, now: clock(), access, tenant, progress: progress) }
            }
            for await log in group {
                results[log.application] = log
                if request == asked, setup.active == tenant, setup.generation == generation {
                    kept = (Pull(query: query, logs: query.applications.compactMap { results[$0] }, ended: false), tenant, generation)
                }
                // A newer pull replaced this one: what's still reading finishes, nothing more starts.
                if request == asked, let application = waiting.next() {
                    group.addTask { await Self.read(application, query, cap: cap, now: clock(), access, tenant, progress: progress) }
                }
            }
        }
        guard request == asked, setup.active == tenant, setup.generation == generation else { return }
        kept = (Pull(query: query, logs: query.applications.compactMap { results[$0] }, ended: true), tenant, generation)
    }

    private func note(_ application: ActivityLogs.Application, through: Date, request: Int) {
        if request == asked { readThrough[application] = through }
    }

    /// One log, on the tenant the pull began on: a queued read never goes to a domain switched to since.
    private static func read(_ application: ActivityLogs.Application, _ query: Query, cap: Int, now: Date, _ access: UserAccess,
                             _ tenant: Domain, progress: @escaping @Sendable (ActivityLogs.Application, Date) async -> Void) async -> Log {
        // The window: the last `hours`, or from a time to a time; Gmail's at most 30 days back from its end.
        let end = query.to ?? now
        var start = query.from ?? end.addingTimeInterval(-Double(query.hours) * 3_600)
        if application == .gmail { start = max(start, end.addingTimeInterval(-Double(ActivityLogs.gmailMaxHours) * 3_600)) }
        let span = Int((end.timeIntervalSince(start) / 3_600).rounded(.up))
        let hours = query.from == nil ? ActivityLogs.window(application, asked: query.hours) : min(max(span, 1), 4_320)
        if application == .chrome, !query.users.isEmpty { return await chrome(query, hours: hours, cap: cap, access, tenant) }
        if application == .admin, !query.users.isEmpty { return await admin(query, hours: hours, cap: cap, access, tenant) }
        // The Devices log records no address, so a pull by one would drop it whole: its registrations instead, for the
        // accounts asked, which the reader ties to a suspect sign-in by time (syncs say nothing of an address either).
        // One event name at most: GAM caps each name's read on its own, so paging on the oldest of several would skip one's.
        let events = application == .mobile && !query.ip.isEmpty ? ["DEVICE_REGISTER_UNREGISTER_EVENT"] : []
        let ip = events.isEmpty ? query.ip : ""
        let (rows, through) = await complete(users: query.users, start: start, end: end, cap: cap) { through in
            await progress(application, through)
        } read: { users, start, end in
            await access.activity(application, users: users, hours: hours, start: start, end: end, ip: ip, events: events, cap: cap,
                                  in: tenant)
        }
        return Log(application: application, rows: rows, hours: hours, capped: through != nil, through: through)
    }

    /// Every event of the window, read oldest first (asked for after a real incident, 2026-10-23: "I need it all … the oldest
    /// first, then the newer"). One read of the whole window first: most logs come back short of the cap, and are whole.
    /// One at the cap is read a day at a time from the window's start, each day read back from its end until it's whole
    /// (`paged`, at most `perDay` reads), each day's end a second past the next day's start (whether Google keeps an end's
    /// own second isn't said), an event read twice kept once. Bounded (invariant 9): `budget` reads in all; past it, or a
    /// day still at its cap, or a read that fails, it stops there, so what's unread is the newest: `through` is when it was
    /// read completely through (nil: all of it). `progress` hears each day as it's done. A first read that fails is the
    /// failure.
    static func complete(users: [String], start: Date, end: Date, cap: Int, perDay: Int = ActivityLogs.readsPerDay,
                         budget: Int = ActivityLogs.readsPerLog, progress: (Date) async -> Void,
                         read: (_ users: [String], _ start: String, _ end: String) async -> Result<[ActivityLogs.Row], UserAccess.Problem>)
        async -> (rows: Result<[ActivityLogs.Row], UserAccess.Problem>, through: Date?) {
        let first = await read(users, time(start), time(end))
        guard case .success(let whole) = first else { return (first, nil) }
        func full(_ rows: [ActivityLogs.Row]) -> Bool {
            users.count <= 1 ? rows.count >= cap : Dictionary(grouping: rows) { $0.who.lowercased() }.contains { $0.value.count >= cap }
        }
        guard full(whole) else { return (.success(whole), nil) }
        var rows: [ActivityLogs.Row] = [], seen: Set<String> = [], reads = 1, day = start
        func newest() -> [ActivityLogs.Row] {
            rows.enumerated().sorted { a, b in
                (a.element.date ?? .distantPast, b.offset) > (b.element.date ?? .distantPast, a.offset)
            }.map(\.element)
        }
        while day < end {
            let next = min(day.addingTimeInterval(86_400), end)
            let left = min(perDay, budget - reads)
            guard left > 0 else { return (.success(newest()), day) }
            var used = 0
            let (these, dayCapped) = await paged(users: users, window: (time(day), time(next == end ? end : next.addingTimeInterval(1))),
                                                 cap: cap, pages: left) { users, start, end in
                used += 1
                return await read(users, start, end)
            }
            reads += used
            guard case .success(let read) = these else { return (.success(newest()), day) }
            rows += read.filter { seen.insert($0.identity).inserted }
            guard !dayCapped else { return (.success(newest()), day) }
            day = next
            await progress(day)
        }
        return (.success(newest()), nil)
    }

    /// A log read past its cap, still bounded (invariant 9: at most `ActivityLogs.pages` reads of `cap` each). The window
    /// is fixed once, as times, when the log's first read runs (GAM's `-<hours>h` would move with each read, and round to
    /// the minute). A read at the cap is read again over that window up to where it stopped: its oldest event's second and
    /// one more (Google may leave the end's own second out). The events already read are dropped, and it goes on until a
    /// read comes back short or the reads run out; for accounts, each one at the cap goes on by itself. Capped when a last
    /// read was still at the cap, a later read failed, or some address reached the cap that isn't one of the accounts asked
    /// (an alias, an old name: no telling which to go on with). What did come back is kept, said as capped, never passed as
    /// the whole. Newest first, as one read gives them. GAM's cap counts activities and these are events, so a read can look
    /// full sooner: an extra read, never a missed one.
    static func paged(users: [String], window: (start: String, end: String), cap: Int, pages: Int = ActivityLogs.pages,
                      _ read: (_ users: [String], _ start: String, _ end: String) async -> Result<[ActivityLogs.Row], UserAccess.Problem>)
        async -> (rows: Result<[ActivityLogs.Row], UserAccess.Problem>, capped: Bool) {
        let first = await read(users, window.start, window.end)
        guard case .success(var rows) = first else { return (first, false) }
        let start = window.start
        var seen = Set(rows.map(\.identity)), reads = 1, capped = false
        var open: [(users: [String], page: [ActivityLogs.Row])]
        if users.count <= 1 {
            // Every row of one read is that read's, whatever address it carries.
            open = rows.count >= cap ? [(users, rows)] : []
        } else {
            open = users.map { account in ([account], rows.filter { $0.who.lowercased() == account.lowercased() }) }
                .filter { $0.page.count >= cap }
            let going = Set(open.flatMap(\.users).map { $0.lowercased() })
            capped = Dictionary(grouping: rows) { $0.who.lowercased() }.contains { !going.contains($0.key) && $0.value.count >= cap }
        }
        while !open.isEmpty {
            let (who, page) = open.removeFirst()
            guard reads < pages, let oldest = page.compactMap(\.date).min() else {
                capped = true
                continue
            }
            // Read back to the window's start: nothing earlier is in it (and an end before the start is GAM's usage error).
            if let from = try? Date(start, strategy: .iso8601), oldest <= from { continue }
            reads += 1
            guard case .success(let next) = await read(who, start, time(oldest.addingTimeInterval(1))) else {
                capped = true
                continue
            }
            rows += next.filter { seen.insert($0.identity).inserted }
            guard next.count >= cap else { continue }
            // At the cap again: on from its own oldest, unless a whole read fell in that one second (no way further back).
            if let older = next.compactMap(\.date).min(), older < oldest { open.append((who, next)) } else { capped = true }
        }
        let newest = rows.enumerated().sorted { a, b in
            (a.element.date ?? .distantPast, b.offset) > (b.element.date ?? .distantPast, a.offset)
        }.map(\.element)
        return (.success(newest), capped)
    }

    /// `date` as the report's time (`GamCommands.isReportTime`): UTC, to the second, rounded down.
    static func time(_ date: Date) -> String {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)).formatted(.iso8601)
    }

    /// Chrome's log for some accounts: each account read both ways at once (`GamCommands.ChromeMatch`: by the profile's
    /// account, and by GAM's own device match, which finds a Chromebook's sign-ins), an event the second read repeats
    /// dropped, newest first. One read that fails fails the log in GAM's words, never a part passed as the whole; one at the
    /// cap marks it capped.
    private static func chrome(_ query: Query, hours: Int, cap: Int, _ access: UserAccess, _ tenant: Domain) async -> Log {
        var rows: [ActivityLogs.Row] = [], capped = false
        for user in query.users {
            async let profile = access.activity(.chrome, users: [user], hours: hours, ip: query.ip, cap: cap,
                                                chrome: .profile, in: tenant)
            async let device = access.activity(.chrome, users: [user], hours: hours, ip: query.ip, cap: cap,
                                               chrome: .device, in: tenant)
            let reads = await [profile, device]
            var seen: Set<String> = []
            for read in reads {
                switch read {
                case .success(let read):
                    capped = capped || read.count >= cap
                    rows += read.filter { !seen.contains($0.identity) }
                    seen.formUnion(read.map(\.identity))
                case .failure(let problem):
                    return Log(application: .chrome, rows: .failure(UserAccess.Problem(summary: "\(user): \(problem.summary)")),
                               hours: hours, capped: false)
                }
            }
        }
        let newest = rows.enumerated().sorted { a, b in
            (a.element.date ?? .distantPast, b.offset) > (b.element.date ?? .distantPast, a.offset)
        }.map(\.element)
        return Log(application: .chrome, rows: .success(newest), hours: hours, capped: capped)
    }

    /// The admin log for some accounts, read both ways at once (`GamCommands.AdminMatch`): what admins did to them (a
    /// password reset, a sign-out: the lock the reader looks for) and what they did as admins (an attacker with an admin's
    /// account). An event in both is kept once; newest first. One read that fails fails the log in GAM's words; either
    /// read at the cap for an account marks it capped.
    private static func admin(_ query: Query, hours: Int, cap: Int, _ access: UserAccess, _ tenant: Domain) async -> Log {
        async let affected = access.activity(.admin, users: query.users, hours: hours, ip: query.ip, cap: cap,
                                             admin: .affected, in: tenant)
        async let actor = access.activity(.admin, users: query.users, hours: hours, ip: query.ip, cap: cap,
                                          admin: .actor, in: tenant)
        let reads = await [affected, actor]
        var rows: [ActivityLogs.Row] = [], seen: Set<String> = []
        for (read, what) in zip(reads, ["What admins did to these accounts", "What these accounts did as admins"]) {
            switch read {
            case .success(let read):
                rows += read.filter { !seen.contains($0.identity) }
                seen.formUnion(read.map(\.identity))
            case .failure(let problem):
                return Log(application: .admin, rows: .failure(UserAccess.Problem(summary: "\(what): \(problem.summary)")), hours: hours,
                           capped: false)
            }
        }
        // What was done to an account is counted by the account it names, not by the admin who did it.
        var toEach: [String: Int] = [:]
        for row in (try? reads[0].get()) ?? [] {
            toEach[(row.parameters.first { $0.name == "USER_EMAIL" }?.value ?? "").lowercased(), default: 0] += 1
        }
        let capped = toEach.values.contains { $0 >= cap } || ActivityLogs.capped((try? reads[1].get()) ?? [], accounts: query.users, cap: cap)
        let newest = rows.enumerated().sorted { a, b in
            (a.element.date ?? .distantPast, b.offset) > (b.element.date ?? .distantPast, a.offset)
        }.map(\.element)
        return Log(application: .admin, rows: .success(newest), hours: hours, capped: capped)
    }

    public func clear() {
        asked += 1
        kept = nil
    }

    /// Shows `pull` (an incident's evidence) as the last pull, on the connected tenant; one still reading stops counting.
    public func show(_ pull: Pull) {
        guard let tenant = setup.active else { return }
        asked += 1
        kept = (pull, tenant, setup.generation)
    }

    /// The pull an incident's saved exports make (each `ActivityLogs.Export`, oldest first), put together one after another
    /// (`merged`). An export that can't be read is named in `unreadable`, the rest still read.
    public nonisolated static func evidence(_ exports: [ActivityLogs.Export]) -> (pull: Pull, unreadable: [String]) {
        var together: Pull?, unreadable: [String] = []
        for export in exports {
            guard let pull = pull(of: export) else {
                unreadable.append(export.name)
                continue
            }
            together = together.map { merged($0, pull) } ?? pull
        }
        let empty = Pull(query: Query(applications: [], users: [], hours: 0, ip: ""), logs: [], ended: true, fromEvidence: true)
        return (together ?? empty, unreadable)
    }

    /// One export as the pull it saved, or nil when a log of it isn't readable as one: its window, accounts and address,
    /// and each log's own window and cap, from its `about.txt`.
    nonisolated static func pull(of export: ActivityLogs.Export) -> Pull? {
        let about = About(export.about)
        var logs: [Log] = []
        for (application, csv) in export.logs {
            guard let rows = ActivityLogs.rows(exported: csv, application: application) else { return nil }
            logs.append(Log(application: application, rows: .success(rows), hours: about.window[application] ?? about.hours,
                            capped: about.capped.contains(application), through: about.through[application]))
        }
        // In the app's order of the logs, as every pull put together is.
        let order = ActivityLogs.Application.allCases
        logs.sort { order.firstIndex(of: $0.application)! < order.firstIndex(of: $1.application)! }
        return Pull(query: Query(applications: logs.map(\.application), users: about.users, hours: about.hours, ip: about.ip),
                    logs: logs, ended: true, fromEvidence: true)
    }

    /// `older` with `newer` added: each log's rows newest first, an event both read once (by `identity`; within one pull every
    /// row stays, as two events can match in every column), a log stopped at its cap only while both reads of it were (a
    /// read for just the accounts that matter reaches further back), and a log one of them couldn't read taken from the
    /// other. The widest window, every account if either was, and the first address given.
    public nonisolated static func merged(_ older: Pull, _ newer: Pull) -> Pull {
        var logs: [Log] = []
        for application in ActivityLogs.Application.allCases {
            let old = older.logs.first { $0.application == application }, new = newer.logs.first { $0.application == application }
            switch (old, new) {
            case (let old?, let new?):
                switch (old.rows, new.rows) {
                case (.success(let kept), .success(let read)):
                    let known = Set(kept.map(\.identity))
                    let rows = (kept + read.filter { !known.contains($0.identity) }).enumerated().sorted { a, b in
                        (a.element.date ?? .distantPast, b.offset) > (b.element.date ?? .distantPast, a.offset)
                    }.map(\.element)
                    // Both stopped short: read through the later of the two; one read whole: whole.
                    logs.append(Log(application: application, rows: .success(rows), hours: max(old.hours, new.hours),
                                    capped: old.capped && new.capped,
                                    through: old.capped && new.capped ? [old.through, new.through].compactMap { $0 }.max() : nil))
                case (.success, .failure): logs.append(old)
                default: logs.append(new)
                }
            case (let only?, nil), (nil, let only?): logs.append(only)
            case (nil, nil): break
            }
        }
        var seen: Set<String> = []
        let users = older.query.users.isEmpty || newer.query.users.isEmpty ? []
            : (older.query.users + newer.query.users).filter { seen.insert($0.lowercased()).inserted }
        let query = Query(applications: logs.map(\.application), users: users, hours: max(older.query.hours, newer.query.hours),
                          ip: older.query.ip.isEmpty ? newer.query.ip : older.query.ip)
        return Pull(query: query, logs: logs, ended: older.ended && newer.ended, fromEvidence: older.fromEvidence && newer.fromEvidence)
    }

    /// Reads `query`'s logs and adds them to the pull shown (`merged`), as "Pull Again" does for the accounts that matter:
    /// a narrower read never takes away what the wider one found. With nothing shown, a pull as any other.
    public func pull(adding query: Query) async {
        guard let shown = pull, shown.ended else { return await pull(query) }
        await pull(query)
        guard let read = pull, read.ended, read.query == query, !read.fromEvidence, let tenant = setup.active else { return }
        kept = (Self.merged(shown, read), tenant, setup.generation)
    }

    /// Which events to show ("Show the Events" on a to-do item): some accounts', from some addresses, in some logs, through
    /// some apps, or by an agent, each empty for any.
    public struct Filter: Sendable, Equatable {
        public let accounts: [String]
        public let addresses: [String]
        public let applications: [ActivityLogs.Application]
        public let apps: [String]
        public let agent: String

        public init(accounts: [String], addresses: [String] = [], applications: [ActivityLogs.Application] = [], apps: [String] = [],
                    agent: String = "") {
            (self.accounts, self.addresses, self.applications, self.apps, self.agent) = (accounts, addresses, applications, apps, agent)
        }

        public func keeps(_ row: ActivityLogs.Row) -> Bool {
            (accounts.isEmpty || accounts.contains { $0.caseInsensitiveCompare(row.who) == .orderedSame })
                && (addresses.isEmpty || addresses.contains(row.ip))
                && (applications.isEmpty || applications.contains(row.application))
                && (apps.isEmpty || apps.contains(row.app))
                && (agent.isEmpty || row.agent == agent)
        }

        /// `log` with only the rows kept, or nil when it's a log this filter leaves out, or none of its rows is kept.
        public func applied(to log: Log) -> Log? {
            guard applications.isEmpty || applications.contains(log.application) else { return nil }
            guard case .success(let rows) = log.rows else { return log }
            let kept = rows.filter(keeps)
            return kept.isEmpty ? nil : Log(application: log.application, rows: .success(kept), hours: log.hours, capped: log.capped,
                                            through: log.through)
        }

        /// "carol@example.com's events from 198.51.100.23, in Gemini, through Mail Sync Pro".
        public var words: String {
            func list(_ values: [String]) -> String {
                values.count < 3 ? values.joined(separator: " and ") : values.dropLast().joined(separator: ", ") + " and " + values.last!
            }
            var words = accounts.isEmpty ? "Every account's events" : "\(list(accounts))'s events"
            if !addresses.isEmpty { words += " from \(list(addresses))" }
            if !applications.isEmpty { words += ", in \(list(applications.map(\.name)))" }
            if !apps.isEmpty { words += ", through \(list(apps))" }
            if !agent.isEmpty { words += ", by \(agent)" }
            return words
        }
    }

    /// What an export's `about.txt` (`about(_:read:unread:exported:)`) says: the window, the accounts, the address, and for
    /// each log its own window (Gmail's at most 30 days) and whether it stopped at its cap. A line it doesn't know is
    /// passed over; one missing leaves its default (every account, any address, no window).
    struct About {
        var hours = 0, users: [String] = [], ip = ""
        var window: [ActivityLogs.Application: Int] = [:], capped: Set<ActivityLogs.Application> = []
        var through: [ActivityLogs.Application: Date] = [:]

        init(_ text: String) {
            func hoursIn(_ words: Substring) -> Int? {
                let parts = words.split(separator: " ")
                guard parts.count >= 2, let count = Int(parts[0]) else { return nil }
                return parts[1].hasPrefix("day") ? count * 24 : parts[1].hasPrefix("hour") ? count : nil
            }
            for line in text.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("Over the last "), let found = hoursIn(line.dropFirst(14)) {
                    hours = found
                } else if line.hasPrefix("From "), let to = line.range(of: " to "),
                          let from = try? Date(String(line[line.index(line.startIndex, offsetBy: 5)..<to.lowerBound]), strategy: .iso8601),
                          let until = try? Date(String(line[to.upperBound...].dropLast(line.hasSuffix(".") ? 1 : 0)), strategy: .iso8601) {
                    hours = max(1, Int((until.timeIntervalSince(from) / 3_600).rounded(.up)))
                } else if line.hasPrefix("Accounts: ") {
                    let list = line.dropFirst(10).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    users = list == "every account" ? [] : list.components(separatedBy: ", ")
                } else if line.hasPrefix("From IP address: ") {
                    let address = line.dropFirst(17).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    ip = address == "any" ? "" : address
                } else if let dash = line.range(of: "-log.csv: "),
                          let application = ActivityLogs.Application(rawValue: String(line[..<dash.lowerBound])) {
                    if line.contains("older events past the cap weren't read") { capped.insert(application) }
                    if let read = line.range(of: "read completely through "),
                       let at = try? Date(String(line[read.upperBound...].prefix { $0 != "," }), strategy: .iso8601) {
                        capped.insert(application)
                        through[application] = at
                    }
                    if let last = line.range(of: ", the last "), let found = hoursIn(line[last.upperBound...]) { window[application] = found }
                }
            }
        }
    }

    /// The export's events come from `domain`'s accounts: some event's actor is at `domain`, or none has an actor (a pull
    /// that found nothing). Keeps one tenant's logs out of another's incident.
    public nonisolated static func export(_ export: ActivityLogs.Export, isFrom domain: String) -> Bool {
        let suffix = "@" + domain.lowercased()
        var anyone = false
        for (application, csv) in export.logs {
            for row in ActivityLogs.rows(exported: csv, application: application) ?? [] where !row.who.isEmpty {
                if row.who.lowercased().hasSuffix(suffix) { return true }
                anyone = true
            }
        }
        return !anyone
    }

    /// `log`'s rows as a CSV in the one shape, every cell safe to open in a spreadsheet (`AuditExport.csv`).
    public static func csv(_ log: Log) -> String {
        AuditExport.csv(ActivityLogs.table((try? log.rows.get()) ?? []))
    }

    /// "12 hours", or "3 days" from two days up.
    public static func window(_ hours: Int) -> String {
        hours < 48 ? "\(hours) hours" : "\(hours / 24) days"
    }

    /// What Export All wrote: the new folder, the logs in it, and those left out because they weren't read.
    public struct Exported: Sendable {
        public let folder: URL
        public let written: [ActivityLogs.Application]
        public let unread: [ActivityLogs.Application]
    }

    /// Every log of `pull` that was read, each as its CSV, into a new private folder (0700) in `parent`, named for when
    /// it was exported, with `about.txt` saying what was pulled: the CSVs alone don't say which window, accounts or
    /// address. A log that wasn't read is left out and said, never an empty CSV that would pass as no events. The folder
    /// is whole or gone: a file that can't be written removes it (each file is `AuditExport.writePrivately`'s).
    public static func exportAll(_ pull: Pull, into parent: URL, at now: Date = .now, timeZone: TimeZone = .current) throws -> Exported {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: now)
        let folder = try newFolder(in: parent, named: "Incident logs \(stamp)")
        let read = pull.logs.filter { (try? $0.rows.get()) != nil }
        let unread = pull.logs.filter { (try? $0.rows.get()) == nil }
        do {
            for log in read {
                try AuditExport.writePrivately(csv(log), to: folder.appending(path: "\(log.application.rawValue)-log.csv"))
            }
            try AuditExport.writePrivately(about(pull, read: read, unread: unread, exported: "\(stamp) \(timeZone.identifier)"),
                                           to: folder.appending(path: "about.txt"))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return Exported(folder: folder, written: read.map(\.application), unread: unread.map(\.application))
    }

    static func about(_ pull: Pull, read: [Log], unread: [Log], exported: String) -> String {
        let query = pull.query
        let span: String = if let from = query.from { "From \(time(from)) to \(time(query.to ?? .now))." } else {
            "Over the last \(window(query.hours))."
        }
        var lines = ["Incident logs exported \(exported).", span,
                     "Accounts: " + (query.users.isEmpty ? "every account" : query.users.joined(separator: ", ")) + ".",
                     "From IP address: " + (query.ip.isEmpty ? "any" : query.ip) + ".", ""]
        for log in read {
            let count = (try? log.rows.get().count) ?? 0
            let stopped: String = if !log.capped { "" } else if let through = log.through {
                "; read completely through \(time(through)), later events weren't read"
            } else {
                "; older events past the cap weren't read"
            }
            lines.append("\(log.application.rawValue)-log.csv: the \(log.application.name) log, \(count) events"
                         + (log.hours < query.hours ? ", the last \(window(log.hours)) (the most it reads)" : "") + stopped + ".")
        }
        for log in unread {
            if case .failure(let problem) = log.rows { lines.append("Not exported, not read: the \(log.application.name) log: \(problem.summary)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A new folder, never an existing one (" (2)" and on when the name is taken), only its owner's (0700).
    private static func newFolder(in parent: URL, named name: String) throws -> URL {
        for n in 1...99 {
            let folder = parent.appending(path: n == 1 ? name : "\(name) (\(n))", directoryHint: .isDirectory)
            if mkdir(folder.path, 0o700) == 0 { return folder }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }
}
