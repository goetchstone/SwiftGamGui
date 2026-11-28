import Foundation

/// A person's organizations and phones as Google keeps them, read so that a write can send them back whole (roadmap 4.6,
/// GamGUI's `bulk_csv.organizations_from`, `phones.phones_from` and `bulk_csv.held`). Google keeps each as one list a write
/// replaces, so an entry read as fewer, or as something GAM couldn't send back unchanged, would be deleted or altered: such
/// a record is refused (`Unsendable`), never read leniently. In GamEngine so ChangeCore's check before each write
/// (`WriteStep.KeepFirst.unchanged`) compares by the same rule the plan used.
public enum BulkProfile {
    /// Why a person's lists can't go back as they are, in GamGUI's words.
    public struct Unsendable: Error, Sendable, Equatable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    public typealias Organization = GamCommands.Organization
    public typealias Phone = GamCommands.Phone

    /// Python's truthiness for a JSON value: null, false, 0, "" and empty lists or records are false.
    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: false
        case .bool(let flag)?: flag
        case .number(let text)?: Double(text).map { $0 != 0 } ?? true
        case .string(let text)?: !text.isEmpty
        case .array(let items)?: !items.isEmpty
        case .object(let fields)?: !fields.isEmpty
        }
    }

    /// Python's `str()` of a scalar the way GAM would send it back; nil for a list or record, which isn't one value.
    static func text(_ value: JSONValue?) -> String? {
        switch value {
        case nil, .null?: ""
        case .string(let text)?: text
        case .number(let text)?: text
        case .bool(let flag)?: flag ? "True" : "False"
        case .array?, .object?: nil
        }
    }

    /// GamGUI's `organizations_from`: each as GAM would send it back. One GAM couldn't send back as it is is refused: read as
    /// fewer, a write would delete the rest.
    public static func organizations(from record: GamOutput.Record) throws(Unsendable) -> [Organization] {
        let found: [JSONValue]
        switch record["organizations"] {
        case nil: found = []
        case .array(let items)?: found = items
        default: throw Unsendable("GAM's answer didn't list their organizations as organizations")
        }
        let textFields = GamCommands.organizationTextFields.map(\.google)
        let known = Set(textFields).union(["type", "customType", "fullTimeEquivalent", "primary"])
        var out: [Organization] = []
        for item in found {
            guard case .object(let o) = item else { throw Unsendable("GAM's answer didn't list their organizations as organizations") }
            let extra = Set(o.keys).subtracting(known)
            if !extra.isEmpty {
                throw Unsendable("an organization of theirs has \(extra.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }.joined(separator: ", ")), which GAM wouldn't send back")
            }
            var primary = false
            if let flag = o["primary"] {
                guard case .bool(let value) = flag else { throw Unsendable("an organization's primary isn't true or false") }
                primary = value
            }
            var fte: Int?
            switch o["fullTimeEquivalent"] {
            case nil, .null?: fte = nil
            case .number(let text)?:
                guard let value = Int(text) else { throw Unsendable("an organization's full-time equivalent isn't a number") }
                fte = value
            default: throw Unsendable("an organization's full-time equivalent isn't a number")
            }
            guard (textFields + ["type", "customType", "fullTimeEquivalent"]).contains(where: { truthy(o[$0]) }) else {
                throw Unsendable("an organization of theirs is empty, and GAM would send it back as nothing")
            }
            guard let kind = truthy(o["type"]) ? text(o["type"]) : "",
                  let customType = truthy(o["customType"]) ? text(o["customType"]) : "" else {
                throw Unsendable("an organization's type isn't one GAM sends back")
            }
            if !kind.isEmpty, !GamCommands.organizationTypes.contains(kind), !(kind == "custom" && !customType.isEmpty) {
                throw Unsendable("an organization's type “\(kind)” isn't one GAM sends back")
            }
            var fields: [(key: String, value: String)] = []
            for key in textFields where truthy(o[key]) {
                guard let value = text(o[key]) else { throw Unsendable("an organization's \(key) isn't one value") }
                fields.append((key, value))
            }
            out.append(Organization(fields: fields, type: kind, customType: customType, fullTimeEquivalent: fte, primary: primary))
        }
        return out
    }

    /// GamGUI's `phones_from`: the phones in a user record, as Google keeps them. A record that isn't the person's, or phones
    /// that aren't a list of phones, are refused: read as "no phones", the change would delete every phone they have.
    public static func phones(from record: GamOutput.Record) throws(Unsendable) -> [Phone] {
        guard truthy(record["primaryEmail"]) else { throw Unsendable("GAM's answer wasn't this person's record, so their phones aren't known") }
        let found: [JSONValue]
        switch record["phones"] {
        case nil: found = []
        case .array(let items)?: found = items
        default: throw Unsendable("GAM's answer didn't list this person's phones as phones, so they aren't known")
        }
        var out: [Phone] = []
        for item in found {
            guard case .object(let p) = item else {
                throw Unsendable("GAM's answer didn't list this person's phones as phones, so they aren't known")
            }
            var primary = false
            if let flag = p["primary"] {
                // "false" would read as primary.
                guard case .bool(let value) = flag else { throw Unsendable("GAM's answer didn't say which of this person's phones is the primary") }
                primary = value
            }
            func field(_ key: String) throws(Unsendable) -> String {
                guard truthy(p[key]) else { return "" }
                guard let value = text(p[key]) else { throw Unsendable("GAM's answer didn't list this person's phones as phones, so they aren't known") }
                return value
            }
            out.append(Phone(type: try field("type"), customType: try field("customType"), value: try field("value"), primary: primary))
        }
        return out
    }

    /// Which entry the directory shows a value from: the primary, else the first (GamGUI's `_shown`, `shown_index`).
    public static func shownIndex(_ primaries: [Bool]) -> Int? {
        primaries.firstIndex(of: true) ?? (primaries.isEmpty ? nil : 0)
    }

    /// GamGUI's `_with`: `organization` with each non-empty value set, its fields in GAM's order, only those with a value.
    public static func with(_ organization: Organization, title: String = "", department: String = "") -> Organization {
        var values: [String: String] = [:]
        for (key, value) in organization.fields { values[key] = value }
        if !title.isEmpty { values["title"] = title }
        if !department.isEmpty { values["department"] = department }
        let fields = GamCommands.organizationTextFields.map(\.google).compactMap { key in
            values[key].flatMap { $0.isEmpty ? nil : (key: key, value: $0) }
        }
        return Organization(fields: fields, type: organization.type, customType: organization.customType,
                            fullTimeEquivalent: organization.fullTimeEquivalent, primary: organization.primary)
    }

    /// GamGUI's `held`: what the run compares, the organizations and phones as they'd be sent back, and the org unit. Read by
    /// the same readers on both sides, so the directory list and a one-person read compare by what they hold, not how GAM
    /// printed them; lists those readers refuse compare as printed, and so never match a sendable one.
    public static func held(_ record: GamOutput.Record) -> String {
        var parts: [String]
        do throws(Unsendable) {
            let organizations = try organizations(from: record).map { o in
                "org(" + o.fields.map { "\($0.key)=\(JSONValue.quoted($0.value))" }.joined(separator: ",")
                    + ";type=\(JSONValue.quoted(o.type));custom=\(JSONValue.quoted(o.customType))"
                    + ";fte=\(o.fullTimeEquivalent.map(String.init) ?? "none");primary=\(o.primary))"
            }
            let phones = try phones(from: record).map { p in
                "phone(type=\(JSONValue.quoted(p.type));custom=\(JSONValue.quoted(p.customType));value=\(JSONValue.quoted(p.value));primary=\(p.primary))"
            }
            parts = ["organizations=[" + organizations.joined(separator: ",") + "]", "phones=[" + phones.joined(separator: ",") + "]"]
        } catch {
            parts = ["unsendable=" + JSONValue.dumps(.array([record["organizations"] ?? .null, record["phones"] ?? .null]))]
        }
        let unit = truthy(record["orgUnitPath"]) ? (text(record["orgUnitPath"]) ?? "/") : "/"
        return (parts + ["orgUnitPath=" + JSONValue.quoted(unit)]).joined(separator: "|")
    }

    /// The fields the check before each write reads (GamGUI's `profile_now`).
    public static let fields = ["primaryEmail", "organizations", "phones", "orgUnitPath"]
}
