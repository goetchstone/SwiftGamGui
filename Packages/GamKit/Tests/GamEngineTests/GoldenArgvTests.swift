import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// Invariant 11: every Swift builder emits exactly the argv GamGUI's live-proven builder emits, for
/// every case in `Tests/Fixtures/argv.json` (generated from frozen GamGUI by `scripts/gen_fixtures.py`).
/// The fixture is never edited to pass. A GamGUI builder is either ported (`implemented`) or listed in
/// `notPorted` with the reason.
@Suite("Golden argv")
struct GoldenArgvTests {
    enum Value: Decodable, Equatable, Sendable {
        case string(String), bool(Bool), strings([String]), null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
            else if let string = try? container.decode(String.self) { self = .string(string) }
            else { self = .strings(try container.decode([String].self)) }
        }
    }

    struct Case: Decodable {
        let builder: String
        let kwargs: [String: Value]
        let argv: [String]?
        let error: String?
    }

    struct Document: Decodable {
        let builders: [String]
        let cases: [Case]
    }

    enum Missing: Error { case argument(String) }

    typealias Kwargs = [String: Value]

    static func string(_ kwargs: Kwargs, _ key: String) throws -> String {
        guard case .string(let value) = kwargs[key] else { throw Missing.argument(key) }
        return value
    }

    /// An optional string: GamGUI's `None` and `""` both mean "not given".
    static func text(_ kwargs: Kwargs, _ key: String) throws -> String {
        kwargs[key] == .null ? "" : try string(kwargs, key)
    }

    static func strings(_ kwargs: Kwargs, _ key: String) throws -> [String] {
        guard case .strings(let value) = kwargs[key] else { throw Missing.argument(key) }
        return value
    }

    /// An optional list: GamGUI's `None` and `[]` both mean "the default fields".
    static func list(_ kwargs: Kwargs, _ key: String) throws -> [String] {
        kwargs[key] == .null ? [] : try strings(kwargs, key)
    }

    static func flag(_ kwargs: Kwargs, _ key: String) throws -> Bool {
        guard case .bool(let value) = kwargs[key] else { throw Missing.argument(key) }
        return value
    }

    /// GamGUI builders deliberately not ported.
    static let notPorted: [String: String] = [
        "todrive_args": "Sheet export is dropped; CSV only (operator, 2026-10-08)",
    ]

    /// Ported builders, by GamGUI's name.
    static let implemented: [String: @Sendable (Kwargs) throws -> [String]] = [
        "version": { _ in GamCommands.version() },
        "check_svcacct": { try GamCommands.checkServiceAccount(admin: string($0, "admin"), scopes: strings($0, "scopes")) },
        "print_users": { try GamCommands.printUsers(query: text($0, "query"), fields: list($0, "fields")) },
        "print_cros": { try GamCommands.printCros(query: text($0, "query"), fields: list($0, "fields")) },
        "print_filelist": { try GamCommands.printFileList(email: string($0, "email"), query: text($0, "query"), fields: list($0, "fields")) },
        "report_users": { try GamCommands.reportUsers(date: string($0, "date"), parameters: strings($0, "params")) },
        "info_user": { try GamCommands.infoUser(email: string($0, "email"), fields: list($0, "fields")) },
        "create_user": {
            try GamCommands.createUser(
                email: string($0, "email"), firstName: string($0, "first_name"), lastName: string($0, "last_name"),
                password: string($0, "password"), changePassword: flag($0, "change_password"),
                orgUnit: text($0, "org_unit"), notify: text($0, "notify"))
        },
        "update_organization": { try GamCommands.updateOrganization(email: string($0, "email"), title: string($0, "title"), department: string($0, "department")) },
        "set_suspended": { try GamCommands.setSuspended(email: string($0, "email"), suspended: flag($0, "suspended")) },
        "print_calendar_acls": { try GamCommands.printCalendarACLs(email: string($0, "email"), calendar: string($0, "calendar")) },
        "add_calendar_acl": {
            try GamCommands.addCalendarACL(email: string($0, "email"), target: string($0, "target"),
                                           role: .init(validating: string($0, "role")), calendar: string($0, "calendar"))
        },
        "delete_calendar_acl": { try GamCommands.deleteCalendarACL(email: string($0, "email"), scope: string($0, "scope"), calendar: string($0, "calendar")) },
        "print_resources": { try GamCommands.printResources(query: string($0, "query")) },
        "print_user_calendars": { try GamCommands.printUserCalendars(email: string($0, "email")) },
        "print_all_calendars": { _ in GamCommands.printAllCalendars() },
        "print_calendar_acls_cal": { try GamCommands.printCalendarACLs(calendarID: string($0, "calendar_id")) },
        "add_calendar_acl_cal": {
            try GamCommands.addCalendarACL(calendarID: string($0, "calendar_id"), scope: string($0, "scope"),
                                           role: .init(validating: string($0, "role")), sendNotifications: flag($0, "send_notifications"))
        },
        "delete_calendar_acl_cal": { try GamCommands.deleteCalendarACL(calendarID: string($0, "calendar_id"), scope: string($0, "scope")) },
        "subscribe_calendar": { try GamCommands.subscribeCalendar(email: string($0, "email"), calendarID: string($0, "calendar_id"), selected: flag($0, "selected")) },
        "remove_calendar": { try GamCommands.removeCalendar(owner: string($0, "owner"), calendarID: string($0, "calendar_id")) },
        "print_events": {
            try GamCommands.printEvents(calendarID: string($0, "calendar_id"), query: string($0, "query"),
                                        after: string($0, "after"), before: string($0, "before"))
        },
        "get_event": { try GamCommands.getEvent(calendarID: string($0, "calendar_id"), eventID: string($0, "event_id")) },
        "delete_event": { try GamCommands.deleteEvent(calendarID: string($0, "calendar_id"), eventID: string($0, "event_id"), doit: flag($0, "doit")) },
        "reset_password": { try GamCommands.resetPassword(email: string($0, "email")) },
        "signout_user": { try GamCommands.signOutUser(email: string($0, "email")) },
        "deprovision_user": { try GamCommands.deprovisionUser(email: string($0, "email")) },
        "create_datatransfer": {
            // GamGUI validates the level only when one is given (`if privacy:`).
            let privacy = try string($0, "privacy")
            return try GamCommands.createDataTransfer(
                oldOwner: string($0, "old_owner"), service: string($0, "service"), newOwner: string($0, "new_owner"),
                privacy: privacy.isEmpty ? nil : .init(validating: privacy))
        },
        "print_datatransfers": { try GamCommands.printDataTransfers(oldOwner: string($0, "old_owner")) },
        "remove_all_calendar_acls": { try GamCommands.removeAllCalendarACLs(email: string($0, "email")) },
        "add_calendar_event": {
            try GamCommands.addCalendarEvent(
                calendar: string($0, "calendar"), summary: string($0, "summary"), start: string($0, "start"),
                end: string($0, "end"), description: string($0, "description"), attendee: string($0, "attendee"))
        },
        "delete_user": { try GamCommands.deleteUser(email: string($0, "email")) },
        "undelete_user": { try GamCommands.undeleteUser(email: string($0, "email")) },
        "create_tasklist": { try GamCommands.createTaskList(assignee: string($0, "assignee"), title: string($0, "title")) },
        "create_task": {
            try GamCommands.createTask(assignee: string($0, "assignee"), taskListID: string($0, "tasklist_id"),
                                       title: string($0, "title"), notes: string($0, "notes"))
        },
        "send_email": { try GamCommands.sendEmail(to: string($0, "to"), subject: string($0, "subject"), body: string($0, "body"), html: flag($0, "html")) },
        "set_signature": { try GamCommands.setSignature(email: string($0, "email"), signature: string($0, "signature"), html: flag($0, "html")) },
        "show_signature": { try GamCommands.showSignature(email: string($0, "email")) },
        "add_delegate": { try GamCommands.addDelegate(email: string($0, "email"), delegate: string($0, "delegate")) },
        "remove_delegate": { try GamCommands.removeDelegate(email: string($0, "email"), delegate: string($0, "delegate")) },
        "print_delegates": { try GamCommands.printDelegates(email: string($0, "email")) },
        "set_vacation": {
            try GamCommands.setVacation(
                email: string($0, "email"), subject: string($0, "subject"), message: string($0, "message"),
                html: flag($0, "html"), start: text($0, "start"), end: text($0, "end"),
                contactsOnly: flag($0, "contacts_only"), domainOnly: flag($0, "domain_only"))
        },
        "vacation_off": { try GamCommands.vacationOff(email: string($0, "email")) },
        "show_vacation": { try GamCommands.showVacation(email: string($0, "email")) },
        "add_forwarding_address": { try GamCommands.addForwardingAddress(email: string($0, "email"), address: string($0, "address")) },
        "print_forwarding_addresses": { try GamCommands.printForwardingAddresses(email: string($0, "email")) },
        "set_forward": {
            try GamCommands.setForward(email: string($0, "email"), address: string($0, "address"),
                                       action: .init(validating: string($0, "action")))
        },
        "forward_off": { try GamCommands.forwardOff(email: string($0, "email")) },
        "search_messages": {
            // GamGUI shows headers for any detail other than its two other labels (its `else`).
            let label = try string($0, "detail")
            return try GamCommands.searchMessages(email: string($0, "email"), query: string($0, "query"),
                                                  detail: GamCommands.match(label, in: GamCommands.MessageDetail.self) ?? .headers)
        },
        "create_user_alias": { try GamCommands.createUserAlias(alias: string($0, "alias"), email: string($0, "email")) },
        "delete_alias": { try GamCommands.deleteAlias(alias: string($0, "alias")) },
        "print_groups": { try GamCommands.printGroups(fields: list($0, "fields")) },
        "print_groups_member": { try GamCommands.printGroups(member: string($0, "email")) },
        "create_group": { try GamCommands.createGroup(email: string($0, "email"), name: string($0, "name"), description: string($0, "description")) },
        "print_group_members": { try GamCommands.printGroupMembers(group: string($0, "group")) },
        "print_domains": { _ in GamCommands.printDomains() },
        "add_group_member": {
            try GamCommands.addGroupMember(group: string($0, "group"), member: string($0, "member"),
                                           role: .init(validating: string($0, "role")))
        },
        "remove_group_member": { try GamCommands.removeGroupMember(group: string($0, "group"), member: string($0, "member")) },
    ]

    static let fixture = try! Data(contentsOf: Fixtures.argvJSON)
    let document: Document = try! JSONDecoder().decode(Document.self, from: Self.fixture)

    @Test func everyGamGUIBuilderIsPortedOrDeliberatelyLeftOut() {
        let ported = Set(Self.implemented.keys), left = Set(Self.notPorted.keys)
        #expect(ported.isDisjoint(with: left))
        #expect(ported.union(left) == Set(document.builders))
    }

    @Test func everyPortedBuilderMatchesGamGUIOnEveryCase() throws {
        var checked = 0, refused = 0
        for item in document.cases {
            guard let build = Self.implemented[item.builder] else { continue }
            if let expected = item.argv {
                // Bytes, not Strings: Swift's == treats "é" and "e" + U+0301 as equal; GAM doesn't.
                #expect(try build(item.kwargs).map { Array($0.utf8) } == expected.map { Array($0.utf8) },
                        "\(item.builder) \(item.kwargs)")
            } else {
                #expect(throws: (any Error).self, "\(item.builder) should refuse \(item.kwargs)") { try build(item.kwargs) }
                refused += 1
            }
            checked += 1
        }
        #expect(checked > 1000)
        #expect(refused > 100)
    }

    @Test func theClosedSetsAndFieldListsAreGamGUIsInOrder() throws {
        let object = try JSONSerialization.jsonObject(with: Self.fixture) as? [String: Any]
        let constants = try #require(object?["constants"] as? [String: Any])
        let swift: [String: [String]] = [
            "GROUP_ROLES": GamCommands.GroupRole.allCases.map(\.rawValue),
            "CALENDAR_ACL_ROLES": GamCommands.CalendarRole.allCases.map(\.rawValue),
            "FORWARD_ACTIONS": GamCommands.ForwardAction.allCases.map(\.rawValue),
            "TRANSFER_PRIVACY": GamCommands.TransferPrivacy.allCases.map(\.rawValue),
            "MESSAGE_DETAIL": GamCommands.MessageDetail.allCases.map(\.rawValue),
            "USER_LIST_FIELDS": GamCommands.userListFields,
            "USER_DETAIL_FIELDS": GamCommands.userDetailFields,
            "GROUP_LIST_FIELDS": GamCommands.groupListFields,
            "CROS_LIST_FIELDS": GamCommands.crosListFields,
            "FILE_LIST_FIELDS": GamCommands.fileListFields,
            "CACHE_FIELDS": GamCommands.cacheFields,
        ]
        for (name, values) in swift {
            #expect(constants[name] as? [String] == values, "\(name)")
        }
        #expect((constants["PY_WHITESPACE"] as? [Int]).map { Set($0.map(UInt32.init)) } == GamCommands.pythonWhitespace)
    }
}
