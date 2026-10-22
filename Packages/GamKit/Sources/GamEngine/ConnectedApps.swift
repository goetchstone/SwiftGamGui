import Foundation

/// The apps people have given access to their account (`GamCommands.printTokens`: GAM's `print tokens`, the Directory API's
/// tokens), grouped by app: who granted it, what it may do in words, and how much that is. Answers "who has which apps and
/// AI agents connected". A name that looks like an AI assistant or agent is marked as such by its name alone.
public enum ConnectedApps {
    /// One person's grant to one app, as GAM prints it: `user,clientId,displayText,anonymous,nativeApp,userKey,scopes`, the
    /// scopes joined by GAM's CSV delimiter (a space by default).
    public struct Grant: Sendable, Equatable {
        public let user: String
        public let clientID: String
        public let name: String
        public let nativeApp: Bool
        public let scopes: [String]

        public init(record: GamOutput.Record) {
            func text(_ key: String) -> String { Fields.text(record[key]) }
            user = text("user")
            clientID = text("clientId")
            name = text("displayText")
            nativeApp = Fields.flag(record["nativeApp"])
            scopes = text("scopes").split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        }
    }

    /// How much an app may do, broadest first.
    public enum Reach: Int, Sendable, Comparable {
        /// All of someone's mail or Drive, their Gmail forwarding, admin or Cloud access.
        case broad
        /// Reading or sending mail, reading Drive, calendar or contacts.
        case some
        /// Signing in, or little else.
        case little

        public static func < (a: Reach, b: Reach) -> Bool { a.rawValue < b.rawValue }
    }

    /// The kinds of broad access, which the summary counts.
    public enum Area: String, Sendable, CaseIterable {
        /// All of Gmail, or reading and changing mail.
        case mail
        /// Gmail forwarding and delegates.
        case forwarding
        /// All of Drive.
        case drive
        /// An admin API.
        case admin
        /// Google Cloud.
        case cloud

        /// "all of Gmail or reading and changing mail".
        public var words: String {
            switch self {
            case .mail: "all of Gmail or reading and changing mail"
            case .forwarding: "Gmail forwarding and delegates"
            case .drive: "all of Drive"
            case .admin: "admin access"
            case .cloud: "Google Cloud"
            }
        }
    }

