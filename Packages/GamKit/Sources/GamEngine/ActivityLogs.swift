import Foundation

/// The Reports API's activity logs (`gam report <application> …`, docs/plans/2026-10-19-compromised-account.md slice 2):
/// sign-ins, app grants, Gmail, access evaluation, Chat, account changes and the rest, every one read into one row shape
/// (when, who, the event, the IP address, and the event's parameters), which the on-device log reader reads too
/// (docs/plans/2026-10-19-on-device-log-reader.md). GAM prints a CSV row per event, newest first (doReport sorts on
/// `id.time`): the activity's columns (`id.time`, `actor.email`, `ipAddress`) beside the event's (`name`, `type`, then
/// each simple parameter under its own name; a nested one, as Gmail's are, flattened under `parameters.N…`).
public enum ActivityLogs {
    public typealias Application = GamCommands.ActivityApplication

    /// How far back a pull reads, in hours: a day, three, a week, a month, six months (the Reports API keeps about six).
    public static let hours = [24, 72, 168, 720, 4_320]
    public static let defaultHours = 72
    /// Bounds each read (invariant 9): the newest this many activities per account.
    public static let cap = 1_000
    /// The Reports API reads the Gmail log at most this far back (GAM's doReport says so, init.py:14767).
    public static let gmailMaxHours = 720
    /// One read's time: GAM reads one account after another, and twenty accounts' Gmail is slow.
    public static let timeout: Duration = .seconds(600)

    /// The window `application` is read for when `hours` is asked: Gmail's at most 30 days.
    public static func window(_ application: Application, asked hours: Int) -> Int {
        application == .gmail ? min(hours, gmailMaxHours) : hours
    }

    /// Some account's events reached the cap, so its older ones weren't read: counted per account (none given: the
    /// whole read is one).
    public static func capped(_ rows: [Row], accounts: [String]) -> Bool {
        guard !accounts.isEmpty else { return rows.count >= cap }
        var counts: [String: Int] = [:]
        for row in rows { counts[row.who.lowercased(), default: 0] += 1 }
        return counts.values.contains { $0 >= cap }
    }
    /// The logs the operator read together on 2026-10-19 (sign-ins, OAuth, Gmail, Access, Chat), and account changes.
    public static let incidentDefault: [Application] = [.login, .token, .gmail, .accessEvaluation, .chat, .userAccounts]

    /// One parameter of an event: a nested one is named by its chain, `message_info.source.address`.
    public struct Parameter: Sendable, Equatable {
        public let name: String
        public let value: String
    }

    /// One event, in the one shape.
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let application: Application
        /// When, as GAM printed it (UTC unless GAM's config converts it), and as a date when it reads as one.
        public let time: String
        public let date: Date?
        public let who: String
        /// The event's name as Google reports it (`login_success`, `authorize`, `allow_token_request`…).
        public let event: String
        public let ip: String
        /// Every other column with a value, by name, in GAM's column order.
        public let parameters: [Parameter]
        /// Google itself raised it: a suspicious sign-in, a failed challenge, a denial, a block, a disabled account.
        public let flagged: Bool

        public init(record: GamOutput.Record, application: Application, index: Int) {
            self.application = application
            func text(_ key: String) -> String { Fields.text(Fields.first(record, key)) }
            time = text("id.time")
            date = try? Date(time, strategy: .iso8601)
            who = text("actor.email")
            event = text("name")
            ip = text("ipAddress")
            id = [text("id.uniqueQualifier"), time, event, String(index)].joined(separator: "|")
            parameters = ActivityLogs.parameters(record)
            let lowered = event.lowercased()
            flagged = ActivityLogs.flaggedEvents.contains(event) || ["suspicious", "blocked", "deny", "disabled", "leak", "attack"]
                .contains(where: lowered.contains)
                || Fields.flag(record["is_suspicious"])
                || (event == "login_challenge" && text("login_challenge_status").lowercased().contains("fail"))
        }

        func value(_ name: String) -> String { parameters.first { $0.name == name }?.value ?? "" }

        /// The event in words: "Signed in", "Google flagged a suspicious sign-in", "Granted an app access".
        public var words: String { ActivityLogs.words(event) }

