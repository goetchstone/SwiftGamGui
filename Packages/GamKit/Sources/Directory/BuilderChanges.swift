import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup

/// The Builder's curated writes (GamGUI's `/builder/preview` and `/builder/run`), through ChangeCore, one at a time: a command's
/// values built as GamGUI builds them (`CuratedCommand`), held by the executor exactly as it will run, confirmed from its sheet
/// (always a click, as GamGUI's Builder asks, `confirm_step=True`), run once and audited with the command it came from. Nothing
/// here runs `gam` itself; the Builder's reads run as its promoted ones do (`UserAccess.catalogRead`).
///
/// Checks GamGUI's Builder doesn't make, each where a run would lose something: the screens' own checks for the same write (a
/// delegate as Users checks one), and a title or department left empty said before it's cleared (GAM sets both together). The
/// connected admin is refused for a suspend, a password reset or a sign-out by the executor, as on every screen.
@MainActor
@Observable
public final class BuilderChanges {
    public enum State: Sendable {
        case idle
        /// The preview the sheet shows; confirming runs exactly this.
        case previewing(Pending)
        case running(Pending)
        case done(String)
        case problem(String)
    }

    /// A held preview with what the confirm sheet says about it.
    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        /// The command's id, so its page alone shows it.
        public let command: String
        public let title: String
        /// Something the operator should know before confirming.
        public let warning: String?

