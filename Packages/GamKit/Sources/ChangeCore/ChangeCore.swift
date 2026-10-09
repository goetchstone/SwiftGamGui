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

    public init(_ write: GamWrite, target: String, summary: String, risk: Risk = .low, requires: [Int] = [],
                about: [String: String] = [:], secrets: [Secret] = [], timeout: Duration = GamRunner.defaultTimeout) {
        self.write = write
        self.target = target
        rawSummary = summary
        self.risk = max(risk, write.action.minimumRisk)
        self.requires = requires
        self.about = about
        self.secrets = secrets
        self.timeout = timeout
    }

    public var action: WriteAction { write.action }

    /// The summary as shown: secrets masked.
    public var summary: String { Executor.masked(rawSummary, secrets: secretTexts) }

    /// The argv as the operator and the audit see it: sensitive values masked.
    public var shownArgv: [String] {
        ArgvRedaction.redact(write.argv).map { Executor.masked($0, secrets: secretTexts) }
    }

    var secretTexts: [String] { secrets.map { String(decoding: $0.bytes, as: UTF8.self) } }

    var change: Change { Change(target: target, summary: rawSummary, risk: risk, argv: write.argv) }
}

extension WriteAction {
    /// The least risk a write of this kind carries, whatever its caller says: GamGUI's
    /// `RiskLevel.DESTRUCTIVE` writes (`gam_connector.py`, the curated catalog, offboarding's steps).
    public var minimumRisk: Risk {
        switch self {
        case .deleteUser, .suspendUser, .removeCalendar, .deleteEvent, .createDataTransfer, .deprovisionUser,
             .resetPassword, .removeAllCalendarACLs, .deleteAlias:
            .destructive
        default:
            .low
        }
    }
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
    }

    /// Why nothing ran, in the operator's words; nil when the preview ran.
    public let refusal: String?
    public let steps: [Step]
    /// Set when an end record couldn't be written: the change ran, but the audit is missing its result.
    public let auditProblem: String?

    public var succeeded: Bool { refusal == nil && steps.allSatisfy { if case .succeeded = $0 { true } else { false } } }

    static func refused(_ why: String) -> RunOutcome { RunOutcome(refusal: why, steps: [], auditProblem: nil) }
}

