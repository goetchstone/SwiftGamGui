import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Phishing screen: one email taken out of every mailbox, for a phishing email sent from a compromised account
/// (docs/domains/phishing.md). The operator pastes its Message-ID. Find runs GAM's own dry run over every active
/// user, a read (without `doit` GAM trashes nothing), and shows who has a copy. Trash holds one ChangeCore step per
/// mailbox with copies, each capped at the copies Find showed there, so the preview is exactly what can run; the
/// operator confirms it by typing the number of mailboxes, and each step is audited. Nothing here runs a write
/// itself: every one goes through `Executor`.
@MainActor
@Observable
public final class PhishingChanges {
    public typealias Problem = DirectoryStore.Problem

    /// A finished search, on the tenant it was read on.
    public struct Search: Sendable {
        public let message: GamCommands.MessageID
        public let copies: MessageCopies
        /// One copy as its first mailbox has it (From, Subject, Date): what the ID matched, to check it's the phish
        /// before trashing it everywhere (review of 2026-10-19). Nil with no copy, or when it couldn't be read.
        public let sample: (mailbox: String, copy: MessageRecipients)?
        /// Why the sample couldn't be read, in words.
        public let sampleProblem: String?
        /// The dry run as the `gam` line an admin would type.
        public let commandLine: String
        let domain: Domain
        let generation: Int
    }

    public enum State: Sendable {
        case idle
        /// Find is running for this Message-ID.
        case finding(GamCommands.MessageID)
        case found(Search)
        case problem(Problem)
    }

