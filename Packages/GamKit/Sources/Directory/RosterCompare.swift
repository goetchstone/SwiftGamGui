import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Stores

/// Compare with Classroom and hand the change list over (plan 2026-11-11 C3, C4; GamGUI's `web/routes/roster.py` at
/// 07c505d). Read only toward Google: the compare runs two Classroom reads and one directory read, one after another, and
/// plans against the kept roster (`RosterPlan`); nothing is written to Classroom, ever. The hand-over is files someone runs
/// with GAM outside this app (`RosterHandover`), saved privately (0600) and never opened.
///
/// One compare runs at a time and can't be stopped (reads at once, no "between targets"); it carries on when the screen is
/// left. Its change list is held in memory only, for the tenant and the kept roster it was made from: a new upload or a
/// purge (another roster, or none) and a tenant switch drop it, and drop a compare still reading too: its reads finish
/// unseen and store nothing, and the next ask starts at once. Both are audited as local events: `roster_compare` (counts
/// and flagged kinds) and `roster_handover` (counts and the flagged kinds included). Never a row.
@MainActor
@Observable
public final class RosterCompare {
    /// A finished compare.
    public struct Held: Sendable {
        public let domain: String
        let generation: Int
        /// The kept roster's hash: the change list is of that roster only.
        public let sha256: String
        /// When it was compared, as the screen and the hand-over say it: `2026-11-11 18:00 UTC`.
        public let when: String
        public let plan: RosterPlan.ChangeList
        /// This compare and no other: the screen resets on it (two compares can share a minute, so `when` can't).
        public let id = UUID()
        /// The change list's search text, lowered once (`RosterPlan.page` runs per keystroke on tens of thousands of rows).
        public let haystack: RosterPlan.Haystack

        init(domain: String, generation: Int, sha256: String, when: String, plan: RosterPlan.ChangeList,
             haystack: RosterPlan.Haystack? = nil) {
            (self.domain, self.generation, self.sha256, self.when, self.plan) = (domain, generation, sha256, when, plan)
            self.haystack = haystack ?? RosterPlan.Haystack(plan)
        }
    }

    /// What one ask came to, for the screen to say.
    public enum Outcome: Sendable {
        case compared(Held)
        case failed(String)
        /// A compare is already reading for this tenant and roster: this ask was ignored.
        case busy
        /// Dropped before it finished (a new roster, a purge, a tenant switch), or no tenant: nothing was stored.
        case dropped
    }

    private struct Tenant: Equatable {
        let domain: String
        let generation: Int
    }

    /// One compare: its tenant and itself (a dropped compare's reads may still be finishing; they're no longer this).
    private struct Run: Equatable {
        let tenant: Tenant
        let id = UUID()
    }

    private var held: Held?
    private var running: Run?
    private var failure: (tenant: Tenant, message: String)?
    private let setup: SetupModel
    private let access: UserAccess
    private let store: RosterStore
    private let auditURL: URL
    @ObservationIgnored private let now: @MainActor () -> Date

    /// A compare that found no roster kept.
    public static let noRoster = "No roster is kept to compare. Read the export again."

    public init(setup: SetupModel, access: UserAccess, store: RosterStore, auditURL: URL,
                now: @escaping @MainActor () -> Date = Date.init) {
        self.setup = setup
        self.access = access
        self.store = store
        self.auditURL = auditURL
        self.now = now
        // A switch made anywhere drops the last tenant's change list at once: nothing of one domain is held under another.
        setup.onTenantChange { [weak self] in self?.drop() }
    }

    private var tenant: Tenant? { setup.active.map { Tenant(domain: $0.name, generation: setup.generation) } }

    /// The change list for the connected tenant, when it's of the roster kept now (`sha256`, the kept roster's hash).
    public func held(for sha256: String?) -> Held? {
        guard let held, let sha256, Tenant(domain: held.domain, generation: held.generation) == tenant,
              held.sha256.utf8.elementsEqual(sha256.utf8) else { return nil }
        return held
    }

    /// A compare is reading for the connected tenant.
    public var isRunning: Bool { running != nil && running?.tenant == tenant }

    /// Why the last compare for the connected tenant failed, in fixed words (or GAM's scrubbed message).
    public var problem: String? { failure.flatMap { $0.tenant == tenant ? $0.message : nil } }

    /// Drops the change list, any failure and the compare reading (it stores nothing when it ends): a new upload, a
    /// purge, a tenant switch.
    public func drop() {
        held = nil
        failure = nil
        running = nil
    }

