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
    /// A log at the cap is read on further back, at most this many reads in all (`IncidentLogs`): `cap` times this bounds it.
    public static let pages = 10
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
    public static func capped(_ rows: [Row], accounts: [String], cap: Int = cap) -> Bool {
        guard !accounts.isEmpty else { return rows.count >= cap }
        var counts: [String: Int] = [:]
        for row in rows { counts[row.who.lowercased(), default: 0] += 1 }
        return counts.values.contains { $0 >= cap }
    }
    /// The logs an incident needs first: sign-ins, OAuth, Gmail, Access, Chat and account changes, the other ways in and out
    /// an attacker uses (sign-ins to other apps through Google, Takeout exports, phones syncing the account), Gemini (an
    /// assistant an attacker can ask to search a mailbox), the admin log, where the lock is (a password reset, a sign-out),
    /// and Contacts (a contact list printed while the attacker had the account is who the phish goes to next).
    public static let incidentDefault: [Application] = [.login, .token, .saml, .gmail, .accessEvaluation, .chat, .userAccounts,
                                                        .takeout, .mobile, .gemini, .admin, .contacts]

    /// One parameter of an event: a nested one is named by its chain, `message_info.source.address`.
    public struct Parameter: Sendable, Equatable {
        public let name: String
        public let value: String
    }

    /// One event, in the one shape.
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        /// The event itself, whichever read it came from: its activity's unique qualifier, time, name and parameters.
        /// Two reads of one log (Chrome's two matches) are merged on it.
        public let identity: String
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
        /// The AI agent that acted (the activity's `isAgenticAction`, `actor.agentAttributionInfo`), in words; empty when none.
        public let agent: String
        /// The app that acted for the person (`actor.applicationInfo`): its name, else its OAuth client ID, and whether it
        /// impersonated them; empty when the person acted themselves.
        public let app: String

        public init(record: GamOutput.Record, application: Application, index: Int) {
            self.application = application
            func text(_ key: String) -> String { Fields.text(Fields.first(record, key)) }
            time = text("id.time")
            date = try? Date(time, strategy: .iso8601)
            event = text("name")
            ip = text("ipAddress")
            parameters = ActivityLogs.parameters(record)
            identity = ([text("id.uniqueQualifier"), time, event] + parameters.map { "\($0.name)=\($0.value)" }).joined(separator: "|")
            id = [text("id.uniqueQualifier"), time, event, String(index)].joined(separator: "|")
            // A Chrome event's person is the account signed in to the profile, else the actor, else the device's user: a
            // Chromebook's account, or on a Mac or PC the computer's login name, which is still who it was.
            let profile = parameters.first { $0.name == "PROFILE_USER_NAME" }?.value ?? ""
            let device = parameters.first { $0.name == "DEVICE_USER" }?.value ?? ""
            // Google's own account warnings in the sign-in log (a suspicious sign-in it blocked, an account it disabled as
            // hijacked) have no actor: the account they're about is `affected_email_address` (a real tenant's log,
            // 2026-10-22). Where there is an actor, that parameter names someone else (a blocked sender).
            let affected = application == .login ? parameters.first { $0.name == "affected_email_address" }?.value ?? "" : ""
            who = application != .chrome ? (text("actor.email").isEmpty ? affected : text("actor.email")) : !profile.isEmpty ? profile
                : !text("actor.email").isEmpty ? text("actor.email") : device
            let lowered = event.lowercased()
            flagged = ActivityLogs.flaggedEvents.contains(event) || ["suspicious", "blocked", "deny", "disabled", "leak", "attack"]
                .contains(where: lowered.contains)
                || Fields.flag(record["is_suspicious"])
                || (event == "login_challenge" && text("login_challenge_status").lowercased().contains("fail"))
            let agentName = text("actor.agentAttributionInfo.agentName"), agentType = text("actor.agentAttributionInfo.agentType")
            let owner = text("actor.agentAttributionInfo.agentOwner.email")
            agent = agentName.isEmpty && agentType.isEmpty && !Fields.flag(record["isAgenticAction"]) ? ""
                : (agentName.isEmpty ? "an AI agent" : "the AI agent \(agentName)")
                    + (agentType.isEmpty ? "" : " (\(agentType.lowercased().replacingOccurrences(of: "_", with: " ")))")
                    + (owner.isEmpty ? "" : ", made by \(owner)")
            let appName = text("actor.applicationInfo.applicationName"), client = text("actor.applicationInfo.oauthClientId")
            // The Devices log names the device itself "Device": no app acted.
            app = (appName.isEmpty || (application == .mobile && appName == "Device")) && client.isEmpty ? ""
                : (appName.isEmpty ? "app \(client)" : appName)
                    + (Fields.flag(record["actor.applicationInfo.impersonation"]) ? " (acting as the person)" : "")
        }

        /// Who acted besides the person, in words: "by the AI agent …", "through Mail Sync Pro"; empty when they acted themselves.
        public var via: String {
            [agent.isEmpty ? "" : "by \(agent)", app.isEmpty ? "" : "through \(app)"].filter { !$0.isEmpty }.joined(separator: "; ")
        }

        func value(_ name: String) -> String { parameters.first { $0.name == name }?.value ?? "" }

        /// The event in words: "Signed in", "Google flagged a suspicious sign-in", "Granted an app access".
        public var words: String {
            switch (application, event) {
            case (.saml, "login_success"): "Signed in to an app through Google"
            case (.saml, "login_failure"): "A sign-in to an app through Google failed"
            case (.chat, "message_posted"): "Posted a Chat message"
            case (.gemini, "feature_utilization"): "Used Gemini"
            case (.mobile, "DEVICE_REGISTER_UNREGISTER_EVENT"): value("ACCOUNT_STATE") == "UNREGISTERED" ? "Unregistered a device" : "Registered a device"
            case (.mobile, "DEVICE_SYNC_EVENT"): "A device synced"
            default: ActivityLogs.words(event)
            }
        }

        /// What else the event says, in words: how they signed in and the challenge, the app and its access, or (for the
        /// other logs) its first few parameters.
        public var details: [String] { said + (via.isEmpty ? [] : [via]) }

        private var said: [String] {
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
                if event == "blocked_sender", !value("affected_email_address").isEmpty { said.append("blocked: \(value("affected_email_address"))") }
                return said
            case .token:
                var said: [String] = []
                let app = value("app_name"), client = value("client_id"), scope = value("scope")
                if !app.isEmpty { said.append(app) } else if !client.isEmpty { said.append("app \(client)") }
                if !scope.isEmpty { said.append("access: " + ActivityLogs.scopes(scope)) }
                return said
            case .chrome:
                var said: [String] = []
                let url = value("URL"), login = value("LOGIN_USER_NAME"), device = value("DEVICE_NAME")
                let platform = value("DEVICE_PLATFORM"), result = value("EVENT_RESULT"), reason = value("EVENT_REASON")
                if !url.isEmpty { said.append(url) }
                if !login.isEmpty { said.append("as \(login)") }
                if !device.isEmpty || !platform.isEmpty {
                    said.append("on " + [device, platform.isEmpty || device.isEmpty ? platform : "(\(platform))"]
                        .filter { !$0.isEmpty }.joined(separator: " "))
                }
                if !result.isEmpty { said.append(result == "BYPASSED" ? "warned, and went on anyway" : ActivityLogs.sentence(result).lowercased()) }
                if !reason.isEmpty, reason != "EVENT_REASON_UNSPECIFIED" { said.append(ActivityLogs.chromeReason(reason)) }
                return said
            case .mobile:
                // "Windows computer (Virtual Machine, Windows 10.0.19045)", its warnings in words ("is not encrypted"), then
                // what else the event says (an action, a property changed), never its identifiers.
                let type = value("DEVICE_TYPE"), about = [value("DEVICE_MODEL"), value("OS_VERSION")].filter { !$0.isEmpty }
                let device = type.isEmpty ? about.joined(separator: ", ")
                    : ActivityLogs.deviceKind(type) + (about.isEmpty ? "" : " (\(about.joined(separator: ", ")))")
                let hidden: Set = ["DEVICE_TYPE", "DEVICE_MODEL", "OS_VERSION", "ACCOUNT_STATE", "type", "DEVICE_ID", "RESOURCE_ID",
                                   "USER_EMAIL", "SERIAL_NUMBER", "IOS_VENDOR_ID", "LAST_SYNC_AUDIT_DATE"]
                func isWarning(_ name: String) -> Bool {
                    ["DEVICE_IS_", "DEVICE_HAS_", "DEVICE_OS_IS_", "DEVICE_SECURITY_PATCH_IS_"].contains { name.hasPrefix($0) }
                }
                let warnings = parameters.filter { isWarning($0.name) && Fields.flag(.string($0.value)) }
                    .map { ActivityLogs.sentence(String($0.name.dropFirst(7))).lowercased() }
                let rest = parameters.filter { !hidden.contains($0.name) && !isWarning($0.name) && !$0.name.hasPrefix("resource") }
                    .prefix(4).map { "\($0.name): \($0.value)" }
                return (device.isEmpty ? [] : [device]) + warnings + rest
            case .admin:
                // Whose account it was done to first: the admin who did it is the row's person.
                let target = value("USER_EMAIL")
                return (target.isEmpty ? [] : ["to \(target)"])
                    + parameters.filter { !["type", "USER_EMAIL"].contains($0.name) }.prefix(3).map { "\($0.name): \($0.value)" }
            default:
                return parameters.filter { !["type", "is_suspicious"].contains($0.name) }.prefix(4).map { "\($0.name): \($0.value)" }
            }
        }
    }

    /// The activity's own columns, and the counts flattenJSON writes for a list: never a parameter.
    static let activityColumns: Set = ["name", "id.time", "actor.email", "ipAddress", "id.uniqueQualifier", "id.applicationName",
                                       "id.customerId", "actor.profileId", "actor.callerType", "actor.key", "parameters",
                                       "isAgenticAction", "actor.agentAttributionInfo.agentName", "actor.agentAttributionInfo.agentType",
                                       "actor.agentAttributionInfo.agentId", "actor.agentAttributionInfo.agentOwner.email",
                                       "actor.applicationInfo.applicationName", "actor.applicationInfo.oauthClientId",
                                       "actor.applicationInfo.impersonation"]

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

    /// The events Google raises itself, beside any whose name says suspicious, blocked, deny, disabled, leak or attack:
    /// Chrome's own warnings among them (a protected password typed on another site, one found in a breach, a dangerous
    /// site or download).
    static let flaggedEvents: Set = ["gov_attack_warning", "risky_sensitive_action_blocked", "risky_sensitive_action_allowed",
                                     "PASSWORD_REUSE", "PASSWORD_BREACH", "UNSAFE_SITE_VISIT", "MALWARE_TRANSFER"]

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
        case "user_signed_out_due_to_suspicious_session_cookie": "Google signed the person out: a suspicious session cookie"
        case "blocked_sender": "Blocked a sender in Gmail"
        case "print_contacts": "Printed their contacts"
        case "passkey_enrolled": "Added a passkey"
        case "passkey_removed": "Removed a passkey"
        case "2sv_enroll": "Turned on 2-Step Verification"
        case "2sv_disable": "Turned off 2-Step Verification"
        case "password_edit": "Changed their password"
        case "recovery_email_edit": "Changed the recovery email"
        case "recovery_phone_edit": "Changed the recovery phone"
        case "recovery_secret_qa_edit": "Changed the recovery question"
        case "CHANGE_PASSWORD": "Changed a person's password"
        case "RESET_SIGNIN_COOKIES": "Signed a person out of every session"
        case "REVOKE_3LO_TOKEN": "Revoked an app's access"
        case "REVOKE_3LO_DEVICE_TOKENS": "Revoked a device's access"
        case "REVOKE_ASP": "Deleted an app password"
        case "DELETE_2SV_SCRATCH_CODES": "Deleted 2-Step Verification backup codes"
        case "SUSPEND_USER": "Suspended a person"
        case "risky_sensitive_action_allowed": "A risky sensitive action was allowed"
        case "risky_sensitive_action_blocked": "A risky sensitive action was blocked"
        case "authorize": "Granted an app access"
        case "revoke": "An app's access was revoked"
        case "LOGIN_EVENT": "Signed in to a website in Chrome"
        case "PASSWORD_REUSE": "Typed a protected password on another website"
        case "PASSWORD_BREACH": "Used a password found in a data breach"
        case "PASSWORD_CHANGED": "Changed a protected password"
        case "UNSAFE_SITE_VISIT": "Chrome warned of an unsafe website"
        case "MALWARE_TRANSFER": "Chrome found malware in a file"
        case "STARTED_USER_TAKEOUT": "Started a Takeout export of the account's data"
        case "COMPLETED_USER_TAKEOUT": "A Takeout export finished"
        case "DOWNLOADED_USER_TAKEOUT": "Downloaded a Takeout export"
        case "SCHEDULED_USER_TAKEOUT": "Scheduled repeating Takeout exports"
        default:
            sentence(event)
        }
    }

    /// `login_failure` or Chrome's `CONTENT_TRANSFER` as "Login failure", "Content transfer".
    static func sentence(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ")
        let rest = words.dropFirst()
        return words.prefix(1).uppercased() + (words.uppercased() == words ? rest.lowercased() : String(rest))
    }

    /// The Devices log's `DEVICE_TYPE` as people say it.
    static func deviceKind(_ type: String) -> String {
        switch type.uppercased() {
        case "WINDOWS": "Windows computer"
        case "MAC", "MAC_OS": "Mac"
        case "LINUX": "Linux computer"
        case "CHROME_OS": "Chromebook"
        case "IOS", "IOS_SYNC": "iPhone or iPad"
        case "ANDROID": "Android device"
        case "GOOGLE_SYNC": "device on Exchange sync"
        default: type
        }
    }

    /// Chrome's reason (`PASSWORD_REUSED_PHISHING_URL`, `UNSAFE_SITE_VISIT_SOCIAL_ENGINEERING`) in words.
    static func chromeReason(_ reason: String) -> String {
        switch reason {
        case "PASSWORD_REUSED_PHISHING_URL": "on a phishing site"
        case "PASSWORD_REUSED_UNAUTHORIZED_SITE": "on a site not on the allowed list"
        case "UNSAFE_SITE_VISIT_SOCIAL_ENGINEERING": "a phishing site"
        case "UNSAFE_SITE_VISIT_MALWARE": "a malware site"
        case "UNSAFE_SITE_VISIT_UNWANTED_SOFTWARE": "an unwanted-software site"
        case "UNSAFE_SITE_VISIT_SSL_ERROR": "a certificate error"
        default: sentence(reason).lowercased()
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
        [["log", "time", "actor", "event", "ip_address", "flagged", "via", "parameters"]] + rows.map { row in
            [row.application.rawValue, row.time, row.who, row.event, row.ip, row.flagged ? "yes" : "", row.via,
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
        case .chrome: "Chrome"
        case .saml: "SAML (sign-ins to other apps)"
        case .calendar: "Calendar"
        case .groups: "Groups"
        case .rules: "Rules"
        case .contextAwareAccess: "Context-aware access"
        case .vault: "Vault"
        case .gemini: "Gemini"
        case .meet: "Meet"
        case .contacts: "Contacts"
        case .keep: "Keep"
        case .tasks: "Tasks"
        case .adminDataAction: "Admin data actions"
        case .accessTransparency: "Access Transparency"
        case .dataStudio: "Looker Studio"
        case .groupsEnterprise: "Groups (Cloud Identity)"
        case .profile: "Profiles"
        case .ldap: "Secure LDAP"
        case .directorySync: "Directory sync"
        case .gcp: "Google Cloud"
        case .cloudSearch: "Cloud Search"
        case .classroom: "Classroom"
        case .dataMigration: "Data migration"
        case .meetHardware: "Meet hardware"
        case .assignments: "Assignments"
        case .graduation: "Graduation"
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
        case .admin: "What admins did to these accounts (a password reset, a sign-out: the lock), and what they did as admins."
        case .mobile: "Phones, tablets and computers registering or syncing: an attacker's computer can join the account as it "
            + "signs in. It records no address, so a pull by address reads its registrations for the accounts asked."
        case .saml: "Sign-ins to other apps through Google (single sign-on): which apps the account reached."
        case .calendar: "Events made, changed and shared: invitations can carry phishing too."
        case .groups: "Group settings and members: someone added to a group, a group opened to outsiders."
        case .rules: "Data protection and other rules that fired. Some editions don't keep it."
        case .contextAwareAccess: "Access that context-aware rules blocked. Some editions don't keep it."
        case .vault: "Vault searches, exports and holds: what matters when an admin's account was taken."
        case .gemini: "Gemini in Gmail, Docs, Drive and the Gemini app: what was asked and done. An attacker can ask it to find invoices "
            + "or passwords in a mailbox."
        case .meet: "Meetings hosted and joined, and who took part."
        case .contacts: "Contacts printed, exported and changed: a list printed during an attack is who the phish goes to next."
        case .keep: "Notes made, shared and changed."
        case .tasks: "Tasks made and changed."
        case .adminDataAction: "Data actions admins ran, such as exports and deletions."
        case .accessTransparency: "Google staff access to your data, and why. Some editions don't keep it."
        case .dataStudio: "Looker Studio reports and data sources made, shared and viewed."
        case .groupsEnterprise: "Group membership changes made through the Cloud Identity Groups API."
        case .profile: "Changes people made to their own profile."
        case .ldap: "Secure LDAP sign-ins and lookups by the apps that use it."
        case .directorySync: "Directory sync runs from another directory."
        case .gcp: "Google Cloud: projects, resources and who changed them."
        case .cloudSearch: "Cloud Search queries and settings."
        case .classroom: "Classroom activity."
        case .dataMigration: "Data migrated into Workspace."
        case .meetHardware: "Meet room hardware."
        case .assignments: "Assignments (education)."
        case .graduation: "Graduation (education accounts)."
        case .chrome: "Chrome's warnings and website sign-ins, by the account signed in to Chrome or a Chromebook's own. Only what "
            + "Chrome reports: empty can mean its reporting is off, not that Chrome isn't used. Events a Mac or PC ties to no "
            + "account (an extension request) show for every account only."
        }
    }
}
