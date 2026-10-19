import Testing
@testable import GamEngine

/// Builders with no GamGUI builder to hold them to (invariant 11 can't): each one's exact argv, as checked against
/// the vendored GAM 7.48.26's grammar (`Vendor/gam7/GamCommands.txt`, cited) and its source. A change here changes
/// what runs: check the grammar and the source again, and make the mock fail as GAM does. `CommandKindTests` holds
/// these to the read-only rule with GamGUI's builders.
@Suite("Native argv")
struct NativeArgvTests {
    static let cases: [(name: String, command: any GamCommand, argv: [String])] = [
        // 5942 `gam update user <UserItem> <UserAttribute>*`; 5842-5843 `recoveryemail <EmailAddress>`,
        // `recoveryphone <String>`: GAM reads an empty value as the field cleared.
        ("clear_recovery", GamCommands.clearRecovery(email: "<email>"),
         ["update", "user", "<email>", "recoveryemail", "", "recoveryphone", ""]),
        // 5831 `gal|includeinglobaladdresslist [<Boolean>]`: optional, true when bare, so `off` always.
        ("hide_from_directory", GamCommands.hideFromDirectory(email: "<email>"), ["update", "user", "<email>", "gal", "off"]),
        // 8372 `<UserTypeEntity> imap|imap4 <Boolean>`, 8378 `pop|pop3 <Boolean>`: required; `off` is getBoolean's.
        ("imap_off", GamCommands.imapOff(email: "<email>"), ["user", "<email>", "imap", "off"]),
        ("pop_off", GamCommands.popOff(email: "<email>"), ["user", "<email>", "pop", "off"]),
        // 6287-6288: `ownedsecondary` keeps the calendars the person is dataOwner of; `showhidden` is a
        // <CalendarSelectProperty> the same parser loop takes (printShowCalendars), without which hidden ones are missed.
        ("print_owned_secondary_calendars", GamCommands.printOwnedSecondaryCalendars(email: "<email>"),
         ["user", "<email>", "print", "calendars", "ownedsecondary", "showhidden", "fields", "id,summary", "formatjson"]),
        // 1685 omits `ownership`; GAM's source (CALENDARS_SUBCOMMANDS_WITH_OBJECTS) takes only `transfer ownership`.
        ("transfer_calendar_ownership",
         try! GamCommands.transferCalendarOwnership(calendarIDs: ["id1@group.calendar.google.com", "id2@group.calendar.google.com"],
                                                    to: "<email>"),
         ["calendars", "id1@group.calendar.google.com,id2@group.calendar.google.com", "transfer", "ownership", "<email>"]),
        // 7961-7962 `print filters [labelidsonly] … [formatjson]`; 7957 `delete filters <FilterIDEntity>`.
        ("print_filters", GamCommands.printFilters(email: "<email>"), ["user", "<email>", "print", "filters", "labelidsonly", "formatjson"]),
        ("delete_filters", try! GamCommands.deleteFilters(email: "<email>", filterIDs: ["ANe1Bmj1", "ANe1Bmj2"]),
         ["user", "<email>", "delete", "filters", "ANe1Bmj1,ANe1Bmj2"]),
        // 5704 `gam <UserTypeEntity> print vaultholds|holds`: no formatjson; CSV.
        ("print_vault_holds", GamCommands.printVaultHolds(email: "<email>"), ["user", "<email>", "print", "vaultholds"]),
        // The compromised-account check (GAM 7.48.30): 8003 `print forward|forwards [enabledonly]`; 8297 `print sendas
        // [compact] [primary|default] [verifyonly]`; 1579-1582 `print admins [user|group <EmailAddress>|<UniqueID>]`.
        ("print_forward", GamCommands.printForward(email: "<email>"), ["user", "<email>", "print", "forward"]),
        ("print_sendas", GamCommands.printSendAs(email: "<email>"), ["user", "<email>", "print", "sendas", "verifyonly"]),
        ("print_admins", GamCommands.printAdmins(user: "<email>"), ["print", "admins", "user", "<email>"]),
        // 4730-4744 `report <ActivityApplicationName> … [(user all|<UserItem>)|(select <UserTypeEntity>)] … [start <Time>]
        // [end <Time>] … [event|events <EventNameList>] [ip <String>] … [maxactivities <Number>]`; `-72h` is getDeltaTime's,
        // `now` TODAY_NOW's; `select users a,b` the grammar's `users <UserList>`.
        ("report_activity", try! GamCommands.reportActivity(.login, users: ["p@example.com"], hours: 72, ip: "198.51.100.23", maxActivities: 1000),
         ["report", "login", "user", "p@example.com", "start", "-72h", "end", "now", "ip", "198.51.100.23", "maxactivities", "1000"]),
        // 8293 `delete sendas <EmailAddressEntity>` (deleteInfoSendAs).
        ("delete_sendas", try! GamCommands.deleteSendAs(email: "<email>", address: "a@example.net"),
         ["user", "<email>", "delete", "sendas", "a@example.net"]),
    ]

    @Test func eachIsExactlyItsArgv() {
        for item in Self.cases {
            #expect(item.command.argv.map { Array($0.utf8) } == item.argv.map { Array($0.utf8) }, "\(item.name)")
        }
    }

    /// An operator value is one element, whatever it holds.
    @Test func anAddressIsOneElement() {
        let odd = "a b,c@example.com"
        #expect(GamCommands.clearRecovery(email: odd).argv[2] == odd && GamCommands.clearRecovery(email: odd).argv.count == 7)
        #expect(GamCommands.printVaultHolds(email: odd).argv == ["user", odd, "print", "vaultholds"])
    }