    /// Reads Classroom and the directory, and plans against the kept roster. One at a time: a second ask while one runs is
    /// ignored (`.busy`). Not stopped by the screen going away; dropped by `drop()`.
    @discardableResult
    public func compare() async -> Outcome {
        guard let mine = tenant else { return .dropped }
        guard running == nil else { return .busy }
        let run = Run(tenant: mine)
        running = run
        failure = nil
        defer { if running == run { running = nil } }
        /// Still this tenant's compare, not dropped since.
        func current() -> Bool { running == run && tenant == mine }
        let store = self.store, domain = mine.domain
        let kept = await Task.detached { () -> Result<(RosterStore.Meta, RosterSnapshot)?, RosterStore.Failure> in
            do {
                guard let meta = try store.meta(domain: domain), let snapshot = try store.load(domain: domain) else { return .success(nil) }
                return .success((meta, snapshot))
            } catch let failure as RosterStore.Failure {
                return .failure(failure)
            } catch {
                return .failure(RosterStore.Failure("The kept roster couldn't be read."))
            }
        }.value
        guard current(), let pinned = setup.active else { return .dropped }
        let meta: RosterStore.Meta, snapshot: RosterSnapshot
        switch kept {
        case .failure(let problem):
            failure = (mine, problem.message)
            return .failed(problem.message)
        case .success(nil):
            failure = (mine, Self.noRoster)
            return .failed(Self.noRoster)
        case .success(let found?):
            (meta, snapshot) = found
        }
        let classroom: Classroom.State
        switch await access.classroomState(in: pinned) {
        case .failure(let problem):
            guard current() else { return .dropped }
            failure = (mine, problem.summary)
            return .failed(problem.summary)
        case .success(let state):
            classroom = state
        }
        // Fresh: it decides who is added. Without it addresses aren't checked, and the list says so.
        let directory = await access.directoryAddresses(in: pinned).flatMap { $0.isEmpty ? nil : $0 }
        guard current() else { return .dropped }
        let (plan, haystack) = await Task.detached {
            var plan = RosterPlan.plan(snapshot, classroom: classroom.classes, directory: directory, unread: classroom.unread.count)
            if directory == nil { plan.notes.append(RosterPlan.directoryUnread) }
            return (plan, RosterPlan.Haystack(plan))
        }.value
        guard current() else { return .dropped }
        let when = Self.clock(now())
        let made = Held(domain: domain, generation: mine.generation, sha256: meta.sha256, when: when, plan: plan, haystack: haystack)
        held = made
        var counts = JSONObject()
        for kind in RosterPlan.Kind.allCases where plan.count(kind) > 0 { counts[kind.rawValue] = .number(String(plan.count(kind))) }
        let extra: JSONObject = ["compared": .string(when), "roster_sha256": .string(meta.sha256), "counts": .object(counts),
                                 "flagged": .array(plan.flags.map { .string($0.kind.rawValue) }), "incomplete": .bool(plan.incomplete),
                                 "unread": .number(String(classroom.unread.count)),
                                 "unmanaged_ignored": .number(String(plan.unmanagedIgnored))]
        let auditURL = self.auditURL
        _ = await Task.detached { Self.audit(auditURL, "roster_compare", domain: domain, extra: extra) }.value
        return .compared(made)
    }

    /// Saves the hand-over of `held` as a ZIP at `destination` (0600, whole or not at all), with the flagged kinds the
    /// operator ticked (any other is ignored). A sentence for the screen: what was saved, or why not, in fixed words.
    public func handOver(_ held: Held, including flagged: [RosterPlan.Kind], to destination: URL) async -> String {
        let chosen = RosterPlan.Kind.allCases.filter { flagged.contains($0) && held.plan.flag($0) != nil }
        let name = destination.lastPathComponent, plan = held.plan, domain = held.domain, when = held.when
        let auditURL = self.auditURL
        // Off the main actor, all of it: a district's first compare is tens of thousands of changes to split, encode and
        // checksum, and the operator's daily build is Debug.
        return await Task.detached { () -> String in
            let made: (bytes: [UInt8], counts: JSONObject)
            do throws(RosterHandover.Refusal) {
                made = try Self.package(plan, domain: domain, when: when, including: chosen)
            } catch {
                return error.message
            }
            do {
                try AuditExport.writePrivately(bytes: made.bytes, to: destination)
            } catch {
                return "Couldn't save \(name)."
            }
            let extra: JSONObject = ["compared": .string(when), "counts": .object(made.counts),
                                     "included_flagged": .array(chosen.map { .string($0.rawValue) })]
            let auditProblem = Self.audit(auditURL, "roster_handover", domain: domain, extra: extra)
            return "Saved the hand-over to \(name)." + (auditProblem.map { " \($0)" } ?? "")
        }.value
    }

    /// The hand-over's ZIP bytes and its audit counts (each kind handed over, by count). Pure, and off the main actor.
    nonisolated static func package(_ plan: RosterPlan.ChangeList, domain: String, when: String,
                                    including chosen: [RosterPlan.Kind]) throws(RosterHandover.Refusal) -> (bytes: [UInt8], counts: JSONObject) {
        let files = try RosterHandover.build(plan, domain: domain, when: when, including: chosen)
        var counts = JSONObject()
        for change in RosterHandover.kept(plan, including: chosen) {
            counts[change.kind.rawValue] = .number(String((counts[change.kind.rawValue]?.int ?? 0) + 1))
        }
        return (RosterHandover.zip(files, when: when), counts)
    }

    /// `2026-11-11 18:00 UTC` (GamGUI's `clock_text`).
    public nonisolated static func clock(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d UTC", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// One local event in the app's audit log; a sentence when it couldn't be written (what it records stands).
    nonisolated static func audit(_ url: URL, _ action: String, domain: String, extra: JSONObject) -> String? {
        do {
            try AuditLog(url: url).record(action, connector: "local", target: domain, ok: true, extra: extra)
            return nil
        } catch {
            return "Its audit record couldn't be written."
        }
    }
}