        public var id: UUID { preview.id }
        public var isDestructive: Bool { preview.decision.maxRisk == .destructive }
    }

    public private(set) var state: State = .idle
    /// The command the current state is about.
    public private(set) var subject: String?
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    /// Counts previews asked for: one that comes back after a newer one was asked for is dropped, never shown on its page.
    private var asked = 0

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        setup.onTenantChange { [weak self] in self?.dismiss() }
    }

    public var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    /// Whether the current state is about `command`.
    public func concerns(_ command: CuratedCommand) -> Bool { subject == command.id }

    /// The risk a command's write is held at: its own, which `WriteStep` never lets fall below the write's floor.
    nonisolated static func risk(_ command: CuratedCommand) -> Risk {
        switch command.risk {
        case .read: .readOnly
        case .change: .low
        case .destructive: .destructive
        }
    }

    // MARK: previews

    /// GamGUI's preview of a curated write: `values` built (refused in words when a field is missing or wrong), the checks above,
    /// then held for the domain connected now.
    public func preview(_ command: CuratedCommand, values: [String: String]) async {
        guard !isBusy else { return }
        // The tenant the screen's values were typed for, before any await.
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        subject = command.id
        asked += 1
        let request = asked
        func refuse(_ text: String) {
            guard request == asked else { return }
            state = .problem(text)
        }
        let step: WriteStep, warning: String?
        switch self.step(command, values: values) {
        case .success(let built): (step, warning) = built
        case .failure(let why): return refuse(why.words)
        }
        guard let executor else {
            return refuse("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
        }
        let held = await executor.preview([step], confirmStep: true, expecting: tenant, title: "\(command.name) for \(step.target)")
        guard request == asked else {
            if case .success(let preview) = held { await executor.discard(preview.id) }
            return
        }
        switch held {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, command: command.id, title: command.name, warning: warning))
        case .failure(let refusal):
            refuse(refusal.message)
        }
    }

    /// Why a command couldn't be built or checked, in words.
    public struct Refusal: Error, Sendable {
        public let words: String
    }

    /// `command` built from `values` as one held step, with the checks above and anything to know first; or why not.
    func step(_ command: CuratedCommand, values: [String: String]) -> Result<(WriteStep, String?), Refusal> {
        let write: GamWrite
        do {
            guard case .write(let built) = try command.built(values) else {
                return .failure(Refusal(words: "\(command.name) only reads: run it instead."))
            }
            write = built
        } catch {
            guard case .argument(let why) = error else { return .failure(Refusal(words: "\(command.name) couldn't be built.")) }
            return .failure(Refusal(words: why + "."))
        }
        let target = command.target(values)
        func value(_ key: String) -> String { PythonText.strip(values[key] ?? "") }
        var warning: String?
        switch write.action {
        case .addDelegate:
            let check = UserChanges.checkDelegate(value("delegate"), for: target, directory: directory.users)
            if let error = check.error { return .failure(Refusal(words: error)) }
            warning = check.warning
        case .updateOrganization:
            let empty = ["title", "department"].filter { value($0).isEmpty }
            guard !empty.isEmpty else { break }
            let them = empty.count == 1 ? "it" : "them", named = empty.joined(separator: " and ")
            if let user = directory.users?.first(where: { Guard.normalized($0.primaryEmail) == Guard.normalized(target) }) {
                let cleared = empty.filter { !($0 == "title" ? user.title : user.department).isEmpty }
                if !cleared.isEmpty {
                    let it = cleared.count == 1 ? "it" : "them"
                    warning = "GAM sets the title and department together: this clears \(target)'s \(cleared.joined(separator: " and ")). "
                        + "Fill \(it) in to keep \(it)."
                }
            } else {
                warning = "GAM sets the title and department together, and \(target) isn't in the directory as read: if they have a "
                    + "\(named), this clears \(them)."
            }
        default:
            break
        }
        return .success((WriteStep(write, target: target, summary: "\(command.name): \(target)", risk: Self.risk(command),
                                   about: ["command": command.id]), warning))
    }

    // MARK: a sequence (GamGUI's `/builder/sequence/*`, roadmap 2.5)

    /// A step in the sequence: one curated change, built and checked when it was added.
    public struct Queued: Sendable, Identifiable {
        public let id = UUID()
        public let name: String
        public let step: WriteStep
        public let warning: String?
        public var target: String { step.target }
    }

    /// GamGUI's `MAX_SEQUENCE_STEPS`.
    public nonisolated static let maxSequenceSteps = 25
    /// What a sequence's state is about (`subject`): no command has this id.
    public nonisolated static let sequenceSubject = "sequence"

    /// The steps, in the order they run.
    public private(set) var sequence: [Queued] = []
    /// Why the last Add to Sequence didn't add, in words; nil when it did.
    public private(set) var sequenceRefusal: String?
    /// A sequence running: steps ended, of all, and whether Stop was asked.
    public private(set) var sequenceProgress: (done: Int, total: Int, stopping: Bool)?

    /// Whether the current state is the sequence's.
    public var concernsSequence: Bool { subject == Self.sequenceSubject }

    /// Adds `command` with `values` as the sequence's last step, built and checked as Preview… checks it. A held preview of the
    /// sequence is dropped: it no longer shows what would run.
    public func addToSequence(_ command: CuratedCommand, values: [String: String]) {
        guard !isBusy else { return }
        guard sequence.count < Self.maxSequenceSteps else {
            sequenceRefusal = "Sequence is capped at \(Self.maxSequenceSteps) steps."
            return
        }
        switch step(command, values: values) {
        case .success(let (step, warning)):
            sequence.append(Queued(name: command.name, step: step, warning: warning))
            sequenceRefusal = nil
            sequenceEdited()
        case .failure(let why):
            sequenceRefusal = why.words
        }
    }

    public func removeFromSequence(_ id: Queued.ID) {
        guard !isBusy else { return }
        sequence.removeAll { $0.id == id }
        sequenceEdited()
    }

    /// Moves the step at `index` to `to` (GamGUI's up and down).
    public func moveInSequence(from index: Int, to: Int) {
        guard !isBusy, sequence.indices.contains(index), sequence.indices.contains(to) else { return }
        sequence.insert(sequence.remove(at: index), at: to)
        sequenceEdited()
    }

    public func clearSequence() {
        guard !isBusy else { return }
        sequence.removeAll()
        sequenceRefusal = nil
        sequenceEdited()
    }

    /// A step added, removed or moved: a held preview of the sequence, or its last result, no longer stands.
    private func sequenceEdited() {
        guard concernsSequence else { return }
        asked += 1
        state = .idle
    }

    /// The whole sequence held as one preview, for the domain connected now: a confirm always, the word typed at ten steps with a
    /// destructive one (the guard's), and an account delete's address typed.
    public func previewSequence() async {
        guard !isBusy, !sequence.isEmpty else { return }
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        subject = Self.sequenceSubject
        asked += 1
        let request = asked
        guard let executor else {
            state = .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
            return
        }
        let n = sequence.count
        let warning = sequence.compactMap { queued in queued.warning.map { "\(queued.name): \($0)" } }.joined(separator: "\n")
        let held = await executor.preview(sequence.map(\.step), confirmStep: true, expecting: tenant,
                                          title: "Builder sequence \u{2014} \(n) step\(n == 1 ? "" : "s")")
        guard request == asked else {
            if case .success(let preview) = held { await executor.discard(preview.id) }
            return
        }
        switch held {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, command: Self.sequenceSubject, title: preview.title,
                                        warning: warning.isEmpty ? nil : warning))
        case .failure(let refusal):
            state = .problem(refusal.message)
        }
    }

    /// Stop the sequence after the step in flight (GamGUI's Stop, between steps).
    public func stopSequence() async {
        guard case .running(let pending) = state, pending.command == Self.sequenceSubject, let executor else { return }
        guard await executor.stopAfterCurrentStep(pending.id) else { return }
        sequenceProgress?.stopping = true
    }

    /// GamGUI's `_sequence_run.html`: each step's outcome, in order.
    nonisolated static func sequenceDone(_ pending: Pending, _ steps: [RunOutcome.Step], note: String) -> (String, failed: Bool) {
        var lines: [String] = [], ok = 0, failed = false
        for (index, step) in pending.preview.steps.enumerated() {
            let result = index < steps.count ? steps[index] : nil
            let said: String
            switch result {
            case .succeeded?:
                ok += 1
                said = "done"
            case .failed(let message, let kind)?:
                failed = true
                said = [message, kind?.remediation].compactMap { $0 }.joined(separator: " ")
            case .skipped(let why)?, .waiting(let why)?:
                failed = true
                said = why == Executor.stopped ? "not attempted (stopped)" : why
            case nil:
                failed = true
                said = "not attempted"
            }
            lines.append("\(index + 1). \(step.summary) \u{2014} \(said)")
        }
        let total = pending.preview.steps.count
        return ("Ran \(ok) of \(total) step\(total == 1 ? "" : "s").\(note)\n" + lines.joined(separator: "\n"), failed)
    }

    // MARK: confirming

    /// Runs `pending` once, exactly as held, while it's the preview the sheet shows. `confirmation` is what the operator gave; the
    /// executor decides whether it's enough.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        state = .running(pending)
        if pending.command == Self.sequenceSubject {
            sequenceProgress = (0, pending.preview.steps.count, false)
            let (events, observer) = AsyncStream<(Int, RunOutcome.Step)>.makeStream()
            let watcher = Task { @MainActor [weak self] in
                for await _ in events { self?.sequenceProgress?.done += 1 }
            }
            let outcome = await executor.run(pending.preview, confirmation: confirmation, progress: observer)
            observer.finish()
            await watcher.value
            sequenceProgress = nil
            if let refusal = outcome.refusal {
                state = .problem(refusal)
                return
            }
            guard setup.isConnected(to: pending.preview) else {
                state = .idle
                return
            }
            let (words, failed) = Self.sequenceDone(pending, outcome.steps, note: outcome.auditProblem.map { " \($0)" } ?? "")
            state = failed ? .problem(words) : .done(words)
            return
        }
        let outcome = await executor.run(pending.preview, confirmation: confirmation)
        if let refusal = outcome.refusal {
            state = .problem(refusal)
            return
        }
        // A switch while it ran (plan F6): the result is the old domain's, kept in the jobs tray and Audit, not shown here.
        guard setup.isConnected(to: pending.preview) else {
            state = .idle
            return
        }
        let note = outcome.auditProblem.map { " \($0)" } ?? ""
        switch outcome.steps.first {
        case .succeeded:
            state = .done("Done: \(pending.preview.steps.first?.summary ?? pending.title).\(note)")
        case .failed(let message, let kind):
            state = .problem([message, kind?.remediation].compactMap { $0 }.joined(separator: " ") + note)
        case .skipped(let reason), .waiting(let reason):
            state = .problem(reason + note)
        case nil:
            state = .problem("Nothing ran.")
        }
    }

    /// Back to the command; a held preview simply expires unused.
    public func dismiss() {
        guard !isBusy else { return }
        state = .idle
    }
}
