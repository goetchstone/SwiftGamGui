/// GAM's command catalog (`Vendor/gam7/command_catalog.json`: GamGUI's shallow parse of the vendored grammar, regenerated on each
/// GAM bump) and invariant 3's one door from it to a `GamRead`. A command runs here iff the catalog calls it confidently
/// read-only, GamGUI's verb rule checked again here agrees (so an edited catalog can't promote a write), and it isn't a
/// sensitive read (a download or a secret, which GamGUI runs only with an audit record this app doesn't keep yet). Its required
/// arguments become slots; a value is always exactly one argv element, and the keywords around it come only from the grammar
/// line. GamGUI's `core/catalog/readbuilder.py`, held to it command by command by `Tests/Fixtures/catalog_reads.json`.
public struct CommandCatalog: Sendable {
    /// GamGUI's `RiskLevel`, from the first known verb.
    public enum Risk: Int, Sendable, Hashable {
        case read = 0, change = 1, destructive = 2
    }

    /// One argument a runnable command asks for.
    public struct Slot: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable, Hashable {
            /// The person the command is about: emitted as `user <value>`.
            case targetUser = "target_user"
            case user, group, email, text
        }

        public let key: String
        public let label: String
        public let kind: Kind
        public let required: Bool
        /// The grammar's word for it (`<EmailAddress>`), or an example.
        public let placeholder: String
        public var id: String { key }
    }

    /// How a runnable command's argv is put together: the grammar's keywords as they are, and each slot's value in its place.
    enum Part: Sendable, Hashable {
        case literal(String)
        case required(String)
        case optional(String)
        /// `user <value>` or `cros <value>`, only when the value is given.
        case optionalPair(String, prefix: String)
    }

    public struct Command: Sendable, Hashable, Identifiable {
        public let id: String
        public let category: String
        public let subcategory: String
        public let name: String
        /// The grammar line, as GAM's own reference writes it.
        public let syntax: String
        public let verb: String
        public let risk: Risk
        /// No known verb: what it does can't be told, so it never runs.
        public let uncertain: Bool
        /// The short grouping the list is shown in (GamGUI's `_AREA`).
        public let area: String
        /// GamGUI makes it runnable (`_make_reads_buildable`): read-only and certain, by the catalog and by the verb rule.
        public let promoted: Bool
        /// A download or a secret (GamGUI's `_is_sensitive`): browse-only here until its run can be audited.
        public let sensitive: Bool
        /// Empty unless promoted.
        public let slots: [Slot]
        let template: [Part]

        /// It can be run from the Builder.
        public var runnable: Bool { promoted && !sensitive }
    }

    public let version: String
    public let commands: [Command]

    /// One command as the catalog file lists it.
    struct Entry: Sendable {
        let id: String
        let category: String
        let subcategory: String
        let name: String
        let syntax: String
        let verb: String
        let risk: Int
        let uncertain: Bool
    }

    /// `entries` judged: each promoted or not, by the catalog's word, the grammar line and the argv's own keywords.
    init(version: String, entries: [Entry]) {
        self.version = version
        commands = entries.map(Self.command)
    }

    /// One entry as a command. Read-only by the catalog, by the grammar line, and by the keywords its argv actually holds: the
    /// template keeps a word's first alternative and passes over fragments, so an edited line could otherwise emit a write's verb
    /// (review 2026-10-28: `gam update|print user …`), or a required `todrive`.
    static func command(_ entry: Entry) -> Command {
        let risk = Risk(rawValue: entry.risk) ?? .change
        let (slots, template) = readTemplate(entry.syntax)
        let promoted = risk == .read && !entry.uncertain && readOnly(entry.syntax) && readOnly(literals: template)
        return Command(id: entry.id, category: entry.category, subcategory: entry.subcategory, name: entry.name, syntax: entry.syntax,
                       verb: entry.verb, risk: risk, uncertain: entry.uncertain, area: area(of: entry.category), promoted: promoted,
                       sensitive: promoted && sensitive(syntax: entry.syntax, verb: verb(of: entry.syntax)),
                       slots: promoted ? slots : [], template: promoted ? template : [])
    }

    // MARK: GamGUI's verb rule (`core/catalog/parser.py`)

    /// GamGUI's `_READ`, `_DESTRUCTIVE` and `_LOW`: `CommandCatalogTests` holds them to the fixture's copy of GamGUI's.
    static let readVerbs: Set = ["print", "show", "info", "list", "get", "report", "whatis", "checkconnection", "version"]
    static let destructiveVerbs: Set = ["delete", "remove", "wipe", "suspend", "deprovision", "purge", "empty", "trash"]
    static let lowVerbs: Set = [
        "add", "update", "create", "set", "modify", "move", "copy", "sync", "transfer", "import", "rotate", "clear", "enable", "disable",
        "reenable", "send", "append", "insert", "replace", "unsuspend", "undelete", "accept", "reject", "approve", "hide", "unhide",
        "archive", "unarchive", "upload", "download", "issue", "reset", "generate", "signout", "watch", "claim", "release", "select",
        "use", "cancel", "createcontactgroup",
    ]

    /// The grammar line is confidently read-only by GamGUI's rule: among its first six words after `gam`, the first holding a
    /// known verb (one of its `|` alternatives) holds a read verb and no destructive one.
    static func readOnly(_ syntax: String) -> Bool {
        let after = words(syntax).dropFirst()
        func alternatives(_ word: Substring) -> [String] {
            word.split(separator: "|").map { PythonText.lower(PythonText.strip(String($0))) }.filter { !$0.isEmpty }
        }
        guard let verb = after.prefix(6).first(where: { word in
            alternatives(word).contains { readVerbs.contains($0) || destructiveVerbs.contains($0) || lowVerbs.contains($0) }
        }) else { return false }
        let alternativesOfVerb = alternatives(verb)
        return !alternativesOfVerb.contains(where: destructiveVerbs.contains) && alternativesOfVerb.contains(where: readVerbs.contains)
    }

    /// GAM's keywords that change things: `todrive` makes any `print` upload its result as a Sheet to the admin's Drive (a write),
    /// and `doit` lets a destructive command act. Never a value (some reads put a value where GAM reads options, `print events
    /// <EventDisplayProperty>*`), never a keyword of a runnable command's argv. Compared as GAM reads a keyword: lowercased,
    /// underscores dropped (review 2026-10-28).
    static let keywordsThatChange: Set = ["todrive", "doit"]

    static func changesThings(_ word: String) -> Bool {
        keywordsThatChange.contains(String(PythonText.lower(word).unicodeScalars.filter { $0 != "_" }))
    }

    /// The argv's own keywords, in order, are read-only by the same rule: the first known verb among them is a read verb, and none
    /// is a keyword that changes things.
    static func readOnly(literals template: [Part]) -> Bool {
        let words = template.compactMap { part -> String? in if case .literal(let word) = part { word } else { nil } }
        guard !words.contains(where: changesThings) else { return false }
        guard let verb = words.first(where: { readVerbs.contains($0) || destructiveVerbs.contains($0) || lowVerbs.contains($0) }) else {
            return false
        }
        return readVerbs.contains(verb)
    }

    /// The catalog's `verb` as GamGUI's parser makes it, from the grammar line itself (never the file's word for it): the first
    /// alternative of the first of the first six words after `gam` holding a known verb.
    static func verb(of syntax: String) -> String {
        let after = words(syntax).dropFirst()
        guard let word = after.prefix(6).first(where: { word in
            word.split(separator: "|").contains { let lower = PythonText.lower(PythonText.strip(String($0)))
                return readVerbs.contains(lower) || destructiveVerbs.contains(lower) || lowVerbs.contains(lower) }
        }) else { return "" }
        return word.split(separator: "|").map { PythonText.lower(PythonText.strip(String($0))) }.first { !$0.isEmpty } ?? ""
    }

    /// GamGUI's `str.split()`.
    static func words(_ text: String) -> [Substring] { text.split(whereSeparator: \.isWhitespace) }

    /// GamGUI's `_is_sensitive`: a `get` (every one saves a file) or a secret by name (2-Step Verification backup codes, Chrome
    /// browser enrollment tokens). As GamGUI, only when the catalog's verb is itself a word of the line before its last.
    static func sensitive(syntax: String, verb: String) -> Bool {
        let words = words(syntax).map(String.init)
        guard let at = words.dropLast().firstIndex(of: verb) else { return false }
        if verb == "get" { return true }
        let secrets: Set = ["show backupcodes", "print backupcodes", "show browsertokens", "print browsertokens"]
        return words[at + 1].split(separator: "|").contains { secrets.contains("\(verb) \($0)") }
    }

    // MARK: GamGUI's read builder (`core/catalog/readbuilder.py`)

    /// A grammar line's slots and argv template, as GamGUI's `parse_read_template`: required words become keywords or slots;
    /// optional `[...]` groups are dropped, except a person or a device on its own (kept as an optional `user <value>`) and a
    /// single optional placeholder (`info user [<UserItem>]`). A fragment of an alternation or a parenthesized group is passed
    /// over, never guessed at.
    static func readTemplate(_ syntax: String) -> ([Slot], [Part]) {
        var words = words(syntax).map(String.init)
        if words.first == "gam" { words.removeFirst() }
        var slots: [Slot] = [], template: [Part] = [], used: [String: Int] = [:], depth = 0
        func add(_ label: String, _ kind: Slot.Kind, required: Bool, placeholder: String) -> String {
            let key = "a\(slots.count)"
            used[label, default: 0] += 1
            slots.append(Slot(key: key, label: used[label] == 1 ? label : "\(label) \(used[label]!)", kind: kind, required: required,
                              placeholder: placeholder))
            return key
        }
        for (position, word) in words.enumerated() {
            let opens = word.count { $0 == "[" }, closes = word.count { $0 == "]" }
            let startDepth = depth
            depth += opens - closes
            let optional = startDepth > 0 || word.hasPrefix("[")
            let core = PythonText.strip(word, of: [0x5B, 0x5D])   // "[]"
            guard !core.isEmpty else { continue }
            let selfContained = word.hasPrefix("[") && word.hasSuffix("]") && opens == 1 && closes == 1
            let isUser = core.contains("UserTypeEntity") || (core == "<UserItem>" && position == 0)
            let isDevice = core.contains("CrOSTypeEntity") && !core.contains("UserTypeEntity")
            if isUser || isDevice, !optional || selfContained {
                let key = add(isUser ? "User" : "Device", isUser ? .targetUser : .text, required: !optional,
                              placeholder: isUser ? "user@domain" : "<CrOSDeviceID>")
                template += optional ? [.optionalPair(key, prefix: isUser ? "user" : "cros")] : [.literal(isUser ? "user" : "cros"), .required(key)]
                continue
            }
            if optional, selfContained, !core.contains(")") {
                if let placeholder = placeholder(in: core) {
                    template.append(.optional(add(humanized(placeholder), kind(of: placeholder), required: false, placeholder: placeholder)))
                }
                continue
            }
            if optional || word.contains(")") { continue }
            if let placeholder = placeholder(in: core) {
                template.append(.required(add(humanized(placeholder), kind(of: placeholder), required: true, placeholder: placeholder)))
            } else if !core.contains("("), isLiteral(core) {
                template.append(.literal(String(core.split(separator: "|")[0])))
            }
        }
        return (slots, template)
    }

    /// The first `<…>` in `word` (GamGUI's `<[^>]+>`).
    static func placeholder(in word: String) -> String? {
        var start = word.startIndex
        while let open = word[start...].firstIndex(of: "<") {
            let after = word.index(after: open)
            if let close = word[after...].firstIndex(of: ">"), close > after { return String(word[open...close]) }
            start = after
        }
        return nil
    }

    /// A keyword (`print`, `course-participants`, `3lo`) or an alternation of them (`print|show`): GamGUI's `_LITERAL` and
    /// `_LITERAL_ALT`.
    static func isLiteral(_ word: String) -> Bool {
        let parts = word.split(separator: "|", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            guard let first = part.unicodeScalars.first, isLowerOrDigit(first) else { return false }
            return part.unicodeScalars.allSatisfy { isLowerOrDigit($0) || $0 == "_" || $0 == "-" }
        }
    }

    private static func isLowerOrDigit(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) }

    /// `<RoleItem>` → "Role", `<EmailAddress>` → "Email Address" (GamGUI's `_humanize`: the first letter capitalized, the rest
    /// as written).
    static func humanized(_ placeholder: String) -> String {
        var name = String(PythonText.strip(placeholder, of: [0x3C, 0x3E, 0x5B, 0x5D]).split(separator: "|", omittingEmptySubsequences: false).first ?? "")
        for suffix in ["TypeEntity", "Entity", "List", "Item"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
            break
        }
        var spaced = "", previous: Character?
        for character in name {
            if let previous, previous.isASCII, previous.isLowercase || previous.isNumber, character.isASCII, character.isUppercase { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        spaced = PythonText.strip(spaced)
        guard let first = spaced.first else { return placeholder }
        return first.uppercased() + spaced.dropFirst()
    }

    /// GamGUI's `_slot_kind`, by the placeholder's words.
    static func kind(of placeholder: String) -> Slot.Kind {
        let lower = PythonText.lower(placeholder)
        return lower.contains("email") ? .email : lower.contains("group") ? .group : lower.contains("user") ? .user : .text
    }

    // MARK: areas

    /// The areas the list is grouped in, in order (GamGUI's `AREA_ORDER`).
    public static let areas = ["Users & Identity", "Groups", "Org & Domains", "Calendars", "Drive", "Devices", "Classroom",
                               "Security & Access", "Compliance & Audit", "Reporting", "Billing & Licensing", "Messaging", "GAM & Meta", "Other"]

    static let areaCategories: [String: [String]] = [
        "Users & Identity": ["Users", "Aliases", "Schemas", "Administrators", "Customer", "Contacts"],
        "Groups": ["Groups", "Cloud Identity Groups"],
        "Org & Domains": ["Organizational Units", "Domain", "Domains"],
        "Calendars": ["Calendars", "Resource Calendars"],
        "Drive": ["Shared Drives"],
        "Devices": ["ChromeOS Devices", "Mobile Devices", "Cloud Identity Devices", "Printers"],
        "Classroom": ["Classroom", "Classroom User Profiles"],
        "Security & Access": ["Authorization", "Context Aware Access", "Inbound SSO", "Verifications"],
        "Compliance & Audit": ["Vault/Takeout", "Alert Center", "Email Audit Monitor", "Classification Labels", "Cloud Identity Policies"],
        "Reporting": ["Reports", "Analytics Admin"],
        "Billing & Licensing": ["Licenses", "Reseller", "Cloud Channel"],
        "Messaging": ["Chat Bot", "Send Email"],
        "GAM & Meta": ["Meta Commands", "Bulk Processing", "Check connection to Google", "Addresses", "Comment", "Version and Help",
                       "Web Resourses and Sites"],
    ]

    /// GamGUI's `_area_of`: a Chrome category not listed is Devices; anything else unlisted, Other.
    static func area(of category: String) -> String {
        areaCategories.first { $0.value.contains(category) }?.key ?? (category.hasPrefix("Chrome") ? "Devices" : "Other")
    }
}
