import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Signatures screen's write (GamGUI's designer, one person at a time): a template rendered for one
/// person is previewed (held by the executor exactly as it will run), confirmed from its confirm step, run
/// once and audited. After it, "Put Back Previous" previews the signature read before the change. Nothing
/// here runs `gam` itself; every write goes through `Executor`. Ports GamGUI's `routes/signatures.py`
/// for the "Specific user" scope and its 2026-09-23 incidents (design doc S1c, D4, D5).
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

        public var id: UUID { preview.id }
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
    }

    /// Why nothing changed, or the change failed: `summary` in words, `detail` GAM's own error.
    public struct Problem: Sendable, Equatable {
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
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
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
                   isPutBack: false, expecting: tenant)
    }

    /// The signature read before the last change, set again as GAM showed it (its reader strips each line).
    /// Refused on any tenant but the one it was read on.
    public func previewPutBack(previous: Previous) async {
        guard !isBusy else { return }
        if Signature.readAsKeyword(previous.body) != nil {
            state = .problem(Problem(Self.keywordRefusal(previous.body)))
            return
        }
        await hold(previous.body, for: previous.person, title: "Put back \(previous.person.fullName)'s previous signature",
                   confirmLabel: "Put Back Signature", warnings: Self.warnings(template: "", render: previous.body, for: previous.person),
                   previous: nil, isPutBack: true, expecting: (previous.domain, previous.generation))
    }

    private func hold(_ body: String, for person: GamUser, title: String, confirmLabel: String, warnings: [String],
                      previous: Previous?, isPutBack: Bool, expecting: (domain: Domain, generation: Int)?) async {
        guard let executor else {
            state = .problem(Problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh."))
            return
        }
        let email = person.primaryEmail
        let step = WriteStep(GamCommands.setSignature(email: email, signature: body, html: true), target: email,
                             summary: isPutBack ? "Put back \(email)'s previous Gmail signature." : "Replace \(email)'s Gmail signature.")
        switch await executor.preview([step], confirmStep: true, typedCountAbove: Guard.countConfirmAbove, expecting: expecting) {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, person: person, title: title, confirmLabel: confirmLabel,
                                        previous: previous, warnings: warnings, isPutBack: isPutBack))
        case .failure(let refusal):
            state = .problem(Problem(refusal.message))
        }
    }

    // MARK: confirming

    /// Runs `pending` once, exactly as held, while it's the preview the screen shows: an older one (the
    /// template edited or the person changed since) never runs, though the executor still holds it.
    /// `confirmation` is what the operator gave; the executor decides whether it's enough.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        state = .running(pending)
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
        case .skipped(let reason):
            state = .problem(Problem("Couldn't set the signature. \(reason)"))
        case nil:
            state = .problem(Problem("Nothing ran."))
        }
    }

    /// Back to the screen; a held preview simply expires unused.
    public func dismiss() {
        guard !isBusy else { return }
        state = .idle
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
