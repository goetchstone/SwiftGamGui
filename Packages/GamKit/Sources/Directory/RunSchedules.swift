import Foundation
import GamEngine
import Observation
import Setup
import Stores
import Vault

/// The audit runs' schedules on the connected domain (plan F7a, GamGUI #176's routes): which are due, for Home and each run's
/// pane; a run's schedule saved, changed or stopped; its kept runs listed and deleted; and a removed domain's all deleted.
///
/// **Nothing here runs anything** (`WriteRouteTests.aScheduleRunsNothing`): no timer, no task of its own, no notification. A
/// schedule only says a run is due; the run is the operator's Run (⌘R) on its pane, `AuditRunner` as ever. Every look reads the
/// disk again, off the main actor, and only on a screen's ask.
///
/// **Per domain.** Everything is read for the domain connected now, and dropped on a switch (`onTenantChange`): a read that
/// ends after a switch is never shown, so no domain's schedules or kept runs show on another's screens, and nothing compares
/// across domains (the store keys both by domain).
///
/// **Named reports** (GamGUI #178): a named report that runs here (`AuditRuns.namedRuns`, from GAM's command catalog) is scheduled
/// like an audit run. A schedule, or kept runs, under a key nothing here runs any more (a GAM bump renamed a report's read, or a
/// report was dropped) is never due: it is listed apart (`stranded`), where it can be unscheduled and what it kept deleted.
@MainActor
@Observable
public final class RunSchedules {
    /// What a save or a delete did, in words, for one run's pane.
    public struct Notice: Sendable, Equatable {
        public let text: String
        public let problem: Bool
    }

    /// A run's kept runs (headers), or why they can't be listed.
    public enum Kept: Sendable, Equatable {
        case runs([AuditSchedules.KeptRun])
        case problem(String)

        public var runs: [AuditSchedules.KeptRun] {
            if case .runs(let runs) = self { runs } else { [] }
        }
    }

    /// The connected domain's schedules by run key, once read.
    public private(set) var schedules: [String: AuditSchedules.Schedule] = [:]
    /// Why they can't be told; then Home never says "Nothing is due".
    public private(set) var problem: String?
    /// The schedules have been read for the domain connected now.
    public private(set) var loaded = false
    /// Each run's kept runs, once its pane asked.
    public private(set) var kept: [String: Kept] = [:]
    /// What each run's last save or delete did.
    public private(set) var notices: [String: Notice] = [:]
    /// Saving or deleting now: the pane's buttons wait.
    public private(set) var isBusy = false
    /// The named reports that run here, from GAM's command catalog, once read; nil until then, or while it can't be read.
    public private(set) var namedRuns: [AuditRuns.Run]?
    /// Why the catalog couldn't be read: then whether a named report is due is unknown, and Home never says "Nothing is due".
    public private(set) var catalogProblem: String?

    /// A schedule, or runs kept on this Mac, on the connected domain for a key nothing here runs any more.
    public struct Stranded: Sendable, Equatable, Identifiable {
        public let key: String
        /// What it was called: the audit run's or named report's title, else its key.
        public let title: String
        public let schedule: AuditSchedules.Schedule?
        /// How many runs of it are kept on this Mac (0 when `keptProblem` says they couldn't be listed).
        public let kept: Int
        /// Why its kept runs couldn't be listed, in words; nil when they were.
        public var keptProblem: String?
        public var id: String { key }

        public init(key: String, title: String, schedule: AuditSchedules.Schedule?, kept: Int, keptProblem: String? = nil) {
            self.key = key
            self.title = title
            self.schedule = schedule
            self.kept = kept
            self.keptProblem = keptProblem
        }

        /// Nothing of it is scheduled or kept any more: its pane stays up with what clearing it did (GamGUI's `_unstrand`).
        public var cleared: Bool { schedule == nil && kept == 0 && keptProblem == nil }
    }

    /// Each one, in key order, once the schedules were read and the catalog too.
    public private(set) var stranded: [Stranded] = []
    /// Each one cleared since this domain was connected, nothing of it left (`Stranded.cleared`): its pane and notice stay up
    /// until a switch, or until it is stranded again. Never listed on Home or among the stranded.
    public private(set) var cleared: [Stranded] = []

    /// The stranded entry `key` names, or the one just cleared: what its pane shows.
    public func strandedPane(_ key: String) -> Stranded? {
        stranded.first { $0.key == key } ?? cleared.first { $0.key == key }
    }

