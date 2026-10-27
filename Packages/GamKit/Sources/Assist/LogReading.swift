import Foundation

/// The log reader's findings (docs/plans/2026-10-19-on-device-log-reader.md): what the incident logs show, found by rules
/// in code, and the fixes they point to as drafts. Pure: events in as values, findings out. `Assist` depends on no module
/// that can run gam (invariant 10); a draft only names a person or a Message-ID for a screen to open, where that screen's
/// own read, preview and confirmation do the rest.
public enum LogReading {
    /// One log event as the reader sees it: its log (`login`, `token`, `gmail`, `chrome`…), when, whose, the event's name,
    /// the IP address, whether Google flagged it, and its parameters by name.
    public struct Event: Sendable, Equatable {
        public let log: String
        public let time: Date?
        public let who: String
        public let event: String
        public let ip: String
        public let flagged: Bool
        public let parameters: [String: String]
        /// The AI agent that acted, in words ("the AI agent Inbox Helper, made by dana@…"); empty when none.
        public let agent: String
        /// The app that acted for the person ("Mail Sync Pro"); empty when they acted themselves.
        public let app: String

        public init(log: String, time: Date?, who: String, event: String, ip: String, flagged: Bool, parameters: [String: String],
                    agent: String = "", app: String = "") {
            self.log = log
            self.time = time
            self.who = who
            self.event = event
            self.ip = ip
            self.flagged = flagged
            self.parameters = parameters
            self.agent = agent
            self.app = app
        }
    }

    /// What the pull says that its events don't: the address it was pulled by (the operator's to call the attacker's), the
    /// logs it read, by name (nil: not said; a lock is seen only where the admin log was read, by the accounts), the
    /// sign-ins the operator marked as the person's own (`key(account:address:)`), and the logs that stopped at their cap,
    /// each with its oldest event read (a log read for every account can stop short of the attack). And what this app shows
    /// of the emails to pull: Phishing's runs in its audit log (`pulled`), and the emails its Find showed nobody here has
    /// (`nobodyHas`). Facts beside the events, never among them.
    public struct Context: Sendable, Equatable {
        public let pulledBy: String
        public let read: Set<String>?
        public let theirs: Set<String>
        public let capped: [String: Date]
        public let pulled: [Pulled]
        public let nobodyHas: [NobodyHas]
        /// The tenant's domains, lowercased: an address at one is inside (`Reach`).
        public let domains: Set<String>
        /// Every person's address here and each of their aliases, lowercased, to their own address; nil while the directory
        /// isn't read, and for one read empty (a tenant has at least its admin: final review 2026-10-25). An inside address that
        /// isn't one is no one's mailbox (a group, an address no account has): `Reach`.
        public let people: [String: String]?
        /// The warnings the operator picked for each email the attacker sent: its bare Message-ID to theirs (`Reach`).
        public let warnings: [String: Set<String>]

        public init(pulledBy: String = "", read: Set<String>? = nil, theirs: Set<String> = [], capped: [String: Date] = [:],
                    pulled: [Pulled] = [], nobodyHas: [NobodyHas] = [], domains: Set<String> = [], people: [String: String]? = nil,
                    warnings: [String: Set<String>] = [:]) {
            self.pulledBy = pulledBy
            self.read = read
            self.theirs = theirs
            self.capped = capped
            self.pulled = pulled
            self.nobodyHas = nobodyHas
            self.domains = domains
            self.people = people.flatMap { $0.isEmpty ? nil : $0 }
            self.warnings = warnings
        }
    }

    /// Phishing's Find showed no mailbox here has this email, every mailbox and its Spam searched, at `at`, with `by`
    /// connected: kept on this Mac, since a read is never audited. Sent only outside, removed since, or never delivered: the
    /// usual end of Pull All for an email.
    public struct NobodyHas: Sendable, Equatable {
        /// The Message-ID, with or without its angle brackets.
        public let messageID: String
        public let at: Date
        public let by: String

        public init(messageID: String, at: Date, by: String) {
            (self.messageID, self.at, self.by) = (messageID, at, by)
        }
    }

    /// How a to-do item was done, when, and by whom (an admin's address, or "" when none was known).
    public struct Done: Sendable, Equatable {
        public enum How: Sendable, Equatable {
            /// Phishing's latest run trashed the email everywhere it was found (this app's audit log).
            case trashed
            /// Phishing's Find showed nobody here has the email (kept on this Mac).
            case nobodyHasIt
            /// A warning the operator picked went to everyone the email reached (the Gmail log's sends of it).
            case warned
        }
        public let how: How
        public let at: Date
        public let by: String
    }

    /// Phishing's latest run on one email, as this app's audit log shows it: when its newest record was written and by
    /// whom, the steps the run held for the email, those that ended trashed and those that failed (the rest never ended:
    /// not begun after a Stop, cut off, or still running), the mailboxes they named, and whether Find had searched every
    /// mailbox and its Spam for it. The screen reads it from the log; the reader decides what it shows.
    public struct Pulled: Sendable, Equatable {
        /// The Message-ID, with or without its angle brackets.
        public let messageID: String
        public let at: Date
        public let by: String
        public let steps: Int
        public let trashed: Int
        public let failed: Int
        public let mailboxes: Int
        public let searchedEverywhere: Bool

        public init(messageID: String, at: Date, by: String, steps: Int, trashed: Int, failed: Int, mailboxes: Int,
                    searchedEverywhere: Bool) {
            (self.messageID, self.at, self.by, self.steps, self.trashed, self.failed, self.mailboxes, self.searchedEverywhere)
                = (messageID, at, by, steps, trashed, failed, mailboxes, searchedEverywhere)
        }

        /// Every step the run held for it ended trashed, and Find had searched everywhere: no copy Find could see is left.
        /// A step failed or never ended, or a mailbox unsearched (where a copy is unknown), and it's still to do.
        var isDone: Bool { steps > 0 && trashed == steps && searchedEverywhere }

        /// What the run left, as the to-do item says it: "Phishing's last run by … trashed 2 of its 3 steps, but 1 failed: …".
        var left: String {
            var but: [String] = []
            if failed > 0 { but.append("\(failed) failed") }
            let unfinished = max(0, steps - trashed - failed)
            if unfinished > 0 { but.append("\(unfinished) didn't finish") }
            if !searchedEverywhere { but.append("Find couldn't search every mailbox for it") }
            return "Phishing's last run" + (by.isEmpty ? "" : " by \(by)")
                + (trashed >= steps ? " trashed it from every mailbox it found" : " trashed \(trashed) of its \(steps) steps")
                + (but.isEmpty ? "" : ", but " + LogReading.list(but)) + ": find it again there to see what's left."
        }
    }

    /// A Message-ID as Phishing names it: without its angle brackets (the Gmail log keeps them).
    static func bareMessageID(_ id: String) -> String {
        let spaced = id.utf8.first.map { $0 == 0x20 || $0 == 0x09 } ?? false || id.utf8.last.map { $0 == 0x20 || $0 == 0x09 } ?? false
        let trimmed = spaced ? id.trimmingCharacters(in: .whitespaces) : id
        guard trimmed.count > 1, trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    /// A sign-in the operator marked as the person's own: their account and the address, case aside.
    public static func key(account: String, address: String) -> String { account.lowercased() + "|" + address.lowercased() }

    /// Where an account the attacker had stands, read from the logs in time order: the lock (a password reset and a
    /// sign-out, or a suspension, each the first since the attacker's first event, by an admin or by Google), and what
    /// came after it. Its dates are said by the caller's `when`, so the words read in the operator's own time.
    public struct Status: Sendable, Equatable {
        public enum State: Sendable, Equatable {
            /// No lock seen since the attack.
            case notLocked
            /// A password reset or a sign-out, not both.
            case partlyLocked
            case locked
            /// A sign-in from a suspect address after the lock: the attacker may still be in.
            case stillIn
        }
        /// A step of the lock: when, and who did it (an admin's address, or Google).
        public struct Step: Sendable, Equatable {
            public let at: Date
            public let by: String
        }
        public let account: String
        public let state: State
        /// The attacker signed in to it (to Google or another app through it); else they only tried its password, or Google
        /// warned of it.
        public let attackerGotIn: Bool
        /// The account's first event from a suspect address in these logs.
        public let attackedAt: Date?
        public let reset: Step?
        public let signOut: Step?
        public let suspended: Step?
        /// When the lock was whole, or its one half was done.
        public let lockedAt: Date?
        /// The first sign-in from a suspect address after the lock, and its address.
        public let backInAt: Date?
        public let backInFrom: String
        /// The last failed sign-in from a suspect address after the lock: the lock holding.
        public let triedAt: Date?
        /// Addresses it signed in from after the lock that these logs didn't show before the attack.
        public let newAddresses: [String]
        /// Why no lock could be seen, when that's known: the pull's way of reading couldn't show it.
        public let unseen: String?
        /// With no lock since the attack: the last lock step these logs show before it, which may be the lock, the window
        /// starting after the attack began.
        public let earlierLockAt: Date?
        /// What happened to it, in time order: the attacker's sign-ins and changes, each step of every lock (a forced
        /// sign-out, a reset, apps revoked), what Google did, and the person's own changes.
        public let timeline: [Moment]

        public func words(_ when: (Date) -> String) -> String {
            switch state {
            case .stillIn:
                guard let backInAt, let lockedAt else { return "" }
                return "Signed in from \(backInFrom) at \(when(backInAt)), after the lock at \(when(lockedAt)): the attacker may still be in."
            case .locked:
                // Each step at its own time: a sign-out days before the reset is said as days before.
                let steps = suspended.flatMap { $0.at == lockedAt ? [($0.at, "suspended by \($0.by) at \(when($0.at))")] : nil }
                    ?? [reset.map { ($0.at, "password reset by \($0.by) at \(when($0.at))") },
                        signOut.map { ($0.at, "signed out by \($0.by) at \(when($0.at))") }].compactMap(\.self).sorted { $0.0 < $1.0 }
                return "Locked: " + steps.map(\.1).joined(separator: ", then ") + "."
                    + (triedAt.map { " The attacker's address tried again at \(when($0)) and failed: the lock is holding." }
                        ?? " No sign-in from a suspect address since.")
            case .partlyLocked:
                if let reset {
                    return "Password reset at \(when(reset.at)) by \(reset.by), but no sign-out seen: the attacker's open sessions may still work."
                }
                guard let signOut else { return "" }
                return "Signed out at \(when(signOut.at)) by \(signOut.by), but no password reset seen: whoever has the password can "
                    + "sign in again."
            case .notLocked:
                if let unseen { return "No lock seen: \(unseen)." }
                if let earlierLockAt {
                    return "No lock since the first sign-in from a suspect address in these logs; one came at \(when(earlierLockAt)), "
                        + "before it. If the attack began earlier, pull from before it began."
                }
                return "No lock seen in these logs."
            }
        }

    }

    /// One thing that happened to an account, in its timeline: what, in words without its time (the caller says it), and
    /// for several alike, how many and until when.
    public struct Moment: Sendable, Equatable {
        public enum Kind: String, Sendable, CaseIterable {
            case attackerSignedIn, attackerFailed, googleBlocked, attackerChanged, deviceJoined, attackerActivity, contactsPrinted,
                 signedOut, passwordReset, appsRevoked, appPasswordsDeleted, backupCodesDeleted, recoveryRemoved, suspended,
                 unsuspended, adminChange, googleDisabled, googleSignedOut, ownPassword, own2SV, ownPasskey, ownRecovery
        }
        /// Who did it, as the timeline marks it.
        public enum Who: String, Sendable { case attacker, admin, google, person, unknown }
        public let at: Date
        public let until: Date?
        public let kind: Kind
        public let words: String
        public let count: Int
        /// The words with nothing the logs carry as text (an app's or a device's name, a blocked address), which an
        /// attacker can set: what the model is given.
        public let plain: String

        public var who: Who {
            switch kind {
            case .attackerSignedIn, .attackerFailed, .attackerChanged, .deviceJoined, .attackerActivity: .attacker
            case .googleBlocked, .googleDisabled, .googleSignedOut: .google
            case .ownPassword, .own2SV, .ownPasskey, .ownRecovery: .person
            case .contactsPrinted: .unknown
            default: .admin
            }
        }
    }

    /// Something left to do, worked out by code from where each account stands and what the logs show; the model only
    /// words it. `id` ("T1") is what the model's sentences cite. It leaves the list once the logs show it done (a lock, a
    /// device removed, recovery details cleared), or once this app shows an email pulled or nobody here having it, which then
    /// lists it as done (`Reading.done`, "D1", with `done`); what none can show stays until the incident record can tick it.
    public struct Task: Sendable, Equatable, Identifiable {
        /// Most urgent first.
        public enum Kind: String, Sendable, CaseIterable {
            case secureAgain, secure, finishLock, pullAgain, removeAdded, clearRecovery, unblockSender, deleteDevice, pullEmail,
                 warnRecipients, signOutApp, warnContacts, warnChat, treatAsTaken, confirmAddress, checkPassword, look, checkShared
        }
        public let id: String
        public let kind: Kind
        /// The sentence shown: it may hold what the logs carry as text (a subject), which the model is never given.
        public let words: String
        public let accounts: [String]
        public let drafts: [Draft]
        /// The events it's about, for the screen to show ("Show the Events"): nil when it names no account.
        public let shows: Shown?
        /// The logs to read again for its accounts ("Pull Again"), by their names in the logs (`login`, `gmail`); empty for
        /// none. A read, never a change.
        public let pullsAgain: [String]
        /// How it was done, when and by whom, for an item on `Reading.done`; nil while it's still to do.
        public let done: Done?
    }

    /// Which events a to-do item is about: its accounts', from these addresses (none: any), in these logs, through these
    /// apps, or by this agent (each empty for any). What the screen narrows the logs to; never given to the model (an
    /// app's or agent's name is the logs' text).
    public struct Shown: Sendable, Equatable {
        public let accounts: [String]
        public let addresses: [String]
        public let logs: [String]
        public let apps: [String]
        public let agent: String

        public init(accounts: [String], addresses: [String] = [], logs: [String] = [], apps: [String] = [], agent: String = "") {
            (self.accounts, self.addresses, self.logs, self.apps, self.agent) = (accounts, addresses, logs, apps, agent)
        }
    }

    /// A fix a finding points to: a value for a screen, never a command. Secure Account opens for the person and checks
    /// them; Phishing opens with the Message-ID and finds who has a copy.
    public enum Draft: Sendable, Hashable {
        case secureAccount(String)
        case pullEmail(messageID: String, subject: String)
        /// Secure Account opened for the person with only this picked ("Do It Here"): its preview and confirmation run it.
        case undo(account: String, pick: Pick)

        /// "Secure carol@example.com", "Pull “Invoice” from every mailbox".
        public var title: String {
            switch self {
            case .secureAccount(let person): "Secure \(person)…"
            case .undo: "Do It Here…"
            case .pullEmail(_, let subject):
                // The subject is the attacker's text, of any length: a button shows its start, the finding all of it.
                "Pull “\(subject.isEmpty ? "(no subject)" : subject.count > 40 ? subject.prefix(40) + "…" : subject)” from Every Mailbox…"
            }
        }
    }

    /// What a "Do It Here" picks in the person's Check Account: a computer the attacker's sign-in joined (by the Devices
    /// log's ID for it, which may be Google's own, and when it registered, to find it by time otherwise), or clearing the
    /// recovery details.
    public enum Pick: Sendable, Hashable {
        case computer(resourceID: String, registeredAt: Date?)
        case clearRecovery
    }

    /// One thing the logs show, in a sentence, with the accounts and addresses it concerns, how many events say it, and
    /// the drafts it points to. `id` ("F1") is what the model's points cite.
    public struct Finding: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, CaseIterable {
            case signedInFromSuspect, leftInPlace, deviceAtSuspectSignIn, appFromSuspect, actedFromSuspect, exportedFromSuspect,
                 contactsTaken, mailFromSuspect, passwordOnPhishingSite, failedFromSuspect, otherAppSession, chatFromSuspect,
                 agentActed, pastPhishingWarning, passwordOnOtherSite, breachedPassword, sharedAddress, suspectAddress
        }
        public let id: String
        public let kind: Kind
        /// The sentence shown: it may hold what the logs carry as text (a subject, a URL), which the model is never given.
        public let words: String
        public let accounts: [String]
        public let addresses: [String]
        public let events: Int
        public let drafts: [Draft]
        /// For a suspect address Google marked: the accounts whose own sign-ins it marked there, each one the operator can
        /// mark as that person's own ("That was them"). Empty for every other finding, and for the address they pulled by.
        public let markable: [String]
    }

