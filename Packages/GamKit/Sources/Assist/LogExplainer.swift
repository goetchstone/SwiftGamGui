import Foundation
import FoundationModels

/// The on-device model's rundown of a reading (docs/plans/2026-10-19-on-device-log-reader.md, R2; the incidents plan): what
/// happened, in order, what has been done, and what's left, each of those sentences citing the to-do items code worked
/// out. Code decides what's done and what's left (`LogReading.Status`, `LogReading.Task`); the model only words it. It is
/// given each account's state and the kinds of step in its timeline, counted, and each to-do item's kind and accounts:
/// never the text the logs carry (a subject, a URL, an app's name), which an attacker writes, and never a fix to make
/// up. A sentence about what's left citing no item it was given is dropped. On-device only (`SystemLanguageModel`):
/// nothing leaves the Mac.
public enum LogExplainer {
    /// What the model wrote: its sentences about what's left kept only where they cite to-do items that exist.
    public struct Explanation: Sendable, Equatable {
        public struct Point: Sendable, Equatable {
            public let text: String
            public let cites: [String]
        }
        public let overview: String
        public let done: String
        public let left: [Point]
    }

    /// The answer's shape, which guided generation holds the model to.
    @Generable
    public struct Answer: Sendable, Equatable {
        @Guide(description: "Three plain sentences telling what happened in time order: when and how the attacker got in, to which "
               + "accounts, and when each was locked. Use the dates given.")
        public var overview: String
        @Guide(description: "Two plain sentences: what has been done to secure the accounts, and whether the locks are holding.")
        public var done: String
        @Guide(description: "The most urgent things left, at most three sentences, each grouping tasks of the same kind and citing their IDs.",
               .maximumCount(3))
        public var left: [AnswerPoint]

        public init(overview: String, done: String, left: [AnswerPoint]) {
            self.overview = overview
            self.done = done
            self.left = left
        }
    }

    @Generable
    public struct AnswerPoint: Sendable, Equatable {
        @Guide(description: "One sentence about the tasks cited.")
        public var text: String
        @Guide(description: "The IDs of the tasks this sentence is about, such as T1.")
        public var cites: [String]

        public init(text: String, cites: [String]) {
            self.text = text
            self.cites = cites
        }
    }

    /// Asks a model for an answer: the on-device model, or a stand-in where there is none (tests, CI).
    public protocol Asking: Sendable {
        func answer(instructions: String, prompt: String) async throws -> Answer
    }

    /// The system's on-device model.
    public struct OnDevice: Asking {
        public init() {}

        public func answer(instructions: String, prompt: String) async throws -> Answer {
            let session = LanguageModelSession(model: .default, instructions: instructions)
            return try await session.respond(to: prompt, generating: Answer.self, options: GenerationOptions(temperature: 0.2)).content
        }
    }

    /// Whether the on-device model can answer now, and if not, why, in words.
    public static var unavailable: String? { OnDeviceModel.unavailable("the logs explained") }

    /// The model's standing instructions.
    static let instructions = """
        You write a short rundown of a security incident for an IT administrator, in plain English, as a colleague briefing \
        them. Every fact was found by code from the logs: use only those facts, and never invent an account, an address, an \
        event, a step or a task. Tell what happened as a story in time order, then what has been done, then the most urgent \
        things left, grouping alike tasks and citing their IDs. Don't repeat the task list word for word, never write a \
        command, and never add a task that isn't listed.
        """

    /// What each kind of to-do item means, for the model.
    static func meaning(_ kind: LogReading.Task.Kind) -> String {
        switch kind {
        case .secureAgain: "secure the account again: the attacker signed in after it was locked"
        case .secure: "secure the account: it hasn't been locked since the attack"
        case .finishLock: "finish the lock: only the password reset or only the sign-out was done"
        case .pullAgain: "pull some logs again for just these accounts: the pull doesn't hold all of them for these accounts (read for every "
            + "account, they stop short of the attack, or a recipient's own Gmail log isn't in it)"
        case .removeAdded: "remove the passkey or 2-Step Verification method the attacker added to the account"
        case .clearRecovery: "clear the recovery email and phone the attacker changed"
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

    /// What happened at an account's lock time, as its state says it: a whole lock, half of one, a suspension.
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
    /// that joined, contacts printed, Google's own actions, and each account's lock and the tries after it. The admin's
    /// many single steps are counted under what's been done instead.
    static let storyKinds: Set<LogReading.Moment.Kind> = [.attackerSignedIn, .attackerChanged, .deviceJoined, .contactsPrinted, .googleDisabled,
                                                          .googleSignedOut]
    /// The steps counted under what's been done: an admin's and the person's own.
    static let doneKinds: Set<LogReading.Moment.Kind> = [.signedOut, .passwordReset, .appsRevoked, .appPasswordsDeleted, .backupCodesDeleted,
                                                         .recoveryRemoved, .suspended, .unsuspended, .adminChange, .ownPassword, .own2SV,
                                                         .ownPasskey, .ownRecovery]

    /// The prompt: what happened in time order (each moment's plain words, with its time said by `when`), each account's
    /// state and the steps taken counted by kind, then each to-do item's ID, meaning and accounts. Never a word the logs
    /// carry as text: a moment's plain words leave out names an attacker can set.
    static func prompt(_ reading: LogReading.Reading, when: @Sendable (Date) -> String = { $0.formatted(.iso8601) }) -> String {
        // Each moment of the story, and whether it always stays: the locks, the tries after them and Google's own actions do;
        // the attacker's moves are capped, the earliest 30 kept.
        var story: [(at: Date, line: String, stays: Bool)] = []
        for status in reading.statuses.prefix(20) {
            let failed = status.timeline.filter { $0.kind == .attackerFailed }
            if !status.attackerGotIn, let first = failed.first {
                story.append((first.at, "\(status.account): the attacker tried the password and failed", false))
            }
            story += status.timeline.filter { storyKinds.contains($0.kind) }
                .map { ($0.at, "\(status.account): \($0.plain)", [.googleDisabled, .googleSignedOut].contains($0.kind)) }
            if let locked = status.lockedAt { story.append((locked, "\(status.account): \(lock(status))", true)) }
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
        for task in reading.toDo.prefix(30) {
            lines.append("\(task.id): \(meaning(task.kind))." + (task.accounts.isEmpty ? "" : " Accounts: " + task.accounts.prefix(10).joined(separator: ", ") + "."))
        }
        return lines.joined(separator: "\n")
    }

    /// The model's rundown of `reading`, each sentence about what's left kept only if it cites to-do items that exist
    /// (citing unknown ones dropped from it), and every text trimmed.
    public static func explain(_ reading: LogReading.Reading, when: @Sendable (Date) -> String = { $0.formatted(.iso8601) },
                               using model: some Asking = OnDevice()) async throws -> Explanation {
        let answer = try await model.answer(instructions: instructions, prompt: prompt(reading, when: when))
        let known = Set(reading.toDo.map(\.id))
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let left = answer.left.compactMap { point -> Explanation.Point? in
            let cites = point.cites.map(trimmed).filter(known.contains)
            guard !cites.isEmpty, !trimmed(point.text).isEmpty else { return nil }
            return Explanation.Point(text: trimmed(point.text), cites: cites)
        }
        return Explanation(overview: trimmed(answer.overview), done: trimmed(answer.done), left: left)
    }
}
