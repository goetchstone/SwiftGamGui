import Foundation
import Observation

/// Every write run, listed from any screen (GamGUI's jobs tray, plan U5): what ChangeCore's executor reports as a run starts,
/// as each step ends and as it finishes (`JobEvent`), kept here so it can be watched and stopped from anywhere. Bounded
/// (invariant 9): the full counts, but only a sample of the failures and the newest steps, and only the newest finished runs.
/// It runs nothing: Stop asks the executor to stop after the step in flight, which always finishes and is audited.
public enum JobEvent: Sendable, Equatable {
    /// A confirmed run of `preview`'s steps began checking: `total` steps to decide (a retry round's, only the steps still
    /// waiting). It may wait for another write to end and reads again what its preview assumed, seconds before a step runs.
    case started(job: UUID, preview: UUID, title: String, total: Int)
    /// The checks passed: its steps begin.
    case checked(job: UUID)
    /// One step decided: what it was, in words, and how it ended.
    case step(job: UUID, item: String, outcome: JobOutcome, detail: String)
    case finished(job: UUID)
    /// The checks refused it, for `reason` (what its screen says too): none of its steps ran.
    case refused(job: UUID, reason: String)
}

/// How a step ended, as the tray counts it.
public enum JobOutcome: Sendable, Equatable {
    case succeeded
    case failed
    /// Not begun: stopped, or a step it needs didn't succeed.
    case notRun
    /// Waiting for Google to finish a new account; a later round runs it.
    case waiting
}

/// One run, as the tray shows it.
public struct Job: Sendable, Identifiable, Equatable {
    public struct Step: Sendable, Equatable {
        public let item: String
        public let outcome: JobOutcome
        /// Why it failed or didn't run (GAM's words, masked), at most `detailCap` characters.
        public let detail: String
    }

    public let id: UUID
    /// The preview it runs: what Stop names to the executor.
    public let preview: UUID
    public let title: String
    public let total: Int
    public internal(set) var done = 0
    public internal(set) var succeeded = 0
    public internal(set) var failedTotal = 0
    public internal(set) var notRun = 0
    public internal(set) var waiting = 0
    /// The newest steps, newest last, at most `JobBoard.window`.
    public internal(set) var recent: [Step] = []
    /// The first failures, at most `JobBoard.failedCap`: `failedTotal` counts them all.
    public internal(set) var failed: [Step] = []
    /// Not begun: checking before its first step.
    public internal(set) var checking = true
    /// Why the checks refused it, at most `JobBoard.detailCap` characters: none of its steps ran.
    public internal(set) var refusal: String?
    public internal(set) var finished = false
    /// Stop was asked; the step in flight finishes, nothing after it begins.
    public internal(set) var stopping = false
    public let started: Date
    public internal(set) var ended: Date?

    /// Failures counted past the sample: "and N more".
    public var more: Int { failedTotal - failed.count }

    /// Where it stands, in words: checking, "3 of 12 steps", then how it ended.
    public var status: String {
        guard finished else {
            if checking { return stopping ? "Stopping: none of its steps will run." : "Checking before it runs (after any change running now)…" }
            return (stopping ? "Stopping after the step running: " : "Running: ") + "\(done) of \(total) step\(total == 1 ? "" : "s") done"
                + (failedTotal > 0 ? ", \(failedTotal) failed" : "") + "."
        }
        if let refusal { return "Didn't run: " + refusal }
        var parts = ["\(succeeded) of \(total) succeeded"]
        if failedTotal > 0 { parts.append("\(failedTotal) failed") }
        if notRun > 0 { parts.append("\(notRun) not run") }
        if waiting > 0 { parts.append("\(waiting) waiting for Google") }
        return (failedTotal + notRun + waiting == 0 ? "Done: " : "Ended: ") + parts.joined(separator: ", ") + "."
    }
}

