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

    /// The scheduled runs, in the runs' order, with whether each is due now.
    public func scheduled() -> [(run: AuditRuns.Run, due: AuditSchedules.Due)] {
        AuditRuns.all.compactMap { run in due(run).map { (run, $0) } }
    }

    private func tenantChanged() {
        schedules = [:]
        problem = nil
        loaded = false
        kept = [:]
        notices = [:]
    }

    /// The connected domain's schedules, read again. A read that ends after a switch is dropped.
    public func refresh() async {
        guard let store, let domain = setup.active else {
            tenantChanged()
            return
        }
        let generation = setup.generation
        let read = await Task.detached { () -> Result<[String: AuditSchedules.Schedule], AuditSchedules.Problem> in
            do throws(AuditSchedules.Problem) { return .success(try store.schedules(domain)) } catch { return .failure(error) }
        }.value
        guard setup.active == domain, setup.generation == generation else { return }
        switch read {
        case .success(let found): (schedules, problem) = (found, nil)
        case .failure(let error): (schedules, problem) = ([:], error.reason)
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