/// The only path to a write. An actor, with writes serialized beyond that (GamGUI's `_write_lock`): a
/// run that awaits `gam` doesn't let another write start. Every check is here, not in a screen
/// (GamGUI failure-log 2026-09-23: five routes wrote on a bare POST because only their pages asked).
public actor Executor {
    /// A preview stays runnable this long; `ContinuousClock` counts time asleep (failure-log 2026-09-24).
    public static let previewLifetime: Duration = .seconds(15 * 60)
    /// Held previews kept; the oldest goes first (invariant 9).
    public static let previewsKept = 8

    public typealias Tenant = @Sendable () async -> (domain: Domain, generation: Int)?

    private let runner: AuthenticatedRunner
    private let audit: AuditLog
    private let tenant: Tenant
    private let now: @Sendable () -> ContinuousClock.Instant
    private let actor: String?
    private let extraEnvironment: [String: String]

    private var held: [UUID: HeldPreview] = [:]
    private var order: [UUID] = []
    private var inFlight: Set<String> = []
    private var writing = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Tests only: runs inside the write lock before each step, so a test can hold a write open.
    private var beforeEachStep: (@Sendable () async -> Void)?

    /// `tenant` is the connected domain and its generation (`SetupModel`); `now` and the mock's
    /// environment are for tests.
    public init(runner: AuthenticatedRunner, audit: AuditLog, actor: String? = nil, tenant: @escaping Tenant,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                extraEnvironment: [String: String] = [:]) {
        self.runner = runner
        self.audit = audit
        self.actor = actor
        self.tenant = tenant
        self.now = now
        self.extraEnvironment = extraEnvironment
    }

    func setBeforeEachStep(_ body: (@Sendable () async -> Void)?) { beforeEachStep = body }

    // MARK: previewing

    /// Holds `steps` as a preview of the connected tenant. `precondition`, when given, re-reads what the
    /// preview assumed (the member is still in the group, the event still exists) just before the run:
    /// false means it changed, and the run is refused with "preview again", never re-planned silently.
    public func preview(_ steps: [WriteStep], origin: Origin = .form, confirmStep: Bool = false,
                        typedCountAbove: Int? = nil,
                        precondition: (@Sendable () async throws -> Bool)? = nil) async -> Result<HeldPreview, PreviewRefusal> {
        guard !steps.isEmpty else { return .failure(.nothingToRun) }
        for (index, step) in steps.enumerated() where step.requires.contains(where: { $0 < 0 || $0 >= index }) {
            return .failure(.badPrerequisite(step: index))
        }
        guard let current = await tenant() else { return .failure(.notConnected) }
        let preview = HeldPreview(
            id: UUID(), steps: steps, digest: HeldPreview.digest(of: steps), domain: current.domain,
            generation: current.generation, origin: origin,
            decision: Guard.evaluate(steps.map(\.change), typedCountAbove: typedCountAbove),
            confirmStep: confirmStep, typedCountAbove: typedCountAbove, createdAt: now(), precondition: precondition)
        dropExpired()
        while order.count >= Self.previewsKept { held[order.removeFirst()] = nil }
        held[preview.id] = preview
        order.append(preview.id)
        return .success(preview)
    }

    public enum PreviewRefusal: Error, Equatable, Sendable {
        case nothingToRun, notConnected, badPrerequisite(step: Int)

        public var message: String {
            switch self {
            case .nothingToRun: "There's nothing to change."
            case .notConnected: "Connect a domain on Setup first."
            case .badPrerequisite(let step): "Step \(step + 1) needs a step that doesn't come before it."
            }
        }
    }

    /// Previews currently runnable: a screen offers Confirm only for one of these.
    public func isHeld(_ id: UUID) -> Bool {
        dropExpired()
        return held[id] != nil
    }

    // MARK: running

    static let expired = "That preview has expired or was already run — preview again."
    static let switched = "The active domain changed after the preview — preview again, so it runs on this one."

    /// Runs `preview` once, exactly as held, if every check passes; refused otherwise, with the reason.
    /// The preview is spent either way: a second run needs a new preview.
    public func run(_ preview: HeldPreview, confirmation: OperatorConfirmation) async -> RunOutcome {
        // Taken before any await: two runs of one preview can't both get it.
        guard let taken = held.removeValue(forKey: preview.id) else { return .refused(Self.expired) }
        order.removeAll { $0 == preview.id }
        guard now() - taken.createdAt <= Self.previewLifetime else { return .refused(Self.expired) }
        // Before anything is read again: nothing of this preview runs on another tenant, not even a read.
        guard await isCurrent(taken) else { return .refused(Self.switched) }
        if let why = Guard.refusal(taken.changes, confirmation, confirmStep: taken.needsConfirmClick,
                                   typedCountAbove: taken.typedCountAbove) {
            return .refused(why)
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
        return await execute(taken)
    }

    /// Design doc §6, GamGUI failure-log 2026-09-24: `gam delete user <alias>` deletes the account the alias
    /// belongs to. Each address a step deletes is resolved to its primary just before the run (a read),
    /// and one that resolves elsewhere is refused. No such user: GAM itself will say so.
    private func aliasRefusal(_ preview: HeldPreview) async -> String? {
        var resolved: [(address: String, primary: String?)] = []
        for address in preview.changes.compactMap(Guard.deletedAccount) {
            do {
                let result = try await runner.run(GamCommands.infoUser(email: address, fields: ["primaryEmail"]),
                                                  as: preview.domain, extraEnvironment: extraEnvironment)
                let primary = result.exitCode == 0 ? GamUser(record: GamOutput.one(result.stdout)).primaryEmail : nil
                resolved.append((address, primary))
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

    private func execute(_ preview: HeldPreview) async -> RunOutcome {
        var results: [RunOutcome.Step] = []
        var stoppedBy: String?
        var auditProblem: String?
        for (index, step) in preview.steps.enumerated() {
            if let stoppedBy {
                results.append(.skipped(reason: stoppedBy))
                continue
            }
            if let needed = step.requires.first(where: { if case .succeeded = results[$0] { false } else { true } }) {
                results.append(.skipped(reason: "Step \(needed + 1) didn't succeed."))
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
            await beforeEachStep?()
            let base = extra(for: step, of: preview, index: index)
            let secrets = step.secretTexts
            // No begin record, no write: a write that can't be audited doesn't run, and a crash mid-call
            // must leave its "outcome unknown" record.
            do {
                try record(step, phase: "begin", extra: base, secrets: secrets)
            } catch {
                AuditFailure.report(error)
                stoppedBy = "Stopped: the audit log couldn't be written."
                results.append(.failed(message: "The audit log couldn't be written (\(GamEngineMessage.of(error))), so this didn't run.",
                                       kind: nil))
                continue
            }
            let ran = await run(step, index: index, of: preview, base: base, secrets: secrets)
            results.append(ran.result)
            if let stop = ran.stop { stoppedBy = stop }
            if let problem = ran.auditProblem { auditProblem = problem }
        }
        return RunOutcome(refusal: nil, steps: results, auditProblem: auditProblem)
    }

    /// One step through the runner, with its end record.
    private func run(_ step: WriteStep, index: Int, of preview: HeldPreview, base: JSONObject,
                     secrets: [String]) async -> (result: RunOutcome.Step, stop: String?, auditProblem: String?) {
        var extra = base
        let result: RunOutcome.Step, stop: String?, exitCode: Int32?
        do {
            let ran = try await runner.run(step.write, as: preview.domain, ticket: WriteTicket(), timeout: step.timeout,
                                           extraEnvironment: extraEnvironment)
            exitCode = ran.exitCode
            if ran.exitCode == 0 {
                result = .succeeded(output: Self.masked(ran.stdout, secrets: secrets))
                stop = nil
            } else {
                let error = GamError(exitCode: ran.exitCode, stderr: ran.stderr, argv: step.write.argv, stdout: ran.stdout)
                let message = Self.masked(error.message, secrets: secrets)
                extra["error"] = .string(message)
                extra["kind"] = .string(error.kind.rawValue)
                result = .failed(message: message, kind: error.kind)
                // An account-wide failure fails every later call the same way: stop (bulk loops).
                stop = error.kind.isAccountWide ? "Stopped: \(error.kind.remediation)" : nil
            }
        } catch is CancellationError {
            exitCode = nil
            extra["error"] = .string(Self.interrupted)
            result = .failed(message: Self.interrupted, kind: nil)
            stop = Self.interrupted
        } catch GamRunnerError.timedOut(let seconds) {
            // GamGUI's GAMError(kind=timeout): this target only, not the connection, so a plan goes on.
            exitCode = nil
            let message = "GAM didn't answer within \(seconds) seconds; it may have done part of the change. Check it in Google."
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
            try record(step, phase: "end", extra: extra, exitCode: exitCode, ok: ok, secrets: secrets)
            return (result, stop, nil)
        } catch {
            AuditFailure.report(error)
            return (result, stop, "Step \(index + 1) ran, but its result couldn't be written to the audit log (\(GamEngineMessage.of(error))).")
        }
    }

    static let interrupted = "Interrupted before GAM finished: check the result in Google before running it again."

    private func extra(for step: WriteStep, of preview: HeldPreview, index: Int) -> JSONObject {
        var extra: JSONObject = [:]
        for key in step.about.keys.sorted() where !(step.about[key] ?? "").isEmpty { extra[key] = .string(step.about[key]!) }
        extra["preview"] = .string(preview.id.uuidString)
        extra["digest"] = .string(preview.digest)
        extra["origin"] = .string(preview.origin.rawValue)
        extra["step"] = .number(String(index))
        return extra
    }

    private func record(_ step: WriteStep, phase: String, extra: JSONObject, exitCode: Int32? = nil, ok: Bool? = nil,
                        secrets: [String]) throws {
        var extra = extra
        extra["phase"] = .string(phase)
        try audit.record(step.write.action.rawValue, target: step.target, argv: step.write.argv, exitCode: exitCode,
                         ok: ok, actor: actor, extra: extra, secrets: secrets)
    }

    private func dropExpired() {
        let now = now()
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
    /// A write that began and never ended: the app quit or crashed mid-call (design doc §6). Shown on the
    /// next launch as "outcome unknown — check", from the audit log alone.
    public struct Unfinished: Sendable, Equatable {
        public let action: String
        public let target: String
        public let at: String
        let preview: String
        let step: Int
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
            let key = "\(preview)/\(step)"
            if phase == "end" {
                ended.insert(key)
            } else if phase == "begin", !ended.contains(key) {
                found.append(Unfinished(action: record["action"]?.string ?? "", target: record["target"]?.string ?? "",
                                        at: record["ts"]?.string ?? "", preview: preview, step: step))
            }
        }
        return found
    }

    /// The operator checked these in Google: an end record each, marked acknowledged, so they stop showing.
    public func acknowledge(_ unfinished: [Unfinished]) throws {
        for write in unfinished {
            try audit.record(write.action, target: write.target, actor: actor,
                             extra: ["preview": .string(write.preview), "step": .number(String(write.step)),
                                     "phase": .string("end"), "acknowledged": .bool(true)])
        }
    }
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
