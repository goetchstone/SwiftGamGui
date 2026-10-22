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

    /// What the operator knows that the logs don't: the address they pulled by (theirs to call the attacker's), and when
    /// the account was locked.
    public struct Context: Sendable, Equatable {
        public let pulledBy: String
        public let lockedAt: Date?

        public init(pulledBy: String = "", lockedAt: Date? = nil) {
            self.pulledBy = pulledBy
            self.lockedAt = lockedAt
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
            case signedInFromSuspect, appFromSuspect, actedFromSuspect, exportedFromSuspect, mailFromSuspect, passwordOnPhishingSite,
                 failedFromSuspect, chatFromSuspect, agentActed, afterLock, pastPhishingWarning, passwordOnOtherSite, breachedPassword,
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
    }

    /// Every finding, most serious first, and each draft once in the order the findings point to them.
    public struct Reading: Sendable, Equatable {
        public let findings: [Finding]
        public let events: Int

        public var drafts: [Draft] {
            var seen: Set<Draft> = []
            return findings.flatMap(\.drafts).filter { seen.insert($0).inserted }
        }
    }

    /// An address more accounts than this signed in from is likely shared (an office, a VPN): its sign-ins draft no fix.
    public static let shared = 10

    /// Google's own word that a sign-in was someone else's: a suspicious-sign-in event or one marked suspicious. Not every
    /// flag: a person's own failed challenge, or a denied cookie, is flagged too, from the office as often as anywhere.
    static func marksAttacker(_ event: Event) -> Bool {
        event.log == "login" && (event.event.hasPrefix("suspicious_") || event.event == "gov_attack_warning"
            || event.event == "account_disabled_hijacked" || ["true", "1"].contains(event.parameters["is_suspicious"]?.lowercased() ?? ""))
    }

    /// The findings in `events`. Suspect addresses are those of a sign-in Google called suspicious (`marksAttacker`), and
    /// the one the operator pulled by; never an address only because many accounts used it, which an office's does.
    public static func read(_ events: [Event], context: Context = Context()) -> Reading {
        var found: [Pending] = []
        var suspects: [String] = []
        for event in events where !event.ip.isEmpty && (marksAttacker(event) || event.ip == context.pulledBy) && !suspects.contains(event.ip) {
            suspects.append(event.ip)
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
                                 here.count, []))
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

        // A failed sign-in from a suspect address: someone had that account's password, likely from the fake page.
        let tried = events.filter { acting.contains($0.ip) && isAccount($0.who) && $0.log == "login" && $0.event == "login_failure" }
        let inside = Set(entered.map { $0.who.lowercased() })
        for (account, theirs) in grouped(tried) where !inside.contains(account.lowercased()) {
            found.append(Pending(.failedFromSuspect, "Someone tried \(account)'s password from \(list(unique(theirs.map(\.ip)))): they may "
                                 + "have typed it into the fake page.", [account], unique(theirs.map(\.ip)), theirs.count,
                                 [.secureAccount(account)]))
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

        // Anything a suspect address did after the lock.
        if let locked = context.lockedAt {
            let after = events.filter { acting.contains($0.ip) && ($0.time.map { $0 > locked } ?? false) }
            if !after.isEmpty {
                let accounts = unique(after.map(\.who).filter(isAccount))
                found.append(Pending(.afterLock, "\(after.count) event\(after.count == 1 ? "" : "s") from a suspect address after the lock"
                                     + (accounts.isEmpty ? "." : ", for " + list(accounts) + "."), accounts, unique(after.map(\.ip)),
                                     after.count, []))
            }
        }

        let ranked = found.enumerated().sorted { a, b in
            (Finding.Kind.allCases.firstIndex(of: a.element.kind)!, a.offset) < (Finding.Kind.allCases.firstIndex(of: b.element.kind)!, b.offset)
        }.map(\.element)
        return Reading(findings: ranked.enumerated().map { index, item in
            Finding(id: "F\(index + 1)", kind: item.kind, words: item.words, accounts: item.accounts, addresses: item.addresses,
                    events: item.events, drafts: item.drafts)
        }, events: events.count)
    }

    /// A finding before it has its place (and so its ID).
    private struct Pending {
        let kind: Finding.Kind, words: String, accounts: [String], addresses: [String], events: Int, drafts: [Draft]
        init(_ kind: Finding.Kind, _ words: String, _ accounts: [String], _ addresses: [String], _ events: Int, _ drafts: [Draft]) {
            (self.kind, self.words, self.accounts, self.addresses, self.events, self.drafts) = (kind, words, accounts, addresses, events, drafts)
        }
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
        case "mobile": "a phone"
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