    /// Who one email the attacker sent reached, from the Gmail log's own events for it, as Google's Gmail log events say it
    /// (Google's schema for Gmail logs; the Admin console's Event): `event_info.mail_event_type` 1 Send, 2 Receive, 6
    /// released from quarantine, 30 Bounced, 5 quarantined, 34 rejected or slowed for too much mail, and an event whose
    /// `event_info.success` is false; `message_info.flattened_destinations` every recipient as `service:selector:address`,
    /// comma-separated. Every address its sends named, Bcc included, then any mailbox that received it unnamed. Code works it
    /// out; the model is never given it (it holds addresses and a subject).
    public struct Reach: Sendable, Equatable {
        public enum Outcome: String, Sendable {
            /// A mailbox here received it (a Receive, or a release from quarantine).
            case received
            /// A Bounced event names them.
            case bounced
            /// Quarantined, rejected for too much mail, or an event Google marked failed, and no receipt after.
            case blocked
            /// Its sends named them, and the logs read show nothing else: outside, the most Google's log says.
            case sent
            /// Inside, but no one's mailbox (a group, an address no account has): its members show by their own receipts.
            case notAMailbox
        }

        public struct Recipient: Sendable, Equatable, Identifiable {
            public let address: String
            public let inside: Bool
            /// A person's mailbox here: their receipt is what says a warning reached them.
            public let mailbox: Bool
            public let outcome: Outcome
            public let at: Date?
            /// The log's own word that a warning that counts reached them: their mailbox's receipt of it (a person here), or
            /// its send Google didn't mark failed naming them with nothing failing after (outside, or no one's mailbox). False
            /// is "not shown warned", never "not warned": a receipt in a log not read can't be seen. Nil while no warning that
            /// counts is picked.
            public let warned: Bool?
            /// To warn: reached (all but an address that bounced and isn't a person's mailbox here) and not shown warned. A
            /// person here whose copy bounced stays to warn (final review 2026-10-25: the CSV said "bounced" and nothing more).
            public var toWarn: Bool { !(outcome == .bounced && !mailbox) && warned != true }
            public var id: String { address }
        }

        /// An email sent after this one by an account here, from an address that isn't the attacker's, to people it reached:
        /// what the operator can pick as the warning. Or one picked, as the logs read show it, with why it doesn't count.
        public struct Candidate: Sendable, Equatable, Identifiable {
            public let messageID: String
            public let sender: String
            public let subject: String
            public let at: Date?
            /// How many of the people this email reached it went to (a candidate), or the log shows it reaching (a pick).
            public let covers: Int
            /// A pick that counts: those people, by the log's word (what done names it by). Empty for a candidate.
            public let warned: Set<String>
            /// Why a warning picked doesn't count (not in the logs read, sent from the attacker's address, sent before the
            /// email); nil when it does.
            public let problem: String?
            public var id: String { messageID }
        }

        /// Bare, as Phishing names it.
        public let messageID: String
        public let subject: String
        /// The accounts whose sends of it the logs show.
        public let senders: [String]
        public let recipients: [Recipient]
        /// At most `candidatesShown`, the most people covered first.
        public let candidates: [Candidate]
        public let warnings: [Candidate]
        /// Entries in its sends' recipients that don't read as an address: never dropped unsaid, and never done while any is.
        public let unreadable: Int
        /// Its sends the log shows naming no recipient at all (no recipients field): who they went to is unknown, so never done.
        public let unnamed: Int
        /// People here still to warn whose Gmail log the pull doesn't show from this email on (no receipt of anything since it
        /// went): what to pull again. None while the directory isn't read: a group can't be told from a person then, and GAM
        /// refuses a whole read naming one (final review 2026-10-25).
        public let unread: [String]

        /// Who to warn about it: everyone it was addressed to or received by. Over-warning is safe and under-warning the harm
        /// (review 2026-10-24), so only an address that bounced and isn't a person's mailbox here (outside, or no one's) is left
        /// out: a warning to it would bounce too. A quarantine, a rejection, or a person here whose copy bounced stays on.
        public var reached: [Recipient] { recipients.filter { !($0.outcome == .bounced && !$0.mailbox) } }
        /// Reached and not shown warned by a warning that counts.
        public var toWarn: [Recipient] { recipients.filter(\.toWarn) }

        /// Every candidate is offered (a warning can be split over several emails), the most people first, at most this many.
        public static let candidatesShown = 100
        public static let columns = ["address", "where", "reached", "when", "warned", "to warn"]

        /// The outcome in words, as the screen and the CSV say it.
        public static func words(_ recipient: Recipient) -> String {
            switch recipient.outcome {
            case .received: "received"
            case .bounced: "bounced"
            case .blocked: "quarantined or rejected"
            case .sent: recipient.inside ? "sent, no receipt in the logs read" : "sent, no bounce in the logs read"
            case .notAMailbox: "no one's mailbox here: a group or an address no account has"
            }
        }

        /// The list as a CSV's rows, under `columns`.
        public var rows: [[String]] {
            recipients.map { recipient in
                [recipient.address, recipient.inside ? "inside" : "outside", Self.words(recipient),
                 recipient.at.map { $0.formatted(.iso8601) } ?? "", recipient.warned.map { $0 ? "yes" : "not shown" } ?? "",
                 recipient.toWarn ? "yes" : ""]
            }
        }
    }

    /// Every finding, most serious first; where each account the attacker touched stands, with its timeline; what's left
    /// to do, and what this app's audit log shows done; and each draft once in the order the findings point to them.
    public struct Reading: Sendable, Equatable {
        public let findings: [Finding]
        public let statuses: [Status]
        public let toDo: [Task]
        /// The emails Phishing pulled from every mailbox, or that its Find showed nobody here has, each with how, when and by
        /// whom (`Task.done`).
        public let done: [Task]
        public let events: Int
        /// Who each email the attacker sent reached, in the to-do list's order of them.
        public let reaches: [Reach]

        public var drafts: [Draft] {
            var seen: Set<Draft> = []
            return findings.flatMap(\.drafts).filter { seen.insert($0).inserted }
        }

        /// The Message-IDs of every email still to pull, each once, in the to-do list's order: never one done.
        public var emailsToPull: [String] {
            var seen: Set<String> = []
            return toDo.flatMap(\.drafts).compactMap { draft in
                if case .pullEmail(let id, _) = draft, seen.insert(id).inserted { id } else { nil }
            }
        }
    }

    /// An address more accounts than this signed in from is likely shared (an office, a VPN): its sign-ins draft no fix.
    public static let shared = 10

    /// Google's own word that a sign-in was someone else's: a suspicious-sign-in event, an account disabled as hijacked,
    /// or a sign-in marked suspicious, unless that sign-in was proved with a passkey or security key (the person's own
    /// device), or re-proves a session from an address the account signs in from unmarked. Real logs
    /// mark both: a passkey re-sign-in through a privacy relay's address, and a person re-proving themselves at
    /// their usual address after Google disabled their account; an attacker's sign-in is commonly a password one. Not every flag
    /// either: a person's own failed challenge, or a denied cookie, is flagged too. A sign-in the operator marked as the
    /// person's own (`Context.theirs`) never is. A passkey proves the person only when the account added none in these logs
    /// before that sign-in (`passkeysAdded`): an attacker who had the account can enroll their own (review 2026-10-22).
    static func marksAttacker(_ event: Event, ordinary: Set<String> = [], theirs: Set<String> = [],
                              passkeysAdded: [String: Date] = [:]) -> Bool {
        guard event.log == "login", !theirs.contains(key(account: event.who, address: event.ip)) else { return false }
        if event.event.hasPrefix("suspicious_") || event.event == "gov_attack_warning" || event.event == "account_disabled_hijacked" {
            return true
        }
        guard isMarked(event) else { return false }
        let methods = (event.parameters["login_challenge_method"] ?? "").split(separator: " ")
        let added = passkeysAdded[event.who.lowercased()].map { added in event.time.map { added <= $0 } ?? true } ?? false
        if !added, methods.contains(where: { ["passkey", "security_key", "security_key_otp"].contains($0) }) { return false }
        return !(event.parameters["login_type"] == "reauth" && ordinary.contains(key(account: event.who, address: event.ip)))
    }

    /// Google marked this one sign-in suspicious.
    static func isMarked(_ event: Event) -> Bool { ["true", "1"].contains(event.parameters["is_suspicious"]?.lowercased() ?? "") }

    /// A Gmail event that is a message sent. Every Gmail event is `delivery`, and its `event_info.mail_event_type` says what
    /// happened (Google's "Gmail Activity Events"): 1 sent, 35 the send begun. The rest (31 viewed, 7 opened, 29 a draft, 13
    /// trashed…) aren't a send: from the attacker's address they are the person's own mail the attacker read, and pulling it
    /// would take real mail from everyone who has it (in use it listed every message an attacker read).
    static func isSent(_ event: Event) -> Bool {
        Int(event.parameters["event_info.mail_event_type"] ?? "").map(sentTypes.contains) ?? false
    }

    static let sentTypes: Set = [1, 35]

