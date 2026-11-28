import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

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

    /// The reads a bound step's source runs through at the preview (roadmap 5.2), each recorded as the Builder's reads are.
    private let access: UserAccess?
    private let readAudit: ReadAudit?

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, access: UserAccess? = nil, readAudit: ReadAudit? = nil) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.access = access
        self.readAudit = readAudit
        setup.onTenantChange { [weak self] in self?.dismiss() }
    }

    public var isBusy: Bool {
        if resolving { return true }
        if case .running = state { return true }
        return false
    }

    /// A sequence's bound reads running for its preview (roadmap 5.2): busy, so a second Preview doesn't read again.
    public private(set) var resolving = false

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
        let step: WriteStep, built: String?
        switch self.step(command, values: values) {
        case .success(let made): (step, built) = made
        case .failure(let why): return refuse(why.words)
        }
        guard let executor else {
            return refuse("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
        }
        // Roadmap 4.8: a folder's move or copy is counted and its Manager checked before it's held.
        let (folderNotes, refusals) = await folderMoves([step], in: tenant?.domain)
        guard request == asked else { return }
        if !refusals.isEmpty { return refuse(refusals.joined(separator: " ")) }
        let shown = ([built].compactMap { $0 } + folderNotes).joined(separator: "\n")
        let warning: String? = shown.isEmpty ? nil : shown
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

    // MARK: a folder into a shared drive (roadmap 4.8, GamGUI's `_folder_moves`)

    /// Each folder move or copy in `steps` (`SharedDrives.folderMove`), read before it's held: what the folder holds by owner,
    /// and whether the person is a Manager of the drive in their own name (GAM moves or copies into a drive only as one). A read
    /// that failed is said, never an empty folder or a Manager; only a read that answered "not a Manager" refuses.
    func folderMoves(_ steps: [WriteStep], in domain: Domain?) async -> (notes: [String], refusals: [String]) {
        var found: [(email: String, folder: String, drive: String)] = []
        for step in steps where Self.folderCommands.contains(step.about["command"] ?? "") {
            guard let move = SharedDrives.folderMove(of: step.shownArgv) else { continue }
            if !found.contains(where: { $0 == move }) { found.append(move) }
        }
        guard !found.isEmpty, let access else { return ([], []) }
        let domains = await access.tenantDomains()
        var notes: [String] = [], refusals: [String] = []
        // Drive knows the person by their primary address: an alias typed is them (the directory as read), never "someone else".
        let primaries = directory.users.map(GamUser.primaryOfEveryAddress) ?? [:]
        for move in found {
            let person = primaries[PythonText.lower(PythonText.strip(move.email))] ?? move.email
            async let counted = access.folderCount(person, folderID: move.folder, domains: domains, in: domain)
            async let read = access.driveMembers(move.drive, in: domain)
            let (count, members) = await (counted, read)
            var manager: Bool?, managerWhy = ""
            switch members {
            case .success(let members): manager = SharedDrives.managesDirectly(person, members)
            case .failure(let problem): managerWhy = problem.summary
            }
            if manager == false {
                refusals.append("\(move.email) isn't a Manager of that shared drive in their own name, and GAM moves or copies into a "
                                + "drive only as one: make them a Manager on the Shared Drives screen first.")
            }
            let countWhy: String
            if case .failure(let problem) = count { countWhy = problem.summary } else { countWhy = "" }
            notes.append(Self.folderNote(email: move.email, folder: move.folder, domains: domains, count: try? count.get(),
                                         countWhy: countWhy, manager: manager, managerWhy: managerWhy))
        }
        return (notes, refusals)
    }

    /// The two curated commands a folder's move counts and checks (GamGUI's `MOVE_FOLDER`, `COPY_FOLDER_REST`).
    static let folderCommands: Set<String> = ["build.move_folder_to_shared_drive", "build.copy_rest_of_folder_to_shared_drive"]

    /// GamGUI's `_folder_move_note.html`, in words: what the folder holds by owner, and what GAM can't take back.
    nonisolated static func folderNote(email: String, folder: String, domains: [String], count: SharedDrives.FolderCount?, countWhy: String,
                                       manager: Bool?, managerWhy: String) -> String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? one : many }
        var lines: [String] = []
        switch count {
        case nil:
            lines.append("Couldn't count what folder \(folder) holds. \(countWhy) What would move and what would be copied is unknown.")
        case let c? where c.files == 0:
            lines.append("Folder \(folder) holds no files" + (c.folders > 0 ? ", only \(c.folders) folder\(n(c.folders, "", "s"))" : "") + ".")
        case let c?:
            lines.append("Folder \(folder) holds \(c.files) file\(n(c.files, "", "s"))"
                         + (c.folders > 0 ? " in \(c.folders) folder\(n(c.folders, "", "s")) below it" : "") + ":")
            if c.mine > 0 {
                lines.append("\u{2022} \(c.mine) \(email) owns: the move takes \(n(c.mine, "it", "them")) into the drive.")
            }
            if c.domain > 0 {
                lines.append("\u{2022} \(c.domain) someone else in the domain owns: Google moves \(n(c.domain, "it", "each")) only if \(email) may "
                             + "and the owner is a member of the drive. A file it won't move stays where it is, and step 2 copies it.")
            }
            if c.outside > 0 {
                let more = c.outside - c.outsideNames.count
                lines.append("\u{2022} \(c.outside) owned outside \(domains.joined(separator: ", ")), which Google never moves into a shared "
                             + "drive: step 2 copies \(n(c.outside, "it", "them")), and \(n(c.outside, "the original stays with its owner", "the originals stay with their owners")) "
                             + "(\(c.outsideNames.joined(separator: ", "))\(more > 0 ? " and \(more) more" : ""))." )
            }
        }
        if manager == nil {
            lines.append("Couldn't check that \(email) is a Manager of the drive. \(managerWhy) GAM refuses to move or copy into it unless "
                         + "they are, in their own name.")
        }
        lines.append("Files in the trash aren't counted or copied, and the move reports each as not moved, so a folder holding one reads "
                     + "as failed. GAM has no dry run for either step, and a run that stops partway can't be undone: what moved stays "
                     + "moved. The original folders stay in \(email)'s Drive.")
        return lines.joined(separator: "\n")
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

    /// A step in the sequence: one curated change, built and checked when it was added; a read, whose result a later step can
    /// take its values from (roadmap 5.2); or a step bound to one, filled in at the preview.
    public struct Queued: Sendable, Identifiable {
        public let id = UUID()
        public let name: String
        let kind: Kind
        public let warning: String?

        enum Kind: Sendable {
            case write(WriteStep)
            case read(GamRead, command: String, target: String)
            case bound(Bound)
        }

        /// A step whose fields take `=stepN.Column` values: the source is a read, by its id, so a move keeps it.
        struct Bound: Sendable {
            let command: CuratedCommand
            /// Each bound field and the column it takes, in the command's field order.
            let binds: [(field: String, column: String)]
            /// Every other field, as typed.
            let fields: [String: String]
            let source: UUID
        }

        public var step: WriteStep? { if case .write(let step) = kind { step } else { nil } }
        public var isRead: Bool { if case .read = kind { true } else { false } }
        public var target: String {
            switch kind {
            case .write(let step): step.target
            case .read(_, _, let target): target
            case .bound(let bound): "each \(bound.binds.map(\.column).joined(separator: ", "))"
            }
        }

        /// What the sequence shows for it.
        public var commandLine: String {
            switch kind {
            case .write(let step): step.commandLine
            case .read(let read, _, _): GamCommandLine.text(read.argv)
            case .bound(let bound): "once for each \(bound.binds.map(\.column).joined(separator: ", ")) in a read's result"
            }
        }

        /// The step whose read this one takes its values from, by its place in `sequence` (1-based), or nil.
        public func source(in sequence: [Queued]) -> Int? {
            guard case .bound(let bound) = kind, let index = sequence.firstIndex(where: { $0.id == bound.source }) else { return nil }
            return index + 1
        }
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
        let binds = command.fields.compactMap { field in SequenceBinds.parse(values[field.key] ?? "").map { (field, $0) } }
        let queued: Result<Queued, Refusal>
        if !binds.isEmpty {
            queued = boundStep(command, binds: binds, values: values)
        } else if command.reads {
            do {
                guard case .read(let read) = try command.built(values) else { throw GamCommands.Invalid.argument("not a read") }
                queued = .success(Queued(name: command.name, kind: .read(read, command: command.id, target: command.target(values)),
                                         warning: nil))
            } catch GamCommands.Invalid.argument(let why) {
                queued = .failure(Refusal(words: why + "."))
            } catch {
                queued = .failure(Refusal(words: "\(command.name) couldn't be built."))
            }
        } else {
            queued = step(command, values: values).map { Queued(name: command.name, kind: .write($0.0), warning: $0.1) }
        }
        switch queued {
        case .success(let step):
            sequence.append(step)
            sequenceRefusal = nil
            sequenceEdited()
        case .failure(let why):
            sequenceRefusal = why.words
        }
    }

    /// GamGUI's `_bound_step`: a step whose fields take `=stepN.Column` values, checked now (step N is an earlier read with no
    /// bindings of its own), kept unfilled: its writes are built per row at the preview.
    private func boundStep(_ command: CuratedCommand, binds: [(CuratedCommand.Field, (step: Int, column: String))],
                           values: [String: String]) -> Result<Queued, Refusal> {
        let sources = Set(binds.map(\.1.step))
        guard sources.count == 1, let n = sources.first else {
            return .failure(Refusal(words: "A step can take its values from one earlier step, not several."))
        }
        guard (1...max(sequence.count, 1)).contains(n), n <= sequence.count else {
            return .failure(Refusal(words: "There's no step \(n) before this one."))
        }
        let source = sequence[n - 1]
        guard source.isRead else {
            return .failure(Refusal(words: "Step \(n) isn't a read with its own values, so it can't feed a later step: only a read's "
                                    + "result can, since a change's doesn't exist until it runs."))
        }
        guard !command.reads else {
            return .failure(Refusal(words: "Only a change can take its values from a read here: run \(command.name) on its own."))
        }
        if binds.contains(where: { $0.0.kind == .choice }) {
            return .failure(Refusal(words: "A choice can't come from another step's result."))
        }
        let bound = Set(binds.map(\.0.key))
        var fields: [String: String] = [:]
        for field in command.fields where !bound.contains(field.key) {
            var value = PythonText.strip(values[field.key] ?? "")
            // A choice left as the form showed it is its default, as `CuratedCommand.built` reads it (#222's review).
            if value.isEmpty, field.kind == .choice { value = field.defaultValue }
            if field.required, value.isEmpty { return .failure(Refusal(words: "\(field.label) is required.")) }
            fields[field.key] = value
        }
        return .success(Queued(name: command.name, kind: .bound(Queued.Bound(command: command, binds: binds.map { ($0.0.key, $0.1.column) },
                                                                               fields: fields, source: source.id)),
                               warning: nil))
    }

    /// GamGUI's `_resolve`: the sequence with each bound step filled in from its read, `(steps, labels, notes)`, or the
    /// refusal. Each read a later step binds to runs now, once, recorded as the Builder's reads are; each distinct row becomes
    /// one step built by its command's own builder. A read alone, that nothing takes from, isn't a change and isn't held.
    private func resolved(in domain: Domain) async -> Result<(steps: [WriteStep], labels: [String], notes: [String]), Refusal> {
        var steps: [WriteStep] = [], labels: [String] = [], notes: [String] = []
        /// Each filled-in step's own warning (`step`'s: an update that clears a field, say), by step, said once with its count.
        var warned: [(step: Int, warning: String, count: Int)] = []
        var rows: [Int: [GamOutput.Record]?] = [:]
        let feeding = Set(sequence.compactMap { $0.source(in: sequence) })
        for (offset, queued) in sequence.enumerated() {
            let i = offset + 1
            switch queued.kind {
            case .write(let step):
                steps.append(step)
                labels.append(queued.name)
            case .read:
                // Swift's sequences hold only changes: a read runs here, at the preview, for the steps that take from it.
                notes.append(feeding.contains(i) ? "Step \(i) only reads: it ran just now to fill in the steps that take from it, "
                             + "and doesn't run again." : "Step \(i) only reads, and no step takes values from it, so it doesn't run.")
            case .bound(let bound):
                guard let j = queued.source(in: sequence), j < i else {
                    return .failure(Refusal(words: "Step \(i) takes its values from a step that isn't before it any more. Remove it and "
                                            + "queue it again."))
                }
                guard case .read(let read, let command, let target) = sequence[j - 1].kind else {
                    return .failure(Refusal(words: "Step \(j) isn't a read, so step \(i) can't take values from it."))
                }
                if rows[j] == nil {
                    guard let access, let readAudit else {
                        return .failure(Refusal(words: "Step \(j)'s read can't run here, so who step \(i) runs for isn't known. Nothing will run."))
                    }
                    switch await access.catalogRead(read, command: command, target: target, in: domain, recordingTo: readAudit) {
                    case .success(let result): rows[j] = .some(result.tableRows == nil ? nil : result.rows)
                    case .failure(let problem):
                        return .failure(Refusal(words: "Step \(j)'s read failed, so who step \(i) runs for isn't known. Nothing will run. "
                                                + problem.summary))
                    }
                }
                let values: [[String]]
                switch SequenceBinds.values(from: rows[j] ?? nil, columns: bound.binds.map(\.column), source: j, step: i) {
                case .success(let found): values = found
                case .failure(let refusal): return .failure(Refusal(words: refusal.message))
                }
                if values.isEmpty { notes.append("Step \(j) found nothing, so step \(i) runs for no one.") }
                for value in values {
                    var filled = bound.fields
                    for (bind, cell) in zip(bound.binds, value) { filled[bind.field] = cell }
                    switch step(bound.command, values: filled) {
                    case .success(let (step, warning)):
                        steps.append(step)
                        labels.append(queued.name)
                        if let warning {
                            // The same words for each row but the person: counted, the first said.
                            if let index = warned.firstIndex(where: { $0.step == i }) { warned[index].count += 1 } else { warned.append((i, warning, 1)) }
                        }
                        if steps.count > SequenceBinds.maxResolvedSteps { return .failure(Refusal(words: SequenceBinds.tooMany)) }
                    case .failure(let why):
                        return .failure(Refusal(words: "Step \(i) can't take “\(value.joined(separator: ", "))” from step \(j): \(why.words)"))
                    }
                }
            }
            if steps.count > SequenceBinds.maxResolvedSteps { return .failure(Refusal(words: SequenceBinds.tooMany)) }
        }
        for (i, warning, count) in warned {
            notes.append("Step \(i): \(warning)" + (count > 1 ? " (and the same for \(count - 1) more of its \(count) people)" : ""))
        }
        return .success((steps, labels, notes))
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
        guard let tenant else {
            state = .problem("Connect a domain on Setup first.")
            return
        }
        // Roadmap 5.2: what is shown, held, guarded, run and exported is the sequence filled in from its reads.
        resolving = true
        let filled = await resolved(in: tenant.domain)
        resolving = false
        guard request == asked else { return }
        let steps: [WriteStep], labels: [String], notes: [String]
        switch filled {
        case .success(let value): (steps, labels, notes) = value
        case .failure(let refusal):
            state = .problem(refusal.words)
            return
        }
        guard !steps.isEmpty else {
            state = .problem((notes + ["There's nothing to change."]).joined(separator: " "))
            return
        }
        let n = steps.count
        resolving = true
        let (folderNotes, refusals) = await folderMoves(steps, in: tenant.domain)
        resolving = false
        guard request == asked else { return }
        if !refusals.isEmpty {
            state = .problem(refusals.joined(separator: " "))
            return
        }
        let warning = (sequence.compactMap { queued in queued.warning.map { "\(queued.name): \($0)" } } + notes + folderNotes)
            .joined(separator: "\n")
        heldLabels = labels
        // A step filled in from a read counts toward the guard's typed count, as a bulk run's people do.
        let bound = sequence.contains { if case .bound = $0.kind { true } else { false } }
        let held = await executor.preview(steps, confirmStep: true, typedCountAbove: bound ? Guard.countConfirmAbove : nil, expecting: tenant,
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

    /// Each step's name as the sequence held it when previewed: what the exported file calls them.
    private var heldLabels: [String] = []

    /// The previewed sequence as a batch file (roadmap 5.3): the steps the preview held, never what is queued now; the preview
    /// stays held, so it can still run. Audited first, as `sequence_export`; refused in words.
    public func exportSequence(_ pending: Pending) async -> Result<String, Refusal> {
        guard let executor, pending.command == Self.sequenceSubject else { return .failure(Refusal(words: "Preview the sequence first.")) }
        switch await executor.exportBatch(pending.id, labels: heldLabels) {
        case .success(let file): return .success(file)
        case .failure(let refusal): return .failure(Refusal(words: refusal.message))
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
