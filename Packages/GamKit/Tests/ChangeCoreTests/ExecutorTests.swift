import Foundation
import Synchronization
import Testing
@testable import ChangeCore
@testable import GamEngine
import TestSupport
import Vault

/// The write chokepoint, run against the strict mock `gam`: a confirm runs exactly its held preview,
/// once, on the tenant it was made for, through the guard, audited begin and end. The cases port
/// GamGUI's `test_write_routes_guarded.py` (a bare confirm, an edited form, a replay) and §10's list
/// (a tenant switch, time asleep, a target already in flight).
/// A value tests change while the executor reads it (the tenant, the clock).
final class Shared<T: Sendable>: Sendable {
    let value: Mutex<T>
    init(_ initial: T) { value = Mutex(initial) }
}

@Suite("Executor", .serialized)
final class ExecutorTests {
    let example = Domain("example.com")!
    let other = Domain("example.org")!
    let base: URL
    let auditURL: URL
    let argvLog: URL
    let audit: AuditLog
    let runner: AuthenticatedRunner
    let tenantState: Shared<(domain: Domain, generation: Int)?>
    let offset = Shared(Duration.zero)
    let start = ContinuousClock.now

    init() throws {
        let store = MemoryStore()
        for domain in [example, other] {
            try store.write(Data(#"{"client_email": "gam@p.iam.gserviceaccount.com"}"#.utf8), as: .oauth2Service, for: domain)
            try store.write(Data(#"{"decoded_id_token": {"email": "admin@example.com"}}"#.utf8), as: .oauth2, for: domain)
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-exec-\(UUID().uuidString)")
        base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        auditURL = scratch.appending(path: "audit/audit.jsonl")
        argvLog = scratch.appending(path: "argv.log")
        audit = AuditLog(url: auditURL)
        runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: Vault(store: store), runtimeDirectory: base)
        tenantState = Shared((example, 1))
    }

    deinit {
        try? FileManager.default.removeItem(at: base.deletingLastPathComponent())
    }

    private func executor() -> Executor {
        let tenant = tenantState, offset = offset, start = start
        var environment = Fixtures.mockEnvironment
        environment["GAM_MOCK_ARGV_LOG"] = argvLog.path
        return Executor(runner: runner, audit: audit, actor: "admin@example.com",
                        tenant: { tenant.value.withLock { $0 } }, now: { start + offset.value.withLock { $0 } },
                        extraEnvironment: environment)
    }

    private func held(_ executor: Executor, _ steps: [WriteStep], origin: Origin = .form,
                      precondition: (@Sendable () async throws -> Bool)? = nil) async throws -> HeldPreview {
        try await executor.preview(steps, origin: origin, precondition: precondition).get()
    }

    /// Every argv the mock ran, in order (it logs each as a count then its elements, NUL-separated).
    private func ran() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls
    }

    private var records: [JSONObject] { AuditLog.records(at: auditURL).reversed() }

    private let confirmed = OperatorConfirmation(confirmed: true)
    private func suspend(_ email: String = "alice@example.com") -> WriteStep {
        WriteStep(GamCommands.setSuspended(email: email, suspended: true), target: email, summary: "Suspend \(email)")
    }

    // MARK: the confirm runs what was held, once

    @Test func aConfirmedPreviewRunsExactlyItsArgvOnceAndIsAuditedBeginAndEnd() async throws {
        let executor = executor()
        let preview = try await held(executor, [suspend()])
        let outcome = await executor.run(preview, confirmation: confirmed)
        #expect(outcome.refusal == nil)
        #expect(outcome.succeeded)
        #expect(ran() == [["update", "user", "alice@example.com", "suspended", "on"]])
        let phases = records.compactMap { $0["extra"]?.object?["phase"]?.string }
        #expect(phases == ["begin", "end"])
        let end = try #require(records.last)
        #expect(end["action"]?.string == "suspendUser")
        #expect(end["ok"]?.bool == true)
        #expect(end["actor"]?.string == "admin@example.com")
        #expect(end["extra"]?.object?["digest"]?.string == preview.digest)
        #expect(end["extra"]?.object?["origin"]?.string == "form")

        let again = await executor.run(preview, confirmation: confirmed)
        #expect(again.refusal == "That preview has expired or was already run — preview again.", "a replay")
        #expect(ran().count == 1)
    }

    /// GamGUI failure-log 2026-09-23: routes wrote on a bare POST. Here the executor asks the guard.
    @Test func aBareConfirmOfADestructiveChangeWritesNothing() async throws {
        let executor = executor()
        let preview = try await held(executor, [suspend()])
        let outcome = await executor.run(preview, confirmation: OperatorConfirmation())
        #expect(outcome.refusal == "This change needs confirmation — preview it, then confirm.")
        #expect(ran().isEmpty)
        #expect(records.isEmpty)
        #expect(await executor.isHeld(preview.id) == false, "a refused preview is spent too")
    }

    @Test func anAccountDeleteNeedsItsAddressTyped() async throws {
        let executor = executor()
        let step = WriteStep(GamCommands.deleteUser(email: "carol@example.com"), target: "carol@example.com", summary: "Delete")
        let refused = await executor.run(try await held(executor, [step]), confirmation: confirmed)
        #expect(refused.refusal == "Type the exact email address to confirm.")
        let typed = OperatorConfirmation(confirmed: true, typedAddresses: ["carol@example.com"])
        #expect(await executor.run(try await held(executor, [step]), confirmation: typed).succeeded)
    }

    /// A caller can't understate a write's risk: a delete marked low is still destructive.
    @Test func theRiskNeverFallsBelowTheActionsFloor() {
        let step = WriteStep(GamCommands.deleteUser(email: "a@example.com"), target: "a@example.com", summary: "", risk: .low)
        #expect(step.risk == .destructive)
        #expect(WriteStep(GamCommands.signOutUser(email: "a@example.com"), target: "a", summary: "").risk == .low)
    }

    // MARK: the preview's world must still hold

    /// GamGUI review 2, R5: a confirm left open across a tenant switch ran on the new tenant.
    @Test func aTenantSwitchAfterThePreviewRefusesIt() async throws {
        let executor = executor()
        let reread = Shared(false)
        let preview = try await held(executor, [suspend()], precondition: {
            reread.value.withLock { $0 = true }
            return true
        })
        tenantState.value.withLock { $0 = (other, 2) }
        let outcome = await executor.run(preview, confirmation: confirmed)
        #expect(outcome.refusal == "The active domain changed after the preview — preview again, so it runs on this one.")
        #expect(ran().isEmpty)
        #expect(reread.value.withLock { $0 } == false, "refused before re-reading anything on the other tenant")
    }

    /// GamGUI's binding fix: a switch landing while the run re-reads its precondition (or waits for the
    /// write lock) must still refuse it, so the tenant is checked again just before the write.
    @Test func aTenantSwitchDuringThePreconditionRefusesIt() async throws {
        let executor = executor()
        let tenant = tenantState, other = other
        let preview = try await held(executor, [suspend()], precondition: {
            tenant.value.withLock { $0 = (other, 2) }
            return true
        })
        #expect(await executor.run(preview, confirmation: confirmed).refusal
                == "The active domain changed after the preview — preview again, so it runs on this one.")
        #expect(ran().isEmpty)
    }

    /// Failure-log 2026-09-24: a lid closed mid-preview. Time asleep counts.
    @Test func aPreviewExpiresAfterFifteenMinutes() async throws {
        let executor = executor()
        let preview = try await held(executor, [suspend()])
        offset.value.withLock { $0 = Executor.previewLifetime + .seconds(1) }
        #expect(await executor.run(preview, confirmation: confirmed).refusal
                == "That preview has expired or was already run — preview again.")
        #expect(ran().isEmpty)
    }

    @Test func aChangedPreconditionAsksForANewPreviewNeverReplans() async throws {
        let executor = executor()
        let preview = try await held(executor, [suspend()], precondition: { false })
        #expect(await executor.run(preview, confirmation: confirmed).refusal == "What the preview showed has changed since — preview again.")
        #expect(ran().isEmpty)
    }

    /// Failure-log 2026-09-23: a second run started on a target whose first was still running.
    @Test func aTargetAlreadyInFlightIsRefused() async throws {
        let executor = executor()
        let (entered, enteredGate) = AsyncStream<Void>.makeStream()
        let (release, releaseGate) = AsyncStream<Void>.makeStream()
        let first = try await held(executor, [suspend()], precondition: {
            enteredGate.yield()
            for await _ in release { break }
            return true
        })
        let confirm = confirmed
        let running = Task { [executor, first] in await executor.run(first, confirmation: confirm) }
        for await _ in entered { break }
        let second = try await held(executor, [suspend()])
        #expect(await executor.run(second, confirmation: confirmed).refusal
                == "A change to alice@example.com is already running — wait for it to finish, then preview again.")
        releaseGate.yield()
        #expect(await running.value.succeeded)
        #expect(ran().count == 1)
    }

