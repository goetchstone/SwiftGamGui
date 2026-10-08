/// The closed sets and field lists GamGUI's builders use (`core/gam/commands.py`), held to the
/// fixture's `constants` by `GoldenArgvTests`. A closed set is a type, so a builder can't be handed a
/// role GAM doesn't know; `init(validating:)` ports GamGUI's validator for text that arrives free-form.
extension GamCommands {
    /// `gam print users` returns only `primaryEmail` unless fields are named; these fill the users list.
    /// `organizations` carries the job title (the practical "role" for automations).
    public static let userListFields = ["primaryEmail", "name", "suspended", "orgUnitPath", "organizations"]
    /// The detail view: identity, role and automation signals, security flags.
    public static let userDetailFields = [
        "primaryEmail", "name", "suspended", "orgUnitPath", "isAdmin", "isDelegatedAdmin",
        "isEnrolledIn2Sv", "lastLoginTime", "aliases", "organizations", "locations", "phones", "recoveryEmail",
    ]
    /// `gam print groups` likewise returns only `email` unless fields are named.
    public static let groupListFields = ["email", "name", "description", "directMembersCount"]
    public static let crosListFields = [
        "deviceId", "serialNumber", "status", "orgUnitPath", "annotatedAssetId", "annotatedUser", "lastSync", "model",
    ]
    public static let fileListFields = ["id", "name", "mimeType", "owners", "modifiedTime", "webViewLink"]
    /// Fetched once and cached: serves the users list (it needs the title), reports, and the detail
    /// view, so opening a user is instant and uses the JSON path rather than `info user`'s text.
    public static let cacheFields = [
        "primaryEmail", "name", "suspended", "orgUnitPath", "organizations",
        "isAdmin", "isDelegatedAdmin", "isEnrolledIn2Sv", "lastLoginTime", "recoveryEmail",
        "aliases", "locations", "phones",
    ]

    /// Group membership roles (Directory).
    public enum GroupRole: String, CaseIterable, Sendable {
        case member, manager, owner

        /// GamGUI's `_validate_role`: trimmed and lowercased; an empty role is `member`.
        public init(validating text: String) throws {
            guard let role = GamCommands.match(GamCommands.stripLower(text.isEmpty ? "member" : text), in: Self.self) else {
                throw Invalid.argument("invalid group role; expected member, manager or owner")
            }
            self = role
        }
    }

    /// `<CalendarACLRole>` in the vendored grammar, in its order.
    public enum CalendarRole: String, CaseIterable, Sendable {
        case editor, freeBusy = "freebusy", freeBusyReader = "freebusyreader", owner, reader, writer
        case writerWithoutPrivateAccess = "writerwithoutprivateaccess", noAccess = "none"

        /// GamGUI's `_validate_calendar_role`: trimmed and lowercased; an empty role is refused.
        public init(validating text: String) throws {
            guard let role = GamCommands.match(GamCommands.stripLower(text), in: Self.self) else {
                throw Invalid.argument("invalid calendar role; expected one of "
                    + Self.allCases.map(\.rawValue).joined(separator: ", "))
            }
            self = role
        }
    }

    /// What `forward on` does with the original copy.
    public enum ForwardAction: String, CaseIterable, Sendable {
        case keep, archive, markRead = "markread", trash, delete

        /// GamGUI's check in `set_forward`: exact, no trimming or case folding.
        public init(validating text: String) throws {
            guard let action = GamCommands.match(text, in: Self.self) else {
                throw Invalid.argument("invalid forward action")
            }
            self = action
        }
    }

    /// `[private|shared|all]` (GamCommands.txt 3599): which of the old owner's Drive files move; `all`
    /// is both. GAM sends the level only when one is named, so without one the Data Transfer API's own
    /// default decides whether files the old owner had shared move.
    public enum TransferPrivacy: String, CaseIterable, Sendable {
        case `private`, shared, all

        /// GamGUI's check in `create_datatransfer`: an empty level is none (`nil`, `if privacy:`);
        /// any other is matched exactly, with no trimming or case folding.
        public init?(validating text: String) throws {
            if text.isEmpty { return nil }
            guard let privacy = GamCommands.match(text, in: Self.self) else {
                throw Invalid.argument("invalid transfer privacy level; expected private, shared or all")
            }
            self = privacy
        }
    }

    /// How much of each message a search shows.
    public enum MessageDetail: String, CaseIterable, Sendable {
        case headers = "Headers", headersAndBody = "Headers + body", summary = "Summary"

        /// GamGUI's reading of a label in `search_messages`: an exact match, and headers for anything
        /// else (its `else`), never a refusal.
        public init(label: String) {
            self = GamCommands.match(label, in: Self.self) ?? .headers
        }
    }

    /// Python's `text.strip().lower()`, as GamGUI's validators normalize.
    static func stripLower(_ text: String) -> String {
        PythonText.strip(text).lowercased()
    }

    /// The case whose raw value has exactly `text`'s bytes. Swift's `==` and `init(rawValue:)` use
    /// canonical equivalence, which GAM doesn't (RULE-FEEDBACK: byte tripwires compare bytes).
    static func match<Choice: RawRepresentable & CaseIterable>(_ text: String, in _: Choice.Type) -> Choice?
    where Choice.RawValue == String {
        Choice.allCases.first { $0.rawValue.utf8.elementsEqual(text.utf8) }
    }
}
