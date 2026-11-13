import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Signatures screen's write (GamGUI's designer): a template rendered for one person is previewed (held by the
/// executor exactly as it will run), confirmed from its confirm step, run once and audited. After it, "Put Back
/// Previous" previews the signature read before the change. For a scope (a group's members, an org unit, the whole
/// company) the preview holds one write per person, each with that person's render; the run is in the jobs tray with
/// Stop, each write audited, and "Retry the N that failed" previews exactly those people again with the same template.
/// Nothing here runs a `gam` write itself; every write goes through `Executor`. Ports GamGUI's `routes/signatures.py`
/// (preview, retry, apply) and its 2026-09-23 incidents (design doc S1c, D4, D5).
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
        /// Their signature as read when this was previewed: what "Put Back Previous" restores. Nil when it
        /// wasn't read (still reading, or the read failed), and for a put back itself.
        public let previous: Previous?
        /// Said before the confirm, each in words: a curly quote in a tag, a render that clears the
        /// signature, GAM storing something other than the body.
        public let warnings: [String]
        public let isPutBack: Bool
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

        public var id: UUID { preview.id }
        /// One write per person of a scope, run in the jobs tray: no Put Back, a sample on the sheet.
        public var isScoped: Bool { scope != nil }
        /// The signature the run will send: the held argv element itself, not a copy made beside it.
        public var body: String { preview.steps.first?.signatureBody ?? "" }
    }

    /// A person's signature as read before a change, with the tenant it was read on: a Put Back of it is
    /// refused on any other (GamGUI failure-log 2026-09-25).
    public struct Previous: Sendable {
        public let person: GamUser
        public let body: String
        let domain: Domain
        let generation: Int
    }

    public struct Done: Sendable {
        public let message: String
        /// What "Put Back Previous" restores; nil after a put back, or when the signature wasn't read.
        public let previous: Previous?
        /// A scope's run: each person it failed for, with why (the first `failuresKept`), and how many in all.
        public let failures: [String]
        public let failedCount: Int
        /// A scope's run that didn't set every signature: stopped, or some failed.
        public let partial: Bool
        /// What "Retry the N that failed" previews; nil when nothing failed.
        public let retry: Retry?

        init(message: String, previous: Previous?, failures: [String] = [], failedCount: Int = 0, partial: Bool = false,
             retry: Retry? = nil) {
            self.message = message
            self.previous = previous
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
        public var stopping = false
        public var done: Int { applied + failed }

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

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, runner: AuthenticatedRunner? = nil) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.runner = runner
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

    /// `template` rendered for `person`, held as one `signature … html` write with its confirm step (D5).
    /// `current` is their signature as the screen read it, kept for "Put Back Previous". A render GAM
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
        let previous = current.flatMap { body in
            tenant.map { Previous(person: person, body: body, domain: $0.domain, generation: $0.generation) }
        }
        await hold(render, for: person, title: "Replace \(person.fullName)'s signature", confirmLabel: "Replace Signature",
                   warnings: Self.warnings(template: template, render: render, for: person), previous: previous,
                   isPutBack: false, expecting: tenant, serial: serial)
    }

    /// The signature read before the last change, set again as GAM showed it (its reader strips each line).
    /// Refused on any tenant but the one it was read on.
    public func previewPutBack(previous: Previous) async {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        if Signature.readAsKeyword(previous.body) != nil {
            state = .problem(Problem(Self.keywordRefusal(previous.body)))
            return
        }
        await hold(previous.body, for: previous.person, title: "Put back \(previous.person.fullName)'s previous signature",
                   confirmLabel: "Put Back Signature", warnings: Self.warnings(template: "", render: previous.body, for: previous.person),
                   previous: nil, isPutBack: true, expecting: (previous.domain, previous.generation), serial: serial)
    }

    private func hold(_ body: String, for person: GamUser, title: String, confirmLabel: String, warnings: [String],
                      previous: Previous?, isPutBack: Bool, expecting: (domain: Domain, generation: Int)?, serial: Int) async {
        guard let executor else {
            state = .problem(Problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh."))
            return
        }
        let email = person.primaryEmail
        let step = WriteStep(GamCommands.setSignature(email: email, signature: body, html: true), target: email,
                             summary: isPutBack ? "Put back \(email)'s previous Gmail signature." : "Replace \(email)'s Gmail signature.")
        let held = await executor.preview([step], confirmStep: true, typedCountAbove: typedCountAbove, expecting: expecting)
        guard await isCurrent(serial, held, executor) else { return }
        switch held {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, person: person, title: title, confirmLabel: confirmLabel,
                                        previous: previous, warnings: warnings, isPutBack: isPutBack, scope: nil, people: [person],
                                        template: "", isRetry: false, notes: []))
        case .failure(let refusal):
            state = .problem(Problem(refusal.message))
        }
    }

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
            state = .problem(Problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh."))
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
            steps.append(WriteStep(GamCommands.setSignature(email: email, signature: render, html: true), target: email,
                                   summary: "Replace \(email)'s Gmail signature."))
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
                confirmLabel: "Replace \(count) Signature\(count == 1 ? "" : "s")", previous: nil, warnings: warnings,
                isPutBack: false, scope: scope, people: people, template: template, isRetry: isRetry, notes: notes))
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
        state = .done(Self.scopeDone(pending, outcome.steps, note: outcome.auditProblem.map { " \($0)" } ?? ""))
    }

    /// Stop a scope's run after the write in flight (GamGUI's Stop): the rest read "Not run: stopped."
    public func stop() async {
        guard case .running(let pending) = state, pending.isScoped, let executor else { return }
        guard await executor.stopAfterCurrentStep(pending.id) else { return }
        progress?.stopping = true
    }

    /// GamGUI's `_sig_apply.html` result: how many were set, why it stopped and how many weren't attempted, and who failed.
    nonisolated static func scopeDone(_ pending: Pending, _ steps: [RunOutcome.Step], note: String) -> Done {
        let total = pending.people.count
        var set = 0, failures: [String] = [], failed: [String] = [], notRun = 0, stoppedBy: String?
        for (index, person) in pending.people.enumerated() {
            let step = index < steps.count ? steps[index] : nil
            switch step {
            case .succeeded?: set += 1
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
        let message: String
        if notRun > 0 {
            let why = stoppedBy == Executor.stopped || stoppedBy == nil ? "Stopped by you \u{2014} \(notRun) not attempted."
                : "\(stoppedBy!) The remaining \(notRun) \(notRun == 1 ? "was" : "were") not attempted."
            message = "\(why) Applied to \(set) of \(total) before stopping."
        } else {
            message = "Applied to \(set) of \(total) user\(total == 1 ? "" : "s")."
        }
        let retry = failed.isEmpty || pending.scope == nil ? nil
            : Retry(template: pending.template, failed: failed, scope: pending.scope!, domain: pending.preview.domain,
                    generation: pending.preview.generation)
        return Done(message: message + note, previous: nil, failures: failures, failedCount: failed.count,
                    partial: notRun > 0 || !failed.isEmpty, retry: retry)
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
            state = .done(Done(message: (pending.isPutBack ? "Put back \(name)'s previous signature." : "Replaced \(name)'s signature.")
                                   + note,
                               previous: pending.previous))
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
        state = .done(Done(message: "Applied to \(people.count - 2) of \(people.count) users.", previous: nil,
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
