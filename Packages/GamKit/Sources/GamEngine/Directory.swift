import Foundation

/// Users, groups and members read from GAM's records, as GamGUI's `core/gam/models.py` reads them:
/// tolerant, since GAM's keys vary by command and version (`primaryEmail` or `email`, `name.givenName`
/// or `First Name`), and flags arrive as booleans, words or numbers. The record itself is kept for
/// detail views. Held to `Tests/Fixtures/gam_models.json` by `DirectoryTests`. A list or object where
/// text belongs reads as empty (GamGUI would print its Python repr); every scalar reads as Python's
/// `str()` of it.
///
/// Not `Equatable`: comparing would walk the whole record on every SwiftUI update. Printed or dumped, a
/// model shows its own fields, not the record, so a log doesn't carry the directory.
public struct GamUser: Sendable, Identifiable, CustomReflectable {
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
    /// The name, or the address when there is none. Stored, not worked out on each read: the list sorts
    /// by it, and a sort reads it a hundred thousand times in a large directory.
    public let fullName: String
    public let record: GamOutput.Record
    /// The address, or a one-off identity for a record without one, so two such rows never share an id.
    public let id: String

    public var customMirror: Mirror {
        Mirror(self, children: ["primaryEmail": primaryEmail, "suspended": suspended, "orgUnitPath": orgUnitPath])
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
        let joined = PythonText.strip(givenName + " " + familyName)
        fullName = joined.isEmpty ? primaryEmail : joined
        id = Fields.identity(primaryEmail)
    }
}

extension GamUser {
    /// This user as a confirmed write left them, so the cached directory shows the change without a
    /// reload (GamGUI's `patch_user`). The record itself is patched and read again, so every field comes
    /// from one place: GAM's `organization … primary` sets the primary organization's title and
    /// department together.
    public func with(title: String? = nil, department: String? = nil, suspended: Bool? = nil) -> GamUser {
        var record = record
        if let suspended { record["suspended"] = .bool(suspended) }
        if title != nil || department != nil {
            var items = record["organizations"]?.array ?? []
            let index = items.firstIndex { $0.object?["primary"]?.truthy == true } ?? (items.isEmpty ? nil : 0)
            var organization = index.flatMap { items[$0].object } ?? ["primary": .bool(true)]
            if let title { organization["title"] = .string(title) }
            if let department { organization["department"] = .string(department) }
            if let index { items[index] = .object(organization) } else { items.append(.object(organization)) }
            record["organizations"] = .array(items)
            // A CSV-shaped record names them flat too, and the reader falls back to those: keep them equal,
            // or a cleared title would come back from the flat key.
            if let title, record["Organization Title"] != nil { record["Organization Title"] = .string(title) }
            if let department, record["Organization Department"] != nil { record["Organization Department"] = .string(department) }
        }
        return GamUser(record: record)
    }
}

public struct GamGroup: Sendable, Identifiable, CustomReflectable {
    public let email: String
    public let name: String
    public let description: String
    public let membersCount: Int?
    public let record: GamOutput.Record
    public let id: String

    public var customMirror: Mirror {
        Mirror(self, children: ["email": email, "membersCount": membersCount as Any])
    }

    public init(record: GamOutput.Record) {
        self.record = record
        email = Fields.text(Fields.first(record, "email", "Email", "Group"))
        name = Fields.text(Fields.first(record, "name", "Name"))
        description = Fields.text(Fields.first(record, "description", "Description"))
        membersCount = Fields.first(record, "directMembersCount", "Members").flatMap(Fields.int)
        id = Fields.identity(email)
    }
}

public struct GroupMember: Sendable, Identifiable, CustomReflectable {
    public let email: String
    /// `OWNER`, `MANAGER` or `MEMBER`.
    public let role: String
    /// `USER`, `GROUP`, `CUSTOMER`…
    public let memberType: String
    public let status: String
    public let record: GamOutput.Record
    public let id: String

    public var customMirror: Mirror {
        Mirror(self, children: ["email": email, "role": role, "memberType": memberType])
    }

    public init(record: GamOutput.Record) {
        self.record = record
        email = Fields.text(Fields.first(record, "email", "Email"))
        role = PythonText.upper(Fields.first(record, "role", "Role").map(Fields.text) ?? "MEMBER")
        memberType = PythonText.upper(Fields.first(record, "type", "Type").map(Fields.text) ?? "USER")
        status = Fields.text(Fields.first(record, "status", "Status"))
        id = Fields.identity(email)
    }
}

/// GamGUI's field helpers, with Python's truthiness and conversions.
enum Fields {
    static func identity(_ address: String) -> String {
        address.isEmpty ? "#" + UUID().uuidString : address
    }

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

    /// Python's `str()` of a scalar: `None`, `True`, `1.5` for `1.50`, `100.0` for `1E2`, `nan`. Empty
    /// for nothing given, and for a list or object (Python would print its repr).
    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text): text
        case .bool(let flag): flag ? "True" : "False"
        case .null: "None"
        case .number(let text): number(text)
        default: ""
        }
    }

    /// Python's `str()` of what `json.loads` made of a number: an `int` printed as Python prints it,
    /// a `float` as its `repr`.
    static func number(_ text: String) -> String {
        switch text {
        case "NaN": return "nan"
        case "Infinity": return "inf"
        case "-Infinity": return "-inf"
        default: break
        }
        if !text.unicodeScalars.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) {
            return text == "-0" ? "0" : text
        }
        return Double(text).map(floatRepr) ?? text
    }

    /// Python's `repr(float)`: the shortest digits that read back (as Swift's description has them),
    /// written positionally unless the decimal exponent is below -4 or above 15.
    static func floatRepr(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if value == 0 { return value.sign == .minus ? "-0.0" : "0.0" }
        var text = Substring(value.description), sign = ""
        if text.hasPrefix("-") { sign = "-"; text = text.dropFirst() }
        let parts = text.split(separator: "e", maxSplits: 1)
        let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0].split(separator: ".", maxSplits: 1)
        let whole = String(mantissa[0]), fraction = mantissa.count == 2 ? String(mantissa[1]) : ""
        var digits = whole + fraction
        var point = whole.count + exponent        // value = 0.digits x 10^point
        while digits.hasPrefix("0"), digits.count > 1 { digits.removeFirst(); point -= 1 }
        while digits.hasSuffix("0"), digits.count > 1 { digits.removeLast() }
        if point <= -4 || point > 16 {
            let tail = digits.dropFirst()
            let power = point - 1
            return sign + String(digits.first!) + (tail.isEmpty ? "" : "." + tail)
                + "e" + (power < 0 ? "-" : "+") + (abs(power) < 10 ? "0" : "") + String(abs(power))
        }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) + ".0" }
        return sign + digits.prefix(point) + "." + digits.dropFirst(point)
    }

    /// `_as_bool`: a word means true when it is true, yes, on or 1; anything else by truthiness.
    static func flag(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        if case .string(let text) = value {
            return ["true", "yes", "on", "1"].contains(PythonText.lower(PythonText.strip(text)))
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
            var scalars = Substring(PythonText.strip(text, of: PythonText.intWhitespace)).unicodeScalars[...]
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
