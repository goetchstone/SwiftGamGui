/// Calendars read from GAM's records, as GamGUI's `core/gam/models.py` reads them (`CalendarACL`,
/// `UserCalendar`, `ResourceCalendar`): tolerant of GAM's alternate keys, every scalar read as Python's
/// `str()` of it. Held to `Tests/Fixtures/gam_models.json` by `CalendarTests`, with one listed difference:
/// the writer's label (F7, `docs/domains/calendars.md`).

/// One access rule on a calendar: who has access (the scope) and at what role.
public struct CalendarACL: Sendable, Identifiable, CustomReflectable {
    /// `user`, `group`, `domain` or `default`, lowercased.
    public let scopeType: String
    /// The address or domain; empty for `default` and a bare `domain`.
    public let scopeValue: String
    /// Stripped and lowercased, so the owner check never breaks on GAM's casing (`freeBusyReader`).
    public let role: String
    public let record: GamOutput.Record
    public let id: String

    public var customMirror: Mirror {
        Mirror(self, children: ["scopeType": scopeType, "role": role])
    }

    /// GamGUI's `from_json`: the scope's type and value, or, without a type, the rule's ID split at its first
    /// colon (`user:bob@x`, `group:g@x`, `domain:x`, `default`).
    public init(record: GamOutput.Record) {
        let scope = record["scope"]?.object ?? [:]
        var type = PythonText.strip(Fields.text(Fields.truthy(scope["type"])))
        var value = PythonText.strip(Fields.text(Fields.truthy(scope["value"])))
        if type.isEmpty {
            let rule = PythonText.strip(Fields.text(Fields.first(record, "id", "Id")))
            if !rule.isEmpty {
                let scalars = rule.unicodeScalars
                if let colon = scalars.firstIndex(of: ":") {
                    type = String(scalars[..<colon])
                    value = String(scalars[scalars.index(after: colon)...])
                } else {
                    type = rule
                    value = ""
                }
            }
        }
        self.record = record
        scopeType = PythonText.lower(type.isEmpty ? "user" : type)
        scopeValue = value
        role = PythonText.lower(PythonText.strip(Fields.text(Fields.first(record, "role", "Role"))))
        id = Fields.identity(PythonText.strip(Fields.text(Fields.first(record, "id", "Id"))))
    }

    public var isOwner: Bool { role == "owner" }

    /// GamGUI's `who`.
    public var who: String {
        switch scopeType {
        case "default": "Public (anyone)"
        case "domain": scopeValue.isEmpty ? "Entire domain" : "Everyone at \(scopeValue)"
        default: scopeValue.isEmpty ? scopeType : scopeValue
        }
    }

    /// GamGUI's `role_label`, but a writer is "Make changes to events": Google's writer can't change sharing,
    /// and GamGUI's own share picker says "Make changes" (F7).
    public var roleLabel: String { Self.label(forRole: role) }

    /// A role's words, for a rule's role as GAM printed it (any case) or as the grammar names it.
    public static func label(forRole role: String) -> String {
        switch PythonText.lower(role) {
        case "owner": "Owner"
        case "writer", "editor": "Make changes to events"
        case "writerwithoutprivateaccess": "Make changes (no private events)"
        case "reader": "See all event details"
        case "freebusyreader", "freebusy": "See free/busy only"
        case "none": "No access"
        default: role.isEmpty ? "—" : role
        }
    }

    /// GamGUI's `scope_token`: what GAM's `delete calendaracls` takes for this rule.
    public var scopeToken: String {
        switch scopeType {
        case "default": "default"
        case "domain": scopeValue.isEmpty ? "domain" : "domain:\(scopeValue)"
        case "group": "group:\(scopeValue)"
        default: scopeValue
        }
    }
}

/// A calendar in a person's calendar list, with their access to it.
public struct UserCalendar: Sendable, Identifiable, CustomReflectable {
    public let calendarID: String
    public let summary: String
    public let accessRole: String
    public let primary: Bool
    public let record: GamOutput.Record
    public var id: String { calendarID }