    /// The findings in `events`. Suspect addresses are those of a sign-in Google called suspicious (`marksAttacker`), and
    /// the one the operator pulled by; never an address only because many accounts used it, which an office's does.
    public static func read(_ events: [Event], context: Context = Context()) -> Reading {
        var found: [Pending] = []
        // Each account's addresses it signed in from without Google's mark: a re-sign-in from one is the person's.
        let ordinary = Set(events.filter { $0.log == "login" && $0.event == "login_success" && !$0.ip.isEmpty && !isMarked($0) }
            .map { key(account: $0.who, address: $0.ip) })
        // Each account's first passkey added in these logs, from any address.
        var passkeysAdded: [String: Date] = [:]
        for event in events where event.log == "login" && event.event == "passkey_enrolled" {
            guard let at = event.time else { continue }
            passkeysAdded[event.who.lowercased()] = min(at, passkeysAdded[event.who.lowercased()] ?? at)
        }
        var suspects: [String] = [], markedBy: [String: [String]] = [:]
        for event in events where !event.ip.isEmpty {
            let marks = marksAttacker(event, ordinary: ordinary, theirs: context.theirs, passkeysAdded: passkeysAdded)
            guard marks || event.ip == context.pulledBy else { continue }
            if !suspects.contains(event.ip) { suspects.append(event.ip) }
            // Only an account's own sign-in Google marked can be the person's: never its warning that it blocked one.
            if marks, isMarked(event), isAccount(event.who) { markedBy[event.ip, default: []].append(event.who) }
        }
        if !context.pulledBy.isEmpty, !suspects.contains(context.pulledBy) { suspects.append(context.pulledBy) }

        // Each suspect address and the accounts it touched; one many accounts signed in from (not the operator's) is set
        // aside as likely shared: securing everyone behind an office's address would lock the office out.
        var acting: Set<String> = []
        let suspected = Set(suspects)
        let fromSuspect = Dictionary(grouping: events.filter { suspected.contains($0.ip) }, by: \.ip)
        for address in suspects {
            let here = fromSuspect[address] ?? []
            let accounts = unique(here.map(\.who).filter(isAccount))
            let signedIn = unique(here.filter { $0.log == "login" && $0.event == "login_success" }.map(\.who).filter(isAccount))
            if address != context.pulledBy, signedIn.count > shared {
                found.append(Pending(.sharedAddress, "\(signedIn.count) accounts signed in from \(address), where Google saw a suspicious "
                                     + "sign-in: it may be "
                                     + "shared (an office or a VPN). Check it before securing anyone.", signedIn, [address], here.count, [],
                                     todo: [(.checkShared, "Check whether \(address) is your office or a VPN before securing anyone behind it.", [])]))
                continue
            }
            acting.insert(address)
            let why = address == context.pulledBy ? "You pulled the logs by \(address)" : "Google called a sign-in from \(address) suspicious"
            found.append(Pending(.suspectAddress, why + (accounts.isEmpty ? "." : ": it touched " + list(accounts) + "."), accounts, [address],
                                 here.count, [], markable: address == context.pulledBy ? [] : unique(markedBy[address] ?? [])))
        }

        // A sign-in (to Google, or to another app through it), an app grant or an account change from a suspect address:
        // the attacker had that account.
        let entered = events.filter { acting.contains($0.ip) && isAccount($0.who)
            && ((["login", "saml"].contains($0.log) && $0.event == "login_success") || ($0.log == "token" && $0.event == "authorize")
                || $0.log == "useraccounts") }
        for (account, theirs) in grouped(entered) {
            let what = unique(theirs.map {
                switch $0.log {
                case "login": "signed in to Google"
                case "saml": "reached another app through Google (SAML)"
                case "token": "granted an app access"
                default: "changed account settings"
                }
            })
            found.append(Pending(.signedInFromSuspect, "\(account) \(list(what)) from \(list(unique(theirs.map(\.ip)))).", [account],
                                 unique(theirs.map(\.ip)), theirs.count, [.secureAccount(account)]))
        }

        // Each account's own events and the admin's done to it: what every rule about one account reads.
        let about = Accounts(events)

        // A device registered to an account in the minutes around its sign-in from a suspect address: the attacker's own
        // computer joined to the account as it signed in. The Devices log has no address, so only the account and the time
        // tie the two.
        // The sign-in nearest the registration, from any address, decides: a person's own new computer beside their own
        // sign-in isn't the attacker's, however near a suspect one; an even tie says nothing.
        let signIns = Dictionary(grouping: events.filter { ["login", "saml"].contains($0.log) && $0.event == "login_success"
            && $0.time != nil && isAccount($0.who) }) { $0.who.lowercased() }
        var joined: [(device: Event, signIn: Event, gap: TimeInterval)] = []
        for device in events where device.log == "mobile" && device.event == "DEVICE_REGISTER_UNREGISTER_EVENT"
            && device.parameters["ACCOUNT_STATE"] != "UNREGISTERED" && isAccount(device.who) {
            guard let at = device.time else { continue }
            // How long after each of the account's sign-ins it registered (negative: before), in the window.
            let near = (signIns[device.who.lowercased()] ?? [])
                .map { (signIn: $0, after: at.timeIntervalSince($0.time ?? at)) }
                .filter { deviceWindow.contains($0.after) }
            guard let nearest = near.min(by: { abs($0.after) < abs($1.after) }), acting.contains(nearest.signIn.ip),
                  !near.contains(where: { abs($0.after) == abs(nearest.after) && !acting.contains($0.signIn.ip) })
            else { continue }
            joined.append((device, nearest.signIn, abs(nearest.after)))
        }
        for (account, theirs) in grouped(joined.map(\.device)) {
            let mine = joined.filter { $0.device.who.lowercased() == account.lowercased() }
            let ips = unique(mine.map(\.signIn.ip)), gap = mine.map(\.gap).max() ?? 0
            let when = gap <= 60 ? "within a minute of" : "within \(Int((gap / 60).rounded(.up))) minutes of"
            let devices = list(unique(theirs.map(deviceWords)))
            // Still there unless the latest word on the device says it left (`deviceWord`). Registered or approved again is
            // there again, from any address; gone never counts from a suspect's (security reviews 2026-10-22).
            let left = theirs.filter { device in
                let ids = Set([device.parameters["DEVICE_ID"], device.parameters["RESOURCE_ID"]].compactMap { $0 }.filter { !$0.isEmpty })
                guard !ids.isEmpty, let at = device.time else { return true }
                let words = about[account].filter { ($0.time ?? .distantPast) > at }
                    .compactMap { event in Self.deviceWord(event, on: ids, of: account).map { (event, there: $0) } }
                    .filter { $0.there || !acting.contains($0.0.ip) }
                return words.max { ($0.0.time ?? .distantPast) < ($1.0.time ?? .distantPast) }?.there ?? true
            }
            found.append(Pending(.deviceAtSuspectSignIn, devices.prefix(1).uppercased() + devices.dropFirst() + " joined \(account)'s "
                                 + "account \(when) its sign-in from \(list(ips)): likely the attacker's own. Check Account lists it, "
                                 + "to block or take the account off.", [account], ips, theirs.count,
                                 [.secureAccount(account)],
                                 todo: left.map { device in
                                    (.deleteDevice, "Block or take \(account) off \(deviceWords(device)) that joined at the attacker's sign-in: "
                                     + "Do It Here, or the Admin console's Devices.",
                                     [.undo(account: account, pick: .computer(resourceID: device.parameters["RESOURCE_ID"] ?? "", registeredAt: device.time))])
                                 }))
        }

        // A failed sign-in from a suspect address: someone had that account's password, likely from the fake page.
        let tried = events.filter { acting.contains($0.ip) && isAccount($0.who) && $0.log == "login" && $0.event == "login_failure" }
        let inside = Set(entered.map { $0.who.lowercased() })
        for (account, theirs) in grouped(tried) where !inside.contains(account.lowercased()) {
            found.append(Pending(.failedFromSuspect, "Someone tried \(account)'s password from \(list(unique(theirs.map(\.ip)))): they may "
                                 + "have typed it into the fake page.", [account], unique(theirs.map(\.ip)), theirs.count,
                                 [.secureAccount(account)]))
        }

        // Every account the attacker touched: signed in to, tried the password of, or warned of by Google, from a suspect
        // address, or whose password Chrome saw typed on a phishing site. Each one's status and timeline, and its lock if
        // it's still to do. Not a Gmail row's account: whose mailbox that is isn't certain from the row alone.
        let touched = events.filter { acting.contains($0.ip) && isAccount($0.who) && ["login", "saml", "token", "useraccounts"].contains($0.log) }
            .sorted { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
        var phishedAt: [String: Date] = [:]
        for event in events where event.log == "chrome" && event.event == "PASSWORD_REUSE" && event.parameters["EVENT_REASON"] == "PASSWORD_REUSED_PHISHING_URL" {
            let account = isAccount(event.parameters["TRIGGER_USER"] ?? "") ? event.parameters["TRIGGER_USER"] ?? "" : event.who
            guard isAccount(account), let at = event.time else { continue }
            phishedAt[account.lowercased()] = min(at, phishedAt[account.lowercased()] ?? at)
        }
        let accounts = unique(touched.map(\.who) + phishedAt.keys.sorted())
        let own = accounts.map { about[$0] }
        func statuses(held: [String: ClosedRange<Date>]) -> [Status] {
            zip(accounts, own).map { account, own in
                status(account, own, acting: acting, context: context, joined: joined.map(\.device), phishedAt: phishedAt[account.lowercased()],
                       held: held)
            }
        }
        // An account the attacker got into, from then until its own lock: what it did as an admin meanwhile is no lock
        // (security review 2026-10-22). Read once to know those, then again without them.
        var held: [String: ClosedRange<Date>] = [:]
        for status in statuses(held: [:]) where status.attackerGotIn {
            if let from = status.attackedAt { held[status.account.lowercased()] = from...max(from, status.lockedAt ?? .distantFuture) }
        }
        let statuses = statuses(held: held)
        var statusTasks: [(Task.Kind, String, [String], [Draft], Shown?)] = []
        for (status, own) in zip(statuses, own) {
            let account = status.account
            // The account's events from the attacker's addresses: what "Show the Events" shows for its lock.
            let theirs = Shown(accounts: [account], addresses: unique(own.filter {
                $0.who.lowercased() == account.lowercased() && suspects.contains($0.ip)
            }.map(\.ip)))
            switch status.state {
            case .stillIn:
                statusTasks.append((.secureAgain, "Secure \(account) again: the attacker signed in from \(status.backInFrom) after the lock. Look "
                                    + "for a passkey or another way back.", [account], [.secureAccount(account)], theirs))
            case .partlyLocked:
                statusTasks.append((.finishLock, status.reset != nil
                                    ? "Sign \(account) out of every session: the password was reset, but no sign-out was seen."
                                    : "Reset \(account)'s password: they were signed out, but the password the attacker may have wasn't changed.",
                                    [account], [.secureAccount(account)], theirs))
            case .notLocked:
                statusTasks.append((.secure, "Secure \(account): " + (status.attackerGotIn ? "the attacker got in" : "the attacker's address tried their password")
                                    + (status.unseen.map { ", and no lock could be seen (\($0))." }
                                        ?? (status.earlierLockAt != nil ? ", and no lock is seen after it; one came earlier, so pull from before "
                                            + "the attack began to tell." : ", and no lock has been seen since.")),
                                    [account], [.secureAccount(account)], theirs))
            case .locked:
                break
            }
            if !status.newAddresses.isEmpty {
                statusTasks.append((.confirmAddress, "Ask \(account) whether \(list(status.newAddresses)) \(status.newAddresses.count == 1 ? "is" : "are") "
                                    + "theirs: a sign-in after the lock, from an address these logs didn't show before the attack.", [account], [],
                                    Shown(accounts: [account], addresses: status.newAddresses)))
            }
            // The account's contacts printed between the attacker's first event and the lock: who the phish goes to next.
            // The Contacts log names no address, so the time ties it to the attack.
            let printed = own.filter { event in
                event.log == "contacts" && event.event == "print_contacts" && event.who.lowercased() == account.lowercased()
                    && (event.time.map { at in
                        (status.attackedAt.map { at >= $0 } ?? false) && (status.state == .stillIn || (status.lockedAt.map { at <= $0 } ?? true))
                    } ?? false)
            }
            if !printed.isEmpty {
                let count = printed.compactMap { Int($0.parameters["CONTACTS_COUNT"] ?? "") }.max()
                found.append(Pending(.contactsTaken, "\(account)'s contacts" + (count.map { " (\($0.formatted(.number.locale(Locale(identifier: "en_US")))))" } ?? "")
                                     + " were printed " + (printed.count == 1 ? "" : "\(printed.count) times ") + "while the attacker had the account: "
                                     + "the people on that list may get the phish next. Warn them not to act on it.", [account], [], printed.count, [],
                                     todo: [(.warnContacts, "Warn the people in \(account)'s contacts not to act on email from \(account) sent while the "
                                             + "attacker had it.", [])]))
            }
        }

        // What a lock leaves in place, done from a suspect address: a way back in (a passkey, a 2-Step Verification phone or
        // app) or a way to take the account back (the recovery email or phone). A reset and a sign-out undo none of them.
        let leftovers = events.filter { acting.contains($0.ip) && isAccount($0.who) && Self.leftovers[$0.event] != nil
            && ["login", "useraccounts"].contains($0.log) }
        for (account, theirs) in grouped(leftovers) {
            let things = unique(theirs.compactMap { event in
                event.event == "blocked_sender"
                    ? Self.leftovers[event.event].map { $0 + (event.parameters["affected_email_address"].map { " (\($0))" } ?? "") }
                    : Self.leftovers[event.event]
            })
            let recovery = theirs.contains { $0.event.hasPrefix("recovery_") }
            let blocked = theirs.contains { $0.event == "blocked_sender" }
            let others = theirs.contains { !$0.event.hasPrefix("recovery_") && $0.event != "blocked_sender" }
            // Each recovery detail the attacker changed stays to clear unless an admin, not from a suspect address, removed that
            // same detail after the change (security review 2026-10-22). The question no admin step removes.
            func stillSet(_ edit: String, removedBy removal: String) -> Bool {
                guard let changed = theirs.filter({ $0.event == edit }).compactMap(\.time).max() else { return false }
                return !about[account].contains { $0.log == "admin" && $0.event == removal && $0.parameters["USER_EMAIL"]?.lowercased() == account.lowercased()
                    && !acting.contains($0.ip) && ($0.time ?? .distantPast) > changed }
            }
            let cleared = !stillSet("recovery_email_edit", removedBy: "REMOVE_RECOVERY_EMAIL")
                && !stillSet("recovery_phone_edit", removedBy: "REMOVE_RECOVERY_PHONE")
            let question = theirs.contains { $0.event == "recovery_secret_qa_edit" }
            var todo: [(Task.Kind, String, [Draft])] = []
            if others {
                todo.append((.removeAdded, "Remove what the attacker added to \(account): "
                             + list(unique(theirs.filter { !$0.event.hasPrefix("recovery_") && $0.event != "blocked_sender" }.compactMap { Self.leftovers[$0.event] }))
                             + ", on the Admin console's page for them (Security), or with them in their Google Account.", []))
            }
            if question {
                todo.append((.clearRecovery, "Have \(account) set a new recovery question in their Google Account: the attacker changed it, "
                             + "and no admin step resets it.", []))
            }
            if theirs.contains(where: { ["recovery_email_edit", "recovery_phone_edit"].contains($0.event) }), !cleared {
                todo.append((.clearRecovery, "Clear \(account)'s recovery email and phone: Check Account's “Clear recovery email & phone” step.",
                             [.undo(account: account, pick: .clearRecovery)]))
            }
            if blocked {
                let senders = unique(theirs.filter { $0.event == "blocked_sender" }.compactMap { $0.parameters["affected_email_address"] })
                todo.append((.unblockSender, "Have \(account) unblock \(senders.isEmpty ? "the blocked sender" : list(senders)) in Gmail: Settings, "
                             + "Filters and Blocked Addresses.", []))
            }
            found.append(Pending(.leftInPlace, "From \(list(unique(theirs.map(\.ip)))), \(account)'s account got \(list(things)): a lock "
                                 + "doesn't undo \(things.count == 1 ? "it" : "them")."
                                 + (others ? " Remove what isn't theirs on the Admin console's page for them (Security), or with them in "
                                    + "their Google Account." : "")
                                 + (recovery ? " Check Account shows the recovery details, and its “Clear recovery email & phone” step "
                                    + "removes them." : "")
                                 + (blocked ? " A blocked sender's mail goes to Spam, and blocking the bounce address hides a mass send: "
                                    + "unblock it in their Gmail settings (Filters and Blocked Addresses)." : ""),
                                 [account], unique(theirs.map(\.ip)), theirs.count, recovery ? [.secureAccount(account)] : [], todo: todo))
        }

        // Another app reached through Google from a suspect address: that app keeps its own session, which Google's
        // sign-out doesn't end.
        let reached = events.filter { $0.log == "saml" && $0.event == "login_success" && acting.contains($0.ip) && isAccount($0.who) }
        for (account, theirs) in grouped(reached) {
            let apps = unique(theirs.compactMap { $0.parameters["application_name"] }.filter { !$0.isEmpty })
            let named = apps.isEmpty ? "another app" : list(apps)
            found.append(Pending(.otherAppSession, "\(account) signed in to \(named) through Google from \(list(unique(theirs.map(\.ip)))): "
                                 + "Google's sign-out doesn't end \(apps.count > 1 ? "those apps' sessions" : "that app's session"). "
                                 + "Sign them out there too.", [account], unique(theirs.map(\.ip)), theirs.count, [],
                                 todo: [(.signOutApp, "Sign \(account) out of \(named) too: Google's sign-out doesn't end that session.", [])]))
        }

        // The account's data exported with Google Takeout from a suspect address: it may be in the attacker's hands.
        let exported = events.filter { $0.log == "takeout" && acting.contains($0.ip) && isAccount($0.who)
            && ["STARTED_USER_TAKEOUT", "DOWNLOADED_USER_TAKEOUT", "SCHEDULED_USER_TAKEOUT"].contains($0.event) }
        for (account, theirs) in grouped(exported) {
            let products = unique(theirs.compactMap { $0.parameters["PRODUCTS_REQUESTED"] }.filter { !$0.isEmpty })
            found.append(Pending(.exportedFromSuspect, "\(account)'s data was exported with Google Takeout from "
                                 + list(unique(theirs.map(\.ip))) + (products.isEmpty ? "" : " (\(list(products)))")
                                 + ": treat it as in the attacker's hands.", [account], unique(theirs.map(\.ip)), theirs.count,
                                 [.secureAccount(account)],
                                 todo: [(.treatAsTaken, "Treat \(account)'s exported data as the attacker's, and decide who must be told.", [])]))
        }

        // An app acting for an account from a suspect address: the attacker's app, or theirs through the person's grant.
        let throughApp = events.filter { acting.contains($0.ip) && !$0.app.isEmpty && isAccount($0.who) }
        for (account, theirs) in grouped(throughApp) {
            let apps = unique(theirs.map(\.app)), logs = unique(theirs.map { logName($0.log) })
            found.append(Pending(.appFromSuspect, "\(list(apps)) acted for \(account) from \(list(unique(theirs.map(\.ip)))) (\(list(logs))).",
                                 [account], unique(theirs.map(\.ip)), theirs.count, [.secureAccount(account)],
                                 todo: [(.look, "See what \(list(apps)) did for \(account) from the attacker's address.", [])],
                                 shows: Shown(accounts: [account], addresses: unique(theirs.map(\.ip)), apps: apps)))
        }

        // Anything else a suspect address did as an account: Gemini asked to search a mailbox, Drive, Contacts, Calendar…
        // Not the logs other rules read, nor access evaluation, whose token checks come with every sign-in.
        let covered: Set = ["login", "token", "saml", "useraccounts", "gmail", "chat", "takeout", "chrome", "accessevaluation"]
        let other = events.filter { acting.contains($0.ip) && $0.app.isEmpty && isAccount($0.who) && !covered.contains($0.log) }
        for (account, theirs) in grouped(other) {
            let logs = unique(theirs.map { logName($0.log) })
            found.append(Pending(.actedFromSuspect, "\(account) used \(list(logs)) from \(list(unique(theirs.map(\.ip)))): see what was "
                                 + "searched, opened or changed.", [account], unique(theirs.map(\.ip)), theirs.count, [.secureAccount(account)],
                                 todo: [(.look, "See what was searched, opened or changed in \(account)'s \(list(logs)) from the attacker's address.", [])],
                                 shows: Shown(accounts: [account], addresses: unique(theirs.map(\.ip)), logs: unique(theirs.map(\.log)))))
        }

        // AI agents acting for people: said, by agent, and called out when the account is one the attacker had.
        var agents: [String: [Event]] = [:], agentOrder: [String] = []
        for event in events where !event.agent.isEmpty && isAccount(event.who) {
            if agents[event.agent] == nil { agentOrder.append(event.agent) }
            agents[event.agent, default: []].append(event)
        }
        for agent in agentOrder {
            let theirs = agents[agent] ?? [], accounts = unique(theirs.map(\.who))
            let attacked = accounts.filter { inside.contains($0.lowercased()) }
            found.append(Pending(.agentActed, "\(agent.prefix(1).uppercased() + agent.dropFirst()) acted for \(list(accounts)) "
                                 + "(\(theirs.count) event\(theirs.count == 1 ? "" : "s"): \(list(unique(theirs.map { logName($0.log) }))))"
                                 + (attacked.isEmpty ? "." : ", including \(list(attacked)), whom the attacker had: check what it did."),
                                 accounts, unique(theirs.map(\.ip).filter { !$0.isEmpty }), theirs.count, [],
                                 todo: attacked.isEmpty ? [] : [(.look, "See what \(agent) did for \(list(attacked)).", [])],
                                 shows: Shown(accounts: attacked, agent: agent)))
        }

        // Chat messages from a suspect address: phishing can go out in Chat too.
        let chatted = events.filter { $0.log == "chat" && $0.event == "message_posted" && acting.contains($0.ip) && isAccount($0.who) }
        for (account, theirs) in grouped(chatted) {
            found.append(Pending(.chatFromSuspect, "\(account) posted \(theirs.count) Chat message\(theirs.count == 1 ? "" : "s") from "
                                 + list(unique(theirs.map(\.ip))) + ": ask who got them not to open their links.", [account],
                                 unique(theirs.map(\.ip)), theirs.count, [],
                                 todo: [(.warnChat, "Ask who got \(account)'s Chat messages not to open their links.", [])]))
        }

        // Chrome's own warnings, by the account whose password it was (the trigger's), else the profile's.
        func chrome(_ name: String, _ keep: (Event) -> Bool = { _ in true }) -> [(String, [Event])] {
            grouped(events.filter { $0.log == "chrome" && $0.event == name && keep($0) }.map { event in
                let trigger = event.parameters["TRIGGER_USER"] ?? ""
                return isAccount(trigger) ? Event(log: event.log, time: event.time, who: trigger, event: event.event, ip: event.ip,
                                                  flagged: event.flagged, parameters: event.parameters) : event
            }.filter { isAccount($0.who) })
        }
        func sites(_ theirs: [Event]) -> String {
            let urls = unique(theirs.compactMap { $0.parameters["URL"] }.filter { !$0.isEmpty })
            return urls.isEmpty ? "a site" : list(urls)
        }
        for (account, theirs) in chrome("PASSWORD_REUSE", { $0.parameters["EVENT_REASON"] == "PASSWORD_REUSED_PHISHING_URL" }) {
            found.append(Pending(.passwordOnPhishingSite, "\(account) typed their password on \(sites(theirs)), a phishing site (Chrome).",
                                 [account], [], theirs.count, [.secureAccount(account)]))
        }
        for (account, theirs) in chrome("PASSWORD_REUSE", { $0.parameters["EVENT_REASON"] != "PASSWORD_REUSED_PHISHING_URL" }) {
            found.append(Pending(.passwordOnOtherSite, "\(account) used their password on \(sites(theirs)) (Chrome): if that site is "
                                 + "breached, so is this account.", [account], [], theirs.count, [],
                                 todo: [(.checkPassword, "Have \(account) change that password wherever else they use it.", [])]))
        }
        for (account, theirs) in chrome("PASSWORD_BREACH") {
            found.append(Pending(.breachedPassword, "Chrome found a password of \(account)'s in a data breach, on \(sites(theirs)).",
                                 [account], [], theirs.count, [],
                                 todo: [(.checkPassword, "Have \(account) change the password Chrome found in a breach.", [])]))
        }
        for (account, theirs) in chrome("UNSAFE_SITE_VISIT", { $0.parameters["EVENT_RESULT"] == "BYPASSED" }) {
            found.append(Pending(.pastPhishingWarning, "\(account) went past Chrome's warning to \(sites(theirs)): check whether they "
                                 + "typed a password there.", [account], [], theirs.count, [],
                                 todo: [(.checkPassword, "Ask \(account) whether they typed a password at \(sites(theirs)).", [])]))
        }

        // Mail sent from a suspect address: the message to pull from everyone. Only a send (`isSent`): what the attacker read,
        // drafted or trashed there is the person's own mail. Its sender is secured by their sign-in from that address, not
        // here: whose mailbox a Gmail row is isn't certain from the row alone.
        // One Phishing has trashed from every mailbox (its audit log, `Pulled`), or that its Find showed nobody here has
        // (`NobodyHas`), is done: listed with how, when and by whom, and drafted nowhere again. The latest of the two decides:
        // a run after a check found copies again. A run that left any is still to do, saying what it left.
        var messages: [String: [Event]] = [:], order: [String] = []
        for event in events where event.log == "gmail" && acting.contains(event.ip) && isSent(event) {
            guard let id = event.parameters["message_info.rfc2822_message_id"], !id.isEmpty else { continue }
            if messages[id] == nil { order.append(id) }
            messages[id, default: []].append(event)
        }
        var runs: [String: Pulled] = [:]
        for run in context.pulled {
            let id = bareMessageID(run.messageID)
            if runs[id].map({ $0.at < run.at }) ?? true { runs[id] = run }
        }
        var checks: [String: NobodyHas] = [:]
        for check in context.nobodyHas {
            let id = bareMessageID(check.messageID)
            if checks[id].map({ $0.at < check.at }) ?? true { checks[id] = check }
        }
        var pulledDone: Set<String> = [], doneTasks: [(Task.Kind, String, [String], Done)] = []
        for id in order {
            let theirs = messages[id] ?? []
            let subject = theirs.compactMap { $0.parameters["message_info.subject"] }.first { !$0.isEmpty } ?? ""
            let named = "“\(subject.isEmpty ? "(no subject)" : subject)” (\(id))"
            let accounts = unique(theirs.map(\.who).filter(isAccount)), run = runs[bareMessageID(id)], check = checks[bareMessageID(id)]
            var todo: [(Task.Kind, String, [Draft])] = []
            if let check, run.map({ $0.at <= check.at }) ?? true {
                pulledDone.insert(id)
                doneTasks.append((.pullEmail, "Nobody here has \(named): Phishing's Find searched every mailbox and its Spam.", accounts,
                                  Done(how: .nobodyHasIt, at: check.at, by: check.by)))
            } else if let run, run.isDone {
                pulledDone.insert(id)
                doneTasks.append((.pullEmail, "Pulled \(named): trashed from " + (run.mailboxes == 1 ? "the one mailbox" : "the \(run.mailboxes) mailboxes")
                                  + " that had it, every mailbox searched first.", accounts, Done(how: .trashed, at: run.at, by: run.by)))
            } else {
                todo = [(.pullEmail, "Pull \(named) from every mailbox: it went out from the attacker's address." + (run.map { " " + $0.left } ?? ""),
                         [.pullEmail(messageID: id, subject: subject)])]
            }
            found.append(Pending(.mailFromSuspect, "\(named) was sent from " + list(unique(theirs.map(\.ip))) + ".", accounts,
                                 unique(theirs.map(\.ip)), theirs.count, [.pullEmail(messageID: id, subject: subject)], todo: todo))
        }
        // Who each reached, and whether the warnings picked reached them all: done only on the log's own word for each of
        // them, with the directory read and nothing unreadable; what the logs read can't show is to pull again.
        let reaches = reaches(order, in: events, attacker: acting, context: context)
        var warnTasks: [(Task.Kind, String, [String], [Draft], Shown?, [String])] = []
        for reach in reaches {
            let named = "“\(reach.subject.isEmpty ? "(no subject)" : reach.subject)” (\(reach.messageID))"
            // Show the Events: the sender's Gmail events, where its sends and bounces are.
            let shows = reach.senders.isEmpty ? nil : Shown(accounts: reach.senders, logs: ["gmail"])
            if !reach.unread.isEmpty {
                let shown = Array(reach.unread.prefix(20))
                warnTasks.append((.pullAgain, "Pull the Gmail log again for \(list(shown))"
                                  + (reach.unread.count > shown.count ? " (the first 20 of \(reach.unread.count))" : "")
                                  + ": whether they got a warning about \(named) is in their own Gmail log, which the pull doesn't have.",
                                  shown, [], nil, ["gmail"]))
            }
            for warning in reach.warnings where warning.problem != nil {
                warnTasks.append((.warnRecipients, "The warning picked for \(named), \(warning.messageID), doesn't count: \(warning.problem!).",
                                  reach.senders, [], shows, []))
            }
            if reach.unnamed > 0 {
                warnTasks.append((.warnRecipients, "The log shows \(reach.unnamed == 1 ? "a send" : "\(reach.unnamed) sends") of \(named) naming no "
                                  + "recipient: who it went to isn't in the logs read. Check it in the Admin console's Gmail log events, then warn them.",
                                  reach.senders, [], shows, []))
            }
            if reach.unreadable > 0 {
                warnTasks.append((.warnRecipients, "\(reach.unreadable) of the recipients the log names for \(named) don't read as an address: "
                                  + "check them in the Admin console's Gmail log events, then warn them.", reach.senders, [], nil, []))
            }
            guard !reach.reached.isEmpty else { continue }
            // The warnings that count and reached someone it reached, by the log's word: what done names.
            let warned = Set(reach.reached.filter { $0.warned == true }.map(\.address))
            let by = reach.warnings.filter { $0.problem == nil && !$0.warned.isDisjoint(with: warned) }
            if reach.toWarn.isEmpty, reach.unreadable == 0, reach.unnamed == 0, context.people != nil, let latest = by.filter({ $0.at != nil }).max(by: { $0.at! < $1.at! }) {
                // A group or an address no account has counts on the warning's send, as outside does: who got either through a
                // group is in its members' own Gmail logs, which a pull may not have (final review 2026-10-25), so it's said.
                let groups = reach.reached.filter { $0.inside && !$0.mailbox }.count   // quarantined or rejected too (final review)
                doneTasks.append((.warnRecipients, "Warned everyone \(named) reached: \(reach.reached.count) "
                                  + (reach.reached.count == 1 ? "person" : "people")
                                  + (groups == 0 ? "" : " (\(groups == 1 ? "one" : "\(groups)") of them a group or an address no account has, "
                                     + "counted on the warning's send)")
                                  + ", by \(list(by.map { "\($0.sender)'s “\($0.subject)”" })).",
                                  reach.senders, Done(how: .warned, at: latest.at!, by: latest.sender)))
            } else {
                if context.people == nil {
                    warnTasks.append((.warnRecipients, "Read the directory (open Users) to finish Who \(named) reached: until then a group "
                                      + "can't be told from a person, nor whose Gmail log to pull.", reach.senders, [], shows, []))
                }
                if !reach.toWarn.isEmpty {
                    let count = reach.toWarn.count, outside = reach.toWarn.filter { !$0.inside }.count
                    warnTasks.append((.warnRecipients, "Warn the \(count) \(count == 1 ? "person" : "people") \(named) reached"
                                      + (by.isEmpty ? "" : " that no warning picked is shown reaching")
                                      + (outside > 0 ? ", \(outside) of them outside" : "") + ": pick the warning sent to them under Who it "
                                      + "reached (its sender's Gmail log in the pull), or send one.", reach.senders, [], shows, []))
                }
            }
        }

        let ranked = found.enumerated().sorted { a, b in
            (Finding.Kind.allCases.firstIndex(of: a.element.kind)!, a.offset) < (Finding.Kind.allCases.firstIndex(of: b.element.kind)!, b.offset)
        }.map(\.element)
        // A finding about an account already locked drafts no lock again, nor one about an email already pulled: what's
        // left is in the to-do list.
        let locked = Set(statuses.filter { $0.state == .locked }.map { $0.account.lowercased() })
        func stillToDraft(_ draft: Draft) -> Bool {
            if case .secureAccount(let account) = draft { return !locked.contains(account.lowercased()) }
            if case .pullEmail(let id, _) = draft { return !pulledDone.contains(id) }
            return true
        }

        // Logs read for every account that stop short of the attack: pull them again for just these accounts.
        var coverage: [(Task.Kind, String, [String], [Draft], Shown?)] = []
        var pullsAgain: [String] = []
        if let first = statuses.compactMap(\.attackedAt).min() {
            let short = context.capped.filter { $0.value > first }.map(\.key).sorted()
            let accounts = statuses.map(\.account)
            if !short.isEmpty {
                coverage.append((.pullAgain, "Pull the \(list(short.map(logName))) \(short.count == 1 ? "log" : "logs") again for just "
                                 + (accounts.count <= 20 ? list(accounts) : "the accounts above, 20 at a time") + ": read for every account, "
                                 + (short.count == 1 ? "it stops at its newest events and doesn't" : "they stop at their newest events and don't")
                                 + " reach back to the attack.", accounts, [], nil))
                pullsAgain = short
            }
        }
        // Most urgent first, each once.
        let todos = statusTasks.map { ($0.0, $0.1, $0.2, $0.3, $0.4, [String]()) } + coverage.map { ($0.0, $0.1, $0.2, $0.3, $0.4, pullsAgain) }
            + ranked.flatMap { item in
                item.todo.map { ($0.0, $0.1, item.accounts, $0.2, item.shows ?? Shown(accounts: item.accounts, addresses: item.addresses), [String]()) }
            } + warnTasks
        var said: Set<String> = []
        let ordered = todos.enumerated().filter { said.insert($0.element.1 + "|" + $0.element.3.map(\.title).joined()).inserted }.sorted { a, b in
            (Task.Kind.allCases.firstIndex(of: a.element.0)!, a.offset) < (Task.Kind.allCases.firstIndex(of: b.element.0)!, b.offset)
        }.map(\.element)

        return Reading(findings: ranked.enumerated().map { index, item in
            Finding(id: "F\(index + 1)", kind: item.kind, words: item.words, accounts: item.accounts, addresses: item.addresses,
                    events: item.events, drafts: item.drafts.filter(stillToDraft), markable: item.markable)
        }, statuses: statuses, toDo: ordered.enumerated().map { index, item in
            Task(id: "T\(index + 1)", kind: item.0, words: item.1, accounts: item.2, drafts: item.3,
                 shows: item.4.flatMap { $0.accounts.isEmpty ? nil : $0 }, pullsAgain: item.5, done: nil)
        }, done: doneTasks.enumerated().map { index, item in
            Task(id: "D\(index + 1)", kind: item.0, words: item.1, accounts: item.2, drafts: [], shows: nil, pullsAgain: [], done: item.3)
        }, events: events.count, reaches: reaches)
    }

    /// Who each email in `ids` (the attacker's sends, as the Gmail log names them) reached (`Reach`), and the emails an
    /// account here sent after it to the same people, from an address that isn't the attacker's (`attacker`). Two passes over
    /// the Gmail events: the first finds whose receipts the pull has and which emails matter (the attacker's, the picks, the
    /// sends here after the first of them); the second sums only those, each once, and each warning's reach is worked out
    /// once. A whole pull holds hundreds of thousands of events (failure log 2026-10-23).
    static func reaches(_ ids: [String], in events: [Event], attacker: Set<String>, context: Context) -> [Reach] {
        guard !ids.isEmpty else { return [] }
        let attackers = Set(ids.map(bareMessageID)), picks = Set(context.warnings.values.flatMap { $0 })
        func idOf(_ event: Event) -> String? {
            guard event.log == "gmail", let id = event.parameters["message_info.rfc2822_message_id"], !id.isEmpty else { return nil }
            return bareMessageID(id)
        }
        func type(_ event: Event) -> Int? { Int(event.parameters["event_info.mail_event_type"] ?? "") }
        // A person's address, alias or plus-address (`alice+tag@`) as the person; anything else as it is.
        func person(_ address: String) -> String {
            guard let people = context.people else { return address }
            if let found = people[address] { return found }
            guard let plus = address.firstIndex(of: "+"), let at = address.lastIndex(of: "@"), plus < at else { return address }
            return people[String(address[..<plus] + address[at...])] ?? address
        }
        // Each address text read once (`address`): a whole pull names the same few thousand addresses again and again. Only
        // ASCII text is kept: strings compare by canonical equivalence, so a kept "é" would answer for an "e\u{301}" and show
        // one email's address in another's bytes (final review 2026-10-25). ASCII is equivalent only to itself, and a string
        // with as many characters as bytes is ASCII (a byte beyond it is part of a scalar of two or more).
        var readings: [String: String?] = [:]
        func read(_ text: String) -> String? {
            guard text.utf8.count == text.count else { return address(text) }
            if let known = readings[text] { return known }
            let found = address(text)
            readings[text] = found
            return found
        }
        // Pass 1: each Gmail event's email and type once; when the attacker's first email went; and the people whose Gmail
        // log the pull has after it (a receipt of anything since: receipts carry no address, so a read by the attacker's
        // address has none, and one from before says nothing of the days after).
        var ided: [(id: String, type: Int?, event: Event)] = [], first = Date.distantFuture, sentHere: Set<String> = []
        var receivers: [(who: String, at: Date?)] = []
        for event in events {
            guard let id = idOf(event) else { continue }
            let kind = type(event)
            ided.append((id, kind, event))
            if kind == 2 || kind == 6 { receivers.append((event.who, event.time)) }
            if attackers.contains(id), let time = event.time { first = min(first, time) }
            // A send not from the attacker's address: mail from outside has none (`Mail.ours` decides each warning exactly).
            if kind == 1, !attacker.contains(event.ip) { sentHere.insert(id) }
        }
        // Each person's latest receipt too: whether the pull has their log from a later email on (final review 2026-10-25:
        // the first email's bound answered for every email after it).
        var receipts: Set<String> = [], latest: [String: Date] = [:]
        for receiver in receivers {
            guard let mailbox = read(receiver.who).map(person) else { continue }
            let at = receiver.at ?? first
            if at >= first { receipts.insert(mailbox) }
            latest[mailbox] = max(latest[mailbox] ?? .distantPast, at)
        }
        // Pass 2: the attacker's emails and the picks, each once; then only the emails here after the first of them that went
        // to someone those reached, each once (review 2026-10-24: every send kept made a reading of a whole pull ten times
        // slower): a send naming one of them, or one a person among them received (a send to a group names the group, not its
        // members: final review 2026-10-25).
        let named = attackers.union(picks)
        var mails = Mail.all(in: ided.filter { named.contains($0.id) }.map(\.event), person: person, reading: read)
        let reachedAll = Set(attackers.flatMap { mails[$0]?.order ?? [] })
        var candidates: Set<String> = []
        for (id, kind, event) in ided where kind == 1 && (event.time ?? first) >= first && !named.contains(id) && !candidates.contains(id)
            && !attacker.contains(event.ip) {
            if destinations(event, reading: read).addresses.contains(where: { reachedAll.contains(person($0)) }), isAccount(event.who) {
                candidates.insert(id)
            }
        }
        // Only one an account here sent can be a warning: mail from outside a person received is never summed (final review).
        for (id, kind, event) in ided where (kind == 2 || kind == 6) && (event.time ?? first) >= first && !named.contains(id)
            && !candidates.contains(id) && sentHere.contains(id) {
            if let mailbox = read(event.who).map(person), reachedAll.contains(mailbox) { candidates.insert(id) }
        }
        mails.merge(Mail.all(in: ided.filter { candidates.contains($0.id) }.map(\.event), person: person, reading: read)) { kept, _ in kept }
        // Each address's answer once: a whole pull asks for the same few thousand addresses again and again.
        var insides: [String: Bool] = [:], mailboxes: [String: Bool] = [:]
        func isInside(_ address: String) -> Bool {
            if let known = insides[address] { return known }
            let inside = receipts.contains(address) || context.people?[address] != nil
                || context.domains.contains(address.split(separator: "@").last.map { String($0) } ?? "")
            insides[address] = inside
            return inside
        }
        func isMailbox(_ address: String) -> Bool {
            if let known = mailboxes[address] { return known }
            let mailbox = isInside(address) && (context.people.map { $0[address] != nil } ?? true || receipts.contains(address))
            mailboxes[address] = mailbox
            return mailbox
        }
        // Each email here that could be a warning, and who it went to (for the offer), by address.
        var warnings: [String: Reach.Candidate] = [:], byAddress: [String: [String]] = [:]
        for (id, mail) in mails where !attackers.contains(id) {
            guard let send = mail.ours(attacker) else { continue }
            warnings[id] = Reach.Candidate(messageID: id, sender: send.who, subject: mail.subject, at: send.time, covers: 0, warned: [], problem: nil)
            for address in mail.addressed { byAddress[address, default: []].append(id) }
        }
        // Who the log says a picked warning reached, worked out once each and only for the picks: a mailbox here whose last
        // word of it is a receipt (one received, then quarantined, wasn't reached: final review 2026-10-25); outside, or no
        // one's mailbox, a send naming it with nothing failing. A failure that names no recipient and isn't a mailbox's own
        // (the sender's, a failed send listing no one) is the whole email's: outside, or no one's mailbox, it reached no one.
        var reachedBy: [String: Set<String>] = [:]
        func reached(by id: String) -> Set<String> {
            if let known = reachedBy[id] { return known }
            guard let mail = mails[id] else { return [] }
            let found = Set(mail.order.filter { address in
                isMailbox(address) ? mail.receivedLast(address)
                    : !mail.wholeFailed && mail.sentOK.contains(address) && mail.failed[address] == nil
            })
            reachedBy[id] = found
            return found
        }
        return ids.map { pasted in
            let id = bareMessageID(pasted), mail = mails[id] ?? Mail()
            let after = (mail.sends + mail.begun).compactMap(\.time).min() ?? .distantPast
            // A warning picked counts only as the candidates do: an account here, not the attacker's address, after the email.
            let picked = (context.warnings[id] ?? []).sorted().map { pick -> Reach.Candidate in
                let found = mails[pick], send = found?.ours(attacker)
                let problem: String? = if attackers.contains(pick) { "it's one the attacker sent" }
                    else if let found, found.sends.isEmpty, !found.begun.isEmpty { "the logs read show its send begun, never sent" }
                    else if found.map({ $0.sends.isEmpty }) ?? true { "it isn't in the logs read: pull its sender's Gmail log" }
                    else if send == nil { "Google marked its send failed, or it was sent from the attacker's address" }
                    else if (send?.time ?? .distantPast) <= after { "it was sent before the email" }
                    else { nil }
                return Reach.Candidate(messageID: pick, sender: (send ?? found?.sends.first)?.who ?? "", subject: found?.subject ?? "",
                                       at: (send ?? found?.sends.first)?.time, covers: 0, warned: [], problem: problem)
            }
            let counting = picked.filter { $0.problem == nil }.map(\.messageID)
            let warned = Set(counting.flatMap { reached(by: $0) })
            let recipients = mail.order.map { address in
                let inside = isInside(address)
                let outcome: Reach.Outcome = if mail.received[address] != nil { .received }
                    else if let failure = mail.failed[address] { failure.bounced ? .bounced : .blocked }
                    else if inside && !isMailbox(address) { .notAMailbox }
                    else { .sent }
                let at: Date? = switch outcome {
                case .received: mail.received[address] ?? nil
                case .bounced, .blocked: mail.failed[address]?.at
                case .sent, .notAMailbox: after == .distantPast ? nil : after
                }
                return Reach.Recipient(address: address, inside: inside, mailbox: isMailbox(address), outcome: outcome, at: at,
                                       warned: counting.isEmpty ? nil : warned.contains(address))
            }
            let reach = Set(recipients.filter { !($0.outcome == .bounced && !$0.mailbox) }.map(\.address))
            var covers: [String: Int] = [:]
            for address in reach { for other in byAddress[address] ?? [] where !picked.contains(where: { $0.messageID == other }) { covers[other, default: 0] += 1 } }
            // The most people first, then the earlier, at most `candidatesShown`: whole counts taken from the top until there are
            // enough, and only those sorted (a sort of every candidate, for each email the attacker sent, was most of a reading's
            // time: final review 2026-10-25).
            var byCount: [Int: [String]] = [:]
            for (other, count) in covers { byCount[count, default: []].append(other) }
            // The bucket that crosses the limit keeps only its earliest, never sorted whole (final review 2026-10-25: nearly every
            // candidate can share one count).
            func earlier(_ a: Reach.Candidate, _ b: Reach.Candidate) -> Bool {
                (a.at ?? .distantPast, a.messageID) < (b.at ?? .distantPast, b.messageID)
            }
            var candidates: [Reach.Candidate] = []
            for count in byCount.keys.sorted(by: >) where candidates.count < Reach.candidatesShown {
                let room = Reach.candidatesShown - candidates.count
                var best: [Reach.Candidate] = []   // at most `room`, earliest first
                for other in byCount[count]! {
                    guard let warning = warnings[other], (warning.at ?? .distantPast) > after else { continue }
                    if best.count == room, let last = best.last, !earlier(warning, last) { continue }
                    best.insert(warning, at: best.firstIndex { earlier(warning, $0) } ?? best.endIndex)
                    if best.count > room { best.removeLast() }
                }
                candidates += best.map { Reach.Candidate(messageID: $0.messageID, sender: $0.sender, subject: $0.subject, at: $0.at, covers: count,
                                                         warned: [], problem: nil) }
            }
            // People here still to warn whose log the pull doesn't show from this email on: their Gmail log is what would show a
            // warning. None while the directory isn't read (`Reach.unread`).
            let unread = context.people == nil ? []
                : recipients.filter { $0.mailbox && $0.warned != true && (latest[$0.address].map { $0 < after } ?? true) }
            return Reach(messageID: id, subject: mail.subject, senders: unique(mail.sends.map(\.who).filter(isAccount)), recipients: recipients,
                         candidates: Array(candidates.prefix(Reach.candidatesShown)),
                         warnings: picked.map { pick in
                             let shown = pick.problem == nil ? reached(by: pick.messageID).intersection(reach) : []
                             return Reach.Candidate(messageID: pick.messageID, sender: pick.sender, subject: pick.subject, at: pick.at,
                                                    covers: shown.count, warned: shown, problem: pick.problem)
                         },
                         unreadable: mail.unreadable, unnamed: mail.unnamed, unread: unique(unread.map(\.address)))
        }
    }

    /// What the Gmail log says of one email (`reaches`): its sends and sends begun, oldest first; every address they named,
    /// then every mailbox that received it unnamed (a group's member, a Bcc a send didn't name), each once, an alias as its
    /// person; who a send Google didn't mark failed named; who received it; and what failed (bounced, quarantined, rejected,
    /// or marked failed, a failed send's recipients too), each with when.
    struct Mail {
        var subject = ""
        var sends: [Event] = []
        var begun: [Event] = []
        var order: [String] = []
        var sentOK: Set<String> = []
        var received: [String: Date?] = [:]
        var failed: [String: (bounced: Bool, at: Date?)] = [:]
        /// When each address last received it, and last failed (one with no time as last of all), for `receivedLast`.
        var lastReceived: [String: Date] = [:], lastFailed: [String: Date] = [:]
        var unreadable = 0
        /// Its Sends (type 1) with no recipient named at all.
        var unnamed = 0
        /// A failure naming no recipient, nor a recipient's own mailbox: the whole email's.
        var wholeFailed = false

        /// Its first send Google didn't mark failed, by an account here, from an address that isn't the attacker's: what
        /// makes it a warning.
        func ours(_ attacker: Set<String>) -> Event? {
            sends.first { isAccount($0.who) && !attacker.contains($0.ip) && $0.parameters["event_info.success"]?.lowercased() != "false" }
        }

        /// Who it went to, failed aside (a whole send failed reached no one it named: final review 2026-10-25): what a candidate
        /// warning is offered and counted by ("to N of them").
        var addressed: Set<String> { Set(order.filter { receivedLast($0) || (!wholeFailed && sentOK.contains($0) && failed[$0] == nil) }) }

        /// Whether its last word for `address` is a receipt: received, and no failure for it at or after (one received, then
        /// quarantined, wasn't reached; one quarantined, then released, was).
        func receivedLast(_ address: String) -> Bool {
            guard let at = lastReceived[address] else { return false }
            return lastFailed[address].map { at > $0 } ?? true
        }

        static func all(in events: [Event], person: (String) -> String, reading read: (String) -> String? = { address($0) }) -> [String: Mail] {
            var byID: [String: [Event]] = [:]
            for event in events {
                guard let id = event.parameters["message_info.rfc2822_message_id"], !id.isEmpty else { continue }
                byID[bareMessageID(id), default: []].append(event)
            }
            return byID.mapValues { events in
                var mail = Mail(), seen: Set<String> = []
                func add(_ address: String) { if seen.insert(address).inserted { mail.order.append(address) } }
                func fail(_ address: String, bounced: Bool, at: Date?) {
                    add(address)
                    // A failure that isn't a bounce wins over one that is: Gmail trying again after a bounce (quarantined, slowed)
                    // leaves someone who may have it, to warn (final review 2026-10-25: the order the two came in decided).
                    if mail.failed[address].map({ $0.bounced && !bounced }) ?? true { mail.failed[address] = (bounced, at) }
                    mail.lastFailed[address] = max(mail.lastFailed[address] ?? .distantPast, at ?? .distantFuture)
                }
                let sorted = events.sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
                mail.subject = sorted.compactMap { $0.parameters["message_info.subject"] }.first { !$0.isEmpty } ?? ""
                var unnamedFailures: [(own: String, bounced: Bool, at: Date?)] = []
                for event in sorted {
                    let type = Int(event.parameters["event_info.mail_event_type"] ?? "")
                    let failedEvent = event.parameters["event_info.success"]?.lowercased() == "false"
                    switch type {
                    case 1, 35:
                        let named = destinations(event, reading: read)
                        if type == 1 { mail.sends.append(event) } else { mail.begun.append(event) }
                        mail.unreadable += named.unreadable
                        // A Send (1) names its recipients (Google's schema); one that names none can't say who it went to.
                        if type == 1, named.addresses.isEmpty, named.unreadable == 0 {
                            mail.unnamed += 1
                            if failedEvent { mail.wholeFailed = true }
                        }
                        for address in named.addresses.map(person) {
                            add(address)
                            if type == 1, failedEvent { fail(address, bounced: false, at: event.time) }
                            else if type == 1 { mail.sentOK.insert(address) }
                        }
                    // A `where` covers only the pattern it follows: each receipt says it (a failed one is a failure, below).
                    case 2 where !failedEvent, 6 where !failedEvent:
                        guard let mailbox = read(event.who).map(person) else { continue }
                        add(mailbox)
                        if mail.received[mailbox] == nil { mail.received[mailbox] = event.time }
                        mail.lastReceived[mailbox] = max(mail.lastReceived[mailbox] ?? .distantPast, event.time ?? .distantPast)
                    default:
                        // A failure names its recipients, or is the mailbox's own (a quarantine, a rejection at receipt).
                        guard type == 30 || type == 5 || type == 34 || failedEvent else { continue }
                        let named = destinations(event, reading: read).addresses.map(person)
                        // Naming no one, it's a mailbox's own (a quarantine at receipt) or, from a sender, the whole email's:
                        // decided once every send is known, below. One whose actor doesn't read is the whole email's (final review
                        // 2026-10-25: it was dropped).
                        if named.isEmpty {
                            if let own = read(event.who).map(person) { unnamedFailures.append((own, type == 30, event.time)) } else { mail.wholeFailed = true }
                        }
                        for address in named { fail(address, bounced: type == 30, at: event.time) }
                    }
                }
                // A sender's is the whole email's; anyone else's is their own mailbox's, which it came to: listed, to warn (final
                // review 2026-10-25: one not named or received before was taken as the whole email's, and its mailbox dropped).
                let senders = Set((mail.sends + mail.begun).compactMap { read($0.who).map(person) })
                for failure in unnamedFailures {
                    if senders.contains(failure.own) { mail.wholeFailed = true } else { fail(failure.own, bounced: failure.bounced, at: failure.at) }
                }
                return mail
            }
        }
    }

    /// `message_info.flattened_destinations` as addresses (`service:selector:address` entries, comma-separated: Google's
    /// schema for Gmail logs), each lowercased and once, and how many entries didn't end in one; `read` is `address`, or a
    /// reading that remembers it. On its bytes in place, each comma found by `memchr`: every send in a whole pull comes
    /// through here (review 2026-10-24: split and trimmed as text, it was most of a reading's time; walked as an array, it
    /// was still most of a Debug build's, 2026-10-25). Every pointer stays within the field: `from`, `to` and `colon` move
    /// only between an entry's start and its comma.
    static func destinations(_ event: Event, reading read: (String) -> String? = { address($0) }) -> (addresses: [String], unreadable: Int) {
        guard var field = event.parameters["message_info.flattened_destinations"], !field.isEmpty else { return ([], 0) }
        var addresses: [String] = [], seen: Set<String> = [], unreadable = 0
        field.withUTF8 { bytes in
            guard var start = bytes.baseAddress else { return }
            let end = start + bytes.count
            while true {
                let comma = memchr(start, 0x2C, end - start).map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) } ?? end
                // The entry's last `:` part, its spaces and tabs off.
                var from = start, to = comma
                while from < to, from.pointee == 0x20 || from.pointee == 0x09 { from += 1 }
                while to > from, (to - 1).pointee == 0x20 || (to - 1).pointee == 0x09 { to -= 1 }
                if from < to {
                    var colon = to
                    while colon > from, (colon - 1).pointee != 0x3A { colon -= 1 }
                    if let found = read(String(decoding: UnsafeBufferPointer(start: colon, count: to - colon), as: UTF8.self)) {
                        if seen.insert(found).inserted { addresses.append(found) }
                    } else {
                        unreadable += 1
                    }
                }
                guard comma < end else { return }
                start = comma + 1
            }
        }
        return (addresses, unreadable)
    }

    /// An email address as Who it reached lists one, lowercased: text around its last `@`, neither part empty, no space or
    /// control character, at most 320 characters. Looser than `isAccount` (which keeps what reaches the model or a draft to
    /// a plain shape): a recipient's address can hold `&`, `#` or letters beyond ASCII, and dropping one would hide someone
    /// still to warn (review 2026-10-24). It's never given to the model. Plain ASCII is read on its bytes; the rest by its
    /// scalars.
    static func address(_ text: String) -> String? {
        let utf8 = text.utf8
        if utf8.allSatisfy({ $0 < 0x80 }) {
            var bytes = Array(utf8)
            while let last = bytes.last, last == 0x20 || last == 0x09 { bytes.removeLast() }
            if let space = bytes.firstIndex(where: { $0 != 0x20 && $0 != 0x09 }) { bytes.removeFirst(space) } else { return nil }
            guard (3...320).contains(bytes.count), bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
                  let at = bytes.lastIndex(of: 0x40), at > 0, at < bytes.count - 1 else { return nil }
            for index in bytes.indices where (0x41...0x5A).contains(bytes[index]) { bytes[index] += 0x20 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard (3...320).contains(text.count), let at = text.lastIndex(of: "@"), at != text.startIndex, text.index(after: at) != text.endIndex,
              !text.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control })
        else { return nil }
        return text
    }

    /// The lock's steps by event name: a password reset by an admin, or by the person from an address they signed in from
    /// before the attack (people do change their own); a sign-out by an admin or by Google; a suspension by an admin
    /// or Google's own disabling. GAM's `deprovision signout` also revokes apps, app passwords and backup codes,
    /// which make no lock alone.
    static let resets: Set = ["CHANGE_PASSWORD", "password_edit"]
    static let signOuts: Set = ["RESET_SIGNIN_COOKIES", "user_signed_out_due_to_suspicious_session_cookie"]
    static let suspensions: Set = ["SUSPEND_USER", "account_disabled_hijacked", "account_disabled_password_leak",
                                   "account_disabled_generic", "account_disabled_spamming", "account_disabled_spamming_through_relay"]

    /// What a lock leaves in place, by event (the sign-in log's passkeys; the account changes log's 2-Step Verification and
    /// recovery), as said mid-sentence.
    static let leftovers: [String: String] = [
        "passkey_enrolled": "a new passkey",
        "2sv_enroll": "2-Step Verification on a phone or app of the attacker's choosing",
        "recovery_email_edit": "a changed recovery email",
        "recovery_phone_edit": "a changed recovery phone",
        "recovery_secret_qa_edit": "a changed recovery question",
        "blocked_sender": "a blocked sender",
    ]

    /// Where `account` stands: the first password reset, sign-out and suspension done to it since the attacker's first
    /// event (by an admin, never from a suspect address, which would be an attacker with an admin's account; or by Google,
    /// as the account's own sign-in log event), the lock they make, and the sign-ins after it. A sign-in from a suspect
    /// address after a lock starts it over: a lock after that sign-in is a new one, read the same way. It reads only the
    /// account's own events and the admin's done to it, so `events` can be just those (`Accounts`), with the same result.
    static func status(_ account: String, _ events: [Event], acting: Set<String>, context: Context, joined: [Event] = [],
                       phishedAt: Date? = nil, held: [String: ClosedRange<Date>] = [:]) -> Status {
        let me = account.lowercased()
        let theirs = events.filter { $0.who.lowercased() == me }
        // When the attack on it began: its first event from a suspect address, or Chrome seeing its password typed on a
        // phishing site. Nothing before counts as its lock, and without it nothing does (security review 2026-10-22).
        let attackedAt = (theirs.filter { acting.contains($0.ip) }.compactMap(\.time) + [phishedAt].compactMap(\.self)).min()
        // The addresses it signed in from before the attack: the person's own. A later sign-in counts as theirs by network
        // (`network`: a home's IPv6 address changes), unless a suspect address shares that network; a password change only
        // from the very address.
        let beforeExact = Set(theirs.filter { event in
            event.log == "login" && event.event == "login_success" && (event.time.map { at in attackedAt.map { at < $0 } ?? false } ?? false)
        }.map(\.ip))
        let suspectNetworks = Set(acting.map(network))
        let knownNetworks = Set(beforeExact.map(network)).subtracting(suspectNetworks)
        let known = { (ip: String) in beforeExact.contains(ip) || knownNetworks.contains(network(ip)) }
        // A suspension later undone isn't a lock.
        let unsuspended = events.filter { $0.log == "admin" && $0.event == "UNSUSPEND_USER" && $0.parameters["USER_EMAIL"]?.lowercased() == me }
            .compactMap(\.time)
        // Done to the account, oldest first: by an admin, never from a suspect address nor through an account the attacker
        // held at the time; by Google; or the person's own password change from the very address they used before the attack.
        let done = events.filter { event in
            guard let at = event.time else { return false }
            if suspensions.contains(event.event), unsuspended.contains(where: { $0 > at }) { return false }
            if event.log == "admin" {
                return event.parameters["USER_EMAIL"]?.lowercased() == me && !acting.contains(event.ip)
                    && !(held[event.who.lowercased()]?.contains(at) ?? false)
            }
            guard ["login", "useraccounts"].contains(event.log), event.who.lowercased() == me else { return false }
            return event.event != "password_edit" || (!acting.contains(event.ip) && beforeExact.contains(event.ip))
        }.sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
        let entries = theirs.filter { acting.contains($0.ip) && ["login", "saml"].contains($0.log) && $0.event == "login_success"
            && $0.time != nil }.sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
        func first(_ names: Set<String>, since: Date?) -> Status.Step? {
            guard let event = done.first(where: { event in names.contains(event.event) && (since.map { (event.time ?? .distantPast) >= $0 } ?? true) }),
                  let at = event.time else { return nil }
            return Status.Step(at: at, by: event.log == "admin" || event.event == "password_edit" ? event.who : "Google")
        }
        var since = attackedAt
        var reset: Status.Step?, signOut: Status.Step?, suspended: Status.Step?, whole: Date?, lockedAt: Date?, backIn: Event?
        while attackedAt != nil {
            reset = first(resets, since: since)
            signOut = first(signOuts, since: since)
            suspended = first(suspensions, since: since)
            whole = [suspended?.at, reset.flatMap { reset in signOut.map { max(reset.at, $0.at) } }].compactMap(\.self).min()
            lockedAt = whole ?? (reset ?? signOut)?.at
            guard let locked = lockedAt else { backIn = nil; break }
            backIn = entries.first { ($0.time ?? .distantPast) > locked }
            guard let back = backIn?.time, done.contains(where: { lockSteps.contains($0.event) && ($0.time ?? .distantPast) > back }) else { break }
            since = back
        }

        let after = lockedAt.map { locked in theirs.filter { ($0.time.map { $0 > locked }) ?? false } } ?? []
        let triedAt = after.filter { acting.contains($0.ip) && $0.log == "login"
            && ($0.event == "login_failure" || $0.event.hasPrefix("suspicious_")) }.compactMap(\.time).max()
        var newPlaces: Set<String> = []
        let newAddresses = after.filter { $0.log == "login" && $0.event == "login_success" && !$0.ip.isEmpty && !acting.contains($0.ip)
            && !known($0.ip) }.map(\.ip).filter { newPlaces.insert(suspectNetworks.contains(network($0)) ? $0 : network($0)).inserted }

        let unseen: String? = if lockedAt != nil { nil }
            else if !context.pulledBy.isEmpty { "a pull by one address doesn't show it (the lock is done from yours): pull by the accounts" }
            else if let read = context.read, !read.contains("admin") { "the admin log, where it would be, wasn't read" }
            else { nil }
        // A lock before the first suspect event these logs hold: the window may start after the attack did.
        let earlierLockAt = lockedAt == nil ? done.last(where: { lockSteps.contains($0.event) })?.time : nil
        let state: Status.State = backIn != nil ? .stillIn : whole != nil ? .locked : lockedAt != nil ? .partlyLocked : .notLocked
        return Status(account: account, state: state, attackerGotIn: !entries.isEmpty, attackedAt: attackedAt, reset: reset, signOut: signOut,
                      suspended: suspended, lockedAt: lockedAt, backInAt: backIn?.time, backInFrom: backIn?.ip ?? "", triedAt: triedAt,
                      newAddresses: newAddresses, unseen: unseen, earlierLockAt: earlierLockAt,
                      timeline: timeline(me, events, acting: acting, since: attackedAt, known: known, joined: joined))
    }

    /// At most this many moments in an account's timeline (invariant 9): the earliest kept.
    static let timelineCap = 200

    /// `me`'s timeline, from the attack on: each attacker sign-in (with how it got past the challenge), failure and change
    /// from a suspect address, the device that joined at one, and the rest the attacker did a line per log; each step of
    /// every lock an admin took (a forced sign-out, a reset, apps revoked at once, recovery removed, a suspension); what
    /// Google did; and the person's own changes, said with the address when it's not one they used before the attack.
    static func timeline(_ me: String, _ events: [Event], acting: Set<String>, since: Date?, known: (String) -> Bool, joined: [Event]) -> [Moment] {
        let from = since ?? .distantPast
        var moments: [Moment] = []
        func add(_ at: Date?, _ kind: Moment.Kind, _ words: String, until: Date? = nil, count: Int = 1, plain: String? = nil) {
            guard let at else { return }
            moments.append(Moment(at: at, until: until, kind: kind, words: words, count: count, plain: plain ?? words))
        }
        var activity: [String: [Event]] = [:]
        for event in events where event.who.lowercased() == me && acting.contains(event.ip) {
            switch (event.log, event.event) {
            case ("login", "login_success"):
                add(event.time, .attackerSignedIn, "The attacker signed in from \(event.ip)" + proof(event))
            case ("saml", "login_success"):
                add(event.time, .attackerSignedIn, "The attacker signed in to \(event.parameters["application_name"] ?? "another app") through Google "
                    + "from \(event.ip)", plain: "The attacker signed in to another app through Google from \(event.ip)")
            case ("login", "login_failure"):
                add(event.time, .attackerFailed, "The attacker's sign-in from \(event.ip) failed")
            case ("login", let name) where name.hasPrefix("suspicious_"):
                add(event.time, .googleBlocked, "Google blocked a suspicious sign-in from \(event.ip)")
            case ("token", "authorize"):
                add(event.time, .attackerChanged, "The attacker gave \(event.parameters["app_name"] ?? "an app") access",
                    plain: "The attacker gave an app access")
            case (_, let name) where changeWords[name] != nil:
                let sender = event.parameters["affected_email_address"].map { " \($0)" } ?? " a sender"
                add(event.time, .attackerChanged, "The attacker " + (changeWords[name] ?? "").replacingOccurrences(of: "{sender}", with: sender),
                    plain: "The attacker " + (changeWords[name] ?? "").replacingOccurrences(of: "{sender}", with: " a sender"))
            case ("login", _), ("accessevaluation", _):
                break   // a sign-in's challenges and token checks are part of the sign-in
            default:
                activity[event.log, default: []].append(event)
            }
        }
        for (log, theirs) in activity.sorted(by: { $0.key < $1.key }) {
            let times = theirs.compactMap(\.time).sorted()
            add(times.first, .attackerActivity, "\(theirs.count) \(logName(log)) event\(theirs.count == 1 ? "" : "s") from the attacker's address",
                until: times.count > 1 ? times.last : nil, count: theirs.count)
        }
        for device in joined where device.who.lowercased() == me {
            let words = deviceWords(device)
            add(device.time, .deviceJoined, words.prefix(1).uppercased() + words.dropFirst() + " joined the account",
                plain: "A computer joined the account at the attacker's sign-in")
        }
        for event in events where event.log == "contacts" && event.event == "print_contacts" && event.who.lowercased() == me
            && (event.time ?? .distantPast) >= from {
            let count = Int(event.parameters["CONTACTS_COUNT"] ?? "").map { " (\($0.formatted(.number.locale(Locale(identifier: "en_US")))))" } ?? ""
            add(event.time, .contactsPrinted, "Their contacts\(count) were printed")
        }
        // An admin's steps, never from a suspect address; an app's access revoked many at once is said once.
        var revoked: [(at: Date, count: Int, by: String)] = []
        for event in events where event.log == "admin" && event.parameters["USER_EMAIL"]?.lowercased() == me && !acting.contains(event.ip)
            && (event.time ?? .distantPast) >= from {
            let by = event.who.isEmpty ? "an admin" : event.who
            switch event.event {
            case "CHANGE_PASSWORD": add(event.time, .passwordReset, "Password reset by \(by)")
            case "RESET_SIGNIN_COOKIES": add(event.time, .signedOut, "Signed out of every session by \(by)")
            case "REVOKE_3LO_TOKEN", "REVOKE_3LO_DEVICE_TOKENS":
                guard let at = event.time else { continue }
                revoked.append((at, 1, by))
            case "REVOKE_ASP": add(event.time, .appPasswordsDeleted, "An app password deleted by \(by)")
            case "DELETE_2SV_SCRATCH_CODES": add(event.time, .backupCodesDeleted, "2-Step Verification backup codes deleted by \(by)")
            case "REMOVE_RECOVERY_EMAIL": add(event.time, .recoveryRemoved, "Recovery email removed by \(by)")
            case "REMOVE_RECOVERY_PHONE": add(event.time, .recoveryRemoved, "Recovery phone removed by \(by)")
            case "SUSPEND_USER": add(event.time, .suspended, "Suspended by \(by)")
            case "UNSUSPEND_USER": add(event.time, .unsuspended, "Unsuspended by \(by)")
            case "MOBILE_DEVICE_BLOCK": add(event.time, .adminChange, "A device blocked by \(by)")
            case "MOBILE_DEVICE_DELETE": add(event.time, .adminChange, "A device removed by \(by)")
            case "MOBILE_DEVICE_WIPE", "MOBILE_ACCOUNT_WIPE": add(event.time, .adminChange, "A device wiped by \(by)")
            case "CHANGE_PASSWORD_ON_NEXT_LOGIN": break   // said with the reset beside it
            default: add(event.time, .adminChange, "\(sentence(event.event)) by \(by)")
            }
        }
        // One batch: the same admin's revocations within a minute of the batch's first.
        var batches: [(at: Date, count: Int, by: String)] = []
        for revoke in revoked.sorted(by: { $0.at < $1.at }) {
            if let last = batches.indices.last(where: { batches[$0].by == revoke.by }), revoke.at.timeIntervalSince(batches[last].at) <= 60 {
                batches[last].count += 1
            } else {
                batches.append(revoke)
            }
        }
        for batch in batches {
            add(batch.at, .appsRevoked, "\(batch.count) app\(batch.count == 1 ? "'s" : "s'") access revoked by \(batch.by)", count: batch.count)
        }
        // Google, and the person: their own changes from addresses that aren't a suspect's.
        for event in events where ["login", "useraccounts"].contains(event.log) && event.who.lowercased() == me && !acting.contains(event.ip)
            && (event.time ?? .distantPast) >= from {
            let from = event.ip.isEmpty || known(event.ip) ? "" : ", from \(event.ip), an address not seen before the attack"
            switch event.event {
            case let name where name.hasPrefix("account_disabled_"):
                add(event.time, .googleDisabled, "Google disabled the account" + (name == "account_disabled_hijacked" ? " as hijacked"
                    : name == "account_disabled_password_leak" ? ": its password leaked" : ""))
            case "user_signed_out_due_to_suspicious_session_cookie":
                add(event.time, .googleSignedOut, "Google signed them out: a suspicious session cookie")
            // From an address not theirs before the attack it may not be them: said without saying who.
            case "password_edit": add(event.time, .ownPassword, from.isEmpty ? "They changed their own password" : "The password was changed" + from)
            case "2sv_enroll": add(event.time, .own2SV, "They turned on 2-Step Verification" + from)
            case "passkey_enrolled": add(event.time, .ownPasskey, "They added a passkey" + from)
            case "recovery_phone_edit": add(event.time, .ownRecovery, "They changed their recovery phone" + from)
            case "recovery_email_edit": add(event.time, .ownRecovery, "They changed their recovery email" + from)
            default: break
            }
        }
        // Once each (a password change is in both the sign-in and account changes logs), in time order.
        var seen: Set<String> = []
        let rank = { (kind: Moment.Kind) in Moment.Kind.allCases.firstIndex(of: kind) ?? 0 }
        return Array(moments.sorted { ($0.at, rank($0.kind), $0.words) < ($1.at, rank($1.kind), $1.words) }
            .filter { seen.insert("\($0.at.timeIntervalSince1970)|\($0.words)").inserted }.prefix(timelineCap))
    }

    /// The network an address is in, to tell a person's own from a new one: an IPv4 address itself; an IPv6 address's
    /// first 64 bits, which a home keeps while its devices change the rest (privacy addresses).
    static func network(_ ip: String) -> String {
        guard ip.contains(":") else { return ip }
        let halves = ip.lowercased().components(separatedBy: "::")
        let head = halves[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        let groups = head.count >= 4 || halves.count == 1 ? head : head + Array(repeating: "0", count: 4 - head.count)
        return groups.prefix(4).map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":")
    }

    /// How an attacker's sign-in got past Google's challenge, mid-sentence: the means of the takeover.
    static func proof(_ event: Event) -> String {
        let methods = (event.parameters["login_challenge_method"] ?? "").split(separator: " ").map(String.init)
        if methods.contains("knowledge_historical_password") { return ", answering Google's question for a previous password" }
        if methods.contains("device_prompt") { return ": someone approved the sign-in prompt on the person's phone" }
        if methods.contains(where: { $0.hasPrefix("idv_") }) { return ": someone entered the code sent to the person's phone" }
        if methods.contains("passkey") { return ", with a passkey" }
        return ""
    }

    /// What an attacker's change was, mid-sentence ("{sender}": the address blocked).
    static let changeWords: [String: String] = [
        "passkey_enrolled": "added a passkey",
        "2sv_enroll": "turned on 2-Step Verification with a phone or app of their choosing",
        "recovery_email_edit": "changed the recovery email",
        "recovery_phone_edit": "changed the recovery phone",
        "recovery_secret_qa_edit": "changed the recovery question",
        "blocked_sender": "blocked{sender} in Gmail",
        "password_edit": "changed the password",
    ]

    /// `CHANGE_TWO_STEP_VERIFICATION_FREQUENCY` as "Change two step verification frequency".
    static func sentence(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Every event that is a step of a lock.
    static let lockSteps = resets.union(signOuts).union(suspensions)

    /// A finding before it has its place (and so its ID).
    private struct Pending {
        let kind: Finding.Kind, words: String, accounts: [String], addresses: [String], events: Int, drafts: [Draft], markable: [String]
        /// What's left to do about it, if anything: each its kind, its sentence, and its drafts.
        let todo: [(Task.Kind, String, [Draft])]
        /// The events its to-do items are about, when narrower than its accounts from its addresses (an app's, a log's).
        let shows: Shown?
        init(_ kind: Finding.Kind, _ words: String, _ accounts: [String], _ addresses: [String], _ events: Int, _ drafts: [Draft],
             markable: [String] = [], todo: [(Task.Kind, String, [Draft])] = [], shows: Shown? = nil) {
            (self.kind, self.words, self.accounts, self.addresses, self.events, self.drafts, self.markable, self.todo, self.shows)
                = (kind, words, accounts, addresses, events, drafts, markable, todo, shows)
        }
    }

    /// When a device's registration is tied to a sign-in: from a minute before it (the two logs' clocks) to ten minutes
    /// after. The attacker's computer registers in the same second; the nearest sign-in from any address decides whose.
    static let deviceWindow: ClosedRange<TimeInterval> = -60...(10 * 60)

    /// What `event` says of the account's device `ids`: true there (registered, approved, access allowed), false gone
    /// (unregistered, an admin's block, wipe or delete done), nil nothing. Google's names, from the Reports API's Devices and Admin
    /// mobile-settings events: a Devices-log action counts only once `EXECUTED` (2026-10-22: a guessed `SUCCESS` matched
    /// nothing Google sends, so a computer an admin blocked stayed on the list).
    static func deviceWord(_ event: Event, on ids: Set<String>, of account: String) -> Bool? {
        let on = [event.parameters["DEVICE_ID"], event.parameters["RESOURCE_ID"]].contains { $0.map(ids.contains) ?? false }
        guard on else { return nil }
        switch (event.log, event.event) {
        case ("mobile", _) where event.who.lowercased() != account.lowercased(): return nil
        case ("mobile", "DEVICE_REGISTER_UNREGISTER_EVENT"): return event.parameters["ACCOUNT_STATE"] != "UNREGISTERED"
        case ("mobile", "DEVICE_ACTION_EVENT"):
            guard event.parameters["ACTION_EXECUTION_STATUS"] == "EXECUTED" else { return nil }
            switch event.parameters["ACTION_TYPE"] ?? "" {
            case "BLOCK", "DISALLOW_ACCESS", "ACCOUNT_WIPE", "DEVICE_WIPE", "UNENROLL": return false
            case "APPROVE", "ALLOW_ACCESS": return true
            default: return nil
            }
        case ("mobile", "DEVICE_COMPLIANCE_CHANGED_EVENT"):
            return event.parameters["DEVICE_DEACTIVATION_REASON"] == "DEVICE_BLOCKED_BY_ADMIN" ? false : nil
        case ("admin", _) where event.parameters["USER_EMAIL"]?.lowercased() != account.lowercased(): return nil
        case ("admin", "MOBILE_DEVICE_BLOCK"), ("admin", "MOBILE_DEVICE_DELETE"), ("admin", "MOBILE_DEVICE_WIPE"),
             ("admin", "MOBILE_ACCOUNT_WIPE"), ("admin", "MOBILE_DEVICE_CANCEL_WIPE_THEN_BLOCK"):
            return false
        case ("admin", "MOBILE_DEVICE_APPROVE"), ("admin", "MOBILE_DEVICE_CANCEL_WIPE_THEN_APPROVE"): return true
        default: return nil
        }
    }

    /// A registered device as people say it, mid-sentence: "a Windows computer (Virtual Machine, Windows 10.0.19045)".
    static func deviceWords(_ event: Event) -> String {
        let kind = switch (event.parameters["DEVICE_TYPE"] ?? "").uppercased() {
        case "WINDOWS": "a Windows computer"
        case "MAC", "MAC_OS": "a Mac"
        case "LINUX": "a Linux computer"
        case "CHROME_OS": "a Chromebook"
        case "IOS", "IOS_SYNC": "an iPhone or iPad"
        case "ANDROID": "an Android device"
        default: "a device"
        }
        let about = [event.parameters["DEVICE_MODEL"] ?? "", event.parameters["OS_VERSION"] ?? ""].filter { !$0.isEmpty }
        return kind + (about.isEmpty ? "" : " (\(about.joined(separator: ", ")))")
    }

    /// A log's name as people say it.
    static func logName(_ log: String) -> String {
        switch log {
        case "login": "Sign-ins"
        case "token": "OAuth"
        case "admin": "Admin"
        case "useraccounts": "Account changes"
        case "saml": "SAML"
        case "takeout": "Takeout"
        case "geminiinworkspaceapps": "Gemini"
        case "drive": "Drive"
        case "calendar": "Calendar"
        case "contacts": "Contacts"
        case "meet": "Meet"
        case "keep": "Keep"
        case "tasks": "Tasks"
        case "gmail": "Gmail"
        case "chat": "Chat"
        case "mobile": "Devices"
        case "datastudio": "Looker Studio"
        case "accessevaluation": "Access evaluation"
        default: log
        }
    }

    /// An account's address: a Chrome event's computer login name ("carol") is not one, and drafts nothing.
    static func isAccount(_ who: String) -> Bool {
        // Strictly an address's shape: a Chrome event's account is what the browser reports, so nothing else (no space, no
        // sentence) reaches a status, a draft or the model (security review 2026-10-22).
        let parts = who.split(separator: "@", omittingEmptySubsequences: false)
        guard who.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".")
        else { return false }
        return parts[0].unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._%+-'".unicodeScalars.contains($0)) }
            && parts[1].unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-".unicodeScalars.contains($0)) }
    }

    /// Each account's events, case aside, in `events`' order: its own (`who`) and the admin log's steps done to it
    /// (`USER_EMAIL`), each once. Every rule about one account reads only these (`status` and its `timeline`, `deviceWord`, the
    /// contacts printed, a recovery detail removed), so each reads its own rather than every event: a whole pull for every
    /// account holds hundreds of thousands, and reading them all once per account took minutes (failure log 2026-10-23).
    struct Accounts {
        private let events: [Event]
        private let indices: [String: [Int]]

        init(_ events: [Event]) {
            var indices: [String: [Int]] = [:]
            for (index, event) in events.enumerated() {
                let who = event.who.lowercased()
                indices[who, default: []].append(index)
                if let target = event.parameters["USER_EMAIL"]?.lowercased(), target != who { indices[target, default: []].append(index) }
            }
            self.events = events
            self.indices = indices
        }

        subscript(_ account: String) -> [Event] { (indices[account.lowercased()] ?? []).map { events[$0] } }
    }

    /// Events by their account (case aside), in the order each account first appears.
    static func grouped(_ events: [Event]) -> [(String, [Event])] {
        var groups: [String: (String, [Event])] = [:], order: [String] = []
        for event in events {
            let key = event.who.lowercased()
            if groups[key] == nil {
                order.append(key)
                groups[key] = (event.who, [])
            }
            groups[key]?.1.append(event)
        }
        return order.compactMap { groups[$0] }
    }

    static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ values: [String]) -> String {
        guard let last = values.last, values.count > 1 else { return values.joined() }
        return values.dropLast().joined(separator: ", ") + " and " + last
    }
}