    /// The list is one element GAM splits on commas: an ID that would split, or isn't a calendar ID, is refused.
    @Test func eachCalendarHandedOverIsOneID() throws {
        // The last four split in Python but not by Swift's Character (review 2026-10-14); then a user's address, which
        // GAM gets as that user's calendar.
        for bad in [[], ["a@group.calendar.google.com,b@group.calendar.google.com"], ["team"], ["a @group.calendar.google.com"],
                    ["file"], ["c_a\u{0600},c_victim@group.calendar.google.com"], ["c_a\u{1F}x@group.calendar.google.com"],
                    ["c_a\u{0600} x@group.calendar.google.com"], ["c_a\u{0600}\u{3000}x@group.calendar.google.com"],
                    ["boss@example.com"], ["a@b@group.calendar.google.com"]] {
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.transferCalendarOwnership(calendarIDs: bad, to: "m@example.com") }
        }
        #expect(try GamCommands.transferCalendarOwnership(calendarIDs: ["c@group.calendar.google.com"], to: "m@example.com").action
                == .transferCalendarOwnership)
    }

    @Test func eachFilterDeletedIsOneID() throws {
        // The last four alone are GAM's list selectors (getChoice ignores case, `_` and `-`): it would read a file.
        for bad in [[], [""], ["a,b"], ["a b"], ["a\u{0600}"], ["ok", "x y"], ["file"], ["CSV_File"], ["csv-kmd"], ["csvdata"]] {
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.deleteFilters(email: "c@example.com", filterIDs: bad) }
        }
        // A selector word is one only as the whole element: beside another ID it's just an ID.
        #expect(try GamCommands.deleteFilters(email: "c@example.com", filterIDs: ["file", "ANe1Bmj2"]).argv.last == "file,ANe1Bmj2")
    }

    /// The address is one <EmailAddressEntity> element GAM splits on commas and Python's whitespace, and reads a file for
    /// when it's a list selector: only one plain address is sent.
    @Test func eachSendAsRemovedIsOneAddress() throws {
        for bad in ["", "a@example.net,b@example.net", "a b@example.net", "file", "csvfile", " a@example.net", "a@example.net\u{3000}",
                    "a\u{1F}b@example.net", "noat.example.net", "<a@example.net>", "Name <a@example.net>", "id:a@example.net",
                    "\u{131}d:a@example.net"] {
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.deleteSendAs(email: "c@example.com", address: bad) }
        }
        let write = try GamCommands.deleteSendAs(email: "c@example.com", address: "billing.desk@example.net")
        #expect(write.action == .deleteSendAs)
    }

    /// The window is 1 hour to the Reports API's six months; every account is one address and at most 20; `ip` is one IP
    /// address or nothing (no `ip` word then); none is `user all`.
    @Test func anActivityReportIsBounded() throws {
        #expect(try GamCommands.reportActivity(.gmail, hours: 72, maxActivities: 1000).argv
                == ["report", "gmail", "user", "all", "start", "-72h", "end", "now", "maxactivities", "1000"])
        #expect(try GamCommands.reportActivity(.accessEvaluation, users: ["a@example.com", "b@example.com"], hours: 24,
                                               events: ["allow_token_request"], maxActivities: 10).argv
                == ["report", "accessevaluation", "select", "users", "a@example.com,b@example.com", "start", "-24h", "end", "now",
                    "events", "allow_token_request", "maxactivities", "10"])
        for hours in [0, -1, 4_321] {
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.reportActivity(.login, hours: hours, maxActivities: 1) }
        }
        for ip in ["198.51.100", "198.51.100.256", "1.2.3.4 ", "1.2.3.4,5.6.7.8", "x", "2001:db8::1 ", "-30d"] {
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.reportActivity(.login, hours: 3, ip: ip, maxActivities: 1) }
        }
        for users in [["a@example.com,b@example.com"], ["a b@example.com"], ["all"], ["file"], Array(repeating: "a@example.com", count: 21)] {
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.reportActivity(.login, users: users, hours: 3, maxActivities: 1) }
        }
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.reportActivity(.login, hours: 3, events: ["a,b"], maxActivities: 1) }
        // The Reports API reads Gmail at most 30 days back (doReport's comment); the others, six months.
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.reportActivity(.gmail, hours: 721, maxActivities: 1) }
        #expect(try GamCommands.reportActivity(.gmail, hours: 720, maxActivities: 1).argv.contains("-720h"))
        // The admin log reads what the accounts did, not what was done to them (doReport maps a user to USER_EMAIL).
        #expect(try GamCommands.reportActivity(.admin, users: ["p@example.com"], hours: 3, maxActivities: 1).argv
                == ["report", "admin", "user", "p@example.com", "userisactor", "start", "-3h", "end", "now", "maxactivities", "1"])
        #expect(!(try GamCommands.reportActivity(.admin, hours: 3, maxActivities: 1).argv.contains("userisactor")))
        #expect(try GamCommands.reportActivity(.login, hours: 3, ip: "2001:db8::1", maxActivities: 1).argv.contains("2001:db8::1"))
    }

    @Test func clearingRecoveryIsDestructiveAndMasked() {
        let write = GamCommands.clearRecovery(email: "carol@example.com")
        #expect(write.action == .clearRecovery && GamCommands.hideFromDirectory(email: "c@example.com").action == .hideFromDirectory)
        #expect(ArgvRedaction.redact(write.argv) == ["update", "user", "carol@example.com", "recoveryemail", ArgvRedaction.mask,
                                                    "recoveryphone", ArgvRedaction.mask])
    }
}
