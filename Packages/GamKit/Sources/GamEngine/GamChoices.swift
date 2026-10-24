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

    /// `[private|shared|all]` (GamCommands.txt 3604): which of the old owner's Drive files move; `all`
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

    /// One email's Message-ID, pasted from its headers, as the Phishing screen searches for it: the email is then
    /// `rfc822msgid:<id>` in one Gmail query, a single argv element (`query`), so the ID is checked as one and can't
    /// carry another Gmail operator. RFC 5322 §3.6.4 `msg-id` is `"<" id-left "@" id-right ">"`; this takes each side as
    /// its `dot-atom-text` (atoms of `atext` joined by single dots), which has no space, quote, parenthesis, colon,
    /// comma or backslash, so nothing in it can end the term or start another operator. Gmail's search syntax keeps
    /// `{ }` (its OR group) of what's left, so those are refused too, and `*`, in case a search reads it as a wildcard
    /// (unverified, and rare in a Message-ID; review of 2026-10-19), and so are the obsolete and bracketed-literal
    /// forms no current mailer sends. ASCII only, at most the RFC's 998-character line.
    public struct MessageID: Sendable, Equatable {
        /// `id-left@id-right`, without the angle brackets: Gmail's `rfc822msgid:` takes it bare.
        public let id: String

        /// At most this many emails in one Find on Phishing (Pull All, invariant 9): each is two domain-wide reads.
        public static let mostPerFind = 100

        /// RFC 5322's `atext`, less Gmail's `{` and `}`, and `*`.
        static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'+-/=?^_`|~".unicodeScalars)
        static let lineLimit = 998

        /// What an operator copies: the bare ID, `<id>`, the whole `Message-ID: <id>` header line, or a search they
        /// already wrote as `rfc822msgid:id`. Anything else is refused with what's wrong, never repaired.
        public init(validating text: String) throws {
            var value = PythonText.strip(text)
            for label in ["message-id:", "rfc822msgid:"] where Self.hasPrefix(value, label) {
                value = PythonText.strip(String(String.UnicodeScalarView(value.unicodeScalars.dropFirst(label.unicodeScalars.count))))
            }
            if value.unicodeScalars.first == "<", value.unicodeScalars.last == ">", value.unicodeScalars.count > 1 {
                value = String(String.UnicodeScalarView(value.unicodeScalars.dropFirst().dropLast()))
            }
            let scalars = Array(value.unicodeScalars)
            guard !scalars.isEmpty else {
                throw Invalid.argument("Paste the email's Message-ID, from its headers (in Gmail, More › Show original).")
            }
            guard scalars.count <= Self.lineLimit else {
                throw Invalid.argument("That's longer than any Message-ID can be (\(Self.lineLimit) characters).")
            }
            if scalars.contains(where: { $0.properties.isWhitespace }) {
                throw Invalid.argument("A Message-ID has no spaces: paste only its value, like <…@mail.example.com>.")
            }
            if scalars.contains("{") || scalars.contains("}") {
                throw Invalid.argument("This Message-ID has { or }, which Gmail's search reads as its own syntax, so it can't be searched for exactly.")
            }
            // By scalar, before anything is split: a combining mark can't then hide an @ or a dot inside a character.
            if let odd = scalars.first(where: { $0 != "@" && $0 != "." && !Self.allowed.contains($0) }) {
                let hex = String(odd.value, radix: 16, uppercase: true)
                let shown = (0x21...0x7E).contains(odd.value) ? "“\(odd)”" : "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                throw Invalid.argument("A Message-ID can't contain \(shown): paste it exactly as the header has it.")
            }
            let sides = scalars.split(separator: "@", omittingEmptySubsequences: false)
            guard sides.count == 2 else {
                throw Invalid.argument("A Message-ID has exactly one @, like <…@mail.example.com>.")
            }
            guard sides.allSatisfy({ $0.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty } })
            else { throw Invalid.argument("Each side of a Message-ID's @ is words joined by single dots, with none at either end.") }
            id = value
        }

        /// Every copy but the sender's own: `-in:sent` keeps the Sent copy in the account that sent it, as evidence.
        public var query: String { "rfc822msgid:\(id) -in:sent" }

        /// Every copy in one mailbox, Sent included: the sender's own is the only one that keeps the Bcc header.
        public var anyCopyQuery: String { "rfc822msgid:\(id)" }

        /// The copies Gmail filed to Spam, which `query` can't reach through `trash messages` (it lists without Spam).
        public var spamQuery: String { "rfc822msgid:\(id) in:spam" }

        /// `text` begins with `label`, ASCII letters in any case.
        static func hasPrefix(_ text: String, _ label: String) -> Bool {
            let head = text.unicodeScalars.prefix(label.unicodeScalars.count)
            return PythonText.lower(String(String.UnicodeScalarView(head))).unicodeScalars.elementsEqual(label.unicodeScalars)
        }
    }

    /// Python's `text.strip().lower()`, as GamGUI's validators normalize.
    static func stripLower(_ text: String) -> String {
        PythonText.lower(PythonText.strip(text))
    }

    /// The case whose raw value has exactly `text`'s bytes. Swift's `==` and `init(rawValue:)` use
    /// canonical equivalence, which GAM doesn't (RULE-FEEDBACK: byte tripwires compare bytes).
    static func match<Choice: RawRepresentable & CaseIterable>(_ text: String, in _: Choice.Type) -> Choice?
    where Choice.RawValue == String {
        Choice.allCases.first { $0.rawValue.utf8.elementsEqual(text.utf8) }
    }
}
