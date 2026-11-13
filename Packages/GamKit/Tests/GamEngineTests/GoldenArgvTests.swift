import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// Invariant 11: every Swift builder emits exactly the argv GamGUI's live-proven builder emits, for
/// every case in `Tests/Fixtures/argv.json` (generated from GamGUI by `scripts/gen_fixtures.py`).
/// The fixture is never edited to pass. A GamGUI builder is either ported (`implemented`) or listed in
/// `notPorted` with the reason.
@Suite("Golden argv")
struct GoldenArgvTests {
    /// A keyword argument as the generator writes it: GamGUI's typed values (`MessageId`, `Phone`) as their fields by name.
    indirect enum Value: Decodable, Equatable, Sendable {
        case string(String), bool(Bool), int(Int), strings([String]), objects([[String: Value]]), object([String: Value]), null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
            else if let int = try? container.decode(Int.self) { self = .int(int) }
            else if let string = try? container.decode(String.self) { self = .string(string) }
            else if let strings = try? container.decode([String].self) { self = .strings(strings) }
            else if let objects = try? container.decode([[String: Value]].self) { self = .objects(objects) }
            else { self = .object(try container.decode([String: Value].self)) }
        }
    }

    struct Case: Decodable {
        let builder: String
        let kwargs: [String: Value]
        let argv: [String]?
        let error: String?
    }

    struct Defaults: Decodable {
        let kwargs: [String: Value]
        let argv: [String]
    }

    struct Document: Decodable {
        let builders: [String]
        let cases: [Case]
        let defaults: [String: Defaults]
    }

    enum Missing: Error { case argument(String) }

    /// A case's keyword arguments, noting which the adapter reads: every one must be, or a builder
    /// could drop an argument GamGUI uses and still match on the cases where it makes no difference.
    final class Args {
        let values: [String: Value]
        private(set) var read: Set<String> = []

        init(_ values: [String: Value]) { self.values = values }

        private func take(_ key: String) -> Value? {
            read.insert(key)
            return values[key]
        }

        func string(_ key: String) throws -> String {
            guard case .string(let value) = take(key) else { throw Missing.argument(key) }
            return value
        }

        /// An optional string: GamGUI's `None` and `""` both mean "not given".
        func text(_ key: String) throws -> String {
            if values[key] == .null {
                read.insert(key)
                return ""
            }
            return try string(key)
        }

        func strings(_ key: String) throws -> [String] {
            guard case .strings(let value) = take(key) else { throw Missing.argument(key) }
            return value
        }

        /// An optional list: GamGUI's `None` and `[]` both mean "the default fields".
        func list(_ key: String) throws -> [String] {
            if values[key] == .null {
                read.insert(key)
                return []
            }
            return try strings(key)
        }

        func flag(_ key: String) throws -> Bool {
            guard case .bool(let value) = take(key) else { throw Missing.argument(key) }
            return value
        }

        func int(_ key: String) throws -> Int {
            guard case .int(let value) = take(key) else { throw Missing.argument(key) }
            return value
        }

        /// GamGUI's `MessageId`, already checked as it was made, so the Swift one is made from the same ID.
        func messageID(_ key: String) throws -> GamCommands.MessageID {
            guard case .object(let fields) = take(key), case .string(let id)? = fields["id"], fields.count == 1 else {
                throw Missing.argument(key)
            }
            return try GamCommands.MessageID(validating: id)
        }

        /// GamGUI's `Phone`s, field for field (an empty list is `[]`, which decodes as strings).
        func phones(_ key: String) throws -> [GamUser.Phone] {
            switch take(key) {
            case .strings(let empty) where empty.isEmpty: return []
            case .objects(let objects):
                return try objects.map { fields in
                    guard fields.count == 4, case .string(let type)? = fields["type"], case .string(let custom)? = fields["custom_type"],
                          case .string(let value)? = fields["value"], case .bool(let primary)? = fields["primary"] else {
                        throw Missing.argument(key)
                    }
                    return GamUser.Phone(type: type, customType: custom, value: value, primary: primary)
                }
            default: throw Missing.argument(key)
            }
        }

        /// A name GamGUI checks against a closed set, which Swift holds as an enum. An unknown one is the adapter's `Missing`,
        /// never `Invalid`: a case GamGUI refuses for it then fails here rather than passing with no Swift builder run (review
        /// 2026-11-11). The sets themselves are held to GamGUI's in `theClosedSetsAndFieldListsAreGamGUIsInOrder`.
        func choice<T>(_ key: String, _ make: (String) -> T?) throws -> T {
            guard let value = make(try string(key)) else { throw Missing.argument(key) }
            return value
        }
    }

    /// GamGUI builders deliberately not ported.
    static let notPorted: [String: String] = [
        "todrive_args": "Sheet export is dropped; CSV only (operator, 2026-10-08)",
    ]

    /// Ported builders, by GamGUI's name.
    static let implemented: [String: @Sendable (Args) throws -> any GamCommand] = [
        "version": { _ in GamCommands.version() },
        "check_svcacct": { try GamCommands.checkServiceAccount(admin: $0.string("admin"), scopes: $0.strings("scopes")) },
        "print_users": { try GamCommands.printUsers(query: $0.text("query"), fields: $0.list("fields")) },
        "print_cros": { try GamCommands.printCros(query: $0.text("query"), fields: $0.list("fields")) },
        "print_filelist": { try GamCommands.printFileList(email: $0.string("email"), query: $0.text("query"), fields: $0.list("fields")) },
        "report_users": { try GamCommands.reportUsers(date: $0.string("date"), parameters: $0.strings("params")) },
        "info_user": { try GamCommands.infoUser(email: $0.string("email"), fields: $0.list("fields")) },
        "create_user": {
            try GamCommands.createUser(
                email: $0.string("email"), firstName: $0.string("first_name"), lastName: $0.string("last_name"),
                password: $0.string("password"), changePassword: $0.flag("change_password"),
                orgUnit: $0.text("org_unit"), notify: $0.text("notify"))
        },
        "update_organization": { try GamCommands.updateOrganization(email: $0.string("email"), title: $0.string("title"), department: $0.string("department")) },
        "set_suspended": { try GamCommands.setSuspended(email: $0.string("email"), suspended: $0.flag("suspended")) },
        "print_calendar_acls": { try GamCommands.printCalendarACLs(email: $0.string("email"), calendar: $0.string("calendar")) },
        "add_calendar_acl": {
            try GamCommands.addCalendarACL(email: $0.string("email"), target: $0.string("target"),
                                           role: .init(validating: $0.string("role")), calendar: $0.string("calendar"))
        },
        "delete_calendar_acl": { try GamCommands.deleteCalendarACL(email: $0.string("email"), scope: $0.string("scope"), calendar: $0.string("calendar")) },
        "print_resources": { try GamCommands.printResources(query: $0.string("query")) },
        "print_user_calendars": { try GamCommands.printUserCalendars(email: $0.string("email")) },
        "print_all_calendars": { _ in GamCommands.printAllCalendars() },
        "print_calendar_acls_cal": { try GamCommands.printCalendarACLs(calendarID: $0.string("calendar_id")) },
        "add_calendar_acl_cal": {
            try GamCommands.addCalendarACL(calendarID: $0.string("calendar_id"), scope: $0.string("scope"),
                                           role: .init(validating: $0.string("role")), sendNotifications: $0.flag("send_notifications"))
        },
        "delete_calendar_acl_cal": { try GamCommands.deleteCalendarACL(calendarID: $0.string("calendar_id"), scope: $0.string("scope")) },
        "subscribe_calendar": { try GamCommands.subscribeCalendar(email: $0.string("email"), calendarID: $0.string("calendar_id"), selected: $0.flag("selected")) },
        "remove_calendar": { try GamCommands.removeCalendar(owner: $0.string("owner"), calendarID: $0.string("calendar_id")) },
        "print_events": {
            try GamCommands.printEvents(calendarID: $0.string("calendar_id"), query: $0.string("query"),
                                        after: $0.string("after"), before: $0.string("before"))
        },
        "get_event": { try GamCommands.getEvent(calendarID: $0.string("calendar_id"), eventID: $0.string("event_id")) },
        "delete_event": { try GamCommands.deleteEvent(calendarID: $0.string("calendar_id"), eventID: $0.string("event_id"), doit: $0.flag("doit")) },
        "reset_password": { try GamCommands.resetPassword(email: $0.string("email")) },
        "signout_user": { try GamCommands.signOutUser(email: $0.string("email")) },
        "deprovision_user": { try GamCommands.deprovisionUser(email: $0.string("email")) },
        "create_datatransfer": {
            try GamCommands.createDataTransfer(
                oldOwner: $0.string("old_owner"), service: $0.string("service"), newOwner: $0.string("new_owner"),
                privacy: .init(validating: $0.string("privacy")))
        },
        "print_datatransfers": { try GamCommands.printDataTransfers(oldOwner: $0.string("old_owner")) },
        "remove_all_calendar_acls": { try GamCommands.removeAllCalendarACLs(email: $0.string("email")) },
        "add_calendar_event": {
            try GamCommands.addCalendarEvent(
                calendar: $0.string("calendar"), summary: $0.string("summary"), start: $0.string("start"),
                end: $0.string("end"), description: $0.string("description"), attendee: $0.string("attendee"))
        },
        "delete_user": { try GamCommands.deleteUser(email: $0.string("email")) },
        "undelete_user": { try GamCommands.undeleteUser(email: $0.string("email")) },
        "create_tasklist": { try GamCommands.createTaskList(assignee: $0.string("assignee"), title: $0.string("title")) },
        "create_task": {
            try GamCommands.createTask(assignee: $0.string("assignee"), taskListID: $0.string("tasklist_id"),
                                       title: $0.string("title"), notes: $0.string("notes"))
        },
        "send_email": { try GamCommands.sendEmail(to: $0.string("to"), subject: $0.string("subject"), body: $0.string("body"), html: $0.flag("html")) },
        "set_signature": { try GamCommands.setSignature(email: $0.string("email"), signature: $0.string("signature"), html: $0.flag("html")) },
        "show_signature": { try GamCommands.showSignature(email: $0.string("email")) },
        "add_delegate": { try GamCommands.addDelegate(email: $0.string("email"), delegate: $0.string("delegate")) },
        "remove_delegate": { try GamCommands.removeDelegate(email: $0.string("email"), delegate: $0.string("delegate")) },
        "print_delegates": { try GamCommands.printDelegates(email: $0.string("email")) },
        "set_vacation": {
            try GamCommands.setVacation(
                email: $0.string("email"), subject: $0.string("subject"), message: $0.string("message"),
                html: $0.flag("html"), start: $0.text("start"), end: $0.text("end"),
                contactsOnly: $0.flag("contacts_only"), domainOnly: $0.flag("domain_only"))
        },
        "vacation_off": { try GamCommands.vacationOff(email: $0.string("email")) },
        "show_vacation": { try GamCommands.showVacation(email: $0.string("email")) },
        "add_forwarding_address": { try GamCommands.addForwardingAddress(email: $0.string("email"), address: $0.string("address")) },
        "print_forwarding_addresses": { try GamCommands.printForwardingAddresses(email: $0.string("email")) },
        "set_forward": {
            try GamCommands.setForward(email: $0.string("email"), address: $0.string("address"),
                                       action: .init(validating: $0.string("action")))
        },
        "forward_off": { try GamCommands.forwardOff(email: $0.string("email")) },
        "search_messages": {
            try GamCommands.searchMessages(email: $0.string("email"), query: $0.string("query"),
                                           detail: .init(label: $0.string("detail")))
        },
        "create_user_alias": { try GamCommands.createUserAlias(alias: $0.string("alias"), email: $0.string("email")) },
        "delete_alias": { try GamCommands.deleteAlias(alias: $0.string("alias")) },
        "print_groups": { try GamCommands.printGroups(fields: $0.list("fields")) },
        "print_groups_member": { try GamCommands.printGroups(member: $0.string("email")) },
        "create_group": { try GamCommands.createGroup(email: $0.string("email"), name: $0.string("name"), description: $0.string("description")) },
        "print_group_members": { try GamCommands.printGroupMembers(group: $0.string("group")) },
        "print_domains": { _ in GamCommands.printDomains() },
        "add_group_member": {
            try GamCommands.addGroupMember(group: $0.string("group"), member: $0.string("member"),
                                           role: .init(validating: $0.string("role")))
        },
        "remove_group_member": { try GamCommands.removeGroupMember(group: $0.string("group"), member: $0.string("member")) },
        // Ported back to GamGUI from here (its 2026-10-30 back-port), so held to it as every builder is.
        "clear_recovery": { try GamCommands.clearRecovery(email: $0.string("email")) },
        "set_password": { try GamCommands.setPassword(email: $0.string("email"), password: $0.string("password")) },
        "hide_from_directory": { try GamCommands.hideFromDirectory(email: $0.string("email")) },
        "imap_off": { try GamCommands.imapOff(email: $0.string("email")) },
        "pop_off": { try GamCommands.popOff(email: $0.string("email")) },
        "update_phones": { try GamCommands.updatePhones(email: $0.string("email"), phones: $0.phones("phones")) },
        "transfer_calendar_ownership": {
            try GamCommands.transferCalendarOwnership(calendarIDs: $0.strings("calendar_ids"), to: $0.string("new_owner"))
        },
        "print_owned_calendars": { try GamCommands.printOwnedSecondaryCalendars(email: $0.string("email")) },
        "print_filters": { try GamCommands.printFilters(email: $0.string("email")) },
        "delete_filters": { try GamCommands.deleteFilters(email: $0.string("email"), filterIDs: $0.strings("filter_ids")) },
        "print_vault_holds": { try GamCommands.printVaultHolds(email: $0.string("email")) },
        "print_forward": { try GamCommands.printForward(email: $0.string("email")) },
        "print_send_as": { try GamCommands.printSendAs(email: $0.string("email")) },
        "delete_send_as": { try GamCommands.deleteSendAs(email: $0.string("email"), address: $0.string("address")) },
        "print_admins": { try GamCommands.printAdmins(user: $0.string("email")) },
        "print_tokens": { _ in try GamCommands.printTokens() },
        "print_user_tokens": { try GamCommands.printTokens(user: $0.string("user")) },
        "print_chrome_profiles": { try GamCommands.printChromeProfiles(user: $0.string("user")) },
        "print_mobile_devices": { try GamCommands.printMobileDevices(user: $0.string("user")) },
        "print_devices": { try GamCommands.printDevices(user: $0.string("user")) },
        "print_script_projects": { try GamCommands.printScriptProjects(user: $0.string("user")) },
        "block_device_user": { try GamCommands.blockDeviceUser(name: $0.string("name")) },
        "delete_device_user": { try GamCommands.deleteDeviceUser(name: $0.string("name")) },
        "list_drafts": { try GamCommands.listMessages(email: $0.string("email"), query: "in:drafts", max: $0.int("most")) },
        "search_scheduled": {
            try GamCommands.searchMessages(email: $0.string("email"), query: Compromised.ScheduledSend.query, max: $0.int("most"))
        },
        "delete_messages": { try GamCommands.deleteMessages(email: $0.string("email"), ids: $0.strings("ids")) },
        "find_message_copies": { try GamCommands.findMessageCopies($0.messageID("message")) },
        "find_spam_copies": { try GamCommands.findSpamCopies($0.messageID("message")) },
        "trash_message": { try GamCommands.trashMessage(email: $0.string("email"), $0.messageID("message"), copies: $0.int("copies")) },
        "trash_messages": { try GamCommands.trashMessages(email: $0.string("email"), ids: $0.strings("ids")) },
        "print_courses": { args in
            try GamCommands.printCourses(
                teacher: args.string("teacher"), student: args.string("student"),
                states: args.strings("states").map { name in
                    guard let state = GamCommands.CourseState(rawValue: name) else { throw Missing.argument("states") }
                    return state
                },
                courseIDs: args.strings("course_ids"), ownerEmail: args.flag("owner_email"), aliases: args.flag("aliases"))
        },
        "print_all_course_participants": { args in
            try GamCommands.printAllCourseParticipants(states: args.strings("states").map { name in
                guard let state = GamCommands.CourseState(rawValue: name) else { throw Missing.argument("states") }
                return state
            })
        },
        "print_course_participants": { try GamCommands.printCourseParticipants(courseID: $0.string("course_id")) },
        "report_activity": { args in
            try GamCommands.reportActivity(
                args.choice("application", GamCommands.ActivityApplication.init(rawValue:)), users: args.strings("users"),
                hours: args.int("hours"), start: args.string("start"), end: args.string("end"), ip: args.string("ip"),
                events: args.strings("events"), maxActivities: args.int("max_activities"),
                chrome: args.choice("chrome") { ["profile": .profile, "device": .device][$0] },
                admin: args.choice("admin") { ["actor": .actor, "affected": .affected][$0] })
        },
    ]

    /// Each builder that has defaults, called with only its required arguments.
    static let defaultCalls: [String: @Sendable () -> any GamCommand] = [
        "add_calendar_acl": { GamCommands.addCalendarACL(email: "<email>", target: "<target>") },
        "add_calendar_acl_cal": { GamCommands.addCalendarACL(calendarID: "<calendar_id>", scope: "<scope>") },
        "add_calendar_event": { GamCommands.addCalendarEvent(calendar: "<calendar>", summary: "<summary>", start: "<start>", end: "<end>") },
        "add_group_member": { GamCommands.addGroupMember(group: "<group>", member: "<member>") },
        "create_datatransfer": { GamCommands.createDataTransfer(oldOwner: "<old_owner>", service: "<service>", newOwner: "<new_owner>") },
        "create_group": { GamCommands.createGroup(email: "<email>") },
        "create_task": { GamCommands.createTask(assignee: "<assignee>", taskListID: "<tasklist_id>", title: "<title>") },
        "create_user": { GamCommands.createUser(email: "<email>", firstName: "<first_name>", lastName: "<last_name>", password: "<password>") },
        "delete_calendar_acl": { GamCommands.deleteCalendarACL(email: "<email>", scope: "<scope>") },
        "delete_event": { GamCommands.deleteEvent(calendarID: "<calendar_id>", eventID: "<event_id>") },
        "info_user": { GamCommands.infoUser(email: "<email>") },
        "print_calendar_acls": { GamCommands.printCalendarACLs(email: "<email>") },
        "print_cros": { GamCommands.printCros() },
        "print_courses": { try! GamCommands.printCourses() },
        "print_datatransfers": { GamCommands.printDataTransfers() },
        "print_events": { GamCommands.printEvents(calendarID: "<calendar_id>") },
        "print_filelist": { GamCommands.printFileList(email: "<email>") },
        "print_groups": { GamCommands.printGroups() },
        "print_resources": { GamCommands.printResources() },
        "print_users": { GamCommands.printUsers() },
        // GamGUI's hours (72) and max_activities (1000) are defaults; Swift has every caller say them, so they're passed
        // as GamGUI's, and the rest (users, the window, ip, events, chrome, admin) are Swift's own defaults.
        "report_activity": { try! GamCommands.reportActivity(.login, hours: 72, maxActivities: 1000) },
        "search_messages": { GamCommands.searchMessages(email: "<email>") },
        "send_email": { GamCommands.sendEmail(to: "<to>", subject: "<subject>", body: "<body>") },
        "set_forward": { GamCommands.setForward(email: "<email>", address: "<address>") },
        "set_signature": { GamCommands.setSignature(email: "<email>", signature: "<signature>") },
        "set_vacation": { GamCommands.setVacation(email: "<email>", subject: "<subject>", message: "<message>") },
        "subscribe_calendar": { GamCommands.subscribeCalendar(email: "<email>", calendarID: "<calendar_id>") },
        "update_organization": { GamCommands.updateOrganization(email: "<email>") },
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
            let args = Args(item.kwargs)
            if let expected = item.argv {
                // Bytes, not Strings: Swift's == treats "é" and "e" + U+0301 as equal; GAM doesn't.
                #expect(try build(args).argv.map { Array($0.utf8) } == expected.map { Array($0.utf8) },
                        "\(item.builder) \(item.kwargs)")
                #expect(args.read == Set(item.kwargs.keys), "\(item.builder) ignores an argument")
            } else {
                // The builder's own refusal, not the adapter's `Missing`.
                #expect(throws: GamCommands.Invalid.self, "\(item.builder) should refuse \(item.kwargs)") { try build(args) }
                refused += 1
            }
            checked += 1
        }
        #expect(checked > 1000)
        #expect(refused > 100)
    }

    @Test func theDefaultsAreGamGUIs() {
        #expect(Set(Self.defaultCalls.keys) == Set(document.defaults.keys).subtracting(Self.notPorted.keys))
        for (name, call) in Self.defaultCalls {
            let expected = document.defaults[name]?.argv
            #expect(call().argv.map { Array($0.utf8) } == expected?.map { Array($0.utf8) }, "\(name)")
        }
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
            "REPORT_APPLICATIONS": GamCommands.ActivityApplication.allCases.map(\.rawValue),
            "COURSE_STATES": GamCommands.CourseState.allCases.map(\.rawValue),
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
        #expect((constants["PY_WHITESPACE"] as? [Int]).map { Set($0.map(UInt32.init)) } == PythonText.whitespace)
    }
}
