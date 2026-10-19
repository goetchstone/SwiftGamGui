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
        let rows = await access.activity(application, users: query.users, hours: hours, ip: query.ip, cap: ActivityLogs.cap, in: tenant)
        return Log(application: application, rows: rows, hours: hours,
                   capped: (try? rows.get()).map { ActivityLogs.capped($0, accounts: query.users) } ?? false)
    }

    public func clear() {
        asked += 1
        kept = nil
    }

    /// `log`'s rows as a CSV in the one shape, every cell safe to open in a spreadsheet (`AuditExport.csv`).
    public static func csv(_ log: Log) -> String {
        AuditExport.csv(ActivityLogs.table((try? log.rows.get()) ?? []))
    }
}
