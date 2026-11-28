import Foundation

/// A group's settings (GamGUI's `core/group_settings.py`, roadmap 4.4): seven of Google's, in words, read with `info group` and
/// changed with `update group`. Each is read again before a change is held and again at the click, and only the settings that
/// change go in the argv, so Google keeps the rest. A setting the read didn't give is unknown, never a default (GAM skips an
/// abuse@ or postmaster@ group's settings without a word). Google refuses some combinations itself, said in its words.
public enum GroupSettings {
    /// GamGUI's `GROUP_SETTINGS`: GAM's word, the Groups Settings API name `info group ... formatjson` prints, the values.
    public static let table: [(key: String, field: String, values: [String])] = [
        ("whocanpostmessage", "whoCanPostMessage", ["anyone_can_post", "all_in_domain_can_post", "all_members_can_post",
                                                    "all_managers_can_post", "all_owners_can_post", "none_can_post"]),
        ("whocanjoin", "whoCanJoin", ["anyone_can_join", "all_in_domain_can_join", "can_request_to_join", "invited_can_join"]),
        ("whocanviewmembership", "whoCanViewMembership", ["all_in_domain_can_view", "all_members_can_view",
                                                          "all_managers_can_view", "all_owners_can_view"]),
        ("allowexternalmembers", "allowExternalMembers", ["true", "false"]),
        ("messagemoderationlevel", "messageModerationLevel", ["moderate_none", "moderate_new_members", "moderate_non_members",
                                                              "moderate_all_messages"]),
        ("allowwebposting", "allowWebPosting", ["true", "false"]),
        ("isarchived", "isArchived", ["true", "false"]),
    ]

    /// GamGUI's `WORDS`: each setting's name on the screen, and each value in words (Google's reference, shortened).
    public static let words: [String: (label: String, values: [String: String])] = [
        "whocanpostmessage": ("Who can post", [
            "anyone_can_post": "Anyone, outside the organization too", "all_in_domain_can_post": "Anyone in the organization",
            "all_members_can_post": "Members", "all_managers_can_post": "Managers and owners",
            "all_owners_can_post": "Owners", "none_can_post": "Nobody"]),
        "whocanjoin": ("Who can join", [
            "anyone_can_join": "Anyone, outside the organization too", "all_in_domain_can_join": "Anyone in the organization",
            "can_request_to_join": "People can ask to join", "invited_can_join": "Only people invited"]),
        "whocanviewmembership": ("Who can see the members", [
            "all_in_domain_can_view": "Anyone in the organization", "all_members_can_view": "Members",
            "all_managers_can_view": "Managers and owners", "all_owners_can_view": "Owners"]),
        "allowexternalmembers": ("Members from outside the organization", ["true": "Allowed", "false": "Not allowed"]),
        "messagemoderationlevel": ("Messages held for a moderator", [
            "moderate_none": "None", "moderate_new_members": "From new members", "moderate_non_members": "From non-members",
            "moderate_all_messages": "All of them"]),
        "allowwebposting": ("Posting from the Groups website", ["true": "Allowed", "false": "Not allowed: email only"]),
        "isarchived": ("Conversation history", ["true": "Kept", "false": "Not kept"]),
    ]

    /// An abuse@ or postmaster@ group: GAM neither reads nor writes its settings, and its update still says it was done.
    public static func skipped(_ group: String) -> Bool {
        let lower = PythonText.lower(group)
        return lower.hasPrefix("abuse@") || lower.hasPrefix("postmaster@")
    }

    public struct Setting: Sendable, Equatable, Identifiable {
        public let key: String
        public let label: String
        /// Google's value as read.
        public let google: String
        /// As GAM is given it, or nil: Google's value isn't one offered here.
        public let value: String?
        public let choices: [(value: String, words: String)]
        public var id: String { key }
        public var shown: String { words[key]?.values[value ?? ""] ?? "Google's value: \(google)" }

        public static func == (a: Setting, b: Setting) -> Bool { a.key == b.key && a.google == b.google && a.value == b.value }
    }

    public struct Change: Sendable, Equatable {
        public let key: String
        /// Google's value when previewed, as read (compared again at the click).
        public let old: String
        public let new: String
        public var label: String { words[key]?.label ?? key }
        public var before: String { words[key]?.values[PythonText.lower(old)] ?? "Google's value: \(old)" }
        public var after: String { words[key]?.values[new] ?? new }
    }

    private static func google(_ value: JSONValue?) -> String? {
        switch value {
        case .bool(let flag)?: flag ? "true" : "false"
        case .string(let text)? where !text.isEmpty: text
        case .number(let text)?: text
        default: nil
        }
    }

    /// GamGUI's `read`: each offered setting as the record has it, or nil when any is missing (unread, never a default).
    public static func read(_ record: GamOutput.Record) -> [Setting]? {
        var out: [Setting] = []
        for (key, field, values) in table {
            guard let google = google(record[field]) else { return nil }
            let lower = PythonText.lower(google)
            out.append(Setting(key: key, label: words[key]!.label, google: google, value: values.contains(lower) ? lower : nil,
                               choices: values.map { ($0, words[key]!.values[$0]!) }))
        }
        return out
    }

    /// GamGUI's `changes`: what `wanted` asks that differs from the read, in the read's order. A value not offered throws.
    public static func changes(_ now: [Setting], wanted: [String: String]) throws -> [Change] {
        var out: [Change] = []
        for setting in now {
            let new = PythonText.strip(wanted[setting.key] ?? "")
            if new.isEmpty { continue }
            guard table.first(where: { $0.key == setting.key })?.values.contains(new) == true else {
                throw GamCommands.Invalid.argument("'\(new)' isn't a value offered for \(setting.label)")
            }
            if new != setting.value { out.append(Change(key: setting.key, old: setting.google, new: new)) }
        }
        return out
    }

    /// GamGUI's `moved`: the held changes whose setting no longer reads as it did at the preview.
    public static func moved(_ held: [Change], now: [Setting]) -> [String] {
        let current = Dictionary(uniqueKeysWithValues: now.map { ($0.key, $0.google) })
        return held.filter { PythonText.lower(current[$0.key] ?? "") != PythonText.lower($0.old) }.map(\.label)
    }

    /// GamGUI's `google_said`: Google's words for a refused update, from GAM's `Group: <g>, Update Failed: <why>`, or nil.
    public static func googleSaid(_ detail: String) -> String? {
        var found: String?
        for line in detail.split(separator: "\n") {
            guard let range = line.range(of: ", Update Failed: "), line.contains("Group: ") else { continue }
            found = PythonText.strip(String(line[range.upperBound...]))
        }
        return found
    }
}