        /// What else the event says, in words: how they signed in and the challenge, the app and its access, or (for the
        /// other logs) its first few parameters.
        public var details: [String] {
            switch application {
            case .login:
                var said: [String] = []
                let type = value("login_type"), method = value("login_challenge_method"), status = value("login_challenge_status")
                let failure = value("login_failure_type")
                if !type.isEmpty { said.append("by \(ActivityLogs.loginType(type))") }
                if !method.isEmpty { said.append("challenge: \(method.replacingOccurrences(of: "_", with: " "))") }
                if !status.isEmpty { said.append(status.lowercased()) }
                if !failure.isEmpty {
                    said.append(failure.replacingOccurrences(of: "login_failure_", with: "").replacingOccurrences(of: "_", with: " "))
                }
                if Fields.flag(.string(value("is_suspicious"))) { said.append("Google marked it suspicious") }
                return said
            case .token:
                var said: [String] = []
                let app = value("app_name"), client = value("client_id"), scope = value("scope")
                if !app.isEmpty { said.append(app) } else if !client.isEmpty { said.append("app \(client)") }
                if !scope.isEmpty { said.append("access: " + ActivityLogs.scopes(scope)) }
                return said
            default:
                return parameters.filter { !["type", "is_suspicious"].contains($0.name) }.prefix(4).map { "\($0.name): \($0.value)" }
            }
        }
    }

    /// The activity's own columns, and the counts flattenJSON writes for a list: never a parameter.
    static let activityColumns: Set = ["name", "id.time", "actor.email", "ipAddress", "id.uniqueQualifier", "id.applicationName",
                                       "id.customerId", "actor.profileId", "actor.callerType", "actor.key", "parameters"]

    /// Each simple column by name, then each nested parameter by its chain of names, in GAM's column order.
    static func parameters(_ record: GamOutput.Record) -> [Parameter] {
        var names: [String: String] = [:]
        for (key, value) in record where key.hasPrefix("parameters.") && key.hasSuffix(".name") {
            names[String(key.dropLast(5))] = Fields.text(value)
        }
        // A list's count column (flattenJSON writes `x` beside `x.0`…) is never a parameter.
        let keys = Set(record.keys)
        func isCount(_ key: String) -> Bool { keys.contains(key + ".0") }
        // GAM sorts its titles as text (`…parameter.10` before `….2`): the nested ones back in their numeric order, after
        // the simple ones in GAM's.
        func padded(_ key: String) -> String {
            key.split(separator: ".").map { part in
                part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && part.count < 9
                    ? String(repeating: "0", count: 9 - part.count) + part : String(part)
            }.joined(separator: ".")
        }
        let ordered = record.members.filter { !$0.key.hasPrefix("parameters.") }
            + record.members.filter { $0.key.hasPrefix("parameters.") }.sorted { padded($0.key) < padded($1.key) }
        var out: [Parameter] = []
        for (key, value) in ordered where !isCount(key) {
            let text = Fields.text(Fields.truthy(value))   // a short row's missing cell is null, never "None"
            guard !text.isEmpty, !activityColumns.contains(key) else { continue }
            guard key.hasPrefix("parameters.") else {
                out.append(Parameter(name: key, value: text))
                continue
            }
            // `….value`, `….intValue`, `….boolValue`, `….multiValue.N`: the value of the parameter whose prefix it has.
            let parts = key.split(separator: ".").map(String.init)
            guard let at = parts.lastIndex(where: { ["value", "intValue", "boolValue", "multiValue"].contains($0) }),
                  !(parts[at] == "multiValue" && at == parts.count - 1)   // a list's count
            else { continue }
            var chain: [String] = []
            for end in stride(from: 2, through: at, by: 1) {
                if let name = names[parts[..<end].joined(separator: ".")] { chain.append(name) }
            }
            guard !chain.isEmpty else { continue }
            let name = chain.joined(separator: ".")
            if let last = out.last, last.name == name, parts[at] == "multiValue" {
                out[out.count - 1] = Parameter(name: name, value: last.value + " " + text)
            } else {
                out.append(Parameter(name: name, value: text))
            }
        }
        // An event GAM wrote both simply and nested says each once.
        var seen: Set<String> = []
        return out.filter { seen.insert($0.name + "\u{0}" + $0.value).inserted }
    }

    /// The events Google raises itself, beside any whose name says suspicious, blocked, deny, disabled, leak or attack.
    static let flaggedEvents: Set = ["gov_attack_warning", "risky_sensitive_action_blocked", "risky_sensitive_action_allowed"]

    static func words(_ event: String) -> String {
        switch event {
        case "login_success": "Signed in"
        case "login_failure": "Sign-in failed"
        case "logout": "Signed out"
        case "login_challenge": "Asked to prove it's them"
        case "login_verification": "2-Step Verification asked"
        case "suspicious_login": "Google flagged a suspicious sign-in"
        case "suspicious_login_less_secure_app": "Google flagged a suspicious sign-in from a less secure app"
        case "suspicious_programmatic_login": "Google flagged a suspicious sign-in by a program"
        case "gov_attack_warning": "Google warned of a government-backed attack"
        case "account_disabled_hijacked": "Google disabled the account: hijacked"
        case "account_disabled_password_leak": "Google disabled the account: password leaked"
        case "account_disabled_spamming", "account_disabled_spamming_through_relay": "Google disabled the account: sending spam"
        case "account_disabled_generic": "Google disabled the account"
        case "risky_sensitive_action_allowed": "A risky sensitive action was allowed"
        case "risky_sensitive_action_blocked": "A risky sensitive action was blocked"
        case "authorize": "Granted an app access"
        case "revoke": "An app's access was revoked"
        default:
            event.replacingOccurrences(of: "_", with: " ").prefix(1).uppercased() + event.replacingOccurrences(of: "_", with: " ").dropFirst()
        }
    }

    static func loginType(_ type: String) -> String {
        switch type {
        case "google_password": "password"
        case "reauth": "signing in again"
        case "saml": "single sign-on (SAML)"
        case "exchange": "Exchange"
        case "unknown": "an unknown way"
        default: type.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// "mail.google.com, contacts.readonly" for a space-separated list of scope URLs.
    static func scopes(_ list: String) -> String {
        list.split(whereSeparator: \.isWhitespace).map { scope in
            let text = String(scope)
            for prefix in ["https://www.googleapis.com/auth/", "https://"] where text.hasPrefix(prefix) {
                return String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            return text
        }.joined(separator: ", ")
    }

    /// The report's rows, newest first as GAM sorted them.
    public static func rows(_ stdout: String, application: Application) -> [Row] {
        GamOutput.records(stdout).enumerated().map { Row(record: $1, application: application, index: $0) }
    }

    /// The addresses to look for elsewhere: each IP in `rows`, those on a flagged event first, then by how often.
    public static func addresses(in rows: [Row]) -> [String] {
        var counts: [String: (count: Int, flagged: Bool, first: Int)] = [:]
        for (index, row) in rows.enumerated() where !row.ip.isEmpty {
            let seen = counts[row.ip]
            counts[row.ip] = ((seen?.count ?? 0) + 1, (seen?.flagged ?? false) || row.flagged, seen?.first ?? index)
        }
        return counts.sorted { a, b in
            a.value.flagged != b.value.flagged ? a.value.flagged : a.value.count != b.value.count ? a.value.count > b.value.count
                : a.value.first < b.value.first
        }.map(\.key)
    }

    /// The rows as a table in the one shape, header first: the log, when, who, the event, the IP address, whether Google
    /// flagged it, and every parameter as `name: value`. For a CSV the caller makes safe to open in a spreadsheet.
    public static func table(_ rows: [Row]) -> [[String]] {
        [["log", "time", "actor", "event", "ip_address", "flagged", "parameters"]] + rows.map { row in
            [row.application.rawValue, row.time, row.who, row.event, row.ip, row.flagged ? "yes" : "",
             row.parameters.map { "\($0.name): \($0.value)" }.joined(separator: " | ")]
        }
    }
}

extension GamCommands.ActivityApplication {
    /// The log as the Admin console names it.
    public var name: String {
        switch self {
        case .login: "Sign-ins (user log)"
        case .token: "OAuth tokens (app access)"
        case .gmail: "Gmail"
        case .accessEvaluation: "Access evaluation"
        case .chat: "Chat"
        case .userAccounts: "Account changes"
        case .drive: "Drive"
        case .takeout: "Takeout"
        case .admin: "Admin console changes"
        case .mobile: "Devices"
        }
    }

    /// What reading it shows, said beside its switch.
    public var about: String {
        switch self {
        case .login: "Sign-ins, failures and challenges, and Google's suspicious-sign-in warnings: the log that matters most."
        case .token: "Apps granted or using access to the account, by app and scope."
        case .gmail: "Mail sent and received. Some editions don't keep it."
        case .accessEvaluation: "The Admin console's “Access” log: cookie validation and access-token requests."
        case .chat: "Chat messages and spaces."
        case .userAccounts: "Password, 2-Step Verification and recovery changes."
        case .drive: "Files viewed, downloaded, shared and deleted."
        case .takeout: "Exports of the account's data."
        case .admin: "What admins changed in the Admin console."
        case .mobile: "Phones and tablets syncing the account."
        }
    }
}
