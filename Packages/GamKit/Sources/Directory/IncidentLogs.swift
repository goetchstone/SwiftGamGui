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

        public init(applications: [ActivityLogs.Application], users: [String], hours: Int, ip: String) {
            self.applications = applications
            self.users = users
            self.hours = hours
            self.ip = ip
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
        /// Some account reached the cap: its older events weren't read.
        public let capped: Bool
        public var id: ActivityLogs.Application { application }
    }

    public struct Pull: Sendable {
        public let query: Query
        /// In the query's order, each as it finishes.
        public internal(set) var logs: [Log]
        public internal(set) var ended: Bool

        /// The sign-in log's IP addresses, the flagged ones first: what to filter every log by next.
        public var addresses: [String] {
            ActivityLogs.addresses(in: logs.first { $0.application == .login }.flatMap { try? $0.rows.get() } ?? [])
        }
    }

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

    public init(setup: SetupModel, access: UserAccess) {
        self.setup = setup
        self.access = access
    }

    /// Reads each of `query`'s logs, a few at once; a newer pull replaces an older one still reading.
    public func pull(_ query: Query) async {
        guard let tenant = setup.active else { return }
        asked += 1
        let request = asked, generation = setup.generation
        kept = (Pull(query: query, logs: [], ended: false), tenant, generation)
        var results: [ActivityLogs.Application: Log] = [:]
        let access = access
        await withTaskGroup(of: Log.self) { group in
            var waiting = query.applications.makeIterator()
            for _ in 0..<Self.concurrent {
                guard let application = waiting.next() else { break }
                group.addTask { await Self.read(application, query, access, tenant) }
            }
            for await log in group {
                results[log.application] = log
                if request == asked, setup.active == tenant, setup.generation == generation {
                    kept = (Pull(query: query, logs: query.applications.compactMap { results[$0] }, ended: false), tenant, generation)
                }
                // A newer pull replaced this one: what's still reading finishes, nothing more starts.
                if request == asked, let application = waiting.next() { group.addTask { await Self.read(application, query, access, tenant) } }
            }
        }
        guard request == asked, setup.active == tenant, setup.generation == generation else { return }
        kept = (Pull(query: query, logs: query.applications.compactMap { results[$0] }, ended: true), tenant, generation)
    }

    /// One log, on the tenant the pull began on: a queued read never goes to a domain switched to since.
    private static func read(_ application: ActivityLogs.Application, _ query: Query, _ access: UserAccess, _ tenant: Domain) async -> Log {
        let hours = ActivityLogs.window(application, asked: query.hours)
        if application == .chrome, !query.users.isEmpty { return await chrome(query, hours: hours, access, tenant) }
        if application == .admin, !query.users.isEmpty { return await admin(query, hours: hours, access, tenant) }
        // The Devices log records no address, so a pull by one would drop it whole: its registrations instead, for the
        // accounts asked, which the reader ties to a suspect sign-in by time (syncs say nothing of an address either).
        let rows = application == .mobile && !query.ip.isEmpty
            ? await access.activity(.mobile, users: query.users, hours: hours, events: ["DEVICE_REGISTER_UNREGISTER_EVENT"],
                                    cap: ActivityLogs.cap, in: tenant)
            : await access.activity(application, users: query.users, hours: hours, ip: query.ip, cap: ActivityLogs.cap, in: tenant)
        return Log(application: application, rows: rows, hours: hours,
                   capped: (try? rows.get()).map { ActivityLogs.capped($0, accounts: query.users) } ?? false)
    }

    /// Chrome's log for some accounts: each account read both ways at once (`GamCommands.ChromeMatch`: by the profile's
    /// account, and by GAM's own device match, which finds a Chromebook's sign-ins), an event the second read repeats
    /// dropped, newest first. One read that fails fails the log in GAM's words, never a part passed as the whole; one at the
    /// cap marks it capped.
    private static func chrome(_ query: Query, hours: Int, _ access: UserAccess, _ tenant: Domain) async -> Log {
        var rows: [ActivityLogs.Row] = [], capped = false
        for user in query.users {
            async let profile = access.activity(.chrome, users: [user], hours: hours, ip: query.ip, cap: ActivityLogs.cap,
                                                chrome: .profile, in: tenant)
            async let device = access.activity(.chrome, users: [user], hours: hours, ip: query.ip, cap: ActivityLogs.cap,
                                               chrome: .device, in: tenant)
            let reads = await [profile, device]
            var seen: Set<String> = []
            for read in reads {
                switch read {
                case .success(let read):
                    capped = capped || read.count >= ActivityLogs.cap
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
    private static func admin(_ query: Query, hours: Int, _ access: UserAccess, _ tenant: Domain) async -> Log {
        async let affected = access.activity(.admin, users: query.users, hours: hours, ip: query.ip, cap: ActivityLogs.cap,
                                             admin: .affected, in: tenant)
        async let actor = access.activity(.admin, users: query.users, hours: hours, ip: query.ip, cap: ActivityLogs.cap,
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
        let capped = toEach.values.contains { $0 >= ActivityLogs.cap }
            || ActivityLogs.capped((try? reads[1].get()) ?? [], accounts: query.users)
        let newest = rows.enumerated().sorted { a, b in
            (a.element.date ?? .distantPast, b.offset) > (b.element.date ?? .distantPast, a.offset)
        }.map(\.element)
        return Log(application: .admin, rows: .success(newest), hours: hours, capped: capped)
    }

    public func clear() {
        asked += 1
        kept = nil
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
        var lines = ["Incident logs exported \(exported).",
                     "Over the last \(window(query.hours)).",
                     "Accounts: " + (query.users.isEmpty ? "every account" : query.users.joined(separator: ", ")) + ".",
                     "From IP address: " + (query.ip.isEmpty ? "any" : query.ip) + ".", ""]
        for log in read {
            let count = (try? log.rows.get().count) ?? 0
            lines.append("\(log.application.rawValue)-log.csv: the \(log.application.name) log, \(count) events"
                         + (log.hours < query.hours ? ", the last \(window(log.hours)) (the most it reads)" : "")
                         + (log.capped ? "; older events past the cap weren't read" : "") + ".")
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