    /// Why GAM's command catalog couldn't be read, in words.
    public struct CatalogUnread: Error, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    /// Reads GAM's command catalog (the Builder's), off the main actor: which named reports run here.
    @ObservationIgnored public var catalog: @Sendable () -> Result<CommandCatalog, CatalogUnread> = {
        .failure(CatalogUnread("This build has no command catalog."))
    }

    /// None in a build without a data folder (it has no GAM either).
    public let store: AuditScheduleStore?
    public let clock: AuditSchedules.Clock
    private let setup: SetupModel
    private let now: @Sendable () -> Date
    /// Told when a run's schedule or kept runs change: what its pane said of its keep no longer holds.
    @ObservationIgnored public var keepChanged: @MainActor (AuditRuns.Run) -> Void = { _ in }

    public init(setup: SetupModel, store: AuditScheduleStore?, clock: AuditSchedules.Clock = .init(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.setup = setup
        self.store = store
        self.clock = clock
        self.now = now
        setup.onTenantChange { [weak self] in self?.tenantChanged() }
    }

    /// Where a schedules file that wasn't a store went, said on Home and the run's pane.
    public var setAside: URL? { store?.setAside }

    /// The run's schedule on the connected domain.
    public func schedule(of run: AuditRuns.Run) -> AuditSchedules.Schedule? { schedules[run.key] }

    /// Whether `run` is due now, in words; nil when it isn't scheduled.
    public func due(_ run: AuditRuns.Run) -> AuditSchedules.Due? {
        schedules[run.key].map { clock.due(run.title, $0, now: now().timeIntervalSince1970) }
    }

    /// Every run a schedule can name now: the audit runs, then the named reports that run here, in Reports' order.
    public var runs: [AuditRuns.Run] { AuditRuns.all + (namedRuns ?? []) }

    /// Why a schedule for a named report can't be told due or not: the catalog couldn't be read, and a schedule names a key that
    /// isn't an audit run. Nil otherwise.
    public var namedUnknown: String? {
        guard namedRuns == nil, let catalogProblem,
              schedules.keys.contains(where: { key in !AuditRuns.all.contains { $0.key == key } }) else { return nil }
        return catalogProblem
    }

    /// The run `key` names, if anything here runs it.
    public func run(_ key: String) -> AuditRuns.Run? { runs.first { $0.key == key } }

    /// The scheduled runs, in the runs' order (the audit runs, then the named reports), with whether each is due now. A schedule
    /// for a key nothing here runs is never due: it is in `stranded`.
    public func scheduled() -> [(run: AuditRuns.Run, due: AuditSchedules.Due)] {
        runs.compactMap { run in due(run).map { (run, $0) } }
    }

    private func tenantChanged() {
        schedules = [:]
        problem = nil
        loaded = false
        kept = [:]
        notices = [:]
        stranded = []
        cleared = []
    }

    /// The named reports that run here, read from the catalog once (the vendored GAM's: it doesn't change while the app runs). A
    /// catalog that couldn't be read is said, and read again on the next look.
    private func loadNamedRuns() async {
        guard namedRuns == nil else { return }
        let catalog = catalog
        let read = await Task.detached { () -> Result<[AuditRuns.Run], CatalogUnread> in catalog().map(AuditRuns.namedRuns) }.value
        switch read {
        case .success(let runs): (namedRuns, catalogProblem) = (runs, nil)
        case .failure(let unread):
            catalogProblem = "GAM's command catalog couldn't be read, so no named report runs here and whether one is due is unknown. "
                + unread.reason
        }
    }

    /// The connected domain's schedules, read again, and what is scheduled or kept there for a key nothing here runs. A read
    /// that ends after a switch is dropped.
    public func refresh() async {
        await loadNamedRuns()
        guard let store, let domain = setup.active else {
            tenantChanged()
            return
        }
        let generation = setup.generation
        // Unknown while the catalog can't be read: then nothing is said to be stranded.
        let runnable = namedRuns.map { Set((AuditRuns.all + $0).map(\.key)) }
        let titles = Dictionary(AuditRuns.all.map { ($0.key, $0.title) } + NamedReport.all.map { ($0.key, $0.title) },
                                uniquingKeysWith: { first, _ in first })
        let read = await Task.detached { () -> Result<([String: AuditSchedules.Schedule], [Stranded]), AuditSchedules.Problem> in
            do throws(AuditSchedules.Problem) {
                // Only the schedules file unread is a problem: the stranded scan below fails soft (GamGUI's runs page falls
                // back to none), so one kept folder that can't be read never hides every schedule, or the pane that could
                // delete it (review of #197).
                let mine = try store.schedules(domain)
                guard let runnable else { return .success((mine, [])) }
                var stranded: [Stranded] = []
                let folders = (try? store.runKeys(domain)) ?? []
                let keys = Set(mine.keys).union(folders).subtracting(runnable)
                for key in keys.sorted(by: { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }) {
                    do throws(AuditSchedules.Problem) {
                        let kept = try store.runs(domain, run: key).count
                        if mine[key] != nil || kept > 0 {
                            stranded.append(Stranded(key: key, title: titles[key] ?? key, schedule: mine[key], kept: kept))
                        }
                    } catch {
                        // Its kept runs can't be listed: it is still listed, so it can be unscheduled or its runs deleted.
                        stranded.append(Stranded(key: key, title: titles[key] ?? key, schedule: mine[key], kept: 0,
                                                 keptProblem: error.reason))
                    }
                }
                return .success((mine, stranded))
            } catch {
                return .failure(error)
            }
        }.value
        guard setup.active == domain, setup.generation == generation else { return }
        switch read {
        case .success(let (found, left)):
            (schedules, stranded, problem) = (found, left, nil)
            cleared.removeAll { entry in left.contains { $0.key == entry.key } }   // stranded again
        case .failure(let error): (schedules, stranded, problem) = ([:], [], error.reason)
        }
        loaded = true
    }

    /// `run`'s kept runs on the connected domain, read again (headers only).
    public func refreshKept(_ run: AuditRuns.Run) async {
        guard let store, let domain = setup.active else { return }
        let generation = setup.generation
        let read = await Task.detached { () -> Kept in
            do throws(AuditSchedules.Problem) { return .runs(try store.runs(domain, run: run.key)) } catch { return .problem(error.reason) }
        }.value
        guard setup.active == domain, setup.generation == generation else { return }
        kept[run.key] = read
    }

    /// A run ended (its keep may have changed what's kept and when it's next due): both read again, and what the pane last said
    /// of a save or delete dropped.
    public func runEnded(_ run: AuditRuns.Run) async {
        notices[run.key] = nil
        await refresh()
        await refreshKept(run)
    }

    /// How many runs to keep, as typed: blank is the default; anything but a whole number from 1 to the cap is nil. ASCII
    /// digits only (GamGUI's `int()` also takes a sign, underscores and other scripts' digits: a listed deviation).
    public nonisolated static func keepCount(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return AuditSchedules.keepDefault }
        guard trimmed.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), trimmed.count <= 3, let keep = Int(trimmed),
              (1...AuditSchedules.keepCap).contains(keep) else { return nil }
        return keep
    }

    /// Gives `run` a cadence on the connected domain, changes it, or (nil) stops scheduling it, which deletes what it kept; then
    /// its kept runs are cut to the count. Local: nothing reaches Google, and nothing runs. The outcome is the run's notice.
    public func save(_ run: AuditRuns.Run, cadence: AuditSchedules.Cadence?, keep text: String) async {
        guard let store, let domain = setup.active, !isBusy else { return }
        guard let keep = Self.keepCount(text) ?? (cadence == nil ? AuditSchedules.keepDefault : nil) else {
            notices[run.key] = Notice(text: "Keep a whole number of runs, from 1 to \(AuditSchedules.keepCap).", problem: true)
            return
        }
        isBusy = true
        defer { isBusy = false }
        let generation = setup.generation, at = now().timeIntervalSince1970
        let result = await Task.detached { () -> Result<(saved: AuditSchedules.Schedule?, gone: Int?), AuditSchedules.Problem> in
            do throws(AuditSchedules.Problem) {
                return .success(try store.setSchedule(domain, run: run.key, cadence: cadence, keep: keep, now: at))
            } catch {
                return .failure(error)
            }
        }.value
        guard setup.active == domain, setup.generation == generation else { return }
        switch result {
        case .failure(let error):
            notices[run.key] = Notice(text: error.reason, problem: true)
        case .success(let (saved, gone)):
            keepChanged(run)
            var text = saved.map { "Saved: \($0.cadence.word.lowercased()), keeping the last \($0.keep) run\($0.keep == 1 ? "" : "s")." }
                ?? "Not scheduled."
            if let gone {
                if gone > 0 { text += " \(Self.runsWord(gone)) \(gone == 1 ? "was" : "were") deleted from this Mac." }
                notices[run.key] = Notice(text: text, problem: false)
            } else {
                notices[run.key] = Notice(text: text + " Its kept runs couldn't all be deleted: delete them below, or try again.",
                                          problem: true)
            }
        }
        await refresh()
        await refreshKept(run)
    }

    /// Deletes every run kept on this Mac for `run` on the connected domain. Its schedule stays. Local: no GAM.
    public func deleteKept(_ run: AuditRuns.Run) async {
        guard let store, let domain = setup.active, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let generation = setup.generation
        let result = await Task.detached { () -> Result<Int, AuditSchedules.Problem> in
            do throws(AuditSchedules.Problem) { return .success(try store.deleteKept(domain, run: run.key)) } catch { return .failure(error) }
        }.value
        guard setup.active == domain, setup.generation == generation else { return }
        switch result {
        case .failure(let error): notices[run.key] = Notice(text: error.reason, problem: true)
        case .success(let gone):
            keepChanged(run)
            notices[run.key] = Notice(text: gone > 0 ? "Deleted \(Self.runsWord(gone)) from this Mac." : "Nothing was kept.",
                                      problem: false)
        }
        await refreshKept(run)
    }

    /// Stops scheduling a key nothing here runs any more, which deletes what it kept, or (`deleteOnly`) deletes what it kept
    /// (GamGUI #178's `_unstrand`). Only a key listed in `stranded` on the connected domain, and never one a run here has: it
    /// can't be given a cadence. Local: no GAM. The outcome is its notice.
    public func clear(_ key: String, deleteOnly: Bool) async {
        guard let store, let domain = setup.active, !isBusy, run(key) == nil,
              let listed = stranded.first(where: { $0.key == key }) else { return }
        isBusy = true
        defer { isBusy = false }
        let generation = setup.generation, at = now().timeIntervalSince1970
        let result = await Task.detached { () -> Result<Int?, AuditSchedules.Problem> in
            do throws(AuditSchedules.Problem) {
                if deleteOnly { return .success(try store.deleteKept(domain, run: key)) }
                return .success(try store.setSchedule(domain, run: key, cadence: nil, keep: AuditSchedules.keepDefault, now: at).gone)
            } catch {
                return .failure(error)
            }
        }.value
        guard setup.active == domain, setup.generation == generation else { return }
        switch result {
        case .failure(let error):
            notices[key] = Notice(text: error.reason, problem: true)
        case .success(nil):
            notices[key] = Notice(text: "Not scheduled. Its kept runs couldn't all be deleted: try again.", problem: true)
        case .success(let gone?) where deleteOnly:
            notices[key] = Notice(text: gone > 0 ? "Deleted \(Self.runsWord(gone)) from this Mac." : "Nothing was kept.", problem: false)
        case .success(let gone?):
            notices[key] = Notice(text: "Not scheduled." + (gone > 0 ? " \(Self.runsWord(gone)) \(gone == 1 ? "was" : "were") deleted "
                                                            + "from this Mac." : ""), problem: false)
        }
        await refresh()
        // Gone from the stranded list: its pane stays up, with what clearing it did, until a switch (GamGUI's `now`).
        guard setup.active == domain, setup.generation == generation, !stranded.contains(where: { $0.key == key }) else { return }
        cleared.removeAll { $0.key == key }
        cleared.append(Stranded(key: key, title: listed.title, schedule: nil, kept: 0))
    }

    /// A domain Setup removed: its schedules and the runs they kept on this Mac (its data at rest) go with it. What went, in words
    /// to add to Setup's notice.
    public func forget(_ domain: Domain) async -> String {
        guard let store else { return "" }
        let result = await Task.detached { () -> Result<(schedules: Int, kept: Int), AuditSchedules.Problem> in
            do throws(AuditSchedules.Problem) { return .success(try store.forget(domain)) } catch { return .failure(error) }
        }.value
        switch result {
        case .failure:
            return " Its schedules and the runs they kept on this Mac couldn't all be deleted: what is left is in \(store.root.path)."
        case .success(let (schedules, kept)):
            guard schedules > 0 || kept > 0 else { return "" }
            return " Its \(schedules) schedule\(schedules == 1 ? "" : "s") and \(kept) kept run\(kept == 1 ? "" : "s") on this Mac were deleted."
        }
    }

    /// "2 kept runs", "1 kept run".
    static func runsWord(_ count: Int) -> String { "\(count) kept run\(count == 1 ? "" : "s")" }
}
