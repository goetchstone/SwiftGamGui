@testable import ChangeCore
import Foundation
import GamEngine
@testable import Jobs
import Synchronization
import TestSupport
import Testing
import Vault

/// The jobs tray (GamGUI's plan U5, `test_jobs_tray.py`): every run the executor makes reported as it starts, as each step ends
/// and as it finishes, in order; a run refused before it starts is no job; Stop from the tray stops it after the step in flight;
/// and the board bounded as GamGUI's registry is (invariant 9).
@MainActor
@Suite("Jobs", .serialized)
final class JobsTests {
    let example = Domain("example.com")!
    let base: URL
    let runner: AuthenticatedRunner
    let events = Shared<[JobEvent]>([])
    let confirmed = OperatorConfirmation(confirmed: true)

    init() throws {
        let store = MemoryStore()
        try store.write(Data(#"{"client_email": "gam@p.iam.gserviceaccount.com"}"#.utf8), as: .oauth2Service, for: example)
        try store.write(Data(#"{"decoded_id_token": {"email": "admin@example.com"}}"#.utf8), as: .oauth2, for: example)
        base = try RuntimeDirectory.prepare(FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-jobs-\(UUID().uuidString)/run"))
        runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: Vault(store: store), runtimeDirectory: base)
    }

    deinit {
        try? FileManager.default.removeItem(at: base.deletingLastPathComponent())
    }

    /// `lag`: the mock's new accounts aren't ready for that many calls (`GAM_MOCK_STATE`'s `new_account_lag`).
    private func executor(report: (@Sendable (JobEvent) -> Void)? = nil, lag: Int? = nil) throws -> Executor {
        let events = events, example = example
        var environment = Fixtures.mockEnvironment
        if let lag {
            let state = base.deletingLastPathComponent().appending(path: "state-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try Data("\(lag)\n".utf8).write(to: state.appending(path: "new_account_lag"))
            environment["GAM_MOCK_STATE"] = state.path
        }
        return Executor(runner: runner, audit: AuditLog(url: base.deletingLastPathComponent().appending(path: "audit/audit.jsonl")),
                        actor: "admin@example.com", tenant: { (example, 1) }, extraEnvironment: environment,
                        jobs: report ?? { event in events.value.withLock { $0.append(event) } })
    }

    private func suspend(_ email: String) -> WriteStep {
        WriteStep(GamCommands.setSuspended(email: email, suspended: true), target: email, summary: "Suspend \(email)")
    }

    /// A run, reported in order: started (its preview, its title, how many steps), each step as it ends in words, finished. A
    /// preview's title is its screen's, else its one kind of change and whom it's for.
    @Test func aRunIsReportedAsItGoes() async throws {
        let executor = try executor()
        let preview = try await executor.preview([suspend("alice@example.com"), suspend("bob@example.com")]).get()
        #expect(preview.title == "Suspend user for 2 addresses")
        #expect(await executor.run(preview, confirmation: confirmed).succeeded)
        let reported = events.value.withLock { $0 }
        guard case .started(let job, preview.id, "Suspend user for 2 addresses", 2)? = reported.first else { Issue.record("\(reported)"); return }
        #expect(Array(reported.dropFirst()) == [
            .step(job: job, item: "Suspend user: alice@example.com", outcome: .succeeded, detail: ""),
            .step(job: job, item: "Suspend user: bob@example.com", outcome: .succeeded, detail: ""),
            .finished(job: job),
        ])
        let titled = try await executor.preview([suspend("carol@example.com")], title: "Offboarding carol@example.com").get()
        #expect(titled.title == "Offboarding carol@example.com")
        #expect(Executor.title(of: [suspend("a@example.com"), WriteStep(GamCommands.signOutUser(email: "a@example.com"), target: "a@example.com",
                                                                         summary: ""), suspend("b@example.com")])
                == "3 changes for a@example.com and 1 more")
    }

    /// A run refused before any step (unconfirmed, expired, another tenant) is no job: nothing ran.
    @Test func aRefusedRunIsNoJob() async throws {
        let executor = try executor()
        let preview = try await executor.preview([suspend("alice@example.com")]).get()
        let refused = await executor.run(preview, confirmation: OperatorConfirmation(confirmed: false))
        #expect(refused.refusal != nil && events.value.withLock { $0.isEmpty })
    }

    /// Stop from the tray: the step in flight finishes, the rest are "not run", the job says it ended so, and a stop after the
    /// end does nothing.
    @Test func stopFromTheTrayStopsAfterTheStepInFlight() async throws {
        let board = JobBoard()
        let executor = try executor(report: board.report)
        board.stopRun = { @Sendable id in await executor.stopAfterCurrentStep(id) }
        let preview = try await executor.preview([suspend("alice@example.com"), suspend("bob@example.com"), suspend("carol@example.com")]).get()
        let calls = Shared(0)
        await executor.setBeforeEachStep { @Sendable in
            guard calls.value.withLock({ $0 += 1; return $0 }) == 2 else { return }
            // The tray's Stop, while step 2 is about to run: its job has been reported by now.
            for _ in 0..<100 where await MainActor.run(body: { board.jobs.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
            let job = await MainActor.run { board.jobs.first?.id }
            #expect(await board.stop(job!))
        }
        let outcome = await executor.run(preview, confirmation: confirmed)
        #expect(outcome.steps[2] == .skipped(reason: Executor.stopped))
        for _ in 0..<100 where board.jobs.first?.finished != true { try await Task.sleep(for: .milliseconds(10)) }
        let job = try #require(board.jobs.first)
        #expect(job.finished && job.succeeded == 2 && job.notRun == 1 && job.done == 3 && !job.stopping)
        #expect(job.status == "Ended: 2 of 3 succeeded, 1 not run.")
        #expect(job.recent.last == Job.Step(item: "Suspend user: carol@example.com", outcome: .notRun, detail: Executor.stopped))
        #expect(await board.stop(job.id) == false, "after the end")
    }

    /// A Stop from the tray stops the whole run, its wait for Google too: a new account's signature waiting when the tray's Stop
    /// comes is never retried, so nothing more of the run reaches GAM (review 2026-10-28: the retry ran it 20 seconds later).
    @Test func aStoppedRunLeavesNothingToRetry() async throws {
        let board = JobBoard()
        let executor = try executor(report: board.report, lag: 5)
        board.stopRun = { @Sendable id in await executor.stopAfterCurrentStep(id) }
        let email = "new@example.com", password = "Xk7m-Qp9r-2Tzv"
        let create = WriteStep(GamCommands.createUser(email: email, firstName: "J", lastName: "L", password: password), target: email,
                               summary: "Create", secrets: [Secret(Data(password.utf8))])
        let signature = WriteStep(GamCommands.setSignature(email: email, signature: "<b>J</b>"), target: email, summary: "Signature",
                                  requires: [0], newAccountFrom: 0)
        let group = WriteStep(GamCommands.addGroupMember(group: "sales@example.com", member: email), target: email, summary: "Group",
                              requires: [0])
        let preview = try await executor.preview([create, signature, group, suspend("bob@example.com")], title: "Onboarding \(email)").get()
        let calls = Shared(0)
        await executor.setBeforeEachStep { @Sendable in
            guard calls.value.withLock({ $0 += 1; return $0 }) == 3 else { return }
            for _ in 0..<100 where await MainActor.run(body: { board.jobs.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
            let job = await MainActor.run { board.jobs.first?.id }
            #expect(await board.stop(job!))
        }
        let outcome = await executor.run(preview, confirmation: confirmed)
        #expect(outcome.steps[1].isWaiting && outcome.steps[3] == .skipped(reason: Executor.stopped))
        #expect(outcome.retry == nil, "stopped: nothing parked for a retry")
    }

    /// Bounded as GamGUI's registry: the newest steps, the first failures with every one counted, each reason cut short, the
    /// newest finished runs; the tray running first, then finished, newest first in each, at most its rows.
    @Test func theBoardIsBounded() {
        let board = JobBoard()
        let big = UUID()
        board.handle(.started(job: big, preview: UUID(), title: "Big", total: 500))
        for n in 0..<300 {
            board.handle(.step(job: big, item: "Step \(n)", outcome: n.isMultiple(of: 2) ? .succeeded : .failed, detail: String(repeating: "x", count: 1_000)))
        }
        let job = board.jobs[0]
        #expect(job.done == 300 && job.failedTotal == 150 && job.failed.count == 150 && job.recent.count == JobBoard.window)
        #expect(job.recent.last?.item == "Step 299" && job.failed.first?.detail.count == JobBoard.detailCap)
        for n in 0..<250 { board.handle(.step(job: big, item: "More \(n)", outcome: .failed, detail: "")) }
        #expect(board.jobs[0].failed.count == JobBoard.failedCap && board.jobs[0].more == 400 - JobBoard.failedCap)
        #expect(board.jobs[0].status == "Running: 550 of 500 steps done, 400 failed.")

        let runs = (0..<12).map { _ in UUID() }
        for (n, id) in runs.enumerated() {
            board.handle(.started(job: id, preview: UUID(), title: "Run \(n)", total: 1))
            board.handle(.finished(job: id))
        }
        #expect(board.jobs.filter(\.finished).count == JobBoard.finishedKept && !board.jobs.contains { $0.title == "Run 0" })
        let tray = board.tray
        #expect(tray.rows.count == JobBoard.trayRows && tray.rows.first?.title == "Big" && tray.rows[1].title == "Run 11")
        #expect(tray.more == board.jobs.count - JobBoard.trayRows && board.running == 1)
        #expect(board.finishedCount == 12 && board.lastFinished?.title == "Run 11", "counted though only ten are kept")
        board.handle(.finished(job: runs[11]))
        #expect(board.finishedCount == 12 && board.running == 1, "a second end of one run counts once")
    }
}
