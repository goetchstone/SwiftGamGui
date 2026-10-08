/// Users, groups and members read from GAM's records, as GamGUI's `core/gam/models.py` reads them:
/// tolerant, since GAM's keys vary by command and version (`primaryEmail` or `email`, `name.givenName`
/// or `First Name`), and flags arrive as booleans, words or numbers. The record itself is kept for
/// detail views. Held to `Tests/Fixtures/gam_models.json` by `DirectoryTests`. A field GAM sends as text
/// is read only as text: a list or object where text belongs reads as empty.
public struct GamUser: Equatable, Sendable, Identifiable {
    public let primaryEmail: String
    public let givenName: String
    public let familyName: String
    public let suspended: Bool
    public let orgUnitPath: String
    public let isAdmin: Bool
    public let isDelegatedAdmin: Bool
    public let isEnrolledIn2SV: Bool
    /// The primary organization's title, the practical "role" for automations.
    public let title: String
    public let department: String
    public let location: String
    public let phone: String
    public let recoveryEmail: String
    public let lastLoginTime: String?
    public let aliases: [String]
    public let record: GamOutput.Record

    public var id: String { primaryEmail }

    /// The name, or the address when there is none.
    public var fullName: String {
        let name = PythonText.strip(givenName + " " + familyName)
        return name.isEmpty ? primaryEmail : name
    }

    public init(record: GamOutput.Record) {
        let name = record["name"].flatMap { $0.truthy ? $0.object : nil } ?? [:]
        let organization = Fields.primary(record["organizations"])
        let location = Fields.primary(record["locations"])
        let phone = Fields.primary(record["phones"])
        self.record = record
        primaryEmail = Fields.text(Fields.first(record, "primaryEmail", "email", "User"))
        givenName = Fields.text(Fields.truthy(Fields.first(name, "givenName")) ?? Fields.first(record, "givenName", "First Name"))
        familyName = Fields.text(Fields.truthy(Fields.first(name, "familyName")) ?? Fields.first(record, "familyName", "Last Name"))
        suspended = Fields.flag(Fields.first(record, "suspended", "Suspended"))
        orgUnitPath = Fields.first(record, "orgUnitPath", "OrgUnitPath").map(Fields.text) ?? "/"
        isAdmin = Fields.flag(Fields.first(record, "isAdmin", "Is Admin"))
        isDelegatedAdmin = Fields.flag(Fields.first(record, "isDelegatedAdmin"))
        isEnrolledIn2SV = Fields.flag(Fields.first(record, "isEnrolledIn2Sv"))
        title = Fields.text(Fields.truthy(organization["title"]) ?? Fields.truthy(Fields.first(record, "Organization Title")))
        department = Fields.text(Fields.truthy(organization["department"])
            ?? Fields.truthy(Fields.first(record, "Organization Department")))
        self.location = Fields.text(Fields.truthy(location["buildingName"]) ?? Fields.truthy(location["buildingId"]))
        self.phone = Fields.text(Fields.truthy(phone["value"]))
        recoveryEmail = Fields.text(Fields.truthy(Fields.first(record, "recoveryEmail")))
        lastLoginTime = Fields.first(record, "lastLoginTime", "Last Login Time").map(Fields.text)
        aliases = Fields.list(Fields.first(record, "aliases", "Aliases"))
    }
}

public struct GamGroup: Equatable, Sendable, Identifiable {
    public let email: String
    public let name: String
    public let description: String
    public let membersCount: Int?
    public let record: GamOutput.Record

    public var id: String { email }

    public init(record: GamOutput.Record) {
        self.record = record
        email = Fields.text(Fields.first(record, "email", "Email", "Group"))
        name = Fields.text(Fields.first(record, "name", "Name"))
        description = Fields.text(Fields.first(record, "description", "Description"))
        membersCount = Fields.first(record, "directMembersCount", "Members").flatMap(Fields.int)
    }
}

public struct GroupMember: Equatable, Sendable, Identifiable {
    public let email: String
    /// `OWNER`, `MANAGER` or `MEMBER`.
    public let role: String
    /// `USER`, `GROUP`, `CUSTOMER`…
    public let memberType: String
    public let status: String
    public let record: GamOutput.Record

    public var id: String { email }

