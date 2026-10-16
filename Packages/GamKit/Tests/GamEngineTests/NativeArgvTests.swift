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

    @Test func clearingRecoveryIsDestructiveAndMasked() {
        let write = GamCommands.clearRecovery(email: "carol@example.com")
        #expect(write.action == .clearRecovery && GamCommands.hideFromDirectory(email: "c@example.com").action == .hideFromDirectory)
        #expect(ArgvRedaction.redact(write.argv) == ["update", "user", "carol@example.com", "recoveryemail", ArgvRedaction.mask,
                                                    "recoveryphone", ArgvRedaction.mask])
    }
}