/// The runs since the app started: running first, then finished, newest first in each.
@MainActor
@Observable
public final class JobBoard {
    /// Steps a job's live feed keeps (GamGUI's `RECENT_WINDOW`).
    public static let window = 12
    /// Failures a job keeps beside its count (GamGUI's `FAILED_SAMPLE_CAP`).
    public static let failedCap = 200
    /// Characters kept of a step's reason (GamGUI's `DETAIL_CAP`: GAM can echo a whole body on a usage error).
    public static let detailCap = 300
    /// Finished jobs kept (GamGUI's `register_job`'s `keep`).
    public static let finishedKept = 10
    /// Jobs the tray lists (GamGUI's `TRAY_ROWS`).
    public static let trayRows = 8

    /// Oldest first.
    public private(set) var jobs: [Job] = []
    /// Runs going now, and runs ended since launch: counters, so a view that shows only these isn't redrawn at every step.
    public private(set) var running = 0
    public private(set) var finishedCount = 0
    /// The run that ended last, for the line spoken when one does.
    public private(set) var lastFinished: Job?
    /// Asks the executor to stop a preview's run after the step in flight (`Executor.stopAfterCurrentStep`); set once the
    /// executor exists, which is made with `report`.
    @ObservationIgnored public var stopRun: (@Sendable (UUID) async -> Bool)?
    @ObservationIgnored private let continuation: AsyncStream<JobEvent>.Continuation
    @ObservationIgnored private var reader: Task<Void, Never>?

    /// What the executor reports into: in order, from any isolation.
    public nonisolated var report: @Sendable (JobEvent) -> Void {
        let continuation = continuation
        return { continuation.yield($0) }
    }

    public init() {
        let (events, continuation) = AsyncStream<JobEvent>.makeStream()
        self.continuation = continuation
        reader = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
    }

    /// One event, as the executor reported it.
    public func handle(_ event: JobEvent) {
        switch event {
        case .started(let id, let preview, let title, let total):
            jobs.append(Job(id: id, preview: preview, title: title, total: total, started: Date()))
            running += 1
        case .checked(let id):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].checking = false
        case .step(let id, let item, let outcome, let detail):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            let step = Job.Step(item: item, outcome: outcome, detail: String(detail.prefix(Self.detailCap)))
            jobs[index].checking = false
            jobs[index].done += 1
            switch outcome {
            case .succeeded: jobs[index].succeeded += 1
            case .failed:
                jobs[index].failedTotal += 1
                if jobs[index].failed.count < Self.failedCap { jobs[index].failed.append(step) }
            case .notRun: jobs[index].notRun += 1
            case .waiting: jobs[index].waiting += 1
            }
            jobs[index].recent.append(step)
            if jobs[index].recent.count > Self.window { jobs[index].recent.removeFirst() }
        case .finished(let id):
            guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].finished else { return }
            end(index)
        case .refused(let id, let reason):
            guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].finished else { return }
            jobs[index].refusal = String(reason.prefix(Self.detailCap))
            end(index)
        }
    }

    private func end(_ index: Int) {
        jobs[index].finished = true
        jobs[index].checking = false
        jobs[index].stopping = false
        jobs[index].ended = Date()
        running -= 1
        finishedCount += 1
        lastFinished = jobs[index]
        // Only the newest finished runs are kept; a running one never goes.
        let finished = jobs.filter(\.finished)
        if finished.count > Self.finishedKept {
            let dropped = Set(finished.prefix(finished.count - Self.finishedKept).map(\.id))
            jobs.removeAll { dropped.contains($0.id) }
        }
    }

    /// Asks the executor to stop `job` after the step in flight. False when it had already ended.
    @discardableResult
    public func stop(_ job: Job.ID) async -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == job }), !jobs[index].finished else { return false }
        let preview = jobs[index].preview
        guard let stopRun, await stopRun(preview) else { return false }
        if let index = jobs.firstIndex(where: { $0.id == job }), !jobs[index].finished { jobs[index].stopping = true }
        return true
    }

    /// The tray's rows (running first, then finished, newest first in each, at most `trayRows`) and how many more there are.
    public var tray: (rows: [Job], more: Int) {
        let newest = Array(jobs.reversed())
        let rows = Array((newest.filter { !$0.finished } + newest.filter(\.finished)).prefix(Self.trayRows))
        return (rows, jobs.count - rows.count)
    }
}
