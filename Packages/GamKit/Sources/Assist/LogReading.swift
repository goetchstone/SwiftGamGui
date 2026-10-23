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
    /// each with its oldest event read (a log read for every account can stop short of the attack).
    public struct Context: Sendable, Equatable {
        public let pulledBy: String
        public let read: Set<String>?
        public let theirs: Set<String>
        public let capped: [String: Date]

        public init(pulledBy: String = "", read: Set<String>? = nil, theirs: Set<String> = [], capped: [String: Date] = [:]) {
            self.pulledBy = pulledBy
            self.read = read
            self.theirs = theirs
            self.capped = capped
        }
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
    /// device removed, recovery details cleared); what the logs can't show stays until the incident record can tick it.
    public struct Task: Sendable, Equatable, Identifiable {
        /// Most urgent first.
        public enum Kind: String, Sendable, CaseIterable {
            case secureAgain, secure, finishLock, pullAgain, removeAdded, clearRecovery, unblockSender, deleteDevice, pullEmail,
                 signOutApp, warnContacts, warnChat, treatAsTaken, confirmAddress, checkPassword, look, checkShared
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

    /// Every finding, most serious first; where each account the attacker touched stands, with its timeline; what's left
    /// to do; and each draft once in the order the findings point to them.
    public struct Reading: Sendable, Equatable {
        public let findings: [Finding]
        public let statuses: [Status]
        public let toDo: [Task]
        public let events: Int

        public var drafts: [Draft] {
            var seen: Set<Draft> = []
            return findings.flatMap(\.drafts).filter { seen.insert($0).inserted }
        }
    }

    /// An address more accounts than this signed in from is likely shared (an office, a VPN): its sign-ins draft no fix.
    public static let shared = 10

    /// Google's own word that a sign-in was someone else's: a suspicious-sign-in event, an account disabled as hijacked,
    /// or a sign-in marked suspicious, unless that sign-in was proved with a passkey or security key (the person's own
    /// device), or re-proves a session from an address the account signs in from unmarked. A real tenant's log
    /// (2026-10-22) marked both: a passkey re-sign-in through iCloud Private Relay, and a person re-proving themselves at
    /// the office after Google disabled their account; every sign-in of the attacker's was a password one. Not every flag
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

        // Mail from a suspect address: the message to pull from everyone. Its sender is secured by their sign-in from that
        // address, not here: whose mailbox a Gmail row is isn't certain from the row alone.
        var messages: [String: [Event]] = [:], order: [String] = []
        for event in events where event.log == "gmail" && acting.contains(event.ip) {
            guard let id = event.parameters["message_info.rfc2822_message_id"], !id.isEmpty else { continue }
            if messages[id] == nil { order.append(id) }
            messages[id, default: []].append(event)
        }
        for id in order {
            let theirs = messages[id] ?? []
            let subject = theirs.compactMap { $0.parameters["message_info.subject"] }.first { !$0.isEmpty } ?? ""
            found.append(Pending(.mailFromSuspect, "“\(subject.isEmpty ? "(no subject)" : subject)” (\(id)) went through Gmail from "
                                 + list(unique(theirs.map(\.ip))) + ".", unique(theirs.map(\.who).filter(isAccount)),
                                 unique(theirs.map(\.ip)), theirs.count, [.pullEmail(messageID: id, subject: subject)],
                                 todo: [(.pullEmail, "Pull “\(subject.isEmpty ? "(no subject)" : subject)” (\(id)) from every mailbox: it went out "
                                         + "from the attacker's address.", [.pullEmail(messageID: id, subject: subject)])]))
        }

        let ranked = found.enumerated().sorted { a, b in
            (Finding.Kind.allCases.firstIndex(of: a.element.kind)!, a.offset) < (Finding.Kind.allCases.firstIndex(of: b.element.kind)!, b.offset)
        }.map(\.element)
        // A finding about an account already locked drafts no lock again: what's left is in the to-do list.
        let locked = Set(statuses.filter { $0.state == .locked }.map { $0.account.lowercased() })
        func stillToDraft(_ draft: Draft) -> Bool {
            if case .secureAccount(let account) = draft { return !locked.contains(account.lowercased()) }
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
        let todos = statusTasks + coverage + ranked.flatMap { item in
            item.todo.map { ($0.0, $0.1, item.accounts, $0.2, item.shows ?? Shown(accounts: item.accounts, addresses: item.addresses)) }
        }
        var said: Set<String> = []
        let ordered = todos.enumerated().filter { said.insert($0.element.1 + "|" + $0.element.3.map(\.title).joined()).inserted }.sorted { a, b in
            (Task.Kind.allCases.firstIndex(of: a.element.0)!, a.offset) < (Task.Kind.allCases.firstIndex(of: b.element.0)!, b.offset)
        }.map(\.element)

        return Reading(findings: ranked.enumerated().map { index, item in
            Finding(id: "F\(index + 1)", kind: item.kind, words: item.words, accounts: item.accounts, addresses: item.addresses,
                    events: item.events, drafts: item.drafts.filter(stillToDraft), markable: item.markable)
        }, statuses: statuses, toDo: ordered.enumerated().map { index, item in
            Task(id: "T\(index + 1)", kind: item.0, words: item.1, accounts: item.2, drafts: item.3,
                 shows: item.4.flatMap { $0.accounts.isEmpty ? nil : $0 }, pullsAgain: item.0 == .pullAgain ? pullsAgain : [])
        }, events: events.count)
    }

    /// The lock's steps by event name: a password reset by an admin, or by the person from an address they signed in from
    /// before the attack (a real tenant, 2026-10-22: people changed their own); a sign-out by an admin or by Google; a suspension by an admin
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