    /// One app and everyone who granted it.
    public struct App: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let users: [String]
        public let scopes: [String]
        public let nativeApp: Bool
        /// What it may do, in words, broadest first.
        public let access: [String]
        public let reach: Reach
        /// The kinds of broad access it has, in `Area`'s order.
        public let areas: [Area]
        /// Its name looks like an AI assistant or agent's (ChatGPT, Claude, Copilot, an "AI" or "agent" in the name…).
        public let looksLikeAI: Bool
    }

    /// Every grant in GAM's output.
    public static func grants(_ stdout: String) -> [Grant] {
        GamOutput.records(stdout).map(Grant.init(record:)).filter { !$0.clientID.isEmpty }
    }

    /// The grants by app: AI assistants and agents first, then the broadest reach, then the most people.
    public static func apps(_ grants: [Grant]) -> [App] {
        var byID: [String: [Grant]] = [:], order: [String] = []
        for grant in grants {
            if byID[grant.clientID] == nil { order.append(grant.clientID) }
            byID[grant.clientID, default: []].append(grant)
        }
        return order.compactMap { id -> App? in
            guard let theirs = byID[id], let first = theirs.first else { return nil }
            var seenScope: Set<String> = [], seenUser: Set<String> = []
            let scopes = theirs.flatMap(\.scopes).filter { seenScope.insert($0).inserted }
            let users = theirs.map(\.user).filter { seenUser.insert($0.lowercased()).inserted }
            let described = scopes.map(describe).sorted { $0.reach < $1.reach }
            var seenWords: Set<String> = []
            let areas = Set(described.compactMap(\.area))
            return App(id: id, name: first.name.isEmpty ? id : first.name, users: users, scopes: scopes,
                       nativeApp: theirs.contains(where: \.nativeApp),
                       access: described.map(\.words).filter { seenWords.insert($0).inserted },
                       reach: described.first?.reach ?? .little, areas: Area.allCases.filter(areas.contains),
                       looksLikeAI: looksLikeAI(first.name))
        }.sorted { a, b in
            (a.looksLikeAI ? 0 : 1, a.reach, -a.users.count, a.name.lowercased()) < (b.looksLikeAI ? 0 : 1, b.reach, -b.users.count, b.name.lowercased())
        }
    }

    /// A scope in words, with how much it reaches and, when that is broad, its kind.
    static func describe(_ scope: String) -> (words: String, reach: Reach, area: Area?) {
        let short = scope.replacingOccurrences(of: "https://www.googleapis.com/auth/", with: "")
        switch short {
        case "https://mail.google.com/", "https://mail.google.com": return ("all of Gmail (read, send, delete)", .broad, .mail)
        case "gmail.modify": return ("read and change mail", .broad, .mail)
        case "gmail.settings.sharing": return ("change Gmail forwarding and delegates", .broad, .forwarding)
        case "drive": return ("all of Drive", .broad, .drive)
        case "cloud-platform": return ("Google Cloud", .broad, .cloud)
        case "gmail.readonly": return ("read mail", .some, nil)
        case "gmail.send": return ("send mail", .some, nil)
        case "gmail.compose": return ("draft and send mail", .some, nil)
        case "gmail.insert": return ("add mail", .some, nil)
        case "gmail.settings.basic": return ("change Gmail settings", .some, nil)
        case "gmail.metadata": return ("read mail headers", .some, nil)
        case "gmail.labels": return ("manage labels", .little, nil)
        case "drive.readonly": return ("read all of Drive", .some, nil)
        case "drive.file": return ("files it made or was given", .little, nil)
        case "calendar", "calendar.events": return ("change calendars", .some, nil)
        case "calendar.readonly", "calendar.events.readonly": return ("read calendars", .some, nil)
        case "contacts", "contacts.readonly", "contacts.other.readonly", "directory.readonly": return ("read contacts", .some, nil)
        case "openid", "email", "profile", "userinfo.email", "userinfo.profile": return ("sign in with Google", .little, nil)
        default:
            if short.hasPrefix("admin.") { return ("admin: \(short.dropFirst(6))", .broad, .admin) }
            if short.hasPrefix("gmail.") { return ("Gmail: \(short.dropFirst(6))", .some, nil) }
            if short.hasPrefix("drive.") { return ("Drive: \(short.dropFirst(6))", .little, nil) }
            return (short.split(separator: "/").last.map(String.init) ?? short, .little, nil)
        }
    }

    /// Whole words in an app's name that mark an AI assistant or agent: the assistants' and automation tools' names, and
    /// the words themselves ("Read AI", "Inbox Agent"). Whole words only: "Promotion Manager" isn't Motion.
    static let aiWords: Set = ["chatgpt", "openai", "gpt", "claude", "anthropic", "copilot", "perplexity", "gemini", "zapier", "n8n",
                               "otter", "fireflies", "fathom", "motion", "reclaim", "superhuman", "grammarly", "jasper", "llm",
                               "ai", "agent", "agents", "assistant", "bot", "gpts"]

    /// The name looks like an AI assistant's or agent's: a word of `aiWords`, "ChatGPT" in "ChatGPT for Gmail", "GPT" in "GPT-4o".
    static func looksLikeAI(_ name: String) -> Bool {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { aiWords.contains(String($0)) }
    }

    /// "ChatGPT: read mail, read all of Drive — 2 people".
    public static func words(_ app: App) -> String {
        "\(app.name): " + (app.access.isEmpty ? "no scopes listed" : app.access.joined(separator: ", "))
            + " — \(app.users.count == 1 ? "1 person" : "\(app.users.count) people")"
    }

    /// What every account's apps add up to, counted by code: the summary Reports shows, and the only facts the on-device model
    /// is given to word. It holds no app's name or scopes: the app's maker wrote those, and so can an attacker.
    public struct Summary: Sendable, Equatable {
        public let apps: Int
        /// The people who granted at least one app.
        public let people: Int
        /// The apps whose names look like an AI assistant's or agent's, and the people who granted one.
        public let ai: Int
        public let aiPeople: Int
        /// The apps with broad access, and the AI ones among them.
        public let broad: Int
        public let aiBroad: Int
        /// How many apps have each kind of broad access (an app can have more than one).
        public let areas: [Area: Int]
        /// The apps only one person granted, and the AI ones and the broad ones among them.
        public let onePerson: Int
        public let onePersonAI: Int
        public let onePersonBroad: Int
        /// The most people who granted any one app.
        public let mostPeople: Int

        public init(_ apps: [App]) {
            func people(_ apps: [App]) -> Int { Set(apps.flatMap(\.users).map { $0.lowercased() }).count }
            let ai = apps.filter(\.looksLikeAI), lone = apps.filter { $0.users.count == 1 }
            self.apps = apps.count
            self.people = people(apps)
            self.ai = ai.count
            aiPeople = people(ai)
            broad = apps.filter { $0.reach == .broad }.count
            aiBroad = ai.filter { $0.reach == .broad }.count
            areas = Dictionary(apps.flatMap(\.areas).map { ($0, 1) }, uniquingKeysWith: +)
            onePerson = lone.count
            onePersonAI = lone.filter(\.looksLikeAI).count
            onePersonBroad = lone.filter { $0.reach == .broad }.count
            mostPeople = apps.map(\.users.count).max() ?? 0
        }

        /// The summary in plain words, a sentence each.
        public var sentences: [String] {
            func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
            guard apps > 0 else { return ["No account has given an app access."] }
            var lines = ["\(count(people, "person has", "people have")) given \(count(apps, "app", "apps")) access."]
            lines.append(ai == 0 ? "No app looks like an AI assistant or agent by its name."
                         : "\(count(ai, "app looks", "apps look")) like an AI assistant or agent by name, granted by "
                            + "\(count(aiPeople, "person", "people")); \(aiBroad == 0 ? "none" : "\(aiBroad)") with broad access.")
            lines.append(broad == 0 ? "No app has broad access (all of Gmail or Drive, forwarding, admin or Google Cloud)."
                         : "\(count(broad, "app has", "apps have")) broad access: "
                            + Area.allCases.compactMap { area in areas[area].map { "\($0) to \(area.words)" } }.joined(separator: ", ") + ".")
            if onePerson > 0 {
                let among = [onePersonAI > 0 ? count(onePersonAI, "that looks like AI", "that look like AI") : nil,
                             onePersonBroad > 0 ? "\(onePersonBroad) with broad access" : nil].compactMap { $0 }
                lines.append("\(count(onePerson, "app was", "apps were")) granted by one person only"
                             + (among.isEmpty ? "." : ", among them " + among.joined(separator: " and ") + "."))
            }
            lines.append("At most \(count(mostPeople, "person", "people")) granted any one app.")
            return lines
        }
    }
}
