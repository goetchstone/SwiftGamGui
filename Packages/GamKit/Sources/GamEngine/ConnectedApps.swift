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
            return App(id: id, name: first.name.isEmpty ? id : first.name, users: users, scopes: scopes,
                       nativeApp: theirs.contains(where: \.nativeApp),
                       access: described.map(\.words).filter { seenWords.insert($0).inserted },
                       reach: described.first?.reach ?? .little, looksLikeAI: looksLikeAI(first.name))
        }.sorted { a, b in
            (a.looksLikeAI ? 0 : 1, a.reach, -a.users.count, a.name.lowercased()) < (b.looksLikeAI ? 0 : 1, b.reach, -b.users.count, b.name.lowercased())
        }
    }

    /// A scope in words, with how much it reaches.
    static func describe(_ scope: String) -> (words: String, reach: Reach) {
        let short = scope.replacingOccurrences(of: "https://www.googleapis.com/auth/", with: "")
        switch short {
        case "https://mail.google.com/", "https://mail.google.com": return ("all of Gmail (read, send, delete)", .broad)
        case "gmail.modify": return ("read and change mail", .broad)
        case "gmail.settings.sharing": return ("change Gmail forwarding and delegates", .broad)
        case "drive": return ("all of Drive", .broad)
        case "cloud-platform": return ("Google Cloud", .broad)
        case "gmail.readonly": return ("read mail", .some)
        case "gmail.send": return ("send mail", .some)
        case "gmail.compose": return ("draft and send mail", .some)
        case "gmail.insert": return ("add mail", .some)
        case "gmail.settings.basic": return ("change Gmail settings", .some)
        case "gmail.metadata": return ("read mail headers", .some)
        case "gmail.labels": return ("manage labels", .little)
        case "drive.readonly": return ("read all of Drive", .some)
        case "drive.file": return ("files it made or was given", .little)
        case "calendar", "calendar.events": return ("change calendars", .some)
        case "calendar.readonly", "calendar.events.readonly": return ("read calendars", .some)
        case "contacts", "contacts.readonly", "contacts.other.readonly", "directory.readonly": return ("read contacts", .some)
        case "openid", "email", "profile", "userinfo.email", "userinfo.profile": return ("sign in with Google", .little)
        default:
            if short.hasPrefix("admin.") { return ("admin: \(short.dropFirst(6))", .broad) }
            if short.hasPrefix("gmail.") { return ("Gmail: \(short.dropFirst(6))", .some) }
            if short.hasPrefix("drive.") { return ("Drive: \(short.dropFirst(6))", .little) }
            return (short.split(separator: "/").last.map(String.init) ?? short, .little)
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
}
