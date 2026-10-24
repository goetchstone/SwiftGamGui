import CryptoKit
import Foundation
import GamEngine
import os
import Vault

/// The write chokepoint (design doc §6, invariant 2): a feature builds `WriteStep`s, the executor holds
/// them as a `HeldPreview` the operator looks at, and a confirm runs exactly that preview, once, through
/// the guard and the audit. Nothing else can run a `GamWrite`: the runner's write entry takes a
/// `WriteTicket`, which only `Executor` mints (`WriteRouteTests`).

/// Where a preview came from: the audit says so. Anything but `.form` (a model's or Siri's draft) always
/// needs the operator's Confirm click, whatever its risk (invariant 10).
public enum Origin: String, Sendable {
    case form, siri, model
}

/// One `gam` write in a preview, with what the operator is shown about it. The argv itself stays inside
/// ChangeCore: what a screen reads (`shownArgv`, `summary`) is masked.
public struct WriteStep: Sendable {
    let write: GamWrite
    public let target: String
    private let rawSummary: String
    /// The caller's risk, never below the action's own floor (`WriteAction.minimumRisk`).
    public let risk: Risk
    /// Indices of earlier steps this one needs: a failed or skipped prerequisite skips it.
    public let requires: [Int]
    /// What else the write concerned, for the audit's `extra` (`group`, `event`, `command`…).
    public let about: [String: String]
    public let timeout: Duration
    /// Values that must never reach the audit, an error or the screen (a temporary password): masked
    /// by value everywhere, as GamGUI's `secrets=`, beside the positional masks.
    let secrets: [Secret]

    /// A task on a list an earlier step of the same preview creates (`task(…onListFrom:…)`): that step, and
    /// the builder's inputs, so the run can rebuild the task with the id the list printed. Nil otherwise.
    let listedTask: ListedTask?

    struct ListedTask: Sendable {
        let list: Int
        let assignee: String
        let title: String
        let notes: String
    }

    /// The `.createUser` step whose account this step acts on, when this run may have just made it: a
    /// refusal Google gives an account it hasn't finished setting up then waits (`.waiting`) for
    /// `Executor.retry` instead of failing (GamGUI's parked steps, design doc D3b). Nil: never waits.
    public let newAccountFrom: Int?

    /// GamGUI's `tolerate_kinds`: a failure every one of whose error lines is one of these counts as done. Only
    /// the offboarding sweep may tolerate, and only `Executor.sweepTolerable` (the preview refuses anything
    /// else): one real failure among the benign per-user notices fails the step.
    public let tolerating: Set<GamError.Kind>

    public init(_ write: GamWrite, target: String, summary: String, risk: Risk = .low, requires: [Int] = [],
                about: [String: String] = [:], secrets: [Secret] = [], timeout: Duration = GamRunner.defaultTimeout,
                newAccountFrom: Int? = nil, tolerating: Set<GamError.Kind> = []) {
        self.init(write, target: target, summary: summary, risk: risk, requires: requires, about: about, secrets: secrets,
                  timeout: timeout, newAccountFrom: newAccountFrom, tolerating: tolerating, listedTask: nil)
    }

    private init(_ write: GamWrite, target: String, summary: String, risk: Risk, requires: [Int], about: [String: String],
                 secrets: [Secret], timeout: Duration, newAccountFrom: Int?, tolerating: Set<GamError.Kind>,
                 listedTask: ListedTask?) {
        self.write = write
        self.target = target
        rawSummary = summary
        self.risk = max(risk, write.action.minimumRisk)
        self.requires = requires
        self.about = about
        self.secrets = secrets
        self.timeout = timeout
        self.newAccountFrom = newAccountFrom
        self.tolerating = tolerating
        self.listedTask = listedTask
    }

    /// A task on the list step `list` of the same preview makes for the same `assignee` (GamGUI's
    /// `create_onboarding_runbook`): the list's id exists only once that step has run, so the held argv
    /// carries `listIDPlaceholder(list)` in its place, and `list` is always among `requires`. The run puts in
    /// the id the list printed, through `GamCommands.createTask` again; this is the one argv element a run
    /// takes from anywhere but its preview (design doc D3c).
    public static func task(assignee: String, title: String, notes: String = "", onListFrom list: Int, target: String,
                            summary: String, requires: [Int] = [], about: [String: String] = [:],
                            timeout: Duration = GamRunner.defaultTimeout, newAccountFrom: Int? = nil) -> WriteStep {
        WriteStep(GamCommands.createTask(assignee: assignee, taskListID: listIDPlaceholder(list), title: title, notes: notes),
                  target: target, summary: summary, risk: .low, requires: requires.contains(list) ? requires : requires + [list],
                  about: about, secrets: [], timeout: timeout, newAccountFrom: newAccountFrom, tolerating: [],
                  listedTask: ListedTask(list: list, assignee: assignee, title: title, notes: notes))
    }

    /// What a held task's list id element says until the run knows the id. `list` is the step's index.
    public static func listIDPlaceholder(_ list: Int) -> String { "\u{2039}task list id from step \(list + 1)\u{203A}" }

    /// The same step, running `write` (a listed task with its list's id put in).
    func running(_ write: GamWrite) -> WriteStep {
        WriteStep(write, target: target, summary: rawSummary, risk: risk, requires: requires, about: about, secrets: secrets,
                  timeout: timeout, newAccountFrom: newAccountFrom, tolerating: tolerating, listedTask: listedTask)
    }

    public var action: WriteAction { write.action }

    /// The summary as shown: secrets masked.
    public var summary: String { Executor.masked(rawSummary, secrets: secretTexts) }

    /// The argv as the operator and the audit see it: sensitive values masked.
    public var shownArgv: [String] {
        ArgvRedaction.redact(write.argv).map { Executor.masked($0, secrets: secretTexts) }
    }

    /// The step as the `gam …` line the operator reads (GamGUI's `command_line`): `shownArgv`, each element
    /// quoted so its bounds show, with GAM's own `password random` shown as it runs, unless the word is one
    /// of this step's secrets. Display only: nothing ever runs it through a shell.
    public var commandLine: String {
        GamCommandLine.text(write.argv.map { Executor.masked($0, secrets: secretTexts) }, masked: shownArgv)
    }

