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
    /// logs it read, by name (nil: not said; a lock is seen only where the admin log was read, by the accounts), and the
    /// sign-ins the operator marked as the person's own (`key(account:address:)`).
    public struct Context: Sendable, Equatable {
        public let pulledBy: String
        public let read: Set<String>?
        public let theirs: Set<String>

        public init(pulledBy: String = "", read: Set<String>? = nil, theirs: Set<String> = []) {
            self.pulledBy = pulledBy
            self.read = read
            self.theirs = theirs
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

        public func words(_ when: (Date) -> String) -> String {
            switch state {
            case .stillIn:
                guard let backInAt, let lockedAt else { return "" }
                return "Signed in from \(backInFrom) at \(when(backInAt)), after the lock at \(when(lockedAt)): the attacker may still be in."
            case .locked:
                guard let lockedAt else { return "" }
                return "Locked at \(when(lockedAt)): \(how)."
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

        private var how: String {
            if let suspended, suspended.at == lockedAt { return "suspended by \(suspended.by)" }
            guard let reset, let signOut else { return "" }
            return reset.by == signOut.by ? "password reset and signed out by \(reset.by)"
                : "password reset by \(reset.by) and signed out by \(signOut.by)"
        }
    }

    /// A fix a finding points to: a value for a screen, never a command. Secure Account opens for the person and checks
    /// them; Phishing opens with the Message-ID and finds who has a copy.
    public enum Draft: Sendable, Hashable {
        case secureAccount(String)
        case pullEmail(messageID: String, subject: String)

        /// "Secure carol@example.com", "Pull “Invoice” from every mailbox".
        public var title: String {
            switch self {
            case .secureAccount(let person): "Secure \(person)…"
            case .pullEmail(_, let subject):
                // The subject is the attacker's text, of any length: a button shows its start, the finding all of it.
                "Pull “\(subject.isEmpty ? "(no subject)" : subject.count > 40 ? subject.prefix(40) + "…" : subject)” from Every Mailbox…"
            }
        }
    }

    /// One thing the logs show, in a sentence, with the accounts and addresses it concerns, how many events say it, and
    /// the drafts it points to. `id` ("F1") is what the model's points cite.
    public struct Finding: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, CaseIterable {
            case signedInAfterLock, signedInFromSuspect, partlyLocked, leftInPlace, deviceAtSuspectSignIn, appFromSuspect,
                 actedFromSuspect, exportedFromSuspect, contactsTaken, mailFromSuspect, passwordOnPhishingSite, failedFromSuspect,
                 otherAppSession,
                 newAddressAfterLock, chatFromSuspect, agentActed, pastPhishingWarning, passwordOnOtherSite, breachedPassword,
                 sharedAddress, suspectAddress
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

    /// Every finding, most serious first, where each account the attacker had stands, and each draft once in the order the
    /// findings point to them.
    public struct Reading: Sendable, Equatable {
        public let findings: [Finding]
        public let statuses: [Status]
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
        for address in suspects {
            let here = events.filter { $0.ip == address }
            let accounts = unique(here.map(\.who).filter(isAccount))
            let signedIn = unique(here.filter { $0.log == "login" && $0.event == "login_success" }.map(\.who).filter(isAccount))
            if address != context.pulledBy, signedIn.count > shared {
                found.append(Pending(.sharedAddress, "\(signedIn.count) accounts signed in from \(address), where Google saw a suspicious "
                                     + "sign-in: it may be "
                                     + "shared (an office or a VPN). Check it before securing anyone.", signedIn, [address], here.count, []))
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

        // A device registered to an account in the minutes around its sign-in from a suspect address: the attacker's own
        // computer joined to the account as it signed in. The Devices log has no address, so only the account and the time
        // tie the two.
        // The sign-in nearest the registration, from any address, decides: a person's own new computer beside their own
        // sign-in isn't the attacker's, however near a suspect one; an even tie says nothing.
        let signIns = events.filter { isAccount($0.who) && ["login", "saml"].contains($0.log) && $0.event == "login_success"
            && $0.time != nil }
        var joined: [(device: Event, signIn: Event, gap: TimeInterval)] = []
        for device in events where device.log == "mobile" && device.event == "DEVICE_REGISTER_UNREGISTER_EVENT"
            && device.parameters["ACCOUNT_STATE"] != "UNREGISTERED" && isAccount(device.who) {
            guard let at = device.time else { continue }
            // How long after each of the account's sign-ins it registered (negative: before), in the window.
            let near = signIns.filter { $0.who.lowercased() == device.who.lowercased() }
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
            found.append(Pending(.deviceAtSuspectSignIn, devices.prefix(1).uppercased() + devices.dropFirst() + " joined \(account)'s "
                                 + "account \(when) its sign-in from \(list(ips)): likely the attacker's own. Check Account lists it; "
                                 + "block or delete it in the Admin console's Devices.", [account], ips, theirs.count,
                                 [.secureAccount(account)]))
        }

        // A failed sign-in from a suspect address: someone had that account's password, likely from the fake page.
        let tried = events.filter { acting.contains($0.ip) && isAccount($0.who) && $0.log == "login" && $0.event == "login_failure" }
        let inside = Set(entered.map { $0.who.lowercased() })
        for (account, theirs) in grouped(tried) where !inside.contains(account.lowercased()) {
            found.append(Pending(.failedFromSuspect, "Someone tried \(account)'s password from \(list(unique(theirs.map(\.ip)))): they may "
                                 + "have typed it into the fake page.", [account], unique(theirs.map(\.ip)), theirs.count,
                                 [.secureAccount(account)]))
        }

        // Where each account the attacker had stands, and what to do when the lock is half done or didn't hold.
        let statuses = grouped(entered).map { account, _ in status(account, events, acting: acting, context: context) }
        for status in statuses {
            let account = status.account
            switch status.state {
            case .stillIn:
                found.append(Pending(.signedInAfterLock, "\(account) signed in from \(status.backInFrom) after the lock: the attacker may "
                                     + "still be in. Secure it again, and look for a passkey or another way back.", [account],
                                     [status.backInFrom], 1, [.secureAccount(account)]))
            case .partlyLocked:
                found.append(Pending(.partlyLocked, status.reset != nil
                                     ? "\(account)'s password was reset, but no sign-out was seen: the attacker's open sessions may still work."
                                     : "\(account) was signed out, but no password reset was seen: whoever has the password can sign in again.",
                                     [account], [], 1, [.secureAccount(account)]))
            case .locked, .notLocked:
                break
            }
            // The account's contacts printed between the attacker's first event and the lock: who the phish goes to next.
            // The Contacts log names no address, so the time ties it to the attack.
            let printed = events.filter { event in
                event.log == "contacts" && event.event == "print_contacts" && event.who.lowercased() == account.lowercased()
                    && (event.time.map { at in
                        (status.attackedAt.map { at >= $0 } ?? false) && (status.state == .stillIn || (status.lockedAt.map { at <= $0 } ?? true))
                    } ?? false)
            }
            if !printed.isEmpty {
                let count = printed.compactMap { Int($0.parameters["CONTACTS_COUNT"] ?? "") }.max()
                found.append(Pending(.contactsTaken, "\(account)'s contacts" + (count.map { " (\($0.formatted(.number.locale(Locale(identifier: "en_US")))))" } ?? "") + " were printed "
                                     + (printed.count == 1 ? "" : "\(printed.count) times ") + "while the attacker had the account: the "
                                     + "people on that list may get the phish next. Warn them not to act on it.", [account], [], printed.count, []))
            }
            if !status.newAddresses.isEmpty {
                found.append(Pending(.newAddressAfterLock, "\(account) signed in after the lock from \(list(status.newAddresses)), not seen "
                                     + "before the attack in these logs: check it's them.", [account], status.newAddresses,
                                     status.newAddresses.count, []))
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
            found.append(Pending(.leftInPlace, "From \(list(unique(theirs.map(\.ip)))), \(account)'s account got \(list(things)): a lock "
                                 + "doesn't undo \(things.count == 1 ? "it" : "them")."
                                 + (others ? " Remove what isn't theirs on the Admin console's page for them (Security), or with them in "
                                    + "their Google Account." : "")
                                 + (recovery ? " Check Account shows the recovery details, and its “Clear recovery email & phone” step "
                                    + "removes them." : "")
                                 + (blocked ? " A blocked sender's mail goes to Spam, and blocking the bounce address hides a mass send: "
                                    + "unblock it in their Gmail settings (Filters and Blocked Addresses)." : ""),
                                 [account], unique(theirs.map(\.ip)), theirs.count, recovery ? [.secureAccount(account)] : []))
        }

        // Another app reached through Google from a suspect address: that app keeps its own session, which Google's
        // sign-out doesn't end.
        let reached = events.filter { $0.log == "saml" && $0.event == "login_success" && acting.contains($0.ip) && isAccount($0.who) }
        for (account, theirs) in grouped(reached) {
            let apps = unique(theirs.compactMap { $0.parameters["application_name"] }.filter { !$0.isEmpty })
            let named = apps.isEmpty ? "another app" : list(apps)
            found.append(Pending(.otherAppSession, "\(account) signed in to \(named) through Google from \(list(unique(theirs.map(\.ip)))): "
                                 + "Google's sign-out doesn't end \(apps.count > 1 ? "those apps' sessions" : "that app's session"). "
                                 + "Sign them out there too.", [account], unique(theirs.map(\.ip)), theirs.count, []))
        }

        // The account's data exported with Google Takeout from a suspect address: it may be in the attacker's hands.
        let exported = events.filter { $0.log == "takeout" && acting.contains($0.ip) && isAccount($0.who)
            && ["STARTED_USER_TAKEOUT", "DOWNLOADED_USER_TAKEOUT", "SCHEDULED_USER_TAKEOUT"].contains($0.event) }
        for (account, theirs) in grouped(exported) {
            let products = unique(theirs.compactMap { $0.parameters["PRODUCTS_REQUESTED"] }.filter { !$0.isEmpty })
            found.append(Pending(.exportedFromSuspect, "\(account)'s data was exported with Google Takeout from "
                                 + list(unique(theirs.map(\.ip))) + (products.isEmpty ? "" : " (\(list(products)))")
                                 + ": treat it as in the attacker's hands.", [account], unique(theirs.map(\.ip)), theirs.count,
                                 [.secureAccount(account)]))
        }

        // An app acting for an account from a suspect address: the attacker's app, or theirs through the person's grant.
        let throughApp = events.filter { acting.contains($0.ip) && !$0.app.isEmpty && isAccount($0.who) }
        for (account, theirs) in grouped(throughApp) {
            let apps = unique(theirs.map(\.app)), logs = unique(theirs.map { logName($0.log) })
            found.append(Pending(.appFromSuspect, "\(list(apps)) acted for \(account) from \(list(unique(theirs.map(\.ip)))) (\(list(logs))).",
                                 [account], unique(theirs.map(\.ip)), theirs.count, [.secureAccount(account)]))
        }

        // Anything else a suspect address did as an account: Gemini asked to search a mailbox, Drive, Contacts, Calendar…
        // Not the logs other rules read, nor access evaluation, whose token checks come with every sign-in.
        let covered: Set = ["login", "token", "saml", "useraccounts", "gmail", "chat", "takeout", "chrome", "accessevaluation"]
        let other = events.filter { acting.contains($0.ip) && $0.app.isEmpty && isAccount($0.who) && !covered.contains($0.log) }
        for (account, theirs) in grouped(other) {
            let logs = unique(theirs.map { logName($0.log) })
            found.append(Pending(.actedFromSuspect, "\(account) used \(list(logs)) from \(list(unique(theirs.map(\.ip)))): see what was "
                                 + "searched, opened or changed.", [account], unique(theirs.map(\.ip)), theirs.count, [.secureAccount(account)]))
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
                                 accounts, unique(theirs.map(\.ip).filter { !$0.isEmpty }), theirs.count, []))
        }

        // Chat messages from a suspect address: phishing can go out in Chat too.
        let chatted = events.filter { $0.log == "chat" && $0.event == "message_posted" && acting.contains($0.ip) && isAccount($0.who) }
        for (account, theirs) in grouped(chatted) {
            found.append(Pending(.chatFromSuspect, "\(account) posted \(theirs.count) Chat message\(theirs.count == 1 ? "" : "s") from "
                                 + list(unique(theirs.map(\.ip))) + ": ask who got them not to open their links.", [account],
                                 unique(theirs.map(\.ip)), theirs.count, []))
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
                                 + "breached, so is this account.", [account], [], theirs.count, []))
        }
        for (account, theirs) in chrome("PASSWORD_BREACH") {
            found.append(Pending(.breachedPassword, "Chrome found a password of \(account)'s in a data breach, on \(sites(theirs)).",
                                 [account], [], theirs.count, []))
        }
        for (account, theirs) in chrome("UNSAFE_SITE_VISIT", { $0.parameters["EVENT_RESULT"] == "BYPASSED" }) {
            found.append(Pending(.pastPhishingWarning, "\(account) went past Chrome's warning to \(sites(theirs)): check whether they "
                                 + "typed a password there.", [account], [], theirs.count, []))
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
                                 unique(theirs.map(\.ip)), theirs.count, [.pullEmail(messageID: id, subject: subject)]))
        }

        let ranked = found.enumerated().sorted { a, b in
            (Finding.Kind.allCases.firstIndex(of: a.element.kind)!, a.offset) < (Finding.Kind.allCases.firstIndex(of: b.element.kind)!, b.offset)
        }.map(\.element)
        return Reading(findings: ranked.enumerated().map { index, item in
            Finding(id: "F\(index + 1)", kind: item.kind, words: item.words, accounts: item.accounts, addresses: item.addresses,
                    events: item.events, drafts: item.drafts, markable: item.markable)
        }, statuses: statuses, events: events.count)
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
    /// address after a lock starts it over: a lock after that sign-in is a new one, read the same way.
    static func status(_ account: String, _ events: [Event], acting: Set<String>, context: Context) -> Status {
        let me = account.lowercased()
        let theirs = events.filter { $0.who.lowercased() == me }
        let attackedAt = theirs.filter { acting.contains($0.ip) }.compactMap(\.time).min()
        // The addresses it signed in from before the attack: the person's own.
        let before = Set(theirs.filter { event in
            event.log == "login" && event.event == "login_success" && (event.time.map { at in attackedAt.map { at < $0 } ?? false } ?? false)
        }.map(\.ip))
        // Done to the account, oldest first. The person's own password change counts only from an address they used before
        // the attack: one from a new address may be the attacker's, from an address not yet known as theirs.
        let done = events.filter { event in
            event.time != nil && ((event.log == "admin" && event.parameters["USER_EMAIL"]?.lowercased() == me && !acting.contains(event.ip))
                || (["login", "useraccounts"].contains(event.log) && event.who.lowercased() == me
                    && (event.event != "password_edit" || before.contains(event.ip))))
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
        while true {
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
        let newAddresses = unique(after.filter { $0.log == "login" && $0.event == "login_success" && !$0.ip.isEmpty
            && !acting.contains($0.ip) && !before.contains($0.ip) }.map(\.ip))

        let unseen: String? = if lockedAt != nil { nil }
            else if !context.pulledBy.isEmpty { "a pull by one address doesn't show it (the lock is done from yours): pull by the accounts" }
            else if let read = context.read, !read.contains("admin") { "the admin log, where it would be, wasn't read" }
            else { nil }
        // A lock before the first suspect event these logs hold: the window may start after the attack did.
        let earlierLockAt = lockedAt == nil ? done.last(where: { lockSteps.contains($0.event) })?.time : nil
        let state: Status.State = backIn != nil ? .stillIn : whole != nil ? .locked : lockedAt != nil ? .partlyLocked : .notLocked
        return Status(account: account, state: state, attackedAt: attackedAt, reset: reset, signOut: signOut, suspended: suspended, lockedAt: lockedAt,
                      backInAt: backIn?.time, backInFrom: backIn?.ip ?? "", triedAt: triedAt, newAddresses: newAddresses, unseen: unseen,
                      earlierLockAt: earlierLockAt)
    }

    /// Every event that is a step of a lock.
    static let lockSteps = resets.union(signOuts).union(suspensions)

    /// A finding before it has its place (and so its ID).
    private struct Pending {
        let kind: Finding.Kind, words: String, accounts: [String], addresses: [String], events: Int, drafts: [Draft], markable: [String]
        init(_ kind: Finding.Kind, _ words: String, _ accounts: [String], _ addresses: [String], _ events: Int, _ drafts: [Draft],
             markable: [String] = []) {
            (self.kind, self.words, self.accounts, self.addresses, self.events, self.drafts, self.markable)
                = (kind, words, accounts, addresses, events, drafts, markable)
        }
    }

    /// When a device's registration is tied to a sign-in: from a minute before it (the two logs' clocks) to ten minutes
    /// after. The attacker's computer registers in the same second; the nearest sign-in from any address decides whose.
    static let deviceWindow: ClosedRange<TimeInterval> = -60...(10 * 60)

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
        case "accessevaluation": "Google's access checks"
        default: log
        }
    }

    /// An account's address: a Chrome event's computer login name ("carol") is not one, and drafts nothing.
    static func isAccount(_ who: String) -> Bool {
        let parts = who.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
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