    public var customMirror: Mirror {
        Mirror(self, children: ["calendarID": calendarID, "accessRole": accessRole, "primary": primary])
    }

    public init(record: GamOutput.Record) {
        self.record = record
        calendarID = Fields.text(Fields.first(record, "id", "calendarId"))
        summary = Fields.text(Fields.first(record, "summary", "Summary"))
        accessRole = Fields.text(Fields.first(record, "accessRole", "accessrole"))
        primary = Fields.flag(Fields.first(record, "primary"))
    }

    /// GamGUI's row (`calendars.py:302-306`): the summary, else the ID; then `primary · ` and the access role.
    public var label: String { summary.isEmpty ? calendarID : summary }
    public var details: String { (primary ? "primary · " : "") + accessRole }
}

/// A room or other resource's calendar.
public struct ResourceCalendar: Sendable, Identifiable, CustomReflectable {
    public let resourceID: String
    public let name: String
    /// The resource's calendar ID.
    public let email: String
    public let resourceType: String
    public let buildingID: String
    public let record: GamOutput.Record
    public var id: String { email }

    public var customMirror: Mirror {
        Mirror(self, children: ["resourceID": resourceID, "email": email])
    }

    public init(record: GamOutput.Record) {
        self.record = record
        resourceID = Fields.text(Fields.first(record, "resourceId", "id", "ResourceID"))
        name = Fields.text(Fields.first(record, "resourceName", "name", "Name"))
        email = Fields.text(Fields.first(record, "resourceEmail", "email", "Email"))
        resourceType = Fields.text(Fields.first(record, "resourceType", "type"))
        buildingID = Fields.text(Fields.first(record, "buildingId"))
    }

    /// GamGUI's row (`calendars.py:215-219`): the name, else the address; the type, else "resource".
    public var label: String { name.isEmpty ? email : name }
    public var details: String { resourceType.isEmpty ? "resource" : resourceType }

    /// GamGUI's room search (`gam_connector.py:291-295`, `calendars.py:219`): the stripped query, lowercased by
    /// `str.lower()`, a substring of the name, the address or the ID, scalar by scalar; a room without an
    /// address isn't listed. GAM's own `query` is a structured filter, so GamGUI reads every room and filters.
    public static func search(_ rooms: [ResourceCalendar], query: String) -> [ResourceCalendar] {
        let needle = Array(PythonText.lower(PythonText.strip(query)).unicodeScalars)
        return rooms.filter { room in
            !room.email.isEmpty && (needle.isEmpty || [room.name, room.email, room.resourceID].contains { field in
                contains(Array(PythonText.lower(field).unicodeScalars), needle)
            })
        }
    }

    static func contains(_ text: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Bool {
        guard text.count >= needle.count else { return false }
        return (0...(text.count - needle.count)).contains { text[$0..<($0 + needle.count)].elementsEqual(needle) }
    }
}

/// The rules the Calendars screen and the person page check before a share is previewed. None changes the
/// argv for a valid one.
public enum CalendarSharing {
    /// GamGUI's share picker (`_calendar_detail.html:37`, `_calendar.html:20-25`), in its order and words.
    public static let pickerRoles: [(role: GamCommands.CalendarRole, label: String)] = [
        (.reader, "See all details"), (.freeBusyReader, "Free/busy only"), (.writer, "Make changes"),
        (.owner, "Make changes & manage"),
    ]

    /// Who GAM reads and changes `calendarID`'s rules as (`validateCalendar`, gam/__init__.py:41574-41579): an
    /// ID ending `.calendar.google.com` (a secondary, room or holiday calendar) as the admin's own sign-in, nil
    /// when the admin isn't known; any other ID as that address. Google refuses the account GAM acts as a
    /// change to its own access (F4).
    public static func actingAccount(for calendarID: String, admin: String?) -> String? {
        calendarID.unicodeScalars.reversed().starts(with: ".calendar.google.com".unicodeScalars.reversed())
            ? admin : calendarID
    }