    var secretTexts: [String] { secrets.map { String(decoding: $0.bytes, as: UTF8.self) } }

    /// The signature a `.setSignature` step sends, as held: the argv element itself, so the confirm sheet
    /// shows the bytes the run will send rather than a copy made beside them. `shownArgv` keeps it masked
    /// for the audit and the logs. Nil for any other write.
    public var signatureBody: String? {
        guard write.action == .setSignature, write.argv.count > 3 else { return nil }
        return write.argv[3]
    }

    var change: Change { Change(target: target, summary: rawSummary, risk: risk, argv: write.argv) }
}

/// A step prints, dumps and reflects as the operator sees it (`shownArgv`), never its raw argv: a held
/// create carries a temporary password (invariant 4).
extension WriteStep: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "WriteStep(\(action.rawValue), \(target): \(shownArgv.joined(separator: " ")))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["action": action, "target": target, "argv": shownArgv, "requires": requires,
                                "newAccountFrom": newAccountFrom as Any], displayStyle: .struct)
    }
}

extension WriteAction {
    /// The action in words, for the screen and VoiceOver ("Suspend user", not `suspendUser`).
    public var displayName: String {
        let words = rawValue.reduce(into: "") { text, character in
            text += character.isUppercase ? " " + character.lowercased() : String(character)
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The least risk a write of this kind carries, whatever its caller says: GamGUI's
    /// `RiskLevel.DESTRUCTIVE` writes (`gam_connector.py`, the curated catalog, offboarding's steps).
    public var minimumRisk: Risk {
        switch self {
        case .deleteUser, .suspendUser, .removeCalendar, .deleteEvent, .createDataTransfer, .deprovisionUser,
             .resetPassword, .removeAllCalendarACLs, .deleteAlias, .clearRecovery, .transferCalendarOwnership, .deleteFilters,
             .trashMessage, .deleteSendAs, .deleteMessages, .setPassword, .deleteDeviceUser:
            .destructive
        default:
            .low
        }
    }

    /// The writes that may wait for Google to finish a just-created account: the ones GamGUI parks
    /// (`provision_hire`: the signature, a calendar, the task list with its tasks). Not a group add: live
    /// 2026-09-30, those worked on the fresh account at once.
    public static let canWaitForNewAccount: Set<WriteAction> = [.setSignature, .subscribeCalendar, .createTaskList, .createTask]
}

/// A preview the executor holds: exactly what a confirm will run, bound to the tenant it was made on.
/// Only `Executor.preview` makes one.
public struct HeldPreview: Sendable, Identifiable {
    public let id: UUID
    public let steps: [WriteStep]
    /// SHA-256 of every step's argv bytes, in the audit: what ran is provably what was shown.
    public let digest: String
    public let domain: Domain
    public let generation: Int
    public let origin: Origin
    /// What the confirm step must ask for (a click, `confirm` typed, the count, each deleted address).
    public let decision: Guard.Decision
    public let confirmStep: Bool
    public let typedCountAbove: Int?
    /// False for a routine (offboarding) where only `requires` stops a step, as GamGUI's `run_offboard`: a
    /// refused sign-out is then a failed step that stops nothing. True everywhere else: an account-wide
    /// failure (a missing scope) would fail every later call the same way.
    public let stopsAtAccountWideFailure: Bool
    /// An address the operator must type to run it (offboarding's leaver), checked by the executor, never only
    /// the sheet. Nil: none.
    public let typedAddress: String?
    let createdAt: ContinuousClock.Instant
    let precondition: (@Sendable () async throws -> Bool)?

    var changes: [Change] { steps.map(\.change) }

    /// A Confirm click whatever the risk: the flow asked for one, or a model or Siri drafted it.
    public var needsConfirmClick: Bool { confirmStep || origin != .form }

    static func digest(of steps: [WriteStep]) -> String {
        var hasher = SHA256()
        for step in steps {
            for element in step.write.argv {
                hasher.update(data: Data(element.utf8))
                hasher.update(data: Data([0]))
            }
            hasher.update(data: Data([0xFF]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// How a confirmed run went.
public struct RunOutcome: Sendable {
    public enum Step: Sendable, Equatable {
        case succeeded(output: String)
        /// The message is masked; `kind` drives the remediation.
        case failed(message: String, kind: GamError.Kind?)
        case skipped(reason: String)
        /// A step Google wasn't ready to do on an account this run just created (the message is GAM's,
        /// masked), or one that needs such a step ("Waits for step N."): `Executor.retry` runs it again.
        case waiting(message: String)

        public var isSucceeded: Bool { if case .succeeded = self { true } else { false } }
        public var isWaiting: Bool { if case .waiting = self { true } else { false } }
        /// A step whose `gam` didn't finish (a timeout, or an interruption): it may have made its change.
        public var mayHaveChanged: Bool {
            guard case .failed(let message, let kind) = self else { return false }
            return kind == .timeout || message == Executor.interrupted
        }
    }

    /// Why nothing ran, in the operator's words; nil when the preview ran.
    public let refusal: String?
    public let steps: [Step]
    /// Set when an end record couldn't be written: the change ran, but the audit is missing its result.
    public let auditProblem: String?

    /// Steps still waiting for a new account, when they can be retried: pass it to `Executor.retry`.
    public let retry: PendingRetry?

    public var succeeded: Bool { refusal == nil && steps.allSatisfy { if case .succeeded = $0 { true } else { false } } }

    init(refusal: String?, steps: [Step], auditProblem: String?, retry: PendingRetry? = nil) {
        self.refusal = refusal
        self.steps = steps
        self.auditProblem = auditProblem
        self.retry = retry
    }

    static func refused(_ why: String) -> RunOutcome { RunOutcome(refusal: why, steps: [], auditProblem: nil) }
}

/// A confirmed run's steps still waiting for Google to finish a new account (D3d). Opaque: only the
/// executor makes one, and each is good for one `Executor.retry` or `abandon`.
public struct PendingRetry: Sendable, Hashable {
    let id: UUID
    /// Retry rounds already run: 0 after the run itself.
    public let round: Int

    init(id: UUID, round: Int) {
        self.id = id
        self.round = round
    }
}

/// The only path to a write. An actor, with writes serialized beyond that (GamGUI's `_write_lock`): a
/// run that awaits `gam` doesn't let another write start. Every check is here, not in a screen
/// (GamGUI failure-log 2026-09-23: five routes wrote on a bare POST because only their pages asked).
public actor Executor {
    /// A preview stays runnable this long; `ContinuousClock` counts time asleep (failure-log 2026-09-24).
    public static let previewLifetime: Duration = .seconds(15 * 60)
    /// Held previews kept; the oldest goes first (invariant 9).
    public static let previewsKept = 8
    /// Retry rounds after a run: GamGUI's `NEW_ACCOUNT_WAITS` has five.
    public static let newAccountRounds = 5
    /// A run's waiting steps can be retried this long after it ended.
    public static let retryLifetime: Duration = .seconds(15 * 60)
    /// Runs with steps waiting kept; the oldest goes first (invariant 9).
    public static let retriesKept = 8

    public typealias Tenant = @Sendable () async -> (domain: Domain, generation: Int)?

    private let runner: AuthenticatedRunner
    private let audit: AuditLog
    private let tenant: Tenant
    private let now: @Sendable () -> ContinuousClock.Instant
    private let actor: String?
    /// Who is making the change, asked at each run: the admin the connected domain signs in as.
    private let currentActor: (@Sendable () async -> String?)?
    private let extraEnvironment: [String: String]

    private var held: [UUID: HeldPreview] = [:]
    private var order: [UUID] = []
    /// Confirmed runs with steps waiting for a new account, by `PendingRetry.id`: what `retry` continues.
    private var parked: [UUID: Parked] = [:]
    private var parkedOrder: [UUID] = []
    private var inFlight: Set<String> = []
    private var writing = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Tests only: runs inside the write lock before each step, so a test can hold a write open.
    private var beforeEachStep: (@Sendable () async -> Void)?
    /// Previews whose steps are running now, and those asked to stop after the step in flight.
    private var executing: Set<UUID> = []
    private var stopRequests: Set<UUID> = []

    /// `tenant` is the connected domain and its generation (`SetupModel`); `now` and the mock's
    /// environment are for tests.
    public init(runner: AuthenticatedRunner, audit: AuditLog, actor: String? = nil,
                currentActor: (@Sendable () async -> String?)? = nil, tenant: @escaping Tenant,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                extraEnvironment: [String: String] = [:]) {
        self.runner = runner
        self.audit = audit
        self.actor = actor
        self.currentActor = currentActor
        self.tenant = tenant
        self.now = now
        self.extraEnvironment = extraEnvironment
    }

    func setBeforeEachStep(_ body: (@Sendable () async -> Void)?) { beforeEachStep = body }

    // MARK: previewing

    /// Holds `steps` as a preview of the connected tenant. `expecting` is the tenant the screen's reads
    /// began on (a person, the signature a Put Back restores): when that is no longer the connected one,
    /// the preview is refused rather than held for a tenant they weren't read on (GamGUI failure-log
    /// 2026-09-25). `precondition`, when given, re-reads what the preview assumed (the member is still in
    /// the group, the event still exists) just before the run: false means it changed, and the run is
    /// refused with "preview again", never re-planned silently.
    /// `stopsAtAccountWideFailure` and `typedAddress` are for a routine (offboarding): see `HeldPreview`.
    public func preview(_ steps: [WriteStep], origin: Origin = .form, confirmStep: Bool = false,
                        typedCountAbove: Int? = nil, expecting: (domain: Domain, generation: Int)? = nil,
                        stopsAtAccountWideFailure: Bool = true, typedAddress: String? = nil,
                        precondition: (@Sendable () async throws -> Bool)? = nil) async -> Result<HeldPreview, PreviewRefusal> {
        guard !steps.isEmpty else { return .failure(.nothingToRun) }
        for (index, step) in steps.enumerated()
        where step.requires.contains(where: { $0 < 0 || $0 >= index }) || !Self.listedTaskHolds(step, at: index, in: steps)
            || !Self.newAccountWaitHolds(step, at: index, in: steps) {
            return .failure(.badPrerequisite(step: index))
        }
        // GamGUI's sweep alone tolerates, and only its benign per-user notices: never a 403, a scope or an unknown line.
        if let index = steps.firstIndex(where: {
            !$0.tolerating.isEmpty && ($0.action != .removeAllCalendarACLs || !$0.tolerating.isSubset(of: Self.sweepTolerable))
        }) {
            return .failure(.badTolerance(step: index))
        }
        // The address to type is one the preview acts on: a confirmation can't be asked for something else.
        if let typedAddress, Guard.normalized(typedAddress).isEmpty
            || !steps.contains(where: { Self.key($0.target) == Self.key(typedAddress) }) {
            return .failure(.typedAddressNotATarget)
        }
        guard let current = await tenant() else { return .failure(.notConnected) }
        if let expecting, expecting.domain != current.domain || expecting.generation != current.generation {
            return .failure(.tenantChanged)
        }
        let preview = HeldPreview(
            id: UUID(), steps: steps, digest: HeldPreview.digest(of: steps), domain: current.domain,
            generation: current.generation, origin: origin,
            decision: Guard.evaluate(steps.map(\.change), typedCountAbove: typedCountAbove),
            confirmStep: confirmStep, typedCountAbove: typedCountAbove, stopsAtAccountWideFailure: stopsAtAccountWideFailure,
            typedAddress: typedAddress, createdAt: now(), precondition: precondition)
        dropExpired()
        while order.count >= Self.previewsKept { held[order.removeFirst()] = nil }
        held[preview.id] = preview
        order.append(preview.id)
        return .success(preview)
    }

    public enum PreviewRefusal: Error, Equatable, Sendable {
        case nothingToRun, notConnected, tenantChanged, badPrerequisite(step: Int), badTolerance(step: Int), typedAddressNotATarget

        public var message: String {
            switch self {
            case .nothingToRun: "There's nothing to change."
            case .notConnected: "Connect a domain on Setup first."
            case .tenantChanged: "The active domain changed after this was read — preview again on this domain."
            case .badPrerequisite(let step): "Step \(step + 1) needs a step that doesn't come before it."
            case .badTolerance(let step): "Step \(step + 1) would count a failure as done, and only the calendar sweep's notices can be."
            case .typedAddressNotATarget: "The address to type isn't one this change acts on."
            }
        }
    }

    /// What the offboarding sweep may tolerate (GamGUI's `SWEEP_TOLERATED`): a user who never shared with the
    /// leaver, a user without Calendar, and the leaver's own calendar, whose owner rule can't be removed.
    public static let sweepTolerable: Set<GamError.Kind> = [.notFound, .serviceNotEnabled, .ownACL]

    /// GamGUI's words for a sweep that ended with only those notices.
    public static let toleratedOutput = "Completed (best-effort — per-user 'not shared', 'no Calendar' and own-calendar "
        + "notices are expected and were skipped)."


    /// A listed task (D3c) is a `createTask` whose list is an earlier `createTaskList` step it requires, made
    /// for the same assignee, and whose held argv is its builder's with the placeholder for the id: the run
    /// can then put in nothing but that list's id. Any other step holds trivially.
    static func listedTaskHolds(_ step: WriteStep, at index: Int, in steps: [WriteStep]) -> Bool {
        guard let task = step.listedTask else { return true }
        guard step.action == .createTask, task.list >= 0, task.list < index, step.requires.contains(task.list) else { return false }
        let list = steps[task.list].write.argv
        let built = GamCommands.createTask(assignee: task.assignee, taskListID: WriteStep.listIDPlaceholder(task.list),
                                           title: task.title, notes: task.notes)
        return steps[task.list].action == .createTaskList && list.count > 1 && same(list[1], task.assignee)
            && same(built.argv, step.write.argv)
    }

    /// A step that may wait for a new account (D3b) is one of `WriteAction.canWaitForNewAccount`, acting on
    /// the account an earlier `createUser` step makes, which it requires. Any other step holds trivially.
    static func newAccountWaitHolds(_ step: WriteStep, at index: Int, in steps: [WriteStep]) -> Bool {
        // Only a step that may wait itself can need one that may: a retry then runs nothing outside the closed set.
        guard let create = step.newAccountFrom else {
            return !step.requires.contains { $0 >= 0 && $0 < index && steps[$0].newAccountFrom != nil }
        }
        let made = steps.indices.contains(create) ? steps[create].write.argv : [], argv = step.write.argv
        return WriteAction.canWaitForNewAccount.contains(step.action) && create >= 0 && create < index
            && steps[create].action == .createUser && step.requires.contains(create)
            // The account the create makes, as GAM reads an address (GamGUI's `assignee.lower() == email.lower()`).
            && made.count > 2 && argv.count > 1 && argv[0] == "user" && Guard.normalized(argv[1]) == Guard.normalized(made[2])
    }

    /// Byte-for-byte: Swift's `==` on strings compares canonically, so "é" would equal "e\u{301}".
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    static func same(_ a: [String], _ b: [String]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { same($0, $1) } }

    /// Previews currently runnable: a screen offers Confirm only for one of these.
    public func isHeld(_ id: UUID) -> Bool {
        dropExpired()
        return held[id] != nil
    }

    /// Drops a held preview the operator cancelled or replaced, so what its argv carries (a temporary
    /// password) doesn't stay here for `previewLifetime`. An unknown id is ignored.
    public func discard(_ id: UUID) {
        held[id] = nil
        order.removeAll { $0 == id }
    }

    // MARK: running

    static let expired = "That preview has expired or was already run — preview again."
    static let switched = "The active domain changed after the preview — preview again, so it runs on this one."

    /// Runs `preview` once, exactly as held, if every check passes; refused otherwise, with the reason.
    /// The preview is spent either way: a second run needs a new preview. `progress` hears each step's
    /// result as it ends (after its end record, before the next step begins); the caller finishes it.
    public func run(_ preview: HeldPreview, confirmation: OperatorConfirmation,
                    progress: AsyncStream<(Int, RunOutcome.Step)>.Continuation? = nil) async -> RunOutcome {
        // Taken before any await: two runs of one preview can't both get it.
        guard let taken = held.removeValue(forKey: preview.id) else { return .refused(Self.expired) }
        order.removeAll { $0 == preview.id }
        // Stoppable from here, not only once its first step begins: a Stop asked during the checks below (the
        // write lock, the precondition's reads) means none of its steps run (Off2's review, 2026-10-13).
        executing.insert(taken.id)
        defer {
            executing.remove(taken.id)
            stopRequests.remove(taken.id)
        }
        guard now() - taken.createdAt <= Self.previewLifetime else { return .refused(Self.expired) }
        // Before anything is read again: nothing of this preview runs on another tenant, not even a read.
        guard await isCurrent(taken) else { return .refused(Self.switched) }
        if let why = Guard.refusal(taken.changes, confirmation, confirmStep: taken.needsConfirmClick,
                                   typedCountAbove: taken.typedCountAbove) {
            return .refused(why)
        }
        if let typed = taken.typedAddress, !confirmation.typedAddresses.contains(where: { Self.key($0) == Self.key(typed) }) {
            return .refused("Type \(typed) to run this.")
        }
        let targets = Set(taken.steps.map { Self.key($0.target) })
        if let busy = taken.steps.first(where: { inFlight.contains(Self.key($0.target)) }) {
            return .refused("A change to \(busy.target) is already running — wait for it to finish, then preview again.")
        }
        inFlight.formUnion(targets)
        defer { inFlight.subtract(targets) }
        await acquireWriteLock()
        defer { releaseWriteLock() }
        // After the wait for the lock: a preview queued behind a long write may have expired meanwhile,
        // and what it assumed is read again now, not before the wait.
        guard now() - taken.createdAt <= Self.previewLifetime else { return .refused(Self.expired) }
        if let precondition = taken.precondition {
            do {
                guard try await precondition() else { return .refused("What the preview showed has changed since — preview again.") }
            } catch {
                return .refused("What the preview showed couldn't be checked again (\(GamEngineMessage.of(error))) — preview again.")
            }
        }
        if let why = await aliasRefusal(taken) { return .refused(why) }
        guard await isCurrent(taken) else { return .refused(Self.switched) }
        let ran = await execute(taken, progress: progress)
        // A cancelled run leaves nothing to retry: its caller is stopping (review of O1, 2026-10-13).
        return RunOutcome(refusal: nil, steps: ran.steps, auditProblem: ran.auditProblem,
                          retry: Task.isCancelled ? nil : park(taken, ran.steps, ran.listOutputs, round: 0, ranAt: now()))
    }

    // MARK: retrying what waits for a new account (D3d)

    /// A run whose steps wait: the held preview (so a retry runs its argv, under its digest), the results
    /// so far and the lists' output (a waiting task's id), the rounds run and when the run ended.
    private struct Parked {
        let preview: HeldPreview
        let results: [RunOutcome.Step]
        let listOutputs: [Int: String]
        let round: Int
        let ranAt: ContinuousClock.Instant
    }

    static let retrySpent = "Those steps were already retried, or the retry was stopped."
    static let retryOver = "The wait for Google is over — preview what's left again."
    static let heldChanged = "What the preview held has changed since — preview again."

    /// Keeps `results` for a retry when a step waits and a round is left; nil otherwise.
    private func park(_ preview: HeldPreview, _ results: [RunOutcome.Step], _ listOutputs: [Int: String], round: Int,
                      ranAt: ContinuousClock.Instant) -> PendingRetry? {
        guard results.contains(where: \.isWaiting), round < Self.newAccountRounds, now() - ranAt <= Self.retryLifetime
        else { return nil }
        let handle = PendingRetry(id: UUID(), round: round)
        while parkedOrder.count >= Self.retriesKept { parked[parkedOrder.removeFirst()] = nil }
        parked[handle.id] = Parked(preview: preview, results: results, listOutputs: listOutputs, round: round, ranAt: ranAt)
        parkedOrder.append(handle.id)
        return handle
    }

    /// The confirmed run, continued (GamGUI's `finish_new_accounts`, one round): runs again only the steps
    /// still waiting, and those waiting on them, exactly as held, through the same checks as `run` but the
    /// confirmation, which the run already had. Single use: the outcome carries the next handle while a
    /// step still waits and a round is left. Refused after `newAccountRounds` rounds, `retryLifetime`
    /// after the run, on another tenant, or while a target is in flight. The caller does the waiting.
    public func retry(_ handle: PendingRetry, progress: AsyncStream<(Int, RunOutcome.Step)>.Continuation? = nil) async -> RunOutcome {
        // Taken before any await: two retries of one handle can't both get it.
        guard let state = parked.removeValue(forKey: handle.id) else { return .refused(Self.retrySpent) }
        parkedOrder.removeAll { $0 == handle.id }
        executing.insert(state.preview.id)
        defer {
            executing.remove(state.preview.id)
            stopRequests.remove(state.preview.id)
        }
        guard state.round < Self.newAccountRounds, now() - state.ranAt <= Self.retryLifetime else { return .refused(Self.retryOver) }
        guard await isCurrent(state.preview) else { return .refused(Self.switched) }
        let again = state.preview.steps.indices.filter { state.results[$0].isWaiting }.map { state.preview.steps[$0] }
        let targets = Set(again.map { Self.key($0.target) })
        if let busy = again.first(where: { inFlight.contains(Self.key($0.target)) }) {
            return .refused("A change to \(busy.target) is already running — wait for it to finish, then preview again.")
        }
        inFlight.formUnion(targets)
        defer { inFlight.subtract(targets) }
        await acquireWriteLock()
        defer { releaseWriteLock() }
        guard now() - state.ranAt <= Self.retryLifetime else { return .refused(Self.retryOver) }
        // What runs is still what the operator confirmed. The held preview is immutable, so this can't fail today: it
        // is a tripwire for a later change that rebuilds steps, not a defense of its own.
        guard Self.same(HeldPreview.digest(of: state.preview.steps), state.preview.digest) else { return .refused(Self.heldChanged) }
        // As `run` does: what the preview assumed is read again just before its steps run.
        if let precondition = state.preview.precondition {
            do {
                guard try await precondition() else { return .refused("What the preview showed has changed since — preview again.") }
            } catch {
                return .refused("What the preview showed couldn't be checked again (\(GamEngineMessage.of(error))) — preview again.")
            }
        }
        guard await isCurrent(state.preview) else { return .refused(Self.switched) }
        let round = state.round + 1
        let ran = await execute(state.preview, resuming: state.results, listOutputs: state.listOutputs, attempt: round + 1,
                                progress: progress)
        return RunOutcome(refusal: nil, steps: ran.steps, auditProblem: ran.auditProblem,
                          retry: Task.isCancelled ? nil : park(state.preview, ran.steps, ran.listOutputs, round: round, ranAt: state.ranAt))
    }

    /// Stop, between rounds: the waiting steps are dropped, and the handle runs nothing. A round already under
    /// way took its state when it began; it is stopped by cancelling the task awaiting `retry`, which runs no
    /// further step and parks nothing again.
    public func abandon(_ handle: PendingRetry) {
        parked[handle.id] = nil
        parkedOrder.removeAll { $0 == handle.id }
    }

    /// GamGUI's Stop: the step running finishes, with its end record, and no later step of `id` begins; they read
    /// "Not run: stopped." Asked before the first step begins (the run is still checking), none runs. Never cancels
    /// the step in flight (a sweep cut off mid-domain is worse than one that finishes). False when `id` isn't
    /// running, as after it ended.
    public func stopAfterCurrentStep(_ id: UUID) -> Bool {
        guard executing.contains(id) else { return false }
        stopRequests.insert(id)
        return true
    }

    /// A step after a Stop: never begun.
    public static let stopped = "Not run: stopped."

    /// Tests: how many runs' waiting steps are held for a retry.
    var parkedRuns: Int { parked.count }

    /// Design doc §6, GamGUI failure-log 2026-09-24: `gam delete user <alias>` deletes the account the alias
    /// belongs to. Each address a step deletes is resolved to its primary just before the run (a read),
    /// and one that resolves elsewhere is refused. No such user: GAM itself will say so.
    private func aliasRefusal(_ preview: HeldPreview) async -> String? {
        var resolved: [(address: String, primary: String?)] = []
        for address in preview.changes.compactMap(Guard.deletedAccount) {
            do {
                let result = try await runner.run(GamCommands.infoUser(email: address, fields: ["primaryEmail"]),
                                                  as: preview.domain, extraEnvironment: extraEnvironment)
                if result.exitCode == 0 {
                    resolved.append((address, GamUser(record: GamOutput.one(result.stdout)).primaryEmail))
                    continue
                }
                // Only GAM's "does not exist" means no such user. A refusal or a rate limit says nothing
                // about whether the address is an alias, so the delete can't go ahead unresolved.
                let error = GamError(exitCode: result.exitCode, stderr: result.stderr)
                guard error.kind == .notFound else {
                    return "Couldn't check \(address) before deleting it (\(error.message)) — preview again."
                }
                resolved.append((address, nil))
            } catch {
                return "Couldn't check \(address) before deleting it (\(GamEngineMessage.of(error))) — preview again."
            }
        }
        return Guard.aliasDeletes(resolved).first
    }

    private func isCurrent(_ preview: HeldPreview) async -> Bool {
        guard let current = await tenant() else { return false }
        return current.domain == preview.domain && current.generation == preview.generation
    }

    /// Targets compare as GamGUI compares addresses: trimmed and lowercased.
    static func key(_ target: String) -> String { Guard.normalized(target) }

    /// Runs the preview's steps in order. `resuming` a retry: a step whose prior result isn't `.waiting`
    /// keeps it, unrun; `attempt` numbers the retry's audit records.
    private func execute(_ preview: HeldPreview, resuming prior: [RunOutcome.Step]? = nil, listOutputs priorOutputs: [Int: String] = [:],
                         attempt: Int? = nil, progress: AsyncStream<(Int, RunOutcome.Step)>.Continuation?) async
        -> (steps: [RunOutcome.Step], listOutputs: [Int: String], auditProblem: String?) {
        let who = await currentActor?() ?? actor
        var results: [RunOutcome.Step] = []
        var stoppedBy: String?
        var auditProblem: String?
        /// What each list step that succeeded printed: its tasks' id (D3c).
        var listOutputs = priorOutputs
        for (index, planned) in preview.steps.enumerated() {
            if let prior, !prior[index].isWaiting {
                results.append(prior[index])
                continue
            }
            // Each result as it's decided: for a step that ran, after its end record.
            defer { progress?.yield((index, results[index])) }
            if let stoppedBy {
                results.append(.skipped(reason: stoppedBy))
                continue
            }
            // A step needing one that failed is skipped; one needing only steps that wait, waits unrun.
            let unmet = planned.requires.filter { !results[$0].isSucceeded }
            if let needed = unmet.first(where: { !results[$0].isWaiting }) {
                results.append(.skipped(reason: "Step \(needed + 1) didn't succeed."))
                continue
            }
            if let needed = unmet.first {
                results.append(.waiting(message: "Waits for step \(needed + 1)."))
                continue
            }
            // Stop, asked while an earlier step ran: nothing more begins.
            if stopRequests.contains(preview.id) {
                stoppedBy = Self.stopped
                results.append(.skipped(reason: Self.stopped))
                continue
            }
            // Before the begin record: a run cancelled before gam starts is not "interrupted".
            if Task.isCancelled {
                stoppedBy = "Cancelled before it ran."
                results.append(.skipped(reason: "Cancelled before it ran."))
                continue
            }
            // Every step, not just the first: removing or re-importing the domain mid-plan stops the rest.
            guard await isCurrent(preview) else {
                stoppedBy = "Stopped: the active domain changed during the run."
                results.append(.skipped(reason: "Stopped: the active domain changed during the run."))
                continue
            }
            // A listed task runs on the id its list printed, or not at all (D3c).
            var step = planned
            if let task = planned.listedTask {
                guard let write = Self.taskOnItsList(planned, task, listStep: preview.steps[task.list], printed: listOutputs[task.list])
                else {
                    results.append(.failed(message: Self.noListID, kind: nil))
                    continue
                }
                step = planned.running(write)
            }
            await beforeEachStep?()
            let base = extra(for: step, of: preview, index: index, attempt: attempt)
            let secrets = step.secretTexts
            // No begin record, no write: a write that can't be audited doesn't run, and a crash mid-call
            // must leave its "outcome unknown" record.
            do {
                try record(step, phase: "begin", extra: base, actor: who, secrets: secrets)
            } catch {
                AuditFailure.report(error)
                stoppedBy = "Stopped: the audit log couldn't be written."
                results.append(.failed(message: "The audit log couldn't be written (\(GamEngineMessage.of(error))), so this didn't run.",
                                       kind: nil))
                continue
            }
            // GamGUI's `fresh`: only an account this run created waits for Google.
            let mayWait = planned.newAccountFrom.map { results[$0].isSucceeded } ?? false
            let ran = await run(step, index: index, of: preview, base: base, actor: who, secrets: secrets, mayWait: mayWait)
            results.append(ran.result)
            if step.action == .createTaskList, case .succeeded = ran.result { listOutputs[index] = ran.stdout }
            if let stop = ran.stop { stoppedBy = stop }
            if let problem = ran.auditProblem { auditProblem = problem }
        }
        return (results, listOutputs, auditProblem)
    }

    /// GamGUI's words when a list's `returnidonly` gave no id (`onboarding.py` `_why(None)`).
    static let noListID = "No task list id came back."

    /// `task` rebuilt through its builder on the id `listStep` printed: the last non-empty line, stripped
    /// (GamGUI's `create_onboarding_runbook`), when `usableListID` takes it. Nil unless the rebuilt argv is
    /// the held one in every element but the id, and the list was made for the task's assignee: so the one
    /// element a run takes from outside its preview can be nothing but that list's id.
    static func taskOnItsList(_ held: WriteStep, _ task: WriteStep.ListedTask, listStep: WriteStep,
                              printed: String?) -> GamWrite? {
        guard let id = taskListID(printed: printed ?? ""), listStep.write.argv.count > 1 else { return nil }
        let write = GamCommands.createTask(assignee: listStep.write.argv[1], taskListID: id, title: task.title, notes: task.notes)
        let heldArgv = held.write.argv, idElement = 4
        guard write.argv.count == heldArgv.count, heldArgv.count > idElement,
              same(heldArgv[idElement], WriteStep.listIDPlaceholder(task.list)), same(write.argv[idElement], id),
              heldArgv.indices.allSatisfy({ $0 == idElement || same(write.argv[$0], heldArgv[$0]) })
        else { return nil }
        return write
    }

    /// The id a list step's `returnidonly` printed: its last non-empty line, stripped (GamGUI's
    /// `create_onboarding_runbook`), when `usableListID` takes it; nil otherwise.
    public static func taskListID(printed: String) -> String? {
        let lines = PythonText.lines(printed).map { PythonText.strip($0) }.filter { !$0.isEmpty }
        guard let id = lines.last, usableListID(id) else { return nil }
        return id
    }

    /// GAM's longest task list id is far below this; a longer "id" is output that isn't one.
    static let listIDLimit = 256
    /// GAM's entity-list selectors (`Cmd.ENTITY_LIST_SELECTORS`, read from the vendored 7.48.22 build): as the
    /// whole argument, each reads a file or CSV instead of naming a list.
    static let listSelectors: Set<String> = ["csv", "csvdata", "csvfile", "csvkmd", "csvsubkey", "file"]

    /// Whether GAM's `create task <TasklistEntity>` reads `id` as exactly that one list id. It reads the
    /// argument with `getEntityList(…, shlexSplit=True)`: first as a selector word (`getChoice`: stripped,
    /// lowercased, then without `_` and `-`), then split by POSIX shlex on spaces and commas, where quotes and
    /// a backslash are syntax and `#` starts a comment; `tltitle:` then picks a list by title (GamCommands.txt
    /// 651, 807, 1294). So only printable ASCII without those characters, under the length cap, and neither
    /// a selector nor a title.
    static func usableListID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= listIDLimit,
              scalars.allSatisfy({ (0x21...0x7E).contains($0.value) && !",\"'\\#".unicodeScalars.contains($0) })
        else { return false }
        let lowered = PythonText.lower(id)
        let word = String(String.UnicodeScalarView(lowered.unicodeScalars.filter { $0 != "_" && $0 != "-" }))
        return !lowered.hasPrefix("tltitle:") && !listSelectors.contains(lowered) && !listSelectors.contains(word)
    }

    /// One step through the runner, with its end record. `mayWait`: a refusal Google gives an account it
    /// hasn't finished setting up becomes `.waiting` rather than a failure.
    private func run(_ step: WriteStep, index: Int, of preview: HeldPreview, base: JSONObject, actor who: String?,
                     secrets: [String], mayWait: Bool) async -> (result: RunOutcome.Step, stop: String?, auditProblem: String?, stdout: String?) {
        var extra = base
        let result: RunOutcome.Step, stop: String?, exitCode: Int32?
        var stdout: String?
        do {
            let ran = try await runner.run(step.write, as: preview.domain, ticket: WriteTicket(), timeout: step.timeout,
                                           extraEnvironment: extraEnvironment)
            exitCode = ran.exitCode
            stdout = ran.stdout
            if ran.exitCode == 0 {
                result = .succeeded(output: Self.masked(ran.stdout, secrets: secrets))
                stop = nil
            } else {
                let error = GamError(exitCode: ran.exitCode, stderr: ran.stderr, argv: step.write.argv, stdout: ran.stdout)
                let message = Self.masked(error.message, secrets: secrets)
                extra["error"] = .string(message)
                extra["kind"] = .string(error.kind.rawValue)
                // Every line tolerable, not just the worst (GamError.kinds): one real failure fails the sweep. And
                // every line read: past the capture's cap a real failure may be among the lines dropped.
                let tolerated = !step.tolerating.isEmpty && error.kinds.isSubset(of: step.tolerating) && !ran.stderrTruncated
                if !step.tolerating.isEmpty {
                    extra["tolerated"] = .bool(tolerated)
                    // Counts by kind, never the lines: what the first live sweep tolerated, bounded (invariant 9).
                    var counts = JSONObject()
                    for (kind, count) in error.lineCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                        counts[kind.rawValue] = .number(String(count))
                    }
                    extra["tolerated_kinds"] = .object(counts)
                }
                if tolerated {
                    result = .succeeded(output: Self.toleratedOutput)
                    stop = nil
                } else if mayWait, error.saysNewAccountNotReady {
                    result = .waiting(message: message)
                    stop = nil
                } else {
                    result = .failed(message: message, kind: error.kind)
                    // An account-wide failure fails every later call the same way: stop (bulk loops), unless the
                    // preview is a routine whose steps only `requires` stops.
                    stop = error.kind.isAccountWide && preview.stopsAtAccountWideFailure ? "Stopped: \(error.kind.remediation)" : nil
                }
            }
        } catch is CancellationError {
            exitCode = nil
            if !step.tolerating.isEmpty { extra["tolerated"] = .bool(false) }
            extra["error"] = .string(Self.interrupted)
            result = .failed(message: Self.interrupted, kind: nil)
            stop = Self.interrupted
        } catch GamRunnerError.timedOut(let seconds) {
            // GamGUI's GAMError(kind=timeout): this target only, not the connection, so a plan goes on.
            exitCode = nil
            let message = "GAM didn't answer within \(seconds) seconds; it may have done part of the change. Check it in Google."
            if !step.tolerating.isEmpty { extra["tolerated"] = .bool(false) }
            extra["error"] = .string(message)
            extra["kind"] = .string(GamError.Kind.timeout.rawValue)
            result = .failed(message: message, kind: .timeout)
            stop = nil
        } catch {
            // The Vault, a launch failure: nothing later would fare better.
            exitCode = nil
            let message = Self.masked(GamEngineMessage.of(error), secrets: secrets)
            extra["error"] = .string(message)
            result = .failed(message: message, kind: nil)
            stop = "Stopped: \(message)"
        }
        let ok: Bool = if case .succeeded = result { true } else { false }
        do {
            try record(step, phase: "end", extra: extra, exitCode: exitCode, ok: ok, actor: who, secrets: secrets)
            return (result, stop, nil, stdout)
        } catch {
            AuditFailure.report(error)
            return (result, stop, "Step \(index + 1) ran, but its result couldn't be written to the audit log (\(GamEngineMessage.of(error))).",
                    stdout)
        }
    }

    /// A step cut off by a cancellation (a quit): it may have made its change.
    public static let interrupted = "Interrupted before GAM finished: check the result in Google before running it again."

    private func extra(for step: WriteStep, of preview: HeldPreview, index: Int, attempt: Int?) -> JSONObject {
        var extra: JSONObject = [:]
        for key in step.about.keys.sorted() where !(step.about[key] ?? "").isEmpty { extra[key] = .string(step.about[key]!) }
        extra["preview"] = .string(preview.id.uuidString)
        extra["digest"] = .string(preview.digest)
        extra["origin"] = .string(preview.origin.rawValue)
        extra["step"] = .number(String(index))
        // A retry's records: the run's own are attempt 1, unnumbered.
        if let attempt { extra["attempt"] = .number(String(attempt)) }
        return extra
    }

    private func record(_ step: WriteStep, phase: String, extra: JSONObject, exitCode: Int32? = nil, ok: Bool? = nil,
                        actor: String?, secrets: [String]) throws {
        var extra = extra
        extra["phase"] = .string(phase)
        try audit.record(step.write.action.rawValue, target: step.target, argv: step.write.argv, exitCode: exitCode,
                         ok: ok, actor: actor, extra: extra, secrets: secrets)
    }

    private func dropExpired() {
        let now = now()
        for id in parkedOrder where parked[id].map({ now - $0.ranAt > Self.retryLifetime }) ?? true { parked[id] = nil }
        parkedOrder.removeAll { parked[$0] == nil }
        for id in order where held[id].map({ now - $0.createdAt > Self.previewLifetime }) ?? true { held[id] = nil }
        order.removeAll { held[$0] == nil }
    }

    private func acquireWriteLock() async {
        if !writing {
            writing = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func releaseWriteLock() {
        if waiting.isEmpty { writing = false } else { waiting.removeFirst().resume() }
    }

    /// Every occurrence of each secret masked, longest first, so one inside another can't leave a tail.
    static func masked(_ text: String, secrets: [String]) -> String {
        secrets.filter { !$0.isEmpty }.sorted { $0.utf8.count > $1.utf8.count }
            .reduce(text) { $0.replacingOccurrences(of: $1, with: ArgvRedaction.mask) }
    }
}

// MARK: outcome unknown

extension Executor {
    /// A write that began and never ended, or ended cut off: the app quit or crashed mid-call (design doc §6).
    /// Shown on the next launch as "outcome unknown — check", from the audit log alone.
    public struct Unfinished: Sendable, Equatable {
        public let action: String
        public let target: String
        public let at: String
        /// The action in words when it's one of this app's, else as recorded.
        public var actionName: String { WriteAction(rawValue: action)?.displayName ?? action }
        let preview: String
        let step: Int
        /// A retry round's attempt (2 and up); nil for the run's own.
        public let attempt: Int?
    }

    /// Records read at launch: unfinished writes are recent, and the log can hold a million records.
    public static let unfinishedScanLimit = 20_000

    /// Reads the log: call it off the main actor.
    public static func unfinished(in log: URL, limit: Int = unfinishedScanLimit) -> [Unfinished] {
        var ended: Set<String> = []
        var found: [Unfinished] = []
        // Newest first: an end is seen before the begin it closes.
        for record in AuditLog.records(at: log, limit: limit) {
            guard let extra = record["extra"]?.object, let preview = extra["preview"]?.string,
                  let step = extra["step"].flatMap({ $0.int }), let phase = extra["phase"]?.string else { continue }
            // Each attempt at a step is its own begin and end: a retry round's end doesn't close another's.
            let attempt = extra["attempt"].flatMap { $0.int }
            let key = "\(preview)/\(step)/\(attempt ?? 1)"
            if phase == "end" {
                // An end that says the step was cut off (a quit) leaves its outcome unknown: still to check. One the
                // operator marked as checked, written after it, closes it.
                if extra["error"]?.string != interrupted || extra["acknowledged"]?.bool == true { ended.insert(key) }
            } else if phase == "begin", !ended.contains(key) {
                found.append(Unfinished(action: record["action"]?.string ?? "", target: record["target"]?.string ?? "",
                                        at: record["ts"]?.string ?? "", preview: preview, step: step, attempt: attempt))
            }
        }
        return found
    }

    /// The operator checked these in Google: an end record each, marked acknowledged, so they stop showing.
    /// Only the audit log is written, so it needs no gam.
    public static func acknowledge(_ unfinished: [Unfinished], in log: URL) throws {
        let audit = AuditLog(url: log)
        for write in unfinished {
            var extra: JSONObject = ["preview": .string(write.preview), "step": .number(String(write.step)),
                                     "phase": .string("end"), "acknowledged": .bool(true)]
            if let attempt = write.attempt { extra["attempt"] = .number(String(attempt)) }
            try audit.record(write.action, target: write.target, extra: extra)
        }
    }
}

/// Why a preview's precondition couldn't check what it assumed (a read refused), in words the run's refusal
/// carries: the precondition's own errors would otherwise read as their type's name.
public struct PreconditionFailure: Error, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// An error from below the executor, in words for the operator and the audit: never a secret (the
/// Vault's and the runner's errors carry none) and never a status code alone.
enum GamEngineMessage {
    static func of(_ error: any Error) -> String {
        switch error {
        case let error as VaultError: error.guidance
        case GamRunnerError.timedOut(let seconds): "GAM didn't answer within \(seconds) seconds; it may have done part of the change."
        case GamRunnerError.binaryNotExecutable, GamRunnerError.launchFailed: "GAM couldn't start (\(error))."
        case GamRunnerError.invalidArgument: "A value can't be passed to GAM."
        case let error as EphemeralConfig.Failure: "The private folder for GAM's credentials couldn't be set up (\(error))."
        case let error as POSIXError: error.localizedDescription
        case let error as PreconditionFailure: error.reason
        default: "\(type(of: error))"
        }
    }
}

/// An audit record that couldn't be written: said in the unified log as well as to the operator.
enum AuditFailure {
    private static let log = Logger(subsystem: "io.github.goetchstone.swiftgamgui", category: "audit")

    static func report(_ error: any Error) {
        log.fault("an audit record couldn't be written: \(String(describing: error), privacy: .public)")
    }
}
