import Foundation
import FoundationModels

/// The on-device model's rundown of a reading (docs/plans/2026-10-19-on-device-log-reader.md, R2; the incidents plan): what
/// happened, in order, and what's left, each of those sentences citing the to-do items code worked out; what has been done
/// is code's own sentences. Code decides what's done and what's left (`LogReading.Status`, `LogReading.Task`); the model only words it. It is
/// given each account's state and the kinds of step in its timeline, counted, and each to-do item's kind, accounts and address:
/// never the text the logs carry (a subject, a URL, an app's name), which an attacker writes, and never a fix to make
/// up. A sentence about what's left citing no item it was given is dropped, and any sentence holding a number or an account
/// the facts don't is dropped and counted. On-device only (`SystemLanguageModel`): nothing leaves the Mac.
public enum LogExplainer {
    /// What the model wrote, and what's done in code's words: the model's sentences about what's left kept only where they
    /// cite to-do items that exist and an earlier one didn't, every one of its sentences kept only where its numbers and accounts are the facts'
    /// (`dropped` counts the rest).
    public struct Explanation: Sendable, Equatable {
        public struct Point: Sendable, Equatable {
            public let text: String
            public let cites: [String]
        }
        public let overview: String
        public let done: String
        public let left: [Point]
        public let dropped: Int
    }

    /// The answer's shape, which guided generation holds the model to. Its guide presupposes nothing the facts may not hold:
    /// asked "when each was locked", and what was done and "whether the locks are holding", it said accounts were secured
    /// when nothing was done (failure log 2026-11-17, 2026-11-20 section). What's done isn't asked: code says it (`done`).
    @Generable
    public struct Answer: Sendable, Equatable {
        @Guide(description: "Up to three plain sentences telling what the lines under 'What happened' say, in time order. Say only what "
               + "those lines say. Use the dates given.")
        public var overview: String
        @Guide(description: "The most urgent things left, at most three sentences, each grouping tasks of the same kind and citing their IDs.",
               .maximumCount(3))
        public var left: [AnswerPoint]

        public init(overview: String, left: [AnswerPoint]) {
            self.overview = overview
            self.left = left
        }
    }

    /// The IDs come first: the model writes fields in their order, and with the sentence first it once wrote "Citations: T2."
    /// into it and closed the point without its IDs, an answer that can't be read (2026-11-20, A3's by-hand run).
    @Generable
    public struct AnswerPoint: Sendable, Equatable {
        @Guide(description: "The IDs of the tasks this sentence is about, such as T1.")
        public var cites: [String]
        @Guide(description: "One sentence about the tasks cited.")
        public var text: String

        public init(text: String, cites: [String]) {
            self.text = text
            self.cites = cites
        }
    }

    /// Asks a model for an answer: the on-device model, or a stand-in where there is none (tests, CI).
    public protocol Asking: Sendable {
        func answer(instructions: String, prompt: String) async throws -> Answer
    }

    /// The system's on-device model, greedy (the same answer for the same facts) and capped: with neither, the apps explainer
    /// once wrote until its context was full.
    public struct OnDevice: Asking {
        public init() {}

