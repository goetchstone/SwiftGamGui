import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Phishing screen: an email taken out of every mailbox, for a phishing email sent from a compromised account
/// (docs/domains/phishing.md). The operator pastes its Message-ID, or several, one per line (Pull All, D12). Find runs
/// GAM's own dry run over every active user for each, a read (without `doit` GAM trashes nothing), and beside it a read
/// of the copies in Spam, which the dry run can't see; it shows who has a copy where. Trash holds one ChangeCore step
/// per email and mailbox with copies, capped at the copies Find showed there, and one per mailbox with copies in Spam,
/// naming exactly those copies by ID, so the preview is exactly what can run; the operator confirms it once by typing
/// the number of steps, and each step is audited. Nothing here runs a write itself: every one goes through `Executor`.
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
        /// The copies in Spam, each by its ID; nil when that read failed (`spamProblem` says why), which leaves the rest
        /// of the search as it is.
        public let spam: SpamCopies?
        public let spamProblem: String?
        /// The dry run and the Spam read as the `gam` lines an admin would type.
        public let commandLine: String
        public let spamCommandLine: String
        let domain: Domain
        let generation: Int

        /// Every mailbox with a copy anywhere it could be trashed from: outside Spam, or in it.
        public var mailboxesWithCopies: [String] {
            var seen: Set<String> = []
            return (copies.withCopies.map(\.email) + (spam?.mailboxes.map(\.email) ?? []))
                .filter { seen.insert(PythonText.lower($0)).inserted }
        }

        /// No mailbox has a copy, and every mailbox and its Spam was searched: never said while any went unsearched, where
        /// a copy is unknown (review of 2026-10-19), nor while the Spam read missed a mailbox the dry run listed (one made
        /// between the two reads) or GAM said something neither reader knows (review of 2026-10-23).
        public var nobodyHasIt: Bool {
            guard mailboxesWithCopies.isEmpty, copies.unsearched.isEmpty, copies.otherLines.isEmpty,
                  let spam, spam.unsearched.isEmpty, spam.otherLines.isEmpty else { return false }
            let searched = Set(spam.searched.map(PythonText.lower))
            return copies.mailboxes.allSatisfy { searched.contains(PythonText.lower($0.email)) }
        }
    }

    /// A Find's results, in the order the Message-IDs were pasted: each email's search, or why it couldn't be searched,
    /// which never blocks the others.
    public struct Found: Sendable {
        public let results: [(message: GamCommands.MessageID, result: Result<Search, Problem>)]

        public var searches: [Search] { results.compactMap { try? $0.result.get() } }
        /// The emails some mailbox still has: the ones to trash.
        public var withCopies: [Search] { searches.filter { !$0.mailboxesWithCopies.isEmpty } }
        /// The emails no mailbox here has, every mailbox searched: sent only outside, removed since, or never delivered
        /// (bounced, limited). Never "not sent": the logs and Google's Email Log Search say that.
        public var nobodyHas: [Search] { searches.filter(\.nobodyHasIt) }
        /// The emails no mailbox has a copy of that some mailbox (or its Spam) couldn't be searched for: never clear.
        public var unsure: [Search] { searches.filter { $0.mailboxesWithCopies.isEmpty && !$0.nobodyHasIt } }
        public var failed: [(message: GamCommands.MessageID, problem: Problem)] {
            results.compactMap { if case .failure(let problem) = $0.result { ($0.message, problem) } else { nil } }
        }
    }

    /// One trash a held preview runs: an email's copies in a mailbox outside Spam, at most the count Find saw, or its
    /// copies in Spam, by their IDs.
    public struct Trash: Sendable, Equatable, Identifiable {
        public enum Place: Sendable, Equatable {
            case mailbox(copies: Int)
            case spam(ids: [String])
        }

        public let message: GamCommands.MessageID
        public let email: String
        public let place: Place
        public var id: String { message.id + " " + (inSpam ? email + " spam" : email) }
        public var inSpam: Bool { if case .spam = place { true } else { false } }
        public var copies: Int {
            switch place {
            case .mailbox(let copies): copies
            case .spam(let ids): ids.count
            }
        }
        /// "alice@example.com", or "alice@example.com's Spam".
        public var name: String { inSpam ? "\(email)'s Spam" : email }
    }

    public enum State: Sendable {
        case idle
        /// Find is running for these Message-IDs, and has searched this many of them.
        case finding([GamCommands.MessageID], searched: Int)
        /// Every email searched. With one Message-ID that couldn't be searched, `problem` instead, as before Pull All.
        case found(Found)
        case problem(Problem)
    }

    /// The trash held for the operator to confirm: exactly what a confirm runs.
    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        /// The Find it was held from, every email in it: Find Again and the run's CSV cover the ones that weren't trashed
        /// too (unsure, couldn't be searched), never only these (review of 2026-10-23).
        public let found: Found
        /// The searches it trashes from, in the order pasted: those with a copy somewhere.
        public let searches: [Search]
        /// What each step trashes, in the steps' order: each email's, in turn.
        public let trashes: [Trash]
        public var id: UUID { preview.id }
        /// The mailboxes it trashes from, each once.
        public var mailboxes: [String] {
            var seen: Set<String> = []
            return trashes.map(\.email).filter { seen.insert(PythonText.lower($0)).inserted }
        }
        /// The emails it trashes, each once, in the steps' order.
        public var messages: [GamCommands.MessageID] {
            var seen: Set<String> = []
            return trashes.map(\.message).filter { seen.insert($0.id).inserted }
        }
        /// An email's search, as held.
        public func search(of message: GamCommands.MessageID) -> Search? { searches.first { $0.message == message } }
        var domain: Domain { searches[0].domain }
        var generation: Int { searches[0].generation }
        /// The words the executor asks for: the number of steps (a mailbox with copies in Spam as well is two), and from
        /// ten up `confirm` as well.
        public var typedCount: String { String(trashes.count) }
        public var needsWord: Bool { preview.decision.requiresTypedConfirmation }
    }

    /// A confirmed run: each mailbox's result as it ends.
    public struct Run: Sendable {
        public let pending: Pending
        /// One per mailbox, nil until its step ends.
        public internal(set) var results: [RunOutcome.Step?]
        public internal(set) var ended = false
        /// Stop was asked: the step in flight finishes, no later one begins (a mailbox's Spam step among them).
        public internal(set) var stopping = false
        public internal(set) var auditProblem: String?

        public var trashed: Int { results.filter { $0?.isSucceeded == true }.count }

        /// "Trashed from 3 of 4 mailboxes" (and "1 of 1 Spam folder"), or for several emails "Trashed 9 of 10 steps for 4
        /// emails"; then what failed or didn't run.
        public var summary: String {
            let failed = results.filter { if case .failed? = $0 { true } else { false } }.count
            let notRun = results.filter { if case .skipped? = $0 { true } else { false } }.count
            func part(spam: Bool) -> String? {
                let theirs = zip(pending.trashes, results).filter { $0.0.inSpam == spam }
                guard !theirs.isEmpty else { return nil }
                let done = theirs.filter { $0.1?.isSucceeded == true }.count, total = theirs.count
                return "\(done) of \(total) " + (spam ? "Spam folder\(total == 1 ? "" : "s")" : "mailbox\(total == 1 ? "" : "es")")
            }
            let emails = pending.messages.count
            var text = emails > 1
                ? "\(ended ? "Trashed" : "Trashing") \(trashed) of \(results.count) steps for \(emails) emails"
                : "\(ended ? "Trashed" : "Trashing") from " + [part(spam: false), part(spam: true)].compactMap { $0 }.joined(separator: " and ")
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
            return search.mailboxesWithCopies.filter { !named.contains(PythonText.lower($0)) }
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
        guard let held, held.domain == setup.active, held.generation == setup.generation else { return nil }
        return held
    }

    /// The run going on, or the last one, while it runs or belongs to the connected tenant.
    public var run: Run? {
        guard let ran, isRunning || (ran.pending.domain == setup.active && ran.pending.generation == setup.generation)
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
        let emails = ran.pending.messages.count
        return ((emails > 1 ? "\(emails) emails are" : "An email is") + " still being trashed from \(ran.pending.mailboxes.count) mailboxes.",
                "The steps not yet reached won't run, a mailbox's Spam among them, and the one in progress may stop partway: find the email again before trashing it again.")
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

    /// At most this many Message-IDs in one Find (invariant 9): each is two domain-wide reads.
    public nonisolated static let mostAtOnce = GamCommands.MessageID.mostPerFind
    /// Emails searched at once: each is the dry run and the Spam read together, so twice this many `gam` reads.
    static let searchedAtOnce = 2

    /// The Message-IDs pasted: one, or several one per line (or between commas, which no Message-ID holds), each checked
    /// as `MessageID(validating:)` checks one, each once, at most `mostAtOnce` of them. A header folded onto two lines
    /// ("Message-ID:" then the ID, as some mailers write it) is one. One that isn't a Message-ID is refused with its line,
    /// before GAM.
    public nonisolated static func messages(_ pasted: String) throws -> [GamCommands.MessageID] {
        var lines: [String] = []
        for line in pasted.split(whereSeparator: { $0.isNewline || $0 == "," }).map({ $0.trimmingCharacters(in: .whitespaces) })
        where !line.isEmpty {
            if let last = lines.last, last.lowercased() == "message-id:" { lines[lines.count - 1] = last + " " + line } else { lines.append(line) }
        }
        // None, or one: as before Pull All, its own words.
        guard lines.count > 1 else { return [try GamCommands.MessageID(validating: lines.first ?? pasted)] }
        var seen: Set<String> = [], messages: [GamCommands.MessageID] = []
        for (index, line) in lines.enumerated() {
            let message: GamCommands.MessageID
            do {
                message = try GamCommands.MessageID(validating: line)
            } catch GamCommands.Invalid.argument(let why) {
                throw GamCommands.Invalid.argument("Line \(index + 1): \(why)")
            }
            if seen.insert(message.id).inserted { messages.append(message) }
            guard messages.count <= mostAtOnce else {
                throw GamCommands.Invalid.argument("At most \(mostAtOnce) Message-IDs at once: find the rest after these.")
            }
        }
        return messages
    }

    /// GAM's dry run for each pasted Message-ID over every active user, and beside it the read of its copies in Spam, a
    /// few emails at a time. Replaces the search, problem or held trash shown; refused while a run goes on.
    public func find(_ pasted: String) async {
        guard !isRunning else { return }
        asked += 1
        let ask = asked
        refusal = nil
        dropHeld()
        let generation = setup.generation
        let messages: [GamCommands.MessageID]
        do {
            messages = try Self.messages(pasted)
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
        shown = (.finding(messages, searched: 0), domain, generation)
        let environment = environment
        var results: [Int: Result<Search, Problem>] = [:]
        await withTaskGroup(of: (Int, Result<Search, Problem>).self) { group in
            var waiting = messages.indices.makeIterator()
            for _ in 0..<Self.searchedAtOnce {
                guard let index = waiting.next() else { break }
                group.addTask {
                    (index, await Self.search(messages[index], runner: runner, domain: domain, generation: generation, environment: environment))
                }
            }
            for await (index, result) in group {
                results[index] = result
                // A newer search, Stop, or another tenant (a switch, a credential import): what's searching finishes,
                // nothing more starts, so no read goes on unseen against a tenant the operator left (review 2026-10-23).
                let current = ask == asked && setup.active == domain && setup.generation == generation
                if current { shown = (.finding(messages, searched: results.count), domain, generation) }
                guard current, let next = waiting.next() else { continue }
                group.addTask {
                    (next, await Self.search(messages[next], runner: runner, domain: domain, generation: generation, environment: environment))
                }
            }
        }
        // A newer search, or a switch while this one ran: it no longer speaks for what's shown.
        guard ask == asked, setup.active == domain, setup.generation == generation, results.count == messages.count else { return }
        let found = Found(results: messages.indices.compactMap { index in results[index].map { (messages[index], $0) } })
        if found.results.count == 1, case .failure(let problem) = found.results[0].result {
            shown = (.problem(problem), domain, generation)
        } else {
            shown = (.found(found), domain, generation)
        }
    }

    /// Stops a Find: the emails being searched finish, no more start, and nothing is shown for it (a read: nothing changed).
    public func stopFinding() {
        guard isFinding else { return }
        asked += 1
        shown = nil
    }

    /// One email's search: GAM's dry run over every active user and, at the same time, the read of its copies in Spam,
    /// then one copy's From and Subject; or why it couldn't be searched.
    private nonisolated static func search(
        _ message: GamCommands.MessageID, runner: AuthenticatedRunner, domain: Domain, generation: Int, environment: [String: String]
    ) async -> Result<Search, Problem> {
        let read = GamCommands.findMessageCopies(message), spamRead = GamCommands.findSpamCopies(message)
        // The copies in Spam, read at the same time: its failure is said beside the rest and never blocks them.
        async let spamFound = Self.spamCopies(spamRead, of: message, runner: runner, domain: domain, environment: environment)
        do {
            let result = try await runner.run(read, as: domain, timeout: GamRunner.domainWideTimeout, extraEnvironment: environment)
            // A domain's worth of lines: not on the main actor.
            let copies = try await Task.detached { try MessageCopies(result, argv: read.argv) }.value
            let (spam, spamProblem) = await spamFound
            // What the ID matched, from the first mailbox with a copy, in Spam when that's the only place (the read includes
            // Spam): a read, and not one that blocks the search.
            var sample: (mailbox: String, copy: MessageRecipients)?, sampleProblem: String?
            if let first = copies.withCopies.first?.email ?? spam?.mailboxes.first?.email {
                let look = GamCommands.searchMessages(email: first, query: message.anyCopyQuery, detail: .headers)
                do {
                    let copy = try MessageRecipients.read(try await runner.run(look, as: domain, extraEnvironment: environment),
                                                          argv: look.argv)
                    if let copy { sample = (first, copy) } else { sampleProblem = "\(first)'s copy was gone when it was read." }
                } catch {
                    sampleProblem = DirectoryStore.problem(for: error, argv: look.argv).summary
                }
            }
            return .success(Search(message: message, copies: copies, sample: sample, sampleProblem: sampleProblem, spam: spam,
                                   spamProblem: spamProblem, commandLine: GamCommandLine.text(read.argv),
                                   spamCommandLine: GamCommandLine.text(spamRead.argv), domain: domain, generation: generation))
        } catch let incomplete as MessageCopies.Incomplete {
            return .failure(Problem(summary: "Not every mailbox could be checked, so none are listed rather than some: "
                                        + incomplete.reason + " Find again.", detail: nil))
        } catch {
            return .failure(DirectoryStore.problem(for: error, argv: read.argv))
        }
    }

    /// The copies in Spam, or why they couldn't be read: off the main actor, a domain's worth of lines.
    private nonisolated static func spamCopies(
        _ read: GamRead, of message: GamCommands.MessageID, runner: AuthenticatedRunner, domain: Domain, environment: [String: String]
    ) async -> (SpamCopies?, String?) {
        do {
            let result = try await runner.run(read, as: domain, timeout: GamRunner.domainWideTimeout, extraEnvironment: environment)
            return (try SpamCopies(result, argv: read.argv, message: message), nil)
        } catch let incomplete as MessageCopies.Incomplete {
            return (nil, "Not every mailbox's Spam could be checked, so none is listed rather than some: " + incomplete.reason)
        } catch {
            return (nil, DirectoryStore.problem(for: error, argv: read.argv).summary)
        }
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

    // MARK: export

    public nonisolated static let recipientsColumns = ["address", "where", "header"]

    /// The recipients as the screen lists them, one row per address: outside the tenant's domains, then inside, each
    /// with the header it was first in; then each piece that couldn't be read as an address, as it is (never dropped).
    public nonisolated static func recipientsRows(_ recipients: Recipients) -> [[String]] {
        guard let copy = recipients.copy else { return [] }
        var header: [String: String] = [:]
        for recipient in copy.recipients where header[PythonText.lower(recipient.address)] == nil {
            header[PythonText.lower(recipient.address)] = recipient.header
        }
        func rows(_ addresses: [String], _ place: String) -> [[String]] {
            addresses.map { [$0, place, header[PythonText.lower($0)] ?? ""] }
        }
        return rows(recipients.outside, "outside") + rows(recipients.inside, "inside")
            + copy.unreadableRecipients.map { [$0.address, "unreadable: check by hand", $0.header] }
    }

    public nonisolated static let copiesColumns = ["mailbox", "found", "copies", "in spam", "trash"]

    /// Every mailbox the search read, in its order, with what it found outside Spam and in it and, when `run` trashed from
    /// this search, the outcome of each of its steps ("trashed", "spam: trashed").
    public nonisolated static func copiesRows(_ search: Search, run: Run?) -> [[String]] {
        var outcomes: [String: [String]] = [:]
        if let run, let held = run.pending.search(of: search.message), held.copies == search.copies, held.spam == search.spam {
            for (trash, result) in zip(run.pending.trashes, run.results) where trash.message == search.message {
                let outcome = switch result {
                case nil: run.ended ? "not run" : "waiting"
                case .succeeded?: "trashed"
                case .failed(let message, _)?: "failed: \(message)"
                case .skipped(let reason)?: reason.hasPrefix("Not run") ? reason : "not run: \(reason)"
                case .waiting(let message)?: "waiting: \(message)"
                }
                outcomes[PythonText.lower(trash.email), default: []].append(trash.inSpam ? "spam: \(outcome)" : outcome)
            }
        }
        // In Spam: a count only for a mailbox the Spam read reported searching, never a 0 for one it didn't.
        var spam: [String: String] = [:]
        for email in search.spam?.searched ?? [] { spam[PythonText.lower(email)] = "0" }
        for mailbox in search.spam?.mailboxes ?? [] { spam[PythonText.lower(mailbox.email)] = String(mailbox.ids.count) }
        for mailbox in search.spam?.unsearched ?? [] { spam[PythonText.lower(mailbox.email)] = "not searched: \(mailbox.why)" }
        func row(_ email: String, _ found: String, _ copies: String) -> [String] {
            let key = PythonText.lower(email)
            return [email, found, copies, spam[key] ?? "not searched", outcomes[key]?.joined(separator: "; ") ?? ""]
        }
        let listed = Set(search.copies.mailboxes.map { PythonText.lower($0.email) })
        return search.copies.mailboxes.map { mailbox in
            switch mailbox.finding {
            case .copies(let count): row(mailbox.email, "copies", String(count))
            case .none: row(mailbox.email, "none", "0")
            case .gmailOff: row(mailbox.email, "not searched: Gmail is off", "")
            case .failed(let why): row(mailbox.email, "not searched: \(why)", "")
            }
        }
        // A mailbox only the Spam read reported (one made between the two reads): never dropped.
        + ((search.spam?.mailboxes.map(\.email) ?? []) + (search.spam?.unsearched.map(\.email) ?? []))
            .filter { !listed.contains(PythonText.lower($0)) }.map { row($0, "", "") }
    }

    public nonisolated static let allCopiesColumns = ["message_id"] + copiesColumns

    /// Several emails' searches, each as `copiesRows` lists it with its Message-ID first, in the order pasted; an email that
    /// couldn't be searched is a row of its own saying why, never left out.
    public nonisolated static func allCopiesRows(_ results: [(message: GamCommands.MessageID, result: Result<Search, Problem>)],
                                                 run: Run?) -> [[String]] {
        results.flatMap { message, result -> [[String]] in
            switch result {
            case .success(let search): copiesRows(search, run: run).map { [message.id] + $0 }
            case .failure(let problem): [[message.id, "", "not searched: \(problem.summary)", "", "", ""]]
            }
        }
    }

    /// A dated name for a saved list: "phishing-recipients-2026-10-19.csv".
    public nonisolated static func exportName(_ list: String, on day: Date = Date()) -> String {
        "phishing-\(list)-\(UserChanges.day(day)).csv"
    }

    // MARK: previewing

    /// Holds the trash for every email and mailbox the searches shown found copies in: for each email in turn, one step
    /// per mailbox for its copies outside Spam, at most the count found there, then one per mailbox for its copies in
    /// Spam, exactly those by ID; on the tenant they were read on. The executor refuses it on any other. An email no
    /// mailbox has, or that couldn't be searched, has no step.
    public func previewTrash() async {
        guard !isRunning, case .found(let found) = state else { return }
        refusal = nil
        dropHeld()
        let searches = found.withCopies
        let trashes = searches.flatMap { search in
            search.copies.withCopies.map { Trash(message: search.message, email: $0.email, place: .mailbox(copies: $0.copies)) }
                + (search.spam?.mailboxes.map { Trash(message: search.message, email: $0.email, place: .spam(ids: $0.ids)) } ?? [])
        }
        guard !trashes.isEmpty else {
            refusal = "No mailbox has a copy to trash."
            return
        }
        guard let executor else {
            refusal = "This build has no GAM. Build the app again after running scripts/fetch_gam.sh."
            return
        }
        // Several emails: each step names its email, in the preview and the audit log.
        let several = searches.count > 1
        let steps: [WriteStep]
        do {
            steps = try trashes.map { trash in
                let copies = (trash.copies == 1 ? "the copy" : "the \(trash.copies) copies") + (several ? " of <\(trash.message.id)>" : "")
                switch trash.place {
                case .mailbox(let count):
                    return WriteStep(try GamCommands.trashMessage(email: trash.email, trash.message, copies: count),
                                     target: trash.email, summary: "Move \(copies) in \(trash.email)'s mailbox to its Trash.")
                case .spam(let ids):
                    return WriteStep(try GamCommands.trashMessages(email: trash.email, ids: ids),
                                     target: trash.email, summary: "Move \(copies) in \(trash.email)'s Spam to Trash.")
                }
            }
        } catch {
            refusal = "A mailbox's copies can't be trashed as found: find again."
            return
        }
        // The number of steps typed, however few: each trash empties out of someone's inbox at once.
        let ask = asked
        previewsAsked += 1
        let previewAsk = previewsAsked
        switch await executor.preview(steps, typedCountAbove: 0, expecting: (searches[0].domain, searches[0].generation)) {
        case .success(let preview):
            // A new search began while this was held: it no longer belongs to what's shown.
            guard ask == asked, previewAsk == previewsAsked, !isRunning else {
                await executor.discard(preview.id)
                return
            }
            held = Pending(preview: preview, found: found, searches: searches, trashes: trashes)
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
        ran = Run(pending: pending, results: Array(repeating: nil, count: pending.trashes.count))
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

    /// Stop between steps: the one in flight finishes, no later one begins.
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
    /// Debug builds' screenshots only: the held trash's run, finished, every step trashed. Nothing runs.
    public func showDemoRun() {
        guard let pending else { return }
        dropHeld()
        ran = Run(pending: pending, results: pending.trashes.map { _ in .succeeded(output: "") }, ended: true)
        shown = nil
    }
    #endif
}
