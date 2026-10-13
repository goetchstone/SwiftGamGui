import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// GamGUI parity for reading calendar records (invariant 11): every record in `gam_models.json`'s calendar
/// sections, GamGUI's `CalendarACL`, `UserCalendar` and `ResourceCalendar` over the mock's reads and seeded
/// variants, gives the same fields. One deliberate difference, listed here: the writer label (F7). And the
/// pure rules the Calendars screen checks before a preview: who GAM acts as, and a share target that is one
/// address.
@Suite("Calendar models")
struct CalendarTests {
    struct Fixture<Model: Decodable>: Decodable {
        let record: String
        let model: Model

        var value: GamOutput.Record { JSONValue.parse(record)?.object ?? [:] }
    }

    struct ACL: Decodable {
        let scope_type: String, scope_value: String, role: String, who: String, role_label: String, scope_token: String
    }

    struct Listed: Decodable {
        let id: String, summary: String, access_role: String, primary: Bool
    }

    struct Room: Decodable {
        let resource_id: String, name: String, email: String, resource_type: String, building_id: String
    }

    struct Document: Decodable {
        let calendar_acls: [Fixture<ACL>]
        let user_calendars: [Fixture<Listed>]
        let resources: [Fixture<Room>]
    }

    let document = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.gamModelsJSON))

    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    static func record(_ json: String) -> GamOutput.Record { JSONValue.parse(json)?.object ?? [:] }

    /// GamGUI's `role_label` calls a writer (and an editor, GAM's word for one) "Make changes & manage sharing";
    /// Google's writer can't change sharing, and GamGUI's own share picker says "Make changes" (F7). The one
    /// label this app says differently.
    static let writerLabel = "Make changes to events"

    @Test func aclsReadAsGamGUIReadsThem() {
        var relabelled = 0
        for item in document.calendar_acls {
            let acl = CalendarACL(record: item.value), want = item.model
            let label = "\(item.value)"
            #expect(Self.same(acl.scopeType, want.scope_type) && Self.same(acl.scopeValue, want.scope_value), "scope \(label)")
            #expect(Self.same(acl.role, want.role), "role \(label)")
            #expect(Self.same(acl.who, want.who), "who \(label)")
            #expect(Self.same(acl.scopeToken, want.scope_token), "token \(label)")
            if ["writer", "editor"].contains(PythonText.lower(want.role)) {
                #expect(want.role_label == "Make changes & manage sharing" && acl.roleLabel == Self.writerLabel, "label \(label)")
                relabelled += 1
            } else {
                #expect(Self.same(acl.roleLabel, want.role_label), "label \(label)")
            }
        }
        #expect(document.calendar_acls.count > 150 && relabelled > 3)
        // GamGUI's own test (`test_calendar_acl_parse_user_and_default`), with the writer label as this app says it.
        let user = CalendarACL(record: Self.record(#"{"id": "user:bob@e.com", "role": "writer", "scope": {"type": "user", "value": "bob@e.com"}}"#))
        #expect(user.who == "bob@e.com" && user.roleLabel == Self.writerLabel && user.scopeToken == "bob@e.com")
        let pub = CalendarACL(record: Self.record(#"{"id": "default", "role": "freebusyreader"}"#))
        #expect(pub.scopeType == "default" && pub.who == "Public (anyone)")
        #expect(pub.roleLabel == "See free/busy only" && pub.scopeToken == "default")
        #expect(!pub.isOwner && CalendarACL(record: Self.record(#"{"id": "user:a@e.com", "role": " OWNER "}"#)).isOwner)
    }

    @Test func userCalendarsReadAsGamGUIReadsThem() {
        for item in document.user_calendars {
            let calendar = UserCalendar(record: item.value), want = item.model
            #expect(Self.same(calendar.calendarID, want.id) && Self.same(calendar.summary, want.summary)
                    && Self.same(calendar.accessRole, want.access_role) && calendar.primary == want.primary, "\(item.value)")
        }
        #expect(document.user_calendars.count > 150)
        // `test_resource_and_user_calendar_parse`, and GamGUI's row text (`calendars.py:302-306`).
        let alice = UserCalendar(record: Self.record(#"{"id": "a@e.com", "summary": "Alice", "accessRole": "owner", "primary": true}"#))
        #expect(alice.primary && alice.accessRole == "owner")
        #expect(alice.label == "Alice" && alice.details == "primary · owner")
        let untitled = UserCalendar(record: Self.record(#"{"id": "c_x@group.calendar.google.com", "accessRole": "reader"}"#))
        #expect(untitled.label == "c_x@group.calendar.google.com" && untitled.details == "reader")
    }

    @Test func roomsReadAsGamGUIReadsThem() {
        for item in document.resources {
            let room = ResourceCalendar(record: item.value), want = item.model
            #expect(Self.same(room.resourceID, want.resource_id) && Self.same(room.name, want.name)
                    && Self.same(room.email, want.email) && Self.same(room.resourceType, want.resource_type)
                    && Self.same(room.buildingID, want.building_id), "\(item.value)")
        }
        #expect(document.resources.count > 150)
        let room = ResourceCalendar(record: Self.record(#"{"resourceId": "room-1", "resourceName": "Aspen", "#
                                                               + #""resourceEmail": "aspen@resource.calendar.google.com", "resourceType": "Room"}"#))
        #expect(room.email.hasPrefix("aspen@") && room.name == "Aspen" && room.resourceType == "Room")
        // GamGUI's row text (`calendars.py:215-219`): the name, else the address; the type, else "resource".
        #expect(room.label == "Aspen" && room.details == "Room")
        let bare = ResourceCalendar(record: Self.record(#"{"resourceEmail": "x@resource.calendar.google.com"}"#))
        #expect(bare.label == "x@resource.calendar.google.com" && bare.details == "resource")
    }

    /// GamGUI's room search (`gam_connector.py:291-295`): the stripped query, lowercased by `str.lower()`, a
    /// substring of the name, the address or the ID; rooms without an address dropped (`calendars.py:219`).
    @Test func roomSearchIsGamGUIs() {
        let rooms = [
            ResourceCalendar(record: Self.record(#"{"resourceId": "1001", "resourceName": "Aspen", "resourceEmail": "aspen@resource.calendar.google.com"}"#)),
            ResourceCalendar(record: Self.record(#"{"resourceId": "1002", "resourceName": "Birch Huddle", "resourceEmail": "birch@resource.calendar.google.com"}"#)),
            ResourceCalendar(record: Self.record(#"{"resourceId": "1003", "resourceName": "No address"}"#)),
            ResourceCalendar(record: Self.record(#"{"resourceId": "1004", "resourceName": "\u0130stanbul", "resourceEmail": "ist@resource.calendar.google.com"}"#)),
        ]
        #expect(ResourceCalendar.search(rooms, query: "").map(\.resourceID) == ["1001", "1002", "1004"])
        #expect(ResourceCalendar.search(rooms, query: " ASPEN ").map(\.resourceID) == ["1001"])
        #expect(ResourceCalendar.search(rooms, query: "birch@").map(\.resourceID) == ["1002"], "by address")
        #expect(ResourceCalendar.search(rooms, query: "1002").map(\.resourceID) == ["1002"], "by ID")
        #expect(ResourceCalendar.search(rooms, query: "address").isEmpty, "a room without an address isn't listed")
        // Python lowers U+0130 to "i" and a combining dot above (two scalars), and the search compares those.
        #expect(ResourceCalendar.search(rooms, query: "i\u{307}stan").map(\.resourceID) == ["1004"])
    }

    /// F4 (`validateCalendar`, gam/__init__.py:41574-41579): an ID ending `.calendar.google.com` (secondary,
    /// room, holiday) is read and changed as the admin's own sign-in; any other ID as that address.
    @Test func actingAccountIsGamsRule() {
        let admin = "admin@example.com"
        #expect(CalendarSharing.actingAccount(for: "c_team@group.calendar.google.com", admin: admin) == admin)
        #expect(CalendarSharing.actingAccount(for: "aspen@resource.calendar.google.com", admin: admin) == admin)
        #expect(CalendarSharing.actingAccount(for: "en.usa#holiday@group.v.calendar.google.com", admin: admin) == admin)
        #expect(CalendarSharing.actingAccount(for: "alice@example.com", admin: admin) == "alice@example.com")
        #expect(CalendarSharing.actingAccount(for: "c_team@group.calendar.google.com", admin: nil) == nil, "not known")
        #expect(CalendarSharing.actingAccount(for: "x@calendar.google.com.example.net", admin: admin) == "x@calendar.google.com.example.net")
    }

    /// D5/F5: GAM reads the share target as a list (`getEntityList`): a comma or a space makes several rules, a
    /// selector word reads a local file, a bare name gets the domain appended, and `group:`/`domain` change the
    /// scope. GamGUI's browser field (`type="email"`) let only one address through; so does this check.
    @Test func aShareTargetMustBeOneAddress() {
        for target in ["bob@example.com,carol@example.com", "bob@example.com carol@example.com", "file", "csvfile",
                       "bob", "group:sales@example.com", "user:bob@example.com", "domain", "domain:example.com", "default",
                       "@example.com", "bob@", "bob@example", "bob@example.com\u{3000}x@example.com"] {
            #expect(CalendarSharing.shareTargetProblem(target) != nil, "\(target)")
        }
        for target in ["bob@example.com", "o'brien@example.com", "first.last+tag@sub.example.com"] {
            #expect(CalendarSharing.shareTargetProblem(target) == nil, "\(target)")
        }
        #expect(CalendarSharing.shareTargetProblem("bob") == "“bob” isn't one address: enter a person's full address, like name@example.com.")
    }

    /// `test_calendar_acl_roles_match_grammar_and_mock`: the builders' roles, every `<CalendarACLRole>` the vendored
    /// grammar defines, and the strict mock's list are one set; the share picker offers GamGUI's four of them.
    @Test func theCalendarRolesAreTheGrammarsAndTheMocks() throws {
        let roles = GamCommands.CalendarRole.allCases.map(\.rawValue)
        let mock = try String(contentsOf: Fixtures.mockGam, encoding: .utf8)
        #expect(mock.contains("ACL_ROLES=\"\(roles.joined(separator: "|"))\""))
        let grammar = try String(contentsOf: Fixtures.repoRoot.appending(path: "Vendor/gam7/GamCommands.txt"), encoding: .utf8)
        let definitions = grammar.matches(of: /<CalendarACLRole> ::=\s*(\S+)/).map { String($0.output.1) }
        #expect(definitions.count >= 3 && Set(definitions) == [roles.joined(separator: "|")])
        #expect(CalendarSharing.pickerRoles.map(\.role) == [.reader, .freeBusyReader, .writer, .owner])
        #expect(CalendarSharing.pickerRoles.map(\.label) == ["See all details", "Free/busy only", "Make changes", "Make changes & manage"])
    }

    /// GAM's "Getting … for …" line is progress, not a failure: dropped before a read's error is classified.
    @Test func gettingLinesAreDropped() {
        let stderr = "Getting Calendars for carol@example.com\nUser: carol@example.com, Calendar Service/App not enabled\n"
        #expect(GettingLines.removed(from: stderr) == "User: carol@example.com, Calendar Service/App not enabled\n")
        #expect(GettingLines.removed(from: "Calendar: x, Print Failed: Not Found\n") == "Calendar: x, Print Failed: Not Found\n")
        #expect(GettingLines.removed(from: "Getting nothing done\n") == "Getting nothing done\n", "not GAM's shape")
    }
}
