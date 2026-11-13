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
    public static func storedRole(_ role: GamCommands.CalendarRole) -> String {
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

    /// The group a Calendars-screen target names with GAM's explicit `group:` prefix (`<CalendarACLScope>
    /// group:<EmailAddress>`), as GamGUI's `_subscribers_for` reads it: the prefix in any case, the rest stripped. Nil
    /// for a target without the prefix.
    public static func explicitGroup(_ target: String) -> String? {
        guard PythonText.lower(target).unicodeScalars.starts(with: "group:".unicodeScalars) else { return nil }
        return PythonText.strip(String(String.UnicodeScalarView(target.unicodeScalars.dropFirst(6))))
    }

    /// Why a Calendars-screen target (a person, a group, or `group:` and one group's address) isn't one address, or nil.
    /// The same check as `shareTargetProblem`, in words that say a group can be shared too.
    public static func calendarTargetProblem(_ target: String) -> String? {
        let address = explicitGroup(target) ?? target
        guard shareTargetProblem(address) != nil else { return nil }
        return "“\(target)” isn't one address: enter one person's or group's full address, like name@example.com."
    }
}

/// One event, as GamGUI's `CalendarEvent.from_json` reads it (`models.py`): for the Calendars screen's event search and
/// its delete preview. `start` and `end` are an object's `dateTime`, else its `date`, else GAM's flattened keys; a
/// person is an object's `email`, else the flattened `.email` key. Held to `gam_models.json`'s `calendar_events`.
public struct CalendarEvent: Sendable, Identifiable, CustomReflectable {
    public let eventID: String
    /// "(no title)" for an event without one, as GamGUI shows it.
    public let summary: String
    public let start: String
    public let end: String
    public let organizer: String
    public let creator: String
    public let status: String
    public let recurrence: [String]
    public let recurringEventID: String
    public let record: GamOutput.Record
    public var id: String { eventID }

    public var customMirror: Mirror {
        Mirror(self, children: ["eventID": eventID, "start": start, "status": status])
    }

    public init(record: GamOutput.Record) {
        self.record = record
        eventID = Fields.text(Fields.first(record, "id", "eventId"))
        summary = Fields.truthy(Fields.first(record, "summary", "Summary")).map(Fields.text) ?? "(no title)"
        start = Self.when(record, "start")
        end = Self.when(record, "end")
        organizer = Self.person(record, "organizer")
        creator = Self.person(record, "creator")
        status = Fields.text(Fields.first(record, "status"))
        let rule = record["recurrence"]
        if let rules = rule?.array {
            recurrence = rules.map { Fields.text($0) }
        } else {
            recurrence = Fields.truthy(rule).map { [Fields.text($0)] } ?? []
        }
        recurringEventID = Fields.text(Fields.first(record, "recurringEventId", "recurringeventid"))
    }

    /// `_when`: an object's `dateTime or date`, else `start.dateTime or start.date or start`, each by truthiness.
    static func when(_ record: GamOutput.Record, _ prefix: String) -> String {
        if let object = record[prefix]?.object {
            return (Fields.truthy(object["dateTime"]) ?? Fields.truthy(object["date"])).map(Fields.text) ?? ""
        }
        return (Fields.truthy(record[prefix + ".dateTime"]) ?? Fields.truthy(record[prefix + ".date"])
            ?? Fields.truthy(record[prefix])).map(Fields.text) ?? ""
    }

    /// `_person`: an object's `email`, else `organizer.email or organizer`, by truthiness.
    static func person(_ record: GamOutput.Record, _ prefix: String) -> String {
        if let object = record[prefix]?.object { return Fields.truthy(object["email"]).map(Fields.text) ?? "" }
        return (Fields.truthy(record[prefix + ".email"]) ?? Fields.truthy(record[prefix])).map(Fields.text) ?? ""
    }

    /// A series (it has rules) or one of its occurrences: deleting a series' event deletes every occurrence.
    public var isRecurring: Bool { !recurrence.isEmpty || !recurringEventID.isEmpty }

    /// GamGUI's `when`: the start as Google gave it, or a dash.
    public var when: String { start.isEmpty ? "\u{2014}" : start }

    /// What a row says under the title (`_event_results.html`): when, then the organizer.
    public var details: String { organizer.isEmpty ? when : "\(when) \u{B7} \(organizer)" }
}

/// What the Calendars screen checks before a calendar is deleted (GamGUI's `calendars.py`): only a secondary calendar,
/// and only acting as its data owner while their account is active.
public enum CalendarDeletion {
    /// GamGUI's `SECONDARY_SUFFIX`: a primary calendar's ID is the person's address, a holiday or system one ends
    /// `@group.v.calendar.google.com` or holds `#`, a room's ends `@resource.calendar.google.com`.
    public static let secondarySuffix = "@group.calendar.google.com"

    /// GamGUI's `_is_secondary`: stripped and lowercased, no `#`, ending in the suffix.
    public static func isSecondary(_ calendarID: String) -> Bool {
        let id = PythonText.lower(PythonText.strip(calendarID))
        return !id.isEmpty && !id.unicodeScalars.contains("#") && id.unicodeScalars.reversed().starts(with: secondarySuffix.unicodeScalars.reversed())
    }

    /// Who the delete acts as, or why it can't be deleted here, in GamGUI's words (`_resolve_delete_owner`).
    public enum Owner: Equatable, Sendable {
        case owner(String)
        case refused(String)
    }

    public static let notSecondary = "Only secondary calendars can be deleted here. Primary, holiday and room calendars "
        + "can't be removed this way."

    /// Who the delete acts as: the calendar's data owner (Google's Calendars resource, `dataOwner`: "The email of the owner of
    /// the calendar. Set only for secondary calendars."; GAM's `print settings`, CALENDAR_SETTINGS_FIELDS_CHOICE_MAP), and only
    /// while that account is active (`active`, lowercased). Never another owner instead: Google gives a secondary calendar one
    /// data owner, and only they can delete it. A deliberate difference from GamGUI's `_resolve_delete_owner`, which acted as
    /// the first active `owner` rule in GAM's order (`_owner_candidates`, `_pick_owner`): a co-owner who isn't the data owner.
    public static func owner(of calendarID: String, dataOwner: String?, active: Set<String>) -> Owner {
        guard isSecondary(calendarID) else { return .refused(notSecondary) }
        let owner = PythonText.strip(dataOwner ?? "")
        guard !owner.isEmpty else { return .refused(noOwner) }
        guard active.contains(PythonText.lower(owner)) else {
            return .refused("\(owner), the calendar's owner, is suspended or no longer exists \u{2014} transfer ownership to an "
                + "active user, then delete.")
        }
        return .owner(owner)
    }

    /// GamGUI's words for a calendar with no owner account to act as.
    public static let noOwner = "Couldn't find an owner account to act as \u{2014} the calendar's owner may have been deleted. "
        + "Transfer ownership to an active user first."

    /// The data owner `print settings` names (`calendarId,JSON`, the JSON's `dataOwner`), or nil when it names none.
    public static func dataOwner(_ records: [GamOutput.Record]) -> String? {
        guard let record = records.first else { return nil }
        let owner = PythonText.strip(Fields.text(Fields.first(record, "dataOwner")))
        return owner.isEmpty ? nil : owner
    }


    /// GamGUI's exact-case gate: the word typed, stripped, must be `DELETE`.
    public static let typedWord = "DELETE"
    public static let typedRefusal = "Type DELETE (in capitals) to confirm."

    public static func typedMatches(_ typed: String) -> Bool {
        PythonText.strip(typed).utf8.elementsEqual(typedWord.utf8)
    }
}