    public init(record: GamOutput.Record) {
        self.record = record
        email = Fields.text(Fields.first(record, "email", "Email"))
        role = (Fields.first(record, "role", "Role").map(Fields.text) ?? "MEMBER").uppercased()
        memberType = (Fields.first(record, "type", "Type").map(Fields.text) ?? "USER").uppercased()
        status = Fields.text(Fields.first(record, "status", "Status"))
    }
}

/// GamGUI's field helpers, with Python's truthiness and conversions.
enum Fields {
    /// `_get`: the first key whose value is neither `null` nor `""`.
    static func first(_ record: GamOutput.Record, _ keys: String...) -> JSONValue? {
        for key in keys {
            if let value = record[key], value != .null, value != .string("") { return value }
        }
        return nil
    }

    /// Python's `value or …`: nil when the value is falsy.
    static func truthy(_ value: JSONValue?) -> JSONValue? {
        value.flatMap { $0.truthy ? $0 : nil }
    }

    /// `_primary`: the entry a Directory list marks primary, else the first, else nothing.
    static func primary(_ value: JSONValue?) -> GamOutput.Record {
        guard let items = value?.array, let first = items.first else { return [:] }
        return items.first { $0.object?["primary"]?.truthy == true }?.object ?? first.object ?? [:]
    }

    /// Python's `str()` of a scalar; empty for nothing, and for a list or object where text belongs.
    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text): text
        case .bool(let flag): flag ? "True" : "False"
        case .number(let text): text
        default: ""
        }
    }

    /// `_as_bool`: a word means true when it is true, yes, on or 1; anything else by truthiness.
    static func flag(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        if case .string(let text) = value {
            return ["true", "yes", "on", "1"].contains(PythonText.strip(text).lowercased())
        }
        return value.truthy
    }

    /// `_as_list`: a list's items as text, or a string split on whitespace and commas.
    static func list(_ value: JSONValue?) -> [String] {
        switch value {
        case .array(let items):
            return items.map(text)
        case .string(let joined):
            var parts: [String] = [], current = String.UnicodeScalarView()
            for scalar in PythonText.strip(joined).unicodeScalars {
                if PythonText.isSpace(scalar) || scalar == "," {
                    parts.append(String(current))
                    current = String.UnicodeScalarView()
                } else {
                    current.append(scalar)
                }
            }
            parts.append(String(current))
            return parts.filter { !$0.isEmpty }
        default:
            return []
        }
    }

    /// Python's `int()`, or nil where it raises: a bool is 0 or 1, a float truncates, and text is a
    /// signed run of decimal digits of any script, single underscores between them, spaces around it.
    /// Past `Int`'s range is nil (Python's ints have none; no member count gets there).
    static func int(_ value: JSONValue) -> Int? {
        switch value {
        case .bool(let flag):
            return flag ? 1 : 0
        case .number(let text):
            if let exact = Int(text) { return exact }
            guard text.unicodeScalars.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }),
                  let real = Double(text), real.isFinite, abs(real) < 9.2e18 else { return nil }
            return Int(real.rounded(.towardZero))
        case .string(let text):
            var scalars = Substring(PythonText.strip(text)).unicodeScalars[...]
            var negative = false
            if let sign = scalars.first, sign == "+" || sign == "-" {
                negative = sign == "-"
                scalars = scalars.dropFirst()
            }
            var digits = "", previousWasDigit = false
            for scalar in scalars {
                if scalar == "_" {
                    guard previousWasDigit else { return nil }
                    previousWasDigit = false
                } else if PythonText.isDecimal(scalar), let digit = scalar.properties.numericValue {
                    digits.append(String(Int(digit)))
                    previousWasDigit = true
                } else {
                    return nil
                }
            }
            guard previousWasDigit, let magnitude = Int(digits) else { return nil }
            return negative ? -magnitude : magnitude
        default:
            return nil
        }
    }
}

extension JSONValue {
    /// Python's truthiness: `null`, `false`, zero, and empty text, lists and objects are false.
    public var truthy: Bool {
        switch self {
        case .null: false
        case .bool(let flag): flag
        case .number: double.map { $0 != 0 } ?? true
        case .string(let text): !text.isEmpty
        case .array(let items): !items.isEmpty
        case .object(let members): !members.isEmpty
        }
    }
}
