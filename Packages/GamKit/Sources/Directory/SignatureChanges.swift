import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Stores
import Vault

/// The Signatures screen's write (GamGUI's designer): a template rendered for one person is previewed (held by the
/// executor exactly as it will run), confirmed from its confirm step, run once and audited. For a scope (a group's
/// members, an org unit, the whole company) the preview holds one write per person, each with that person's render; the
/// run is in the jobs tray with Stop, each write audited, and "Retry the N that failed" previews exactly those people
/// again with the same template. Every write keeps the signature it replaces first (`WriteStep.KeepFirst`: ChangeCore
/// reads it exactly and keeps it on this Mac before the write), and "Put Back" previews a kept run's old signatures as
/// a run of their own. Nothing here runs a `gam` write itself, or keeps a signature; every write goes through `Executor`.
/// Ports GamGUI's `routes/signatures.py` (preview, retry, apply, kept, putback) and its 2026-09-23 incidents (design doc
/// S1c, D4, D5; GamGUI #163, #164).
@MainActor
@Observable
public final class SignatureChanges {
    public enum State: Sendable {
        case idle
        /// The preview the screen shows; confirming runs exactly this.
        case previewing(Pending)
        case running(Pending)
        case done(Done)
        case problem(Problem)
    }

    /// A held preview with what the confirm sheet says about it.
    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        public let person: GamUser
        public let title: String
        /// What the confirm button says.
        public let confirmLabel: String
        /// One person's signature as the screen showed it when this was previewed (GAM's display form), beside the new
        /// one on the sheet. Not what's kept: the run reads it again, exactly, and keeps that. Nil when it wasn't read.
        public let current: String?
        /// Said before the confirm, each in words: a curly quote in a tag, a render that clears the
        /// signature, GAM storing something other than the body.
        public let warnings: [String]
        /// A scope's run: whom it was previewed for (nil for one person and a put back).
        public let scope: SignatureScope?
        /// A scope's people, one write each, in the held steps' order; `person` is the first, the sample.
        public let people: [GamUser]
        /// The template each person's signature was rendered from: what a retry renders again.
        public let template: String
        /// A retry of a run's failures (GamGUI's `/signatures/retry`).
        public let isRetry: Bool
        /// Who the preview leaves out, and why, in words (a render GAM would read as a file, someone no longer active).
        public let notes: [String]
        /// A Put Back of a kept run (GamGUI's `/signatures/putback`); nil for a new signature.
        public let putBack: PutBack?