        public func answer(instructions: String, prompt: String) async throws -> Answer {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            return try await session.respond(to: prompt, generating: Answer.self, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 700)).content
        }
    }

    /// Whether the on-device model can answer now, and if not, why, in words.
    public static var unavailable: String? { OnDeviceModel.unavailable("the logs explained") }

    /// The model's standing instructions.
    static let instructions = """
        You write a short rundown of what security logs show for an IT administrator, in plain English, as a colleague \
        briefing them. Every fact was found by code from the logs: use only those facts, and never invent an account, an \
        address, an event, a step or a task. Tell what happened as a story in time order, then the most urgent things left, \
        grouping alike tasks and citing their IDs. If the facts don't say an account was signed in \
        to, or locked, don't say it was. Don't repeat the task list word for word, never write a command, and never add a \
        task that isn't listed.
        """

    /// What each kind of to-do item means, for the model.
    static func meaning(_ kind: LogReading.Task.Kind) -> String {
        switch kind {
        case .secureAgain: "secure the account again: the attacker signed in after it was locked"
        case .secure: "secure the account: it hasn't been locked since the attack"
        case .finishLock: "finish the lock: only the password reset or only the sign-out was done"
        case .pullAgain: "pull some logs again for just these accounts: the pull doesn't hold all of them for these accounts (read for every "
            + "account, they stop short of the attack, or a recipient's own Gmail log isn't in it)"
        case .sweep: "read every account's logs from the attacker's address, to find whom else it reached: quick at any size"
        case .readDirectory: "open Users so the directory is read: until then who the attacker's emails reached can't be finished"
        case .removeAdded: "remove the passkey or 2-Step Verification method the attacker added to the account"
        case .clearRecovery: "clear the recovery email and phone the attacker changed"
        case .recoveryQuestion: "have the person set a new recovery question: the attacker changed it"
        case .unblockSender: "have the person unblock the sender the attacker blocked in Gmail"
        case .deleteDevice: "block the computer that joined the account at the attacker's sign-in, or take the account off it"
        case .pullEmail: "pull the email the attacker sent from every mailbox"
        case .warnRecipients: "warn the people the attacker's email reached that no warning picked is shown reaching yet, or finish the list of who it reached"
        case .signOutApp: "sign the person out of another app reached through Google"
        case .warnContacts: "warn the people in the account's contacts, printed while the attacker had it"
        case .warnChat: "ask who got the account's Chat messages not to open their links"
        case .treatAsTaken: "treat the account's exported data as the attacker's"
        case .confirmAddress: "ask the person whether a new address they signed in from after the lock is theirs"
        case .checkPassword: "have the person check or change a password Chrome saw at risk"
        case .look: "see what was done in the account from the attacker's address"
        case .checkShared: "check whether a flagged address is the office's or a VPN's before securing anyone"
        }
    }

    /// An account's lock, as its state says it: a whole lock, half of one, a suspension. Code's words on what's done (`done`).
    static func lock(_ status: LogReading.Status) -> String {
        switch status.state {
        case .partlyLocked: status.reset != nil ? "password reset, but no sign-out seen" : "signed out, but the password not reset"
        case .locked, .stillIn: status.suspended.map { $0.at == status.lockedAt } == true ? "locked (suspended)"
            : "locked (signed out and the password reset)"
        case .notLocked: "no lock"
        }
    }

    /// An account's state, for the model.
    static func stands(_ status: LogReading.Status) -> String {
        switch status.state {
        case .notLocked: "not locked since the attack"
        case .partlyLocked: "partly locked: only the password reset or only the sign-out was done"
        case .locked: status.triedAt == nil ? "locked" : "locked, and the attacker tried again afterwards and failed"
        case .stillIn: "the attacker signed in after the lock"
        }
    }

    /// A timeline step's kind as people say it, counted ("3 forced sign-outs"), for the model.
    static func counted(_ kind: LogReading.Moment.Kind, _ count: Int) -> String {
        let one = count == 1
        return switch kind {
        case .attackerSignedIn: one ? "the attacker signed in once" : "the attacker signed in \(count) times"
        case .attackerFailed: one ? "one failed sign-in by the attacker" : "\(count) failed sign-ins by the attacker"
        case .googleBlocked: one ? "Google blocked one suspicious sign-in" : "Google blocked \(count) suspicious sign-ins"
        case .attackerChanged: one ? "one change by the attacker" : "\(count) changes by the attacker"
        case .deviceJoined: one ? "the attacker's computer joined the account" : "\(count) of the attacker's computers joined the account"
        case .attackerActivity: "other activity from the attacker's address"
        case .contactsPrinted: one ? "the contacts were printed" : "the contacts were printed \(count) times"
        case .signedOut: one ? "one forced sign-out by an admin" : "\(count) forced sign-outs by an admin"
        case .passwordReset: one ? "one password reset by an admin" : "\(count) password resets by an admin"
        case .appsRevoked: one ? "one app's access revoked" : "\(count) apps' access revoked"
        case .appPasswordsDeleted: "app passwords deleted"
        case .backupCodesDeleted: "backup codes deleted"
        case .recoveryRemoved: "recovery details removed"
        case .suspended: "suspended by an admin"
        case .unsuspended: "unsuspended by an admin"
        case .adminChange: one ? "one other admin change" : "\(count) other admin changes"
        case .googleDisabled: "Google disabled the account"
        case .googleSignedOut: "Google signed the person out"
        case .ownPassword: one ? "the person changed their own password" : "the person changed their own password \(count) times"
        case .own2SV: "the person turned on 2-Step Verification"
        case .ownPasskey: "the person added a passkey"
        case .ownRecovery: "the person changed their recovery details"
        }
    }

    /// The moments that tell the story, from every account's timeline: the attacker's sign-ins and changes, the computers
    /// that joined, contacts printed, Google's own actions, and the attacker's tries after a lock. The locks and the admin's
    /// many single steps are under what's been done instead.
    static let storyKinds: Set<LogReading.Moment.Kind> = [.attackerSignedIn, .attackerChanged, .deviceJoined, .contactsPrinted, .googleDisabled,
                                                          .googleSignedOut]
    /// The steps counted under what's been done: an admin's and the person's own.
    static let doneKinds: Set<LogReading.Moment.Kind> = [.signedOut, .passwordReset, .appsRevoked, .appPasswordsDeleted, .backupCodesDeleted,
                                                         .recoveryRemoved, .suspended, .unsuspended, .adminChange, .ownPassword, .own2SV,
                                                         .ownPasskey, .ownRecovery]

    /// The prompt: what happened in time order (each moment's plain words, with its time said by `when`), each account's
    /// state and the steps taken counted by kind, then each to-do item's ID, meaning, accounts and address. Never a word the
    /// logs carry as text: a moment's plain words leave out names an attacker can set.
    static func prompt(_ reading: LogReading.Reading, when: @Sendable (Date) -> String = { $0.formatted(.iso8601) }) -> String {
        // Each moment of the story, and whether it always stays: the tries after a lock and Google's own actions do; the
        // attacker's moves are capped, the earliest 30 kept. The locks aren't in it: what's done is code's sentences
        // (`done`), and at 40 accounts the story retold them wrong, which account was locked and which half locked, naming
        // real accounts at real times, so no check caught it (failure log 2026-11-17, its 2026-11-20 sections).
        var story: [(at: Date, line: String, stays: Bool)] = []
        for status in reading.statuses.prefix(20) {
            let failed = status.timeline.filter { $0.kind == .attackerFailed }
            if !status.attackerGotIn, let first = failed.first {
                story.append((first.at, "\(status.account): the attacker tried the password and failed", false))
            }
            story += status.timeline.filter { storyKinds.contains($0.kind) }
                .map { ($0.at, "\(status.account): \($0.plain)", [.googleDisabled, .googleSignedOut].contains($0.kind)) }
            if let tried = status.triedAt { story.append((tried, "\(status.account): the attacker tried again after the lock and failed", true)) }
        }
        let moves = Set(story.enumerated().filter { !$0.element.stays }.sorted { $0.element.at < $1.element.at }.prefix(30).map(\.offset))
        var lines = ["What happened, in time order:"]
        lines += story.enumerated().filter { $0.element.stays || moves.contains($0.offset) }.map(\.element)
            .sorted { $0.at < $1.at }.map { "- \(when($0.at)): \($0.line)." }
        lines.append("Where each account stands, and what was done:")
        for status in reading.statuses.prefix(20) {
            var counts: [LogReading.Moment.Kind: Int] = [:]
            for moment in status.timeline { counts[moment.kind, default: 0] += moment.kind == .appsRevoked ? moment.count : 1 }
            let steps = LogReading.Moment.Kind.allCases.filter(doneKinds.contains).compactMap { kind in counts[kind].map { counted(kind, $0) } }
            lines.append("\(status.account): \(stands(status))" + (steps.isEmpty ? "." : ". Done: " + steps.joined(separator: "; ") + "."))
        }
        lines.append(reading.toDo.isEmpty ? "Nothing is left to do." : "Left to do:")
        for task in reading.toDo.prefix(30) { lines.append("\(task.id): \(meaning(task.kind))." + about(task)) }
        // What this app's records show done: an email pulled, a warning sent, a step marked done by hand (never how it was
        // done, which is typed).
        if !reading.done.isEmpty { lines.append("Already done, as this app's records show:") }
        for task in reading.done.prefix(30) {
            let hand = if case .byHand? = task.done?.how { " (marked done by hand)" } else { "" }
            lines.append("- Done: \(meaning(task.kind))\(hand)." + about(task))
        }
        return lines.joined(separator: "\n")
    }

    /// What a to-do item is about, after its meaning: its accounts, and the address a sweep reads from (`sweeps`, which
    /// `LogReading.isAddress` holds to an address's shape). Twelve sweeps that named no address were twelve lines word for
    /// word alike, and the model told them as one review in batches, or as done (failure log 2026-11-17, its 2026-11-20
    /// sections).
    static func about(_ task: LogReading.Task) -> String {
        (task.accounts.isEmpty ? "" : " Accounts: " + task.accounts.prefix(10).joined(separator: ", ") + ".")
            + (task.sweeps.map { " Address: \($0)." } ?? "")
    }

    /// The model's rundown of `reading`, each sentence about what's left kept only if it cites to-do items that exist
    /// (citing unknown ones dropped from it), every sentence checked against the prompt's facts, and every text trimmed.
    public static func explain(_ reading: LogReading.Reading, when: @Sendable (Date) -> String = { $0.formatted(.iso8601) },
                               using model: some Asking = OnDevice()) async throws -> Explanation {
        try await explain(reading, facts: prompt(reading, when: when), using: model)
    }

    /// The report's summary, drafted (the incidents plan: "the model drafts the report's summary from the findings, shown as
    /// the model's and edited by the operator"; asked 2026-10-28: "can we get the model to help generate the report"): the
    /// rundown, told the report's numbers too, as plain paragraphs without the to-do IDs (the report numbers its own list).
    /// Checked as the rundown is (`explain`), against these facts, the report's numbers among them, with the count of
    /// sentences dropped for the screen to say. Coarse (review 2026-10-28): the facts hold times and addresses too, so a small
    /// wrong count can still pass; the operator checks the draft against the report before it's kept.
    public static func summary(_ reading: LogReading.Reading, numbers: [(label: String, number: Int)],
                               when: @Sendable (Date) -> String = { $0.formatted(.iso8601) },
                               using model: some Asking = OnDevice()) async throws -> (text: String, dropped: Int) {
        let facts = prompt(reading, when: when)
            + (numbers.isEmpty ? "" : "\nThe report's numbers:\n" + numbers.map { "- \($0.label): \($0.number)" }.joined(separator: "\n"))
        let explanation = try await explain(reading, facts: facts, using: model)
        let parts = [explanation.overview, explanation.done, explanation.left.map(\.text).joined(separator: " ")]
        return (parts.filter { !$0.isEmpty }.joined(separator: "\n\n"), explanation.dropped)
    }

    /// Each account `text` names, lowercased: a run of the characters an account can hold (`LogReading.isAccount`) that
    /// holds an `@`, its sentence's stop and a possessive trimmed. "carol@example.com—the first" names carol@example.com.
    static func accounts(in text: String) -> [String] {
        text.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber || "._%+-'@".contains($0))) }.filter { $0.contains("@") }.map { run in
            var account = Substring(run)
            if account.hasSuffix("'s") { account = account.dropLast(2) }
            return String(account.trimmingCharacters(in: CharacterSet(charactersIn: ".'-")))
        }
    }

    /// Whether `account`, as a sentence names it, is one the facts hold: whole, or as its name and `@` ("carol@"), or as its
    /// domain ("@example.com"). Never part of a name: "ann@example.com" isn't joann@example.com.
    static func holds(_ facts: Set<String>, _ account: String) -> Bool {
        facts.contains(account) || account.hasSuffix("@") && facts.contains { $0.hasPrefix(account) }
            || account.hasPrefix("@") && account.count > 1 && facts.contains { $0.hasSuffix(account) }
    }

    /// Each run of digits in `text`, in any script ("٥" too, review 2026-10-28), without leading zeros ("09:04" is "9:04"):
    /// what a number written in a sentence must be among the facts' (a count, a date, a time).
    static func digits(in text: String) -> [Substring] {
        text.split(whereSeparator: { !$0.isNumber }).map { run in
            let trimmed = run.drop { $0 == "0" }
            return trimmed.isEmpty ? run.suffix(1) : trimmed
        }
    }

    /// `text`'s sentences, each with its stop, trimmed: split after a `.`, `!` or `?` that a space or the end follows.
    static func sentences(_ text: String) -> [String] {
        var found: [String] = [], current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            if ".!?".contains(character), index + 1 == characters.count || characters[index + 1].isWhitespace {
                found.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return (found + (rest.isEmpty ? [] : [rest])).filter { !$0.isEmpty }
    }

    /// Code's own words for logs with no account the attacker touched, or nil when there is one (a status: signed in to, tried,
    /// changed, or its password typed on a phishing site), which is the story the model tells. Told of "a security incident"
    /// with nothing in it, the model made one up, with an attacker, dates and a lock (2026-11-17). A suspect address with no
    /// account touched (a pull by it that read only Gmail, say) is said as that, never as no attacker.
    public static func untold(_ reading: LogReading.Reading) -> String? {
        guard reading.statuses.isEmpty else { return nil }
        return reading.findings.contains { $0.kind == .suspectAddress } ? suspectOnly : noAttacker
    }

    static let noAttacker = "These logs show no sign of an attacker: no account was signed in to, tried or changed from a suspect address."
    static let suspectOnly = "These logs show a suspect address, but no account signed in to, tried or changed from it: what they show of it "
        + "is in the findings and the to-do list."

    /// What's done, in code's words: each account's lock as these logs show it, alike ones together, then how many steps
    /// this app's records show done. Never the model's: asked what was done, it said accounts were secured when nothing was,
    /// and a sentence like that names only real accounts and no number, so no check catches it (failure log 2026-11-17,
    /// 2026-11-20 sections; review of A3).
    static func done(_ reading: LogReading.Reading) -> String {
        var groups: [(words: String, accounts: [String])] = []
        for status in reading.statuses {
            let words = switch status.state {
            case .notLocked where status.unseen != nil: "No lock these logs can show"
            case .notLocked where status.earlierLockAt != nil: "No lock since the attack (these logs show one before it)"
            case .notLocked: "Not locked yet"
            case .partlyLocked, .locked: lock(status).prefix(1).uppercased() + lock(status).dropFirst()
            case .stillIn: lock(status).prefix(1).uppercased() + lock(status).dropFirst() + ", then the attacker signed in again"
            }
            if let index = groups.firstIndex(where: { $0.words == words }) { groups[index].accounts.append(status.account) }
            else { groups.append((words, [status.account])) }
        }
        var sentences = groups.map { group in
            let shown = group.accounts.prefix(10), more = group.accounts.count - shown.count
            return "\(group.words): " + LogReading.list(Array(shown) + (more > 0 ? ["\(more) more"] : [])) + "."
        }
        if !reading.done.isEmpty {
            let ids = reading.done.map(\.id).joined(separator: ", ")
            sentences.append(reading.done.count == 1 ? "This app's records show one more step done (\(ids))."
                             : "This app's records show \(reading.done.count) more steps done (\(ids)).")
        }
        return sentences.joined(separator: " ")
    }

    /// The model's answer to `facts`, each sentence about what's left kept only if it cites to-do items of `reading`, at least
    /// one that no earlier kept sentence cited, and every sentence only if each run of digits in it is among the facts' and
    /// each account it names is in them; the sentences dropped for those are counted. What's done is code's (`done`). Logs with no account the attacker touched
    /// aren't given to it: the answer is code's `untold` sentence alone.
    static func explain(_ reading: LogReading.Reading, facts: String, using model: some Asking) async throws -> Explanation {
        if let untold = untold(reading) { return Explanation(overview: untold, done: "", left: [], dropped: 0) }
        let answer = try await model.answer(instructions: instructions, prompt: facts)
        let known = Set(reading.toDo.map(\.id)), numbers = Set(digits(in: facts)), named = Set(accounts(in: facts))
        var dropped = 0
        func checked(_ text: String) -> String {
            sentences(text).filter { sentence in
                let stands = digits(in: sentence).allSatisfy(numbers.contains) && accounts(in: sentence).allSatisfy { holds(named, $0) }
                if !stands { dropped += 1 }
                return stands
            }.joined(separator: " ")
        }
        // A point citing only items an earlier one did is dropped: given one kind of task, the model wrote three points on the
        // same twelve sweeps, and the later two told them as done (failure log 2026-11-17, its 2026-11-20 sections).
        var cited: Set<String> = []
        let left = answer.left.compactMap { point -> Explanation.Point? in
            let cites = point.cites.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(known.contains)
            guard !cites.isEmpty, !cites.allSatisfy(cited.contains) else { return nil }
            let text = checked(point.text)
            guard !text.isEmpty else { return nil }
            cited.formUnion(cites)
            return Explanation.Point(text: text, cites: cites)
        }
        return Explanation(overview: checked(answer.overview), done: done(reading), left: left, dropped: dropped)
    }
}