    /// D7: GAM acts as this account for the calendar, and Google refuses it a change to its own access (F4).
    public static let ownAccessRefusal = "That's the account GAM acts as for this calendar; Google doesn't let it "
        + "change its own access."

    /// The role as a phrase for a change's summary ("Let bob@… see all event details on Team Calendar.").
    public static func roleVerb(_ role: GamCommands.CalendarRole) -> String {
        switch role {
        case .owner: "make changes and manage sharing"
        case .writer, .editor: "make changes to events"
        case .writerWithoutPrivateAccess: "make changes (no private events)"
        case .reader: "see all event details"
        case .freeBusy, .freeBusyReader: "see free/busy only"
        case .noAccess: "have no access"
        }
    }

    /// The role as Google stores it, lowercased as `CalendarACL.role` holds it (`CALENDAR_ACL_ROLES_MAP`).
    static func storedRole(_ role: GamCommands.CalendarRole) -> String {
        switch role {
        case .editor: "writer"
        case .freeBusy: "freebusyreader"
        default: role.rawValue
        }
    }

    /// What the operator should know before sharing (D5), none of which changes the argv: the person already
    /// has a rule (sharing replaces it, as Google's insert does), and what an owner can do.
    public static func warnings(target: String, role: GamCommands.CalendarRole, rules: [CalendarACL]?) -> [String] {
        var warnings: [String] = []
        let who = PythonText.lower(PythonText.strip(target))
        if let existing = rules?.first(where: { $0.scopeType == "user" && PythonText.lower($0.scopeValue) == who }) {
            if existing.role == storedRole(role) {
                warnings.append("\(target) already has this access (\(existing.roleLabel)).")
            } else {
                warnings.append("\(target) already has access (\(existing.roleLabel)): sharing changes it to "
                    + "\(CalendarACL.label(forRole: role.rawValue))." + (existing.isOwner ? " This takes away their ownership." : ""))
            }
        }
        if role == .owner { warnings.append("Owners can change sharing and delete the calendar.") }
        return warnings
    }

    /// Why a rule's token can't be sent to GAM's delete as one rule, or nil: GAM reads it as a list too (F5).
    public static func unshareProblem(_ rule: CalendarACL) -> String? {
        let token = rule.scopeToken
        guard token.isEmpty || token.unicodeScalars.contains(where: { $0 == "," || PythonText.whitespace.contains($0.value) })
        else { return nil }
        return "That rule (“\(rule.who)”) can't be removed here: GAM would read it as something else."
    }

    /// Why `target` (already stripped, as GamGUI strips it) isn't one person's address, or nil. GAM reads the
    /// share target as a list (`getEntityList`): a comma or a space makes several rules, a selector word reads a
    /// local file, a bare name gets the domain appended, and `group:`, `user:`, `domain` and `default` change
    /// the scope (F5). GamGUI's browser field (`type="email"`) let only one address through; this does too.
    public static func shareTargetProblem(_ target: String) -> String? {
        guard !Address.looksLikeEmail(target) || target.unicodeScalars.contains(":") else { return nil }
        return "“\(target)” isn't one address: enter a person's full address, like name@example.com."
    }
}

/// GAM's per-entity progress line on stderr (`printGettingEntityItemForWhom`, on by default:
/// "Getting Calendar ACLs for c_team@…"). GamError, like GamGUI's `_PROGRESS_LINE`, knows only "Getting all …",
/// and reads this as an unknown failure that outranks the real one ("Calendar Service/App not enabled"). A read
/// that prints it drops it before classifying.
public enum GettingLines {
    public static func removed(from stderr: String) -> String {
        stderr.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isGetting(PythonText.strip(String($0))) }
            .joined(separator: "\n")
    }

    /// "Getting <items> for <whom>".
    static func isGetting(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        guard scalars.starts(with: "Getting ".unicodeScalars) else { return false }
        return ResourceCalendar.contains(Array(scalars.dropFirst(8)), Array(" for ".unicodeScalars))
    }
}