    @Test func onlyTheLatestPreviewsAreKept() async throws {
        let executor = executor()
        let oldest = try await held(executor, [suspend()])
        for _ in 0..<Executor.previewsKept { _ = try await held(executor, [suspend()]) }
        #expect(await executor.isHeld(oldest.id) == false)
    }

    @Test func noPreviewWithoutAConnectedDomain() async {
        tenantState.value.withLock { $0 = nil }
        let result = await executor().preview([suspend()])
        #expect(throws: Executor.PreviewRefusal.notConnected) { try result.get() }
    }

    // MARK: failures, plans and secrets

    /// An account-wide failure (a missing scope) would fail every later call the same way: the run stops.
    @Test func anAccountWideFailureStopsTheRestAndIsAudited() async throws {
        let executor = executor()
        let signOut = WriteStep(GamCommands.signOutUser(email: "SIGNOUTFAIL@example.com"), target: "SIGNOUTFAIL@example.com",
                                summary: "Sign out")
        let next = WriteStep(GamCommands.signOutUser(email: "alice@example.com"), target: "alice@example.com", summary: "Sign out")
        let outcome = await executor.run(try await held(executor, [signOut, next]), confirmation: confirmed)
        #expect(outcome.steps.first == .failed(
            message: "GAM failed (scope_missing, exit=50): User: SIGNOUTFAIL@example.com, Sign Out Failed: Not Authorized to access this resource/api",
            kind: .scopeMissing))
        guard case .skipped(let reason) = outcome.steps.last else { Issue.record("\(outcome.steps)"); return }
        #expect(reason.hasPrefix("Stopped: A required API scope is not authorized."))
        #expect(ran().count == 1)
        #expect(records.last?["ok"]?.bool == false)
        #expect(records.last?["extra"]?.object?["kind"]?.string == "scope_missing")
    }

    /// A plan's step that requires a failed one is skipped; an independent step still runs.
    @Test func aFailedStepSkipsOnlyWhatRequiresIt() async throws {
        let executor = executor()
        let create = WriteStep(GamCommands.createUser(email: "exists@example.com", firstName: "E", lastName: "X", password: "p"),
                               target: "exists@example.com", summary: "Create", secrets: [Secret(Data("p".utf8))])
        let needsIt = WriteStep(GamCommands.setSuspended(email: "exists@example.com", suspended: false),
                                target: "exists@example.com", summary: "Unsuspend", requires: [0])
        let independent = WriteStep(GamCommands.signOutUser(email: "alice@example.com"), target: "alice@example.com", summary: "Sign out")
        let outcome = await executor.run(try await held(executor, [create, needsIt, independent]), confirmation: confirmed)
        guard case .failed = outcome.steps[0] else { Issue.record("\(outcome.steps)"); return }
        #expect(outcome.steps[1] == .skipped(reason: "Step 1 didn't succeed."))
        guard case .succeeded = outcome.steps[2] else { Issue.record("\(outcome.steps)"); return }
        #expect(ran().count == 2)
    }

    /// GamGUI failure-log 2026-09-23: a hire surnamed "Password" shifted the positional mask. The password
    /// is masked by value in the audit, the shown argv and any error, wherever it sits.
    @Test func aSecretNeverReachesTheAuditOrTheScreen() async throws {
        let executor = executor()
        let password = "Tr0ub4dor&3"
        let create = WriteStep(
            GamCommands.createUser(email: "dana@example.com", firstName: "Dana", lastName: password, password: password),
            target: "dana@example.com", summary: "Create", secrets: [Secret(Data(password.utf8))])
        #expect(!create.shownArgv.contains { $0.contains(password) })
        #expect(!create.summary.contains(password))
        _ = await executor.run(try await held(executor, [create]), confirmation: confirmed)
        let log = try String(contentsOf: auditURL, encoding: .utf8)
        #expect(!log.contains(password))
        #expect(log.contains("dana@example.com"))
        // On the screen too: the output masks a secret wherever GAM printed it.
        let named = WriteStep(GamCommands.createUser(email: "dana2@example.com", firstName: "D", lastName: "X", password: "dana2"),
                              target: "dana2@example.com", summary: "Create dana2", secrets: [Secret(Data("dana2".utf8))])
        #expect(named.summary == "Create ***redacted***")
        let shown = await executor.run(try await held(executor, [named]), confirmation: confirmed)
        guard case .succeeded(let output) = shown.steps.first else { Issue.record("\(shown.steps)"); return }
        #expect(!output.contains("dana2") && output.contains("***redacted***"), "\(output)")
    }

    // MARK: ChangeCore's review (each fails without its fix)

    /// Invariant 10: a model's or Siri's draft needs the operator's Confirm click, even for one LOW write.
    @Test func aDraftFromAModelOrSiriNeedsTheConfirmClick() async throws {
        let executor = executor()
        let off = WriteStep(GamCommands.vacationOff(email: "alice@example.com"), target: "alice@example.com", summary: "Off")
        for origin in [Origin.model, .siri] {
            let preview = try await held(executor, [off], origin: origin)
            #expect(await executor.run(preview, confirmation: OperatorConfirmation()).refusal
                    == "This change needs confirmation — preview it, then confirm.")
        }
        #expect(ran().isEmpty)
        let form = try await held(executor, [off])
        #expect(await executor.run(form, confirmation: OperatorConfirmation()).succeeded, "a form's LOW write needs no click")
    }

    @Test func aFlowsConfirmStepAndTypedCountReachTheGuard() async throws {
        let executor = executor()
        let off = WriteStep(GamCommands.vacationOff(email: "alice@example.com"), target: "alice@example.com", summary: "Off")
        let step = try await executor.preview([off], confirmStep: true).get()
        #expect(await executor.run(step, confirmation: OperatorConfirmation()).refusal
                == "This change needs confirmation — preview it, then confirm.")
        let many = (0..<26).map { WriteStep(GamCommands.vacationOff(email: "u\($0)@example.com"), target: "u\($0)@example.com", summary: "") }
        let counted = try await executor.preview(many, typedCountAbove: Guard.countConfirmAbove).get()
        #expect(await executor.run(counted, confirmation: confirmed).refusal
                == "This changes 26 accounts: preview again, and type 26 to confirm.")
        #expect(ran().isEmpty)
    }

    /// Failure-log 2026-09-24: deleting a user by an alias deletes the account the alias belongs to. The
    /// mock resolves alice@alias.example.net to alice@example.com, as GAM does.
    @Test func deletingAnAliasIsRefusedBeforeItRuns() async throws {
        let executor = executor()
        let alias = "alice@alias.example.net"
        let step = WriteStep(GamCommands.deleteUser(email: alias), target: alias, summary: "Delete")
        let outcome = await executor.run(try await held(executor, [step]),
                                         confirmation: OperatorConfirmation(confirmed: true, typedAddresses: [alias]))
        #expect(outcome.refusal?.hasPrefix("alice@alias.example.net is an alias of alice@example.com") == true, "\(outcome)")
        #expect(!ran().contains { $0.first == "delete" })
    }

    /// No begin record, no write: here the log is a link, which the audit refuses to write through.
    @Test func aWriteThatCantBeAuditedDoesntRun() async throws {
        let executor = executor()
        try FileManager.default.createDirectory(at: auditURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: auditURL, withDestinationURL: base.appending(path: "elsewhere"))
        let outcome = await executor.run(try await held(executor, [suspend()]), confirmation: confirmed)
        guard case .failed(let message, _) = outcome.steps.first else { Issue.record("\(outcome.steps)"); return }
        #expect(message.hasPrefix("The audit log couldn't be written"))
        #expect(ran().isEmpty)
    }

    /// GamGUI's write lock: a second write waits for the first, whatever its target.
    @Test func writesAreSerialized() async throws {
        let executor = executor()
        let (started, startedGate) = AsyncStream<Void>.makeStream()
        let (release, releaseGate) = AsyncStream<Void>.makeStream()
        let first = try await held(executor, [suspend("alice@example.com")])
        let second = try await held(executor, [suspend("bob@example.com")])
        let calls = Shared(0)
        await executor.setBeforeEachStep {
            // Only the first write is held open: without the lock, the second would run meanwhile.
            guard calls.value.withLock({ $0 += 1; return $0 }) == 1 else { return }
            startedGate.yield()
            for await _ in release { break }
        }
        let confirm = confirmed
        let one = Task { [executor, first] in await executor.run(first, confirmation: confirm) }
        for await _ in started { break }
        let two = Task { [executor, second] in await executor.run(second, confirmation: confirm) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(ran().isEmpty, "the second write didn't start while the first held the lock")
        releaseGate.yield()
        #expect(await one.value.succeeded)
        #expect(await two.value.succeeded)
        #expect(ran().count == 2)
    }

    /// A lookup Google refused says nothing about whether the address is an alias: the delete waits.
    @Test func aDeleteWhoseAddressCantBeResolvedDoesntRun() async throws {
        let executor = executor()
        let address = "INFOREFUSED@example.com"
        let step = WriteStep(GamCommands.deleteUser(email: address), target: address, summary: "Delete")
        let outcome = await executor.run(try await held(executor, [step]),
                                         confirmation: OperatorConfirmation(confirmed: true, typedAddresses: [address]))
        #expect(outcome.refusal?.hasPrefix("Couldn't check INFOREFUSED@example.com before deleting it") == true, "\(outcome)")
        #expect(!ran().contains { $0.first == "delete" })
    }

    @Test func aTargetIsFreeAgainAfterItsRunAndCaseDoesntHideIt() async throws {
        let executor = executor()
        #expect(await executor.run(try await held(executor, [suspend()]), confirmation: confirmed).succeeded)
        #expect(await executor.run(try await held(executor, [suspend()]), confirmation: confirmed).succeeded, "in-flight cleared")
        #expect(Executor.key(" ALICE@example.com ") == Executor.key("alice@example.com"))
    }

    @Test func aPlanCantRequireALaterStep() async throws {
        let step = WriteStep(GamCommands.vacationOff(email: "a@example.com"), target: "a@example.com", summary: "", requires: [1])
        let next = WriteStep(GamCommands.vacationOff(email: "b@example.com"), target: "b@example.com", summary: "")
        let result = await executor().preview([step, next])
        #expect(throws: Executor.PreviewRefusal.badPrerequisite(step: 0)) { try result.get() }
    }

    /// Removing or re-importing the domain mid-plan stops the rest.
    @Test func aTenantChangeMidPlanStopsTheRest() async throws {
        let executor = executor()
        let tenant = tenantState
        let steps = ["alice", "bob", "carol"].map { suspend("\($0)@example.com") }
        let preview = try await held(executor, steps)
        let count = Shared(0)
        await executor.setBeforeEachStep {
            if count.value.withLock({ $0 += 1; return $0 }) == 1 { tenant.value.withLock { $0 = nil } }
        }
        let outcome = await executor.run(preview, confirmation: confirmed)
        #expect(outcome.steps.count == 3)
        #expect(ran().count == 1)
        #expect(outcome.steps[1] == .skipped(reason: "Stopped: the active domain changed during the run."))
    }

    @Test func aRunCancelledBeforeGamStartsIsNotRecordedAsInterrupted() async throws {
        let executor = executor()
        let preview = try await held(executor, [suspend()])
        let confirm = confirmed
        let task = Task { [executor, preview] in
            try? await Task.sleep(for: .milliseconds(100))
            return await executor.run(preview, confirmation: confirm)
        }
        task.cancel()
        let outcome = await task.value
        #expect(outcome.steps == [.skipped(reason: "Cancelled before it ran.")])
        #expect(ran().isEmpty)
        #expect(records.isEmpty)
    }

    /// GamGUI's timeout is one target's failure, not the connection's: the plan goes on.
    @Test func aTimeoutFailsItsStepAndThePlanGoesOn() async throws {
        let executor = executor()
        let slow = WriteStep(GamCommands.setSuspended(email: "alice@example.com", suspended: true), target: "alice@example.com",
                             summary: "", timeout: .nanoseconds(1))
        let outcome = await executor.run(try await held(executor, [slow, suspend("bob@example.com")]), confirmation: confirmed)
        guard case .failed(_, let kind) = outcome.steps.first else { Issue.record("\(outcome.steps)"); return }
        #expect(kind == .timeout)
        guard case .succeeded = outcome.steps.last else { Issue.record("\(outcome.steps)"); return }
    }

    @Test func theDigestIsTheArgvBytes() async throws {
        let executor = executor()
        let a = try await held(executor, [suspend("alice@example.com")])
        let b = try await held(executor, [suspend("alice@example.com")])
        let c = try await held(executor, [suspend("alicf@example.com")])
        #expect(a.digest == b.digest)
        #expect(a.digest != c.digest)
        #expect(a.digest.count == 64)
    }

    @Test func anUnfinishedWriteCanBeAcknowledged() async throws {
        try audit.record("suspendUser", target: "bob@example.com", argv: [],
                         extra: ["preview": .string("P1"), "step": .number("0"), "phase": .string("begin")])
        let unfinished = Executor.unfinished(in: auditURL)
        #expect(unfinished.count == 1)
        try Executor.acknowledge(unfinished, in: auditURL)
        #expect(unfinished.first?.actionName == "Suspend user")
        #expect(Executor.unfinished(in: auditURL).isEmpty)
    }

    // MARK: outcome unknown

    @Test func aBeginWithNoEndIsAnOutcomeUnknown() throws {
        try audit.record("suspendUser", target: "bob@example.com", argv: ["update", "user", "bob@example.com", "suspended", "on"],
                         extra: ["preview": .string("P1"), "step": .number("0"), "phase": .string("begin")])
        try audit.record("suspendUser", target: "alice@example.com", argv: [],
                         extra: ["preview": .string("P2"), "step": .number("0"), "phase": .string("begin")])
        try audit.record("suspendUser", target: "alice@example.com", argv: [], ok: true,
                         extra: ["preview": .string("P2"), "step": .number("0"), "phase": .string("end")])
        #expect(Executor.unfinished(in: auditURL).map(\.target) == ["bob@example.com"])
    }
}