    /// The trash held for the operator to confirm: exactly what a confirm runs.
    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        public let search: Search
        /// The mailboxes it trashes from, in the steps' order.
        public let mailboxes: [MessageCopies.Mailbox]
        public var id: UUID { preview.id }
        /// The words the executor asks for: the number of mailboxes, and from ten up `confirm` as well.
        public var typedCount: String { String(mailboxes.count) }
        public var needsWord: Bool { preview.decision.requiresTypedConfirmation }
    }

    /// A confirmed run: each mailbox's result as it ends.
    public struct Run: Sendable {
        public let pending: Pending
        /// One per mailbox, nil until its step ends.
        public internal(set) var results: [RunOutcome.Step?]
        public internal(set) var ended = false
        /// Stop was asked: the mailbox in flight finishes, no later one begins.
        public internal(set) var stopping = false
        public internal(set) var auditProblem: String?

        public var trashed: Int { results.filter { $0?.isSucceeded == true }.count }

        /// "Trashed from 3 of 4 mailboxes", then what failed or didn't run.
        public var summary: String {
            let total = results.count
            let failed = results.filter { if case .failed? = $0 { true } else { false } }.count
            let notRun = results.filter { if case .skipped? = $0 { true } else { false } }.count
            var text = "\(ended ? "Trashed" : "Trashing") from \(trashed) of \(total) mailbox\(total == 1 ? "" : "es")"
            if failed > 0 { text += "; \(failed) failed" }
            if notRun > 0 { text += "; \(notRun) not run" }
            return text + "."
        }
    }

    /// Who the email was sent to, from the sender's own copy, the tenant's own addresses apart from the rest.
    public struct Recipients: Sendable {
        public let sender: String
        public let message: GamCommands.MessageID
        /// The sender's copy; nil when their mailbox has none left (deleted, then purged from Trash).
        public let copy: MessageRecipients?
        /// At one of the tenant's domains or domain aliases.
        public let inside: [String]
        /// Anywhere else: the people to warn outside.
        public let outside: [String]
        /// The read as the `gam` line an admin would type.
        public let commandLine: String
        let domain: Domain
        let generation: Int

        /// A copy the sender sent (Gmail's SENT label), the only kind that can have a Bcc header.
        public var isSentCopy: Bool { copy?.labels.contains("SENT") ?? false }

        /// The mailboxes `search` found a copy in that the headers don't name: they had it by a Bcc the copy didn't
        /// keep (a mail client or script leaves it off) or through a group, so outside recipients may be missing too.
        public func unnamed(in search: Search) -> [String] {
            guard search.message == message, copy != nil else { return [] }
            let named = Set((inside + outside).map(PythonText.lower))
            return search.copies.withCopies.map(\.email).filter { !named.contains(PythonText.lower($0)) }
        }
        public var inTrash: Bool { copy?.labels.contains("TRASH") ?? false }
    }

    public enum RecipientsState: Sendable {
        case idle
        case reading(sender: String)
        case read(Recipients)
        case problem(Problem)
    }

    /// The recipients read shown, while it belongs to the connected tenant.
    public var recipients: RecipientsState {
        guard let listed, listed.domain == setup.active, listed.generation == setup.generation else { return .idle }
        return listed.state
    }

    public var isReadingRecipients: Bool {
        if case .reading = recipients { return true }
        return false
    }

    /// The search, problem or held trash shown, while it belongs to the connected tenant.
    public var state: State {
        guard let shown, shown.domain == setup.active, shown.generation == setup.generation else { return .idle }
        return shown.state
    }

    public var pending: Pending? {
        guard let held, held.search.domain == setup.active, held.search.generation == setup.generation else { return nil }
        return held
    }

    /// The run going on, or the last one, while it runs or belongs to the connected tenant.
    public var run: Run? {
        guard let ran, isRunning || (ran.pending.search.domain == setup.active && ran.pending.search.generation == setup.generation)
        else { return nil }
        return ran
    }

    public private(set) var isRunning = false
    /// Why a preview or a confirm didn't go ahead, in the operator's words.
    public private(set) var refusal: String?

    public var isFinding: Bool {
        if case .finding = state { return true }
        return false
    }

    /// What quitting now would cut short, for the quit alert; nil when nothing would.
    public var interruptible: (what: String, consequence: String)? {
        guard isRunning, let ran else { return nil }
        return ("An email is still being trashed from \(ran.results.count) mailboxes.",
                "The mailboxes not yet reached won't be, and the one in progress may stop partway: find the email again before trashing it again.")
    }

    private var shown: (state: State, domain: Domain?, generation: Int)?
    private var listed: (state: RecipientsState, domain: Domain?, generation: Int)?
    private var askedRecipients = 0
    /// Counts previews asked for: only the latest is held (a double click holds one).
    private var previewsAsked = 0
    private var held: Pending?
    private var ran: Run?
    /// Counts searches asked for: a slower, older one never replaces a newer one.
    private var asked = 0
    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    private let executor: Executor?
    /// Tests only: the mock's state folder, so a search sees what a run just trashed.
    var environment: [String: String] = [:]

    public init(setup: SetupModel, runner: AuthenticatedRunner?, executor: Executor?) {
        self.setup = setup
        self.runner = runner
        self.executor = executor
    }

    // MARK: finding

    /// GAM's dry run for the pasted Message-ID over every active user. Replaces the search, problem or held trash
    /// shown; refused while a run goes on.
    public func find(_ pasted: String) async {
        guard !isRunning else { return }
        asked += 1
        let ask = asked
        refusal = nil
        dropHeld()
        let generation = setup.generation
        let message: GamCommands.MessageID
        do {
            message = try GamCommands.MessageID(validating: pasted)
        } catch GamCommands.Invalid.argument(let why) {
            shown = (.problem(Problem(summary: why, detail: nil)), setup.active, generation)
            return
        } catch {
            return
        }
        guard let domain = setup.active else {
            shown = (.problem(Problem(summary: "Connect a domain on Setup first.", detail: nil)), nil, generation)
            return
        }
        guard let runner else {
            shown = (.problem(Problem(summary: "This build has no GAM. Build the app again after running scripts/fetch_gam.sh.",
                                      detail: nil)), domain, generation)
            return
        }
        shown = (.finding(message), domain, generation)
        let read = GamCommands.findMessageCopies(message)
        let found: State
        do {
            let result = try await runner.run(read, as: domain, timeout: GamRunner.domainWideTimeout, extraEnvironment: environment)
            // A domain's worth of lines: not on the main actor.
            let copies = try await Task.detached { try MessageCopies(result, argv: read.argv) }.value
            // What the ID matched, from the first mailbox with a copy: a read, and not one that blocks the search.
            var sample: (mailbox: String, copy: MessageRecipients)?, sampleProblem: String?
            if let first = copies.withCopies.first {
                let look = GamCommands.searchMessages(email: first.email, query: message.anyCopyQuery, detail: .headers)
                do {
                    let copy = try MessageRecipients.read(try await runner.run(look, as: domain, extraEnvironment: environment),
                                                          argv: look.argv)
                    if let copy { sample = (first.email, copy) } else { sampleProblem = "\(first.email)'s copy was gone when it was read." }
                } catch {
                    sampleProblem = DirectoryStore.problem(for: error, argv: look.argv).summary
                }
            }
            found = .found(Search(message: message, copies: copies, sample: sample, sampleProblem: sampleProblem,
                                  commandLine: GamCommandLine.text(read.argv), domain: domain, generation: generation))
        } catch let incomplete as MessageCopies.Incomplete {
            found = .problem(Problem(summary: "Not every mailbox could be checked, so none are listed rather than some: "
                                         + incomplete.reason + " Find again.", detail: nil))
        } catch {
            found = .problem(DirectoryStore.problem(for: error, argv: read.argv))
        }
        // A newer search, or a switch while this one ran: it no longer speaks for what's shown.
        guard ask == asked, setup.active == domain, setup.generation == generation else { return }
        shown = (found, domain, generation)
    }

    // MARK: who it was sent to

    /// The sender's own copy of the email (Sent, or their Trash), read for its To, Cc and Bcc, and the tenant's domains
    /// to tell inside from outside: two reads. No copy left is said as such, never as an empty list.
    public func listRecipients(sender: String, message pasted: String) async {
        askedRecipients += 1
        let ask = askedRecipients, generation = setup.generation
        func show(_ state: RecipientsState, _ domain: Domain?) { listed = (state, domain, generation) }
        let message: GamCommands.MessageID
        do {
            message = try GamCommands.MessageID(validating: pasted)
        } catch GamCommands.Invalid.argument(let why) {
            return show(.problem(Problem(summary: why, detail: nil)), setup.active)
        } catch {
            return
        }
        let sender = PythonText.strip(sender)
        guard Address.looksLikeEmail(sender) else {
            return show(.problem(Problem(summary: "Enter the address that sent it, like name@example.com.", detail: nil)), setup.active)
        }
        guard let domain = setup.active else {
            return show(.problem(Problem(summary: "Connect a domain on Setup first.", detail: nil)), nil)
        }
        guard let runner else {
            return show(.problem(Problem(summary: "This build has no GAM. Build the app again after running scripts/fetch_gam.sh.",
                                         detail: nil)), domain)
        }
        show(.reading(sender: sender), domain)
        let read = GamCommands.searchMessages(email: sender, query: message.anyCopyQuery, detail: .headers)
        let domainsRead = GamCommands.printDomains()
        let state: RecipientsState
        do {
            let copy = try MessageRecipients.read(try await runner.run(read, as: domain, extraEnvironment: environment), argv: read.argv)
            var inside: [String] = [], outside: [String] = []
            if let copy, !copy.addresses.isEmpty {
                let domains = try TenantDomains.read(try await runner.run(domainsRead, as: domain, extraEnvironment: environment),
                                                     argv: domainsRead.argv)
                for address in copy.addresses {
                    if domains.isInternal(address) { inside.append(address) } else { outside.append(address) }
                }
            }
            state = .read(Recipients(sender: sender, message: message, copy: copy, inside: inside, outside: outside,
                                     commandLine: GamCommandLine.text(read.argv), domain: domain, generation: generation))
        } catch let incomplete as MessageCopies.Incomplete {
            state = .problem(Problem(summary: incomplete.reason, detail: nil))
        } catch {
            state = .problem(DirectoryStore.problem(for: error, argv: read.argv))
        }
        guard ask == askedRecipients, setup.active == domain, setup.generation == generation else { return }
        show(state, domain)
    }

    // MARK: previewing

    /// Holds the trash for every mailbox the search shown found copies in: one step each, at most the copies found
    /// there, on the tenant it was read on. The executor refuses it on any other.
    public func previewTrash() async {
        guard !isRunning, case .found(let search) = state else { return }
        refusal = nil
        dropHeld()
        let mailboxes = search.copies.withCopies
        guard !mailboxes.isEmpty else {
            refusal = "No mailbox has a copy to trash."
            return
        }
        guard let executor else {
            refusal = "This build has no GAM. Build the app again after running scripts/fetch_gam.sh."
            return
        }
        let steps: [WriteStep]
        do {
            steps = try mailboxes.map { mailbox in
                WriteStep(try GamCommands.trashMessage(email: mailbox.email, search.message, copies: mailbox.copies),
                          target: mailbox.email,
                          summary: mailbox.copies == 1 ? "Move the copy in \(mailbox.email)'s mailbox to its Trash."
                                                       : "Move the \(mailbox.copies) copies in \(mailbox.email)'s mailbox to its Trash.")
            }
        } catch {
            refusal = "A mailbox's count can't be trashed: find again."
            return
        }
        // The number of mailboxes typed, however few: each trash empties out of someone's inbox at once.
        let ask = asked
        previewsAsked += 1
        let previewAsk = previewsAsked
        switch await executor.preview(steps, typedCountAbove: 0, expecting: (search.domain, search.generation)) {
        case .success(let preview):
            // A new search began while this was held: it no longer belongs to what's shown.
            guard ask == asked, previewAsk == previewsAsked, !isRunning else {
                await executor.discard(preview.id)
                return
            }
            held = Pending(preview: preview, search: search, mailboxes: mailboxes)
        case .failure(let why):
            refusal = why.message
        }
    }

    /// The confirm sheet was cancelled: its preview goes at once.
    public func cancelPreview() {
        dropHeld()
    }

    private func dropHeld() {
        guard let id = held?.id else { return }
        held = nil
        if let executor { Task { await executor.discard(id) } }
    }

    // MARK: the run

    /// Runs the held trash once, exactly as held, while it's the one shown: each mailbox's result as it ends. The
    /// executor refuses it without the count typed, after its fifteen minutes, or on another tenant.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isRunning, let executor, let shownPending = self.pending, shownPending.id == pending.id else { return }
        refusal = nil
        held = nil
        isRunning = true
        ran = Run(pending: pending, results: Array(repeating: nil, count: pending.mailboxes.count))
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Trashing an email from \(pending.mailboxes.count) mailboxes")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            isRunning = false
        }
        let (events, observer) = AsyncStream<(Int, RunOutcome.Step)>.makeStream()
        let watcher = Task { @MainActor [weak self] in
            for await (index, result) in events { self?.record(result, at: index) }
        }
        let outcome = await executor.run(pending.preview, confirmation: confirmation, progress: observer)
        observer.finish()
        await watcher.value
        if let why = outcome.refusal {
            ran = nil
            refusal = why
            return
        }
        guard var run = ran else { return }
        for (index, result) in outcome.steps.enumerated() where index < run.results.count { run.results[index] = result }
        run.auditProblem = outcome.auditProblem
        run.ended = true
        ran = run
        // The search is spent: its counts are from before the run. Find Again shows what's left.
        shown = nil
    }

    /// Stop between mailboxes: the one in flight finishes, no later one begins.
    public func stop() async {
        guard isRunning, let id = ran?.pending.id, let executor else { return }
        guard await executor.stopAfterCurrentStep(id) else { return }
        ran?.stopping = true
    }

    /// The finished run's results are put away.
    public func dismissRun() {
        guard !isRunning else { return }
        ran = nil
    }

    private func record(_ result: RunOutcome.Step, at index: Int) {
        guard var run = ran, index < run.results.count else { return }
        run.results[index] = result
        ran = run
    }

    #if DEBUG
    /// Debug builds' screenshots only: the held trash's run, finished, every mailbox trashed. Nothing runs.
    public func showDemoRun() {
        guard let pending else { return }
        dropHeld()
        ran = Run(pending: pending, results: pending.mailboxes.map { _ in .succeeded(output: "") }, ended: true)
        shown = nil
    }
    #endif
}