        public var id: UUID { preview.id }
        /// One write per person, run in the jobs tray with Stop, a sample on the sheet: a scope's, or a Put Back's.
        public var isScoped: Bool { scope != nil || putBack != nil }
        public var isPutBack: Bool { putBack != nil }
        /// The signature the run will send: the held argv element itself, not a copy made beside it.
        public var body: String { preview.steps.first?.signatureBody ?? "" }
    }

    /// The kept run a Put Back sets again, and who it leaves out.
    public struct PutBack: Sendable {
        /// The kept run's id (`SignatureBackupStore`).
        public let run: String
        public let what: String
        public let when: Date
        /// Who can't go back exactly, and why, in words: never sent.
        public let leftOut: [LeftOut]
    }

    public struct LeftOut: Sendable, Hashable {
        public let email: String
        public let why: String
    }

    public struct Done: Sendable {
        public let message: String
        /// The kept run holding the signatures this run replaced, for its Put Back; nil when it replaced none.
        public let keptRun: String?
        /// A scope's run: each person it failed for, with why (the first `failuresKept`), and how many in all.
        public let failures: [String]
        public let failedCount: Int
        /// A scope's run that didn't set every signature: stopped, or some failed.
        public let partial: Bool
        /// What "Retry the N that failed" previews; nil when nothing failed.
        public let retry: Retry?

        init(message: String, keptRun: String?, failures: [String] = [], failedCount: Int = 0, partial: Bool = false,
             retry: Retry? = nil) {
            self.message = message
            self.keptRun = keptRun
            self.failures = failures
            self.failedCount = failedCount
            self.partial = partial
            self.retry = retry
        }
    }

    /// A finished scope's failures, for "Retry the N that failed": the template it ran and every address it failed for
    /// (all of them: the run's outcome has each step, so there's no sample to fall short of), bound to its tenant.
    public struct Retry: Sendable {
        public let template: String
        public let failed: [String]
        let scope: SignatureScope
        let domain: Domain
        let generation: Int
    }

    /// A scope's run as it goes: its writes counted as each ends.
    public struct Progress: Sendable, Equatable {
        public var total: Int
        public var applied = 0
        public var failed = 0
        /// A Put Back's people whose signature changed since that run: left as they are.
        public var leftAsTheyAre = 0
        public var stopping = false
        public var done: Int { applied + failed + leftAsTheyAre }

        public init(total: Int) { self.total = total }
    }

    /// The failures a finished scope names (invariant 9; GamGUI's `FAILED_SAMPLE_CAP`).
    public nonisolated static let failuresKept = 200

    /// Why nothing changed, or the change failed: `summary` in words, `detail` GAM's own error.
    public struct Problem: Error, Sendable, Equatable {
        public let summary: String
        public let detail: String?

        init(_ summary: String, detail: String? = nil) {
            self.summary = summary
            self.detail = detail
        }
    }

    public private(set) var state: State = .idle
    /// Counts signatures set: a screen showing a person's current signature reads it again.
    public private(set) var finished = 0
    /// A scope running: how far it is.
    public private(set) var progress: Progress?
    /// The count typed on a scope's sheet didn't match: said there, the sheet stays and its preview isn't spent (the
    /// executor spends a preview it refuses). Cleared once the typing changes (`typingChanged`) or the preview goes.
    public private(set) var typedProblem: String?
    /// Counts each typed refusal, so the sheet says it again on a repeated wrong attempt, not only the first.
    public private(set) var typedRefusals = 0
    /// Above this many people the count must be typed (D5, GamGUI's `COUNT_CONFIRM_ABOVE`); tests lower it, as GamGUI's do.
    var typedCountAbove = Guard.countConfirmAbove
    /// Tests only: the mock's state folder, for the group read.
    var environment: [String: String] = [:]
    /// Each preview, edit and dismissal counts one: a preview whose reads end after the form changed, or after a newer
    /// preview began, holds nothing the screen shows (GamGUI refuses an Apply whose form differs from its preview's).
    private var serial = 0
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    /// For a group scope's members, read when its preview is made.
    private let runner: AuthenticatedRunner?
    /// The signatures runs kept (`SignatureBackupStore`), read for the list and a Put Back. The executor keeps into it.
    private let backups: SignatureBackupStore?
    /// The kept runs, newest first, as last read (`loadKept`); nil until then.
    public private(set) var kept: [SignatureBackupStore.Listed]?
    public private(set) var isLoadingKept = false

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, runner: AuthenticatedRunner? = nil,
                backups: SignatureBackupStore? = nil) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.runner = runner
        self.backups = backups
    }

    public var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: who

    /// The people a signature can be set for: active users, in code-point order by address (GamGUI's
    /// `scope_options` users).
    public var activePeople: [GamUser] {
        (directory.users ?? []).filter { !$0.suspended }
            .sorted { $0.primaryEmail.unicodeScalars.lexicographicallyPrecedes($1.primaryEmail.unicodeScalars) }
    }

    /// Who the screen opens on: the connected admin when they're an active user, otherwise nobody. GamGUI
    /// once opened on whoever sorted first, a colleague whose live signature its default path then
    /// overwrote (its review F18).
    public var defaultPerson: GamUser? {
        guard let admin = setup.connectedAdmin.map(Guard.normalized), !admin.isEmpty else { return nil }
        return activePeople.first { Guard.normalized($0.primaryEmail) == admin }
    }

    // MARK: previews

    /// `template` rendered for `person`, held as one `signature … html` write with its confirm step (D5), keeping the
    /// signature it replaces first. `current` is their signature as the screen showed it, for the sheet. A render GAM
    /// would read as a file keyword is refused here, before any preview.
    public func preview(person: GamUser, template: String, current: String?) async {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        // The tenant the screen's reads (the person, their current signature) belong to, before any await.
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        let render = Signature.render(template, for: person)
        if Signature.readAsKeyword(render) != nil {
            state = .problem(Problem(Self.keywordRefusal(render)))
            return
        }
        guard let executor else {
            state = .problem(Problem(Self.noGam))
            return
        }
        let email = person.primaryEmail
        let held = await executor.preview([Self.step(email, setting: render, summary: "Replace \(email)'s Gmail signature.")],
                                          confirmStep: true, typedCountAbove: typedCountAbove, expecting: tenant)
        guard await isCurrent(serial, held, executor) else { return }
        switch held {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, person: person, title: "Replace \(person.fullName)'s signature",
                                        confirmLabel: "Replace Signature", current: current,
                                        warnings: Self.warnings(template: template, render: render, for: person), scope: nil,
                                        people: [person], template: "", isRetry: false, notes: [], putBack: nil))
        case .failure(let refusal):
            state = .problem(Problem(refusal.message))
        }
    }

    /// Every signature write this screen holds, and the only place it makes one: `email`'s signature set to `setting`, with
    /// the signature it replaces kept first (`WriteStep.KeepFirst`), and, for a Put Back, left alone unless it's still
    /// `expectedNow` (`WriteRouteTests`).
    nonisolated static func step(_ email: String, setting: String, expectedNow: String? = nil, restoring: String? = nil,
                                 summary: String) -> WriteStep {
        WriteStep(GamCommands.setSignature(email: email, signature: setting, html: true), target: email, summary: summary,
                  keepFirst: .signature(email: email, setting: setting, expectedNow: expectedNow, restoring: restoring))
    }

    static let noGam = "This build has no GAM. Build the app again after running scripts/fetch_gam.sh."

    // MARK: a scope (GamGUI's `/signatures/preview`, `/retry`, `/apply`)

    /// `template` for everyone `scope` matches now (GamGUI's `_matched`): the directory's active people, or a group's,
    /// whose members are read here. Held as one write per person, each with that person's render, with the confirm step
    /// and, above `typedCountAbove` people, the count typed. The sheet shows the count and the first person's render.
    public func previewScope(_ scope: SignatureScope, template: String) async {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        let serial = serial
        // The tenant the directory and the group read belong to, before any await.
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        guard let users = directory.users else {
            state = .problem(Problem("Load the directory on Users first."))
            return
        }
        let people: [GamUser]
        if case .group(let group) = scope {
            let read = await members(of: PythonText.strip(group), on: tenant?.domain)
            guard serial == self.serial else { return }
            switch read {
            case .success(let members): people = SignatureScope.match(users, members: members)
            case .failure(let problem):
                state = .problem(problem)
                return
            }
        } else {
            people = SignatureScope.match(users, scope)
        }
        await holdScope(people, template: template, scope: scope, isRetry: false, gone: 0, expecting: tenant, serial: serial)
    }

    /// "Retry the N that failed" (GamGUI's `/signatures/retry`, plan U5): the normal preview and confirm step for exactly
    /// a finished run's failed people still active, with the template it ran, on the tenant it ran on. Writes nothing.
    public func previewRetry(_ retry: Retry) async {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        guard let users = directory.users else {
            state = .problem(Problem("Load the directory on Users first."))
            return
        }
        let (people, gone) = SignatureScope.retry(retry.failed, in: users)
        await holdScope(people, template: retry.template, scope: retry.scope, isRetry: true, gone: gone,
                        expecting: (retry.domain, retry.generation), serial: serial)
    }

    private func holdScope(_ matched: [GamUser], template: String, scope: SignatureScope, isRetry: Bool, gone: Int,
                           expecting: (domain: Domain, generation: Int)?, serial: Int) async {
        guard let executor else {
            state = .problem(Problem(Self.noGam))
            return
        }
        var notes: [String] = []
        if gone > 0 {
            notes.append("\(gone) of those that failed \(gone == 1 ? "is" : "are") no longer an active user and "
                + "\(gone == 1 ? "is" : "are") left out.")
        }
        // A render GAM would read as a file or document to load (F2) is never sent: that person is left out, said here.
        var people: [GamUser] = [], steps: [WriteStep] = [], keywords: [String] = [], empty = 0
        for person in matched {
            let render = Signature.render(template, for: person)
            if Signature.readAsKeyword(render) != nil {
                keywords.append(person.primaryEmail)
                continue
            }
            if PythonText.strip(render).isEmpty { empty += 1 }
            let email = person.primaryEmail
            people.append(person)
            steps.append(Self.step(email, setting: render, summary: "Replace \(email)'s Gmail signature."))
        }
        if !keywords.isEmpty {
            notes.append("Left out \(keywords.count): GAM would take their signature as a file or document to load, not as the "
                + "signature (\(keywords.prefix(Self.namedLeftOut).joined(separator: ", "))"
                + (keywords.count > Self.namedLeftOut ? " and \(keywords.count - Self.namedLeftOut) more" : "") + ").")
        }
        guard let sample = people.first, let body = steps.first?.signatureBody else {
            state = .problem(Problem(matched.isEmpty ? (isRetry ? "None of those that failed is an active user any more."
                                                                : "No active users match this scope.")
                                                     : notes.joined(separator: " ")))
            return
        }
        var warnings: [String] = []
        let quote = Signature.smartQuoteWarning(template)
        if !quote.isEmpty { warnings.append(quote) }
        if empty > 0 {
            warnings.append(empty == people.count ? "This renders empty for everyone: confirming clears their Gmail signatures."
                : "This renders empty for \(empty) of them: confirming clears their Gmail signature\(empty == 1 ? "" : "s").")
        }
        if let changed = Self.storedChange(body) { warnings.append(changed) }
        let count = people.count, users = "\(count) user\(count == 1 ? "" : "s")"
        let jobTitle = isRetry ? "Signature retry \u{2014} \(users)" : "Signature for \(scope.who) \u{2014} \(users)"
        let held = await executor.preview(steps, confirmStep: true, typedCountAbove: typedCountAbove, expecting: expecting,
                                          title: jobTitle)
        guard await isCurrent(serial, held, executor) else { return }
        let whom = "\(count) \(count == 1 ? "person" : "people")"
        switch held {
        case .success(let preview):
            state = .previewing(Pending(
                preview: preview, person: sample,
                title: isRetry ? "Retry the signature for \(whom) in \(scope.who)" : "Set the signature for \(whom) in \(scope.who)",
                confirmLabel: "Replace \(count) Signature\(count == 1 ? "" : "s")", current: nil, warnings: warnings,
                scope: scope, people: people, template: template, isRetry: isRetry, notes: notes, putBack: nil))
        case .failure(let refusal):
            state = .problem(Problem(refusal.message))
        }
    }

    /// Whether the preview numbered `serial` is still the newest; when it isn't, what it held is dropped, never shown.
    private func isCurrent(_ serial: Int, _ held: Result<HeldPreview, Executor.PreviewRefusal>, _ executor: Executor) async -> Bool {
        guard serial != self.serial else { return true }
        if case .success(let preview) = held { await executor.discard(preview.id) }
        return false
    }

    // MARK: the kept signatures, and putting them back (GamGUI's `/signatures/kept`, `/putback/preview`, `/putback`)

    /// The kept runs, read again from this Mac (off the main actor: each is read whole).
    public func loadKept() async {
        guard let backups, !isLoadingKept else { return }
        isLoadingKept = true
        kept = await Task.detached { backups.runs() }.value
        isLoadingKept = false
    }

    /// The kept run `id`'s old signatures, previewed to be set again (GamGUI's Put Back, #164): its people, but anyone whose
    /// old signature GAM would read as a file to load or change on the way in, who is left out and named. Each is held as a
    /// step that keeps what it replaces (so a Put Back can be put back too) and is left alone unless their signature is
    /// still, byte for byte, what that run set as GAM stored it. Only on the domain the run was on, with the count typed
    /// above the guard's threshold. Loaded from the store now, never from the list as shown.
    public func previewPutBack(_ id: String) async {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        let serial = serial
        // The tenant this is for, before any await: the run is checked against it, and the preview held for it.
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        guard let executor, let backups else {
            state = .problem(Problem(Self.noGam))
            return
        }
        let loaded = await Task.detached { () -> Result<SignatureBackupStore.Run, SignatureBackupStore.Problem> in
            do throws(SignatureBackupStore.Problem) { return .success(try backups.load(id)) } catch { return .failure(error) }
        }.value
        guard serial == self.serial else { return }
        let run: SignatureBackupStore.Run
        switch loaded {
        case .success(let found): run = found
        case .failure(let problem):
            state = .problem(Problem("That run can't be put back: \(problem.reason)."))
            return
        }
        guard let tenant else {
            state = .problem(Problem(Executor.PreviewRefusal.notConnected.message))
            return
        }
        guard run.domain.utf8.elementsEqual(tenant.domain.name.utf8) else {
            state = .problem(Problem("That run was on \(run.domain), so it's put back only there: connect \(run.domain) on Setup first."))
            return
        }
        let plan = Self.putBackPlan(run)
        let notes = plan.leftOut.isEmpty ? [] : ["Left out \(plan.leftOut.count), each put back only by hand: "
            + plan.leftOut.prefix(Self.namedLeftOut).map { "\($0.email) (\($0.why))" }.joined(separator: "; ")
            + (plan.leftOut.count > Self.namedLeftOut ? "; and \(plan.leftOut.count - Self.namedLeftOut) more" : "") + "."]
        guard !plan.steps.isEmpty else {
            state = .problem(Problem(run.entries.isEmpty ? "That run kept nobody's signature." : notes.joined()))
            return
        }
        let users = directory.users ?? []
        let people = plan.steps.map { step in
            users.first { Guard.normalized($0.primaryEmail) == Guard.normalized(step.target) }
                ?? GamUser(record: ["primaryEmail": .string(step.target)])
        }
        let count = people.count, whom = "\(count) \(count == 1 ? "person" : "people")"
        let held = await executor.preview(plan.steps, confirmStep: true, typedCountAbove: typedCountAbove, expecting: tenant,
                                          title: "Put back of \(run.what)")
        guard await isCurrent(serial, held, executor) else { return }
        switch held {
        case .success(let preview):
            state = .previewing(Pending(
                preview: preview, person: people[0], title: "Put back the signatures \u{201C}\(run.what)\u{201D} replaced: \(whom).",
                confirmLabel: "Put Back \(count) Signature\(count == 1 ? "" : "s")", current: nil, warnings: [], scope: nil,
                people: people, template: "", isRetry: false, notes: notes,
                putBack: PutBack(run: run.id, what: run.what, when: run.when, leftOut: plan.leftOut)))
        case .failure(let refusal):
            state = .problem(Problem(refusal.message))
        }
    }

    /// GamGUI's `put_back_plan`: each of `run`'s people whose old signature can be set again exactly, as a step, and those
    /// left out with why. One GAM would read as a file to load (`Signature.readAsKeyword`), or store as something else
    /// (`Signature.stored`: a CR, or a backslash-n), can't go back as it was. Each step expects what the run set, as GAM
    /// stored it: anything else there now is someone's change since, left as it is.
    nonisolated static func putBackPlan(_ run: SignatureBackupStore.Run) -> (steps: [WriteStep], leftOut: [LeftOut]) {
        var steps: [WriteStep] = [], leftOut: [LeftOut] = []
        for entry in run.entries {
            if Signature.readAsKeyword(entry.previous) != nil {
                leftOut.append(LeftOut(email: entry.email, why: "GAM would read it as a file to load, so it's left for you to put back by hand"))
            } else if !Signature.stored(entry.previous).utf8.elementsEqual(entry.previous.utf8) {
                leftOut.append(LeftOut(email: entry.email, why: "GAM would change it on the way in, so it can't go back exactly"))
            } else {
                steps.append(step(entry.email, setting: entry.previous, expectedNow: Signature.stored(entry.set), restoring: run.id,
                                  summary: "Put back \(entry.email)'s Gmail signature."))
            }
        }
        return (steps, leftOut)
    }

    /// The addresses a note names before "and N more".
    nonisolated static let namedLeftOut = 5

    /// `print group-members group <address>`: its members, or why they couldn't be read. GamGUI took any failure for a
    /// group with nobody in it ("No active users match"); here it's said, so a failed read never passes for an empty group.
    private func members(of group: String, on domain: Domain?) async -> Result<[GroupMember], Problem> {
        guard !group.isEmpty else { return .failure(Problem("Choose a group first.")) }
        guard let domain, let runner else { return .failure(Problem("Connect a domain on Setup first.")) }
        let read = GamCommands.printGroupMembers(group: group)
        do {
            let result = try await runner.run(read, as: domain, extraEnvironment: environment)
            guard result.exitCode == 0 else {
                let error = GamError(exitCode: result.exitCode, stderr: result.stderr, argv: read.argv)
                let why = error.kind == .notFound ? "\(group) isn't a group here." : error.remediation
                return .failure(Problem("Couldn't read \(group)'s members, so nothing was previewed. \(why)", detail: error.message))
            }
            guard !result.stdoutTruncated else {
                return .failure(Problem("\(group) has more members than one call can return, so nothing was previewed."))
            }
            return .success(GamOutput.records(result.stdout).map(GroupMember.init(record:)))
        } catch {
            let problem = DirectoryStore.problem(for: error, argv: read.argv)
            return .failure(Problem("Couldn't read \(group)'s members, so nothing was previewed. \(problem.summary)",
                                    detail: problem.detail))
        }
    }

    /// A scope's run (GamGUI's `_run_apply`), counted as each write ends; the result names who failed and offers their retry.
    private func confirmScope(_ pending: Pending, _ confirmation: OperatorConfirmation, executor: Executor) async {
        progress = Progress(total: pending.people.count)
        let (events, observer) = AsyncStream<(Int, RunOutcome.Step)>.makeStream()
        let watcher = Task { @MainActor [weak self] in
            for await (_, result) in events {
                switch result {
                case .succeeded: self?.progress?.applied += 1
                case .failed, .waiting: self?.progress?.failed += 1
                case .skipped(let reason) where reason == Executor.changedSince: self?.progress?.leftAsTheyAre += 1
                // A step never begun (after a Stop) isn't a failure: the result counts it as not attempted.
                case .skipped: break
                }
            }
        }
        let outcome = await executor.run(pending.preview, confirmation: confirmation, progress: observer)
        observer.finish()
        await watcher.value
        progress = nil
        if let refusal = outcome.refusal {
            state = .problem(Problem(refusal))
            return
        }
        if outcome.steps.contains(where: \.isSucceeded) { finished += 1 }
        state = .done(Self.scopeDone(pending, outcome.steps, note: outcome.auditProblem.map { " \($0)" } ?? "", kept: outcome.kept))
    }

    /// Stop a scope's run after the write in flight (GamGUI's Stop): the rest read "Not run: stopped."
    public func stop() async {
        guard case .running(let pending) = state, pending.isScoped, let executor else { return }
        guard await executor.stopAfterCurrentStep(pending.id) else { return }
        progress?.stopping = true
    }

    /// GamGUI's `_sig_apply.html` result: how many were set, why it stopped and how many weren't attempted, and who failed.
    /// A Put Back's says how many went back, and who was left as they are, changed since that run (skipped, not failed: a
    /// retry wouldn't put them back either). `kept` is the run's kept signatures, for its own Put Back.
    nonisolated static func scopeDone(_ pending: Pending, _ steps: [RunOutcome.Step], note: String, kept: String?) -> Done {
        let total = pending.people.count
        var set = 0, failures: [String] = [], failed: [String] = [], notRun = 0, stoppedBy: String?, changed: [String] = []
        for (index, person) in pending.people.enumerated() {
            let step = index < steps.count ? steps[index] : nil
            switch step {
            case .succeeded?: set += 1
            case .skipped(let reason)? where reason == Executor.changedSince:
                changed.append(person.primaryEmail)
            case .skipped(let reason)?:
                notRun += 1
                if stoppedBy == nil { stoppedBy = reason }
            case nil:
                notRun += 1
            case .failed(let message, let kind)?:
                failed.append(person.primaryEmail)
                if failures.count < failuresKept {
                    failures.append("\(person.primaryEmail) \u{2014} \(remediation(message, kind: kind, for: person))")
                }
            case .waiting(let message)?:
                failed.append(person.primaryEmail)
                if failures.count < failuresKept { failures.append("\(person.primaryEmail) \u{2014} \(message)") }
            }
        }
        var message: String
        let done = pending.isPutBack ? "Put back" : "Applied to"
        if notRun > 0 {
            let why = stoppedBy == Executor.stopped || stoppedBy == nil ? "Stopped by you \u{2014} \(notRun) not attempted."
                : "\(stoppedBy!) The remaining \(notRun) \(notRun == 1 ? "was" : "were") not attempted."
            message = "\(why) \(done) \(set) of \(total) before stopping."
        } else {
            message = "\(done) \(set) of \(total) \(pending.isPutBack ? "signature" : "user")\(total == 1 ? "" : "s")."
        }
        if !changed.isEmpty {
            message += " \(changed.count) \(changed.count == 1 ? "was" : "were") left as \(changed.count == 1 ? "it is" : "they are"), "
                + "changed since that run: \(Self.named(changed))."
        }
        let retry = failed.isEmpty || pending.scope == nil ? nil
            : Retry(template: pending.template, failed: failed, scope: pending.scope!, domain: pending.preview.domain,
                    generation: pending.preview.generation)
        return Done(message: message + note, keptRun: kept, failures: failures, failedCount: failed.count,
                    partial: notRun > 0 || !failed.isEmpty || !changed.isEmpty, retry: retry)
    }

    /// The first `namedLeftOut` addresses, then "and N more".
    nonisolated static func named(_ emails: [String]) -> String {
        emails.prefix(namedLeftOut).joined(separator: ", ")
            + (emails.count > namedLeftOut ? " and \(emails.count - namedLeftOut) more" : "")
    }

    // MARK: confirming

    /// Runs `pending` once, exactly as held, while it's the preview the screen shows: an older one (the
    /// template edited or the person changed since) never runs, though the executor still holds it.
    /// `confirmation` is what the operator gave; the executor decides whether it's enough. A count typed that isn't the
    /// guard's is said here first (`typedProblem`), so nothing runs and the preview isn't spent.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        let decision = pending.preview.decision
        if !decision.typedCountMatches(confirmation.typedCount) {
            typedProblem = Self.typedCountRefusal(decision.affectedCount)
            typedRefusals += 1
            return
        }
        typedProblem = nil
        state = .running(pending)
        if pending.isScoped { return await confirmScope(pending, confirmation, executor: executor) }
        let outcome = await executor.run(pending.preview, confirmation: confirmation)
        if let refusal = outcome.refusal {
            state = .problem(Problem(refusal))
            return
        }
        let name = pending.person.fullName
        switch outcome.steps.first {
        case .succeeded:
            finished += 1
            let note = outcome.auditProblem.map { " \($0)" } ?? ""
            state = .done(Done(message: "Replaced \(name)'s signature."
                                   + (outcome.kept == nil ? "" : " The one it replaced is kept on this Mac.") + note,
                               keptRun: outcome.kept))
        case .failed(let message, nil) where message.hasPrefix(Executor.notRead):
            // ChangeCore's words already say it wasn't replaced, and why.
            state = .problem(Problem(message))
        case .failed(let message, let kind):
            let why = Self.remediation(message, kind: kind, for: pending.person)
            state = .problem(Problem("Couldn't set the signature. \(why)", detail: kind == nil ? nil : message))
        case .skipped(let reason), .waiting(let reason):
            state = .problem(Problem("Couldn't set the signature. \(reason)"))
        case nil:
            state = .problem(Problem("Nothing ran."))
        }
    }

    #if DEBUG
    /// Debug builds' screenshots only: a finished run for `scope` as if Gmail refused its last two people (their Gmail off),
    /// with its Retry. Nothing is held and no `gam` runs.
    public func showDemoResult(_ scope: SignatureScope, template: String) {
        let people = SignatureScope.match(directory.users ?? [], scope).map(\.primaryEmail)
        guard !isBusy, let active = setup.active, people.count > 2 else { return }
        let failed = Array(people.suffix(2)), why = GamError.Kind.serviceNotEnabled.remediation
        state = .done(Done(message: "Applied to \(people.count - 2) of \(people.count) users.", keptRun: nil,
                           failures: failed.map { "\($0) \u{2014} \(why)" }, failedCount: 2, partial: true,
                           retry: Retry(template: template, failed: failed, scope: scope, domain: active, generation: setup.generation)))
    }
    #endif

    /// Back to the screen; a held preview simply expires unused.
    public func dismiss() {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        state = .idle
    }

    /// What a confirm sheet says about the signatures it replaces (GamGUI's preview: "kept on this Mac first", "two GAM calls
    /// a person"): Gmail keeps no copy, so each is read and kept first, and one that can't be read isn't replaced.
    public nonisolated static func keptFirst(_ count: Int) -> String {
        count == 1
            ? "Replaces their current Gmail signature. Gmail keeps no copy, so it's read and kept on this Mac first, and Put Back "
                + "can set it again. If it can't be read, it isn't replaced."
            : "Replaces each one's current Gmail signature. Gmail keeps no copy, so each is read and kept on this Mac first (two "
                + "GAM calls a person, so it takes about twice as long), and Put Back can set them again. Anyone whose signature "
                + "can't be read isn't replaced."
    }

    /// The count a scope wants typed, in words.
    public nonisolated static func typedCountRefusal(_ count: Int) -> String {
        "Type \(count), the number of people, to confirm."
    }

    /// The typed count changed: an earlier mismatch no longer stands.
    public func typingChanged() {
        typedProblem = nil
    }

    /// The scope, the person or the template changed after a preview: it's dropped, so its confirm runs nothing
    /// (GamGUI refuses an Apply whose form differs from its preview's). A result already shown stays.
    public func edited() {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        if case .previewing = state { state = .idle }
    }

    // MARK: words

    /// What the operator should know before confirming (design doc D4), none of which changes the argv:
    /// GamGUI's curly-quote warning, a render that clears the signature, and GAM storing something other
    /// than the body (F1).
    public nonisolated static func warnings(template: String, render: String, for person: GamUser) -> [String] {
        var warnings: [String] = []
        let quote = Signature.smartQuoteWarning(template)
        if !quote.isEmpty { warnings.append(quote) }
        if PythonText.strip(render).isEmpty {
            warnings.append("This renders empty for \(person.fullName): confirming clears their Gmail signature.")
        } else if let changed = storedChange(render) {
            warnings.append(changed)
        }
        return warnings
    }

    /// "GAM will store this with … changed", when Gmail would hold something other than `body`
    /// (`Signature.stored`: every CR removed, each backslash-n a `<br/>`); nil when it holds `body`.
    public nonisolated static func storedChange(_ body: String) -> String? {
        let withoutCR = String(String.UnicodeScalarView(body.unicodeScalars.filter { $0 != "\r" }))
        var changes: [String] = []
        if withoutCR.utf8.count != body.utf8.count { changes.append("its carriage returns removed") }
        if !Signature.stored(withoutCR).utf8.elementsEqual(withoutCR.utf8) {
            changes.append("each \\n changed to a line break (<br/>)")
        }
        guard !changes.isEmpty else { return nil }
        return "GAM will store this with \(changes.joined(separator: " and ")). The Rendered view shows what Gmail will hold."
    }

    /// Why a body GAM would read as a file keyword (F2) isn't previewed.
    public nonisolated static func keywordRefusal(_ body: String) -> String {
        "GAM would take “\(PythonText.strip(body))” as a file or document to load, not as the signature. "
            + "Change the template so it isn't just that word."
    }

    /// The failure in words. A brand-new account's token is refused "Requested client not authorized" until
    /// Google finishes it (live, 2026-09-30): said only for an account that has never signed in, since
    /// GamError reads those words as unknown.
    nonisolated static func remediation(_ message: String, kind: GamError.Kind?, for person: GamUser) -> String {
        if PythonText.lower(message).contains("requested client not authorized"), neverSignedIn(person) {
            return "Google is still setting up this new account: wait a few minutes, then try again."
        }
        return kind?.remediation ?? message
    }

    /// GAM gives a never-used account's last sign-in as the epoch, or nothing.
    nonisolated static func neverSignedIn(_ person: GamUser) -> Bool {
        guard let time = person.lastLoginTime.map({ PythonText.strip($0) }), !time.isEmpty else { return true }
        return time.unicodeScalars.starts(with: "1970-01-01".unicodeScalars)
    }
}
