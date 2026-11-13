import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock's calendar reads print what GAM 7.48.22 prints and fail as it fails, read from the
/// vendored build's source (`docs/domains/calendars.md`, F1 to F4), and its calendars agree with one another.
/// The mock once refused all four reads, and before that answered them with NDJSON GAM never prints.
@Suite("Mock calendars")
struct MockCalendarsTests {
    let mock = GamRunner(binary: Fixtures.mockGam)
    static let team = "c_team@group.calendar.google.com"

    /// One call of the mock, with GAM's first-run banner (the lines naming the config folder) dropped. `state`,
    /// when given, is the mock's state folder; `admin`, the account the materialized oauth2.txt signs in as.
    private func run(_ argv: [String], state: URL? = nil, admin: String? = nil) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        if let admin {
            try Data(#"{"decoded_id_token": {"email": "\#(admin)"}}"#.utf8).write(to: config.appending(path: "oauth2.txt"))
        }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        let result = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
        let data = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(config.lastPathComponent) }.joined(separator: "\n")
        return (result.exitCode, data, result.stderr)
    }

    private func stateFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-calstate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func marker(_ path: String, in state: URL, _ text: String = "") throws {
        let file = state.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    /// A data file's records, one JSON line each, as GAM prints them in the `JSON` cell.
    private func lines(_ name: String) throws -> [String] {
        try String(contentsOf: Fixtures.mockGamData.appending(path: name), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    private func value(_ key: String, in line: String) throws -> String {
        try #require(JSONValue.parse(line)?.object?[key]?.string, "\(key) in \(line)")
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// F1, F2: each read prints GAM's header, then a row per record, in GAM's CSV dialect; the per-calendar reads
    /// say "Getting … for …" on stderr first, as GAM's `printGettingEntityItemForWhom` does (show_gettings is on
    /// by default).
    @Test func eachCalendarReadPrintsGamsBytes() async throws {
        var calendars = GamOutputTests.gamRow(["primaryEmail", "calendarId", "JSON"])
        for line in try lines("user_calendars/alice@example.com.json") {
            calendars += GamOutputTests.gamRow(["alice@example.com", try value("id", in: line), line])
        }
        var primary = GamOutputTests.gamRow(["primaryEmail", "calendarId", "JSON"])
        for line in try lines("calendar_acls/alice@example.com.json") {
            primary += GamOutputTests.gamRow(["alice@example.com", "alice@example.com", line])
        }
        var team = GamOutputTests.gamRow(["calendarId", "JSON"])
        for line in try lines("calendar_acls/\(Self.team).json") { team += GamOutputTests.gamRow([Self.team, line]) }
        var rooms = GamOutputTests.gamRow(["resourceId", "resourceName", "JSON"])
        for line in try lines("resources.json") {
            rooms += GamOutputTests.gamRow([try value("resourceId", in: line), try value("resourceName", in: line), line])
        }
        let reads: [([String], String, String)] = [
            (GamCommands.printUserCalendars(email: "alice@example.com").argv, calendars, "Getting Calendars for alice@example.com\n"),
            (GamCommands.printCalendarACLs(email: "alice@example.com").argv, primary, "Getting Calendar ACLs for alice@example.com\n"),
            (GamCommands.printCalendarACLs(calendarID: Self.team).argv, team, "Getting Calendar ACLs for \(Self.team)\n"),
            (GamCommands.printResources().argv, rooms, ""),
        ]
        for (argv, expected, stderr) in reads {
            let read = try await run(argv)
            #expect(read.exitCode == 0, "\(argv.joined(separator: " ")): \(read.stderr)")
            #expect(bytes(read.stdout) == bytes(expected), "\(argv.joined(separator: " "))")
            #expect(bytes(read.stderr) == bytes(stderr), "\(argv.joined(separator: " "))")
        }
        // GAM's escapes come back whole: a summary with a quote, a backslash, a comma and non-ASCII, and a room
        // type with a quote and a backslash.
        let rota = try #require(GamOutput.records(calendars).first { $0["id"]?.string == "c_rota@group.calendar.google.com" })
        #expect(rota["summary"]?.string.map(bytes) == bytes("Rota \"B\" C:\\Shifts, Zo\u{EB}"))
        let birch = try #require(GamOutput.records(rooms).first { $0["resourceId"]?.string == "1002" })
        #expect(birch["resourceType"]?.string.map(bytes) == bytes("Huddle \"Pod\" \\ Small"))
        #expect(birch["resourceName"]?.string == "Birch Huddle, 2nd floor" && birch["buildingName"]?.string == "annex")
    }

    /// The per-user reads answer for THAT person (an address in any case is that person, as GAM normalizes a
    /// user entity): answering one person's data for anyone let wrong-target reads pass (failure-log 2026-09-23).
    @Test func aPersonsCalendarsAreTheirOwn() async throws {
        let bob = try await run(GamCommands.printUserCalendars(email: "BOB@example.com").argv)
        #expect(bob.exitCode == 0, "\(bob.stderr)")
        #expect(GamOutput.records(bob.stdout).compactMap { $0["id"]?.string } == ["bob@example.com", Self.team])
        #expect(GamOutput.records(bob.stdout).allSatisfy { $0["primaryEmail"]?.string == "bob@example.com" })
        let carol = try await run(GamCommands.printCalendarACLs(email: "carol@example.com").argv)
        #expect(GamOutput.records(carol.stdout).compactMap { $0["id"]?.string }
                == ["user:carol@example.com", "user:helpdesk@example.com"])
        #expect(GamOutput.records(carol.stdout).allSatisfy { $0["calendarId"]?.string == "carol@example.com" },
                "`primary` reads as the person (55338-55339)")
    }

    /// A per-user calendar read acts AS the person: for an address that isn't one, GAM's token request fails and
    /// it says so against them, exit 50 (the mock's `not_a_user`).
    @Test func aNonUserFailsLikeGam() async throws {
        for argv in [GamCommands.printUserCalendars(email: "nobody@example.com").argv,
                     GamCommands.printCalendarACLs(email: "nobody@example.com").argv] {
            let read = try await run(argv)
            #expect(read.exitCode == 50, "\(argv)")
            #expect(read.stdout.isEmpty)
            #expect(GamError(exitCode: read.exitCode, stderr: read.stderr).kind == .notFound, "\(read.stderr)")
        }
    }

    /// A calendar share tells a group from a person by GAM's member lookup: an address that isn't a group is GAM's
    /// entityUnknownWarning (gam/__init__.py:2578, getGroupMembers :37647-37649 at 7.52.01), "Does not exist" exit 56 in
    /// the domain and "Service not applicable/Does not exist" exit 73 outside it (glmsgs.py:508). Both read as not-found,
    /// so an outside address is shared as a person; any other failure stays a problem.
    @Test func aGroupLookupOfANonGroupFailsAsGamDoes() async throws {
        let inside = try await run(GamCommands.printGroupMembers(group: "Nobody@example.com").argv)
        #expect(inside.exitCode == 56 && inside.stdout.isEmpty)
        #expect(Array(inside.stderr.utf8) == Array("Group: Nobody@example.com, Does not exist\n".utf8))
        let outside = try await run(GamCommands.printGroupMembers(group: "Guest@Example.net").argv)
        #expect(outside.exitCode == 73 && outside.stdout.isEmpty)
        #expect(Array(outside.stderr.utf8) == Array("Group: Guest@Example.net, Service not applicable/Does not exist\n".utf8))
        for read in [inside, outside] {
            #expect(GamError(exitCode: read.exitCode, stderr: read.stderr).kind == .notFound, "\(read.stderr)")
        }
    }

    /// F3/F4: a person with Calendar off is GAM's per-user refusal, exit 73. Listing their calendars says "Getting
    /// Calendars for …" first, which GamError reads as progress, so the refusal keeps its own kind (GamGUI's
    /// `_PROGRESS_LINE` knows only "Getting all …"; failure-log 2026-10-13).
    @Test func calendarOffExits73() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        try marker("nocalendar/carol@example.com", in: state)
        let list = try await run(GamCommands.printUserCalendars(email: "carol@example.com").argv, state: state)
        #expect(list.exitCode == 73)
        #expect(list.stderr == "Getting Calendars for carol@example.com\nUser: carol@example.com, Calendar Service/App not enabled\n")
        #expect(GamError(exitCode: list.exitCode, stderr: list.stderr).kind == .serviceNotEnabled, "\(list.stderr)")
        // The user form checks their primary calendar before it says it's getting the rules.
        let acls = try await run(GamCommands.printCalendarACLs(email: "carol@example.com").argv, state: state)
        #expect(acls.exitCode == 73)
        #expect(GamError(exitCode: acls.exitCode, stderr: acls.stderr).kind == .serviceNotEnabled, "\(acls.stderr)")
        #expect(try await run(GamCommands.printUserCalendars(email: "alice@example.com").argv, state: state).exitCode == 0,
                "only carol's is off")
    }

    /// Only the shapes the app sends are modelled; a field or word GAM doesn't know is GAM's usage error.
    @Test func onlyTheFieldsTheAppSendsAreModelled() async throws {
        let notModelled: [[String]] = [
            ["user", "alice@example.com", "print", "calendars", "fields", "id,summary", "formatjson"],
            ["user", "alice@example.com", "print", "calendars", "fields", "id,summary,accessrole,primary,colorid", "formatjson"],
            ["user", "alice@example.com", "print", "calendars", "fields", "id,summary,accessrole,primary"],
            ["user", "alice@example.com", "print", "calendars", "fields", "id,summary,accessrole,primary", "formatjson", "quotechar", "'"],
            ["user", "alice@example.com", "print", "calendaracls", "primary"],
            ["user", "alice@example.com", "print", "calendaracls", Self.team, "formatjson"],
            ["calendars", Self.team, "print", "calendaracls"],
            ["calendars", Self.team, "print", "calendaracls", "noselfowner", "formatjson"],
            ["calendars", "\(Self.team),c_ops@group.calendar.google.com", "print", "calendaracls", "formatjson"],
            GamCommands.printResources(query: "name:Aspen").argv,
            ["print", "resources", "fields", "id,name", "formatjson"],
            ["print", "resources", "fields", "id,name,email,resourcetype,buildingid"],
        ]
        for argv in notModelled {
            let read = try await run(argv)
            #expect(read.exitCode == 2 && read.stderr.contains("isn't modelled"), "\(argv.joined(separator: " ")): \(read.stderr)")
        }
        let calendarField = try await run(["user", "alice@example.com", "print", "calendars", "fields", "id,bogus", "formatjson"])
        #expect(calendarField.exitCode == 2 && calendarField.stderr.contains("Invalid choice (bogus)"), "\(calendarField.stderr)")
        let roomField = try await run(["print", "resources", "fields", "id,bogus", "formatjson"])
        #expect(roomField.exitCode == 2 && roomField.stderr.contains("Invalid choice (bogus)"), "\(roomField.stderr)")
        let extra = try await run(GamCommands.printCalendarACLs(calendarID: Self.team).argv + ["extra"])
        #expect(extra.exitCode == 2 && extra.stderr.contains("Invalid argument"), "\(extra.stderr)")
        // GAM matches a field lowercased: the app's own words are fields.
        let upper = try await run(["user", "alice@example.com", "print", "calendars", "fields", "ID,Summary,accessRole,primary", "formatjson"])
        #expect(upper.exitCode == 0, "\(upper.stderr)")
    }

    /// F4: GAM's `validateCalendar` fails a calendar it can't get with "… Failed: Not Found", exit 50, not the
    /// mock's old "Does not exist", exit 56.
    @Test func anUnknownCalendarFailsWith50NotFound() async throws {
        let read = try await run(GamCommands.printCalendarACLs(calendarID: "nosuch@group.calendar.google.com").argv)
        #expect(read.exitCode == 50)
        #expect(read.stderr == "Calendar: nosuch@group.calendar.google.com, Print Failed: Not Found\n")
        #expect(read.stdout.isEmpty)
        #expect(GamError(exitCode: read.exitCode, stderr: read.stderr).kind == .notFound)
    }

    /// F3: a calendar with no rules prints the header alone and exits NO_ENTITIES_FOUND_RC (60).
    @Test func noRulesExits60() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        try marker("acls/\(Self.team)", in: state)
        let read = try await run(GamCommands.printCalendarACLs(calendarID: Self.team).argv, state: state)
        #expect(read.exitCode == 60)
        #expect(read.stdout == "calendarId,JSON\n")
        #expect(GamOutput.records(read.stdout).isEmpty)
        let codes = try JSONSerialization.jsonObject(with: Data(contentsOf: Fixtures.exitCodesJSON)) as? [String: Any]
        #expect((codes?["build_rc"] as? [String: Int])?["NO_ENTITIES_FOUND_RC"] == 60)
    }

    /// One data set: every calendar a directory user lists with an ACL in the mock gives them that role there
    /// (by their own rule or the domain's), every directory user an ACL names lists that calendar, and each
    /// group an ACL names is one of the tenant's groups.
    @Test func theCalendarsAgreeWithOneAnother() async throws {
        let groups = Set(try lines("groups.json").map { try value("email", in: $0) })
        let people = ["alice@example.com", "bob@example.com", "carol@example.com", "dana@example.com"]
        var listed: [String: [String: String]] = [:]   // calendar -> person -> role
        for person in people {
            let read = try await run(GamCommands.printUserCalendars(email: person).argv)
            #expect(read.exitCode == 0, "\(read.stderr)")
            for record in GamOutput.records(read.stdout) {
                listed[try #require(record["id"]?.string), default: [:]][person] = record["accessRole"]?.string
            }
            #expect(listed[person]?[person] == "owner", "\(person) owns their primary calendar")
        }
        let acls = try FileManager.default.contentsOfDirectory(atPath: Fixtures.mockGamData.appending(path: "calendar_acls").path)
        // Eight the Calendars screens read, and All Hands, a company calendar no one lists yet: onboarding subscribes to it.
        #expect(acls.count == 9)
        for file in acls {
            let calendar = String(file.dropLast(".json".count))
            let rules = try lines("calendar_acls/\(file)").compactMap { JSONValue.parse($0)?.object }
            var roles: [String: String] = [:]
            for rule in rules {
                let scope = try #require(rule["scope"]?.object)
                let id = try #require(rule["id"]?.string), role = try #require(rule["role"]?.string)
                switch scope["type"]?.string {
                case "user":
                    let who = try #require(scope["value"]?.string)
                    #expect(id == "user:\(who)")
                    roles[who] = role
                    if people.contains(who) { #expect(listed[calendar]?[who] == role, "\(who) lists \(calendar) as \(role)") }
                case "group":
                    #expect(groups.contains(try #require(scope["value"]?.string)), "\(id) is one of the tenant's groups")
                case "domain":
                    #expect(id == "domain:example.com" && scope["value"]?.string == "example.com")
                    for person in people where roles[person] == nil && listed[calendar]?[person] != nil {
                        roles[person] = role
                    }
                default:
                    #expect(id == "default" && scope["value"] == nil, "a default rule has no value")
                }
            }
            if calendar.hasSuffix(".calendar.google.com") { #expect(roles[calendar] == "owner", "\(calendar) owns itself") }
            for (person, role) in listed[calendar] ?? [:] { #expect(roles[person] == role, "\(person)'s \(role) on \(calendar)") }
        }
    }

    // MARK: writes (C2a)

    /// Every object's keys in sorted order, as `json.dumps(sort_keys=True)` writes them.
    static func sortedKeys(_ value: JSONValue) -> Bool {
        guard let object = value.object else { return true }
        let keys = object.map(\.key)
        return keys == keys.sorted() && object.allSatisfy { sortedKeys($0.value) }
    }

    /// The rules of a calendar as the mock prints them now, as (id, role).
    private func rules(_ calendar: String, state: URL) async throws -> [String] {
        let read = try await run(GamCommands.printCalendarACLs(calendarID: calendar).argv, state: state)
        #expect(read.exitCode == 0 || read.exitCode == 60, "\(read.stderr)")
        return GamOutput.records(read.stdout).map { "\($0["id"]?.string ?? "?")=\($0["role"]?.string ?? "?")" }
    }

    /// F5/F6: an added rule is kept in GAM's form: the scope as `normalizeRuleId` makes it (a bare name gets the
    /// domain, `domain` the domain's, an address lowercased) and the role as `CALENDAR_ACL_ROLES_MAP` maps it;
    /// a scope that already has a rule has it replaced, as Google's insert does.
    @Test func anAddThenPrintShowsItInGamsForm() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        let before = try await rules(Self.team, state: state)
        let add = try await run(GamCommands.addCalendarACL(calendarID: Self.team, scope: "Dana@Example.com", role: .editor).argv,
                                state: state, admin: "admin@example.com")
        #expect(add.exitCode == 0, "\(add.stderr)")
        #expect(add.stdout == "Calendar: \(Self.team), Calendar ACL: (Scope: user:dana@example.com, Role: writer), Added\n")
        #expect(try await run(GamCommands.addCalendarACL(calendarID: Self.team, scope: "bob@example.com", role: .freeBusy).argv,
                              state: state).exitCode == 0)
        #expect(try await run(GamCommands.addCalendarACL(calendarID: Self.team, scope: "domain", role: .reader).argv,
                              state: state).exitCode == 0)
        #expect(try await run(GamCommands.addCalendarACL(calendarID: Self.team, scope: "erin", role: .writerWithoutPrivateAccess).argv,
                              state: state).exitCode == 0)
        let after = try await rules(Self.team, state: state)
        #expect(after == before.map {
            $0 == "user:bob@example.com=reader" ? "user:bob@example.com=freeBusyReader"
                : $0 == "domain:example.com=freeBusyReader" ? "domain:example.com=reader" : $0
        } + ["user:dana@example.com=writer", "user:erin@example.com=writerWithoutPrivateAccess"])
        // Every line still in the form GAM prints it.
        let file = try String(contentsOf: state.appending(path: "acls/\(Self.team)"), encoding: .utf8)
        for line in file.split(separator: "\n") {
            let value = try #require(JSONValue.parse(String(line)))
            #expect(String(line).utf8.elementsEqual(JSONValue.dumps(value).utf8) && Self.sortedKeys(value), "\(line)")
        }
        // Another calendar is untouched; a print without the state reads the data file.
        #expect(try await rules(Self.team, state: try stateFolder()) == before)
    }

    /// F6: deleting a rule that isn't there fails "Not Found", exit 50; one that is goes.
    @Test func deletingAMissingRuleFails50() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        let missing = try await run(GamCommands.deleteCalendarACL(calendarID: Self.team, scope: "nobody@example.com").argv, state: state)
        #expect(missing.exitCode == 50)
        #expect(missing.stderr == "Calendar: \(Self.team), Calendar ACL: (Scope: user:nobody@example.com), Delete Failed: Not Found\n")
        #expect(GamError(exitCode: missing.exitCode, stderr: missing.stderr).kind == .notFound)
        for token in ["bob@example.com", "group:sales@example.com", "domain:example.com"] {
            let gone = try await run(GamCommands.deleteCalendarACL(calendarID: Self.team, scope: token).argv, state: state)
            #expect(gone.exitCode == 0, "\(token): \(gone.stderr)")
        }
        #expect(try await rules(Self.team, state: state)
                == ["user:\(Self.team)=owner", "user:alice@example.com=owner", "user:carol@example.com=writer"])
        let again = try await run(GamCommands.deleteCalendarACL(calendarID: Self.team, scope: "bob@example.com").argv, state: state)
        #expect(again.exitCode == 50, "bob's rule is gone")
        let defaultRule = try await run(GamCommands.deleteCalendarACL(email: "alice@example.com", scope: "default").argv, state: state)
        #expect(defaultRule.exitCode == 0 && defaultRule.stdout.contains("(Scope: default), Deleted"), "\(defaultRule.stderr)")
        let unknown = try await run(GamCommands.deleteCalendarACL(calendarID: "nosuch@group.calendar.google.com", scope: "bob@example.com").argv)
        #expect(unknown.exitCode == 50 && unknown.stderr == "Calendar: nosuch@group.calendar.google.com, Delete Failed: Not Found\n")
    }

    /// F4: Google refuses the account GAM acts as a change to its own access: the admin for an ID ending
    /// `.calendar.google.com`, the address itself otherwise, the person for their own primary calendar.
    @Test func ownAccessIsRefusedAsGoogleRefusesIt() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        let refusals: [[String]] = [
            GamCommands.addCalendarACL(calendarID: Self.team, scope: "admin@example.com").argv,
            GamCommands.addCalendarACL(calendarID: "alice@example.com", scope: "alice@example.com").argv,
            GamCommands.addCalendarACL(email: "alice@example.com", target: "alice@example.com").argv,
            GamCommands.deleteCalendarACL(email: "alice@example.com", scope: "alice@example.com").argv,
        ]
        for argv in refusals {
            let refused = try await run(argv, state: state, admin: "admin@example.com")
            #expect(refused.exitCode == 50, "\(argv)")
            #expect(refused.stderr.hasSuffix("Failed: Cannot change your own access level.\n"), "\(refused.stderr)")
            #expect(GamError(exitCode: refused.exitCode, stderr: refused.stderr).kind == .ownACL)
        }
        #expect(try await rules(Self.team, state: state) == (try await rules(Self.team, state: try stateFolder())), "nothing changed")
        // The admin acts only for an ID ending .calendar.google.com: on alice's primary they're anyone.
        let other = try await run(GamCommands.addCalendarACL(calendarID: "alice@example.com", scope: "admin@example.com").argv,
                                  state: state, admin: "admin@example.com")
        #expect(other.exitCode == 0, "\(other.stderr)")
    }

    /// F5: GAM reads the scope as a list: a comma makes two rules; a selector word wants a file.
    @Test func aCommaListIsTwoRulesAsGamReadsIt() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        let two = try await run(GamCommands.addCalendarACL(calendarID: Self.team, scope: "dana@example.com,erin@example.com").argv, state: state)
        #expect(two.exitCode == 0, "\(two.stderr)")
        #expect(two.stdout.split(separator: "\n").count == 2)
        #expect(try await rules(Self.team, state: state).suffix(2) == ["user:dana@example.com=reader", "user:erin@example.com=reader"])
        let file = try await run(GamCommands.addCalendarACL(calendarID: Self.team, scope: "file").argv, state: state)
        #expect(file.exitCode == 2 && file.stderr.contains("Missing argument"), "\(file.stderr)")
    }

    /// A subscribe acts as the person: one who isn't a user fails as any per-user call fails (exit 50), and a
    /// calendar already in their list is Google's `duplicate` (exit 50, Q7). Success is GAM's line (F6), one
    /// level in, as addCalendars prints each calendar's line (Ind.Increment, two spaces).
    @Test func subscribeAsANonUserFails() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        let stranger = try await run(GamCommands.subscribeCalendar(email: "nobody@example.com", calendarID: Self.team).argv, state: state)
        #expect(stranger.exitCode == 50)
        #expect(GamError(exitCode: stranger.exitCode, stderr: stranger.stderr).kind == .notFound, "\(stranger.stderr)")
        let added = try await run(GamCommands.subscribeCalendar(email: "dana@example.com", calendarID: Self.team).argv, state: state)
        #expect(added.exitCode == 0 && added.stdout == "  User: dana@example.com, Calendar: \(Self.team), Added\n", "\(added.stderr)")
        let twice = try await run(GamCommands.subscribeCalendar(email: "dana@example.com", calendarID: Self.team).argv, state: state)
        #expect(twice.exitCode == 50 && twice.stderr == "  User: dana@example.com, Calendar: \(Self.team), Add Failed: Duplicate\n", "\(twice.stderr)")
        let listed = try await run(GamCommands.subscribeCalendar(email: "bob@example.com", calendarID: Self.team).argv, state: state)
        #expect(listed.exitCode == 50, "bob lists Team Calendar already")
        let unknown = try await run(GamCommands.subscribeCalendar(email: "dana@example.com", calendarID: "nosuch@group.calendar.google.com").argv)
        #expect(unknown.exitCode == 50 && GamError(exitCode: unknown.exitCode, stderr: unknown.stderr).kind == .notFound)
    }

    /// Google's calendarList.insert finds only a calendar the person can see: without a rule for them, a group they are in,
    /// their domain or `default`, the subscribe fails "Not Found", exit 50, as a missing calendar does. A group's access
    /// reaches its members, those of a group inside it (carol, through it@ in sales@), and everyone when the CUSTOMER row is
    /// a member (staff@); never a person outside it. A bare address is a person's rule (GAM's `normalizeRuleId`), so a group
    /// shared that way gives its members nothing.
    @Test func aSubscribeNeedsAccessToTheCalendar() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        // Dana's own calendar: only she has a rule, and nobody else lists it.
        let dana = "dana@example.com"
        func subscribe(_ who: String, _ calendar: String = dana) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
            try await run(GamCommands.subscribeCalendar(email: who, calendarID: calendar).argv, state: state)
        }
        func share(_ scope: String) async throws -> Int32 {
            try await run(GamCommands.addCalendarACL(email: dana, target: scope).argv, state: state).exitCode
        }
        let before = try await subscribe("alice@example.com")
        #expect(before.exitCode == 50 && before.stderr == "  User: alice@example.com, Calendar: \(dana), Add Failed: Not Found\n",
                "\(before.stderr)")
        #expect(try await share("sales@example.com") == 0)
        #expect(try await subscribe("alice@example.com").exitCode == 50, "a bare address made a person's rule")
        #expect(try await share("group:sales@example.com") == 0)
        #expect(try await subscribe("alice@example.com").exitCode == 0, "a member")
        #expect(try await subscribe("carol@example.com").exitCode == 0, "a member of a group inside it")
        let outsider = try await subscribe("admin@example.com")
        #expect(outsider.exitCode == 50 && outsider.stderr.hasSuffix("Add Failed: Not Found\n"), "admin isn't sales'")
        #expect(try await share("group:staff@example.com") == 0)
        #expect(try await subscribe("admin@example.com").exitCode == 0, "staff@ holds the CUSTOMER row: everyone")
        // The domain's rule on Team Calendar gives everyone in example.com access.
        #expect(try await subscribe(dana, Self.team).exitCode == 0)
    }

    /// A person with Calendar off: GAM's per-user refusal, exit 73, for a subscribe and for their own rules.
    @Test func subscribeWithCalendarOffExits73() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        try marker("nocalendar/dana@example.com", in: state)
        let subscribe = try await run(GamCommands.subscribeCalendar(email: "dana@example.com", calendarID: Self.team).argv, state: state)
        #expect(subscribe.exitCode == 73)
        #expect(GamError(exitCode: subscribe.exitCode, stderr: subscribe.stderr).kind == .serviceNotEnabled, "\(subscribe.stderr)")
        let share = try await run(GamCommands.addCalendarACL(email: "dana@example.com", target: "bob@example.com").argv, state: state)
        #expect(share.exitCode == 73)
    }

    // MARK: events and a calendar's delete (docs/domains/calendars.md, "Events")

    /// `print events` prints `calendarId,id,JSON` with each event the query selects, in GAM's dialect, after the "Getting"
    /// line (_printShowCalendarEvents, :43257-43302 at 7.51.00); none is the titles alone and exit 60; an event id reads
    /// that one event, and one Google lacks fails "Print Failed: Not Found", exit 50, as does an unknown calendar.
    @Test func eventReadsPrintGamsBytesAndFailAsGamFails() async throws {
        let events = try lines("calendar_events/\(Self.team).json")
        let standup = try #require(events.first { $0.contains("Weekly Standup") })
        let found = try await run(GamCommands.printEvents(calendarID: Self.team, query: "STAND").argv)
        #expect(found.exitCode == 0 && found.stderr == "Getting Events for \(Self.team)\n")
        #expect(bytes(found.stdout) == bytes(GamOutputTests.gamRow(["calendarId", "id", "JSON"])
            + GamOutputTests.gamRow([Self.team, try value("id", in: standup), standup])))
        let none = try await run(GamCommands.printEvents(calendarID: Self.team, query: "nothing like it").argv)
        #expect(none.exitCode == 60 && none.stdout == "calendarId,id,JSON\n")
        let one = try await run(GamCommands.getEvent(calendarID: Self.team, eventID: "0a1b2c3d4e5f6g7h8i9j").argv)
        #expect(one.exitCode == 0 && GamOutput.records(one.stdout).count == 1)
        let missing = try await run(GamCommands.getEvent(calendarID: Self.team, eventID: "0000000000").argv)
        #expect(missing.exitCode == 50 && missing.stderr.hasSuffix("Calendar: \(Self.team), Event: 0000000000, Print Failed: Not Found\n"))
        #expect(GamError(exitCode: missing.exitCode, stderr: missing.stderr).kind == .notFound)
        let unknown = try await run(GamCommands.printEvents(calendarID: "nosuch@group.calendar.google.com", query: "x").argv)
        #expect(unknown.exitCode == 50 && unknown.stderr.contains("Calendar: nosuch@group.calendar.google.com, Print Failed: Not Found"))
        // Never an unbounded read: GAM's other selectors aren't modelled, and a field GAM doesn't know is its invalid choice.
        let other = try await run(["calendars", Self.team, "print", "events", "matchfield", "summary", "x", "formatjson"])
        #expect(other.exitCode == 2 && other.stderr.contains("isn't modelled"))
        let field = try await run(["calendars", Self.team, "print", "events", "fields", "id,bogus", "formatjson"])
        #expect(field.exitCode == 2 && field.stderr.contains("Invalid choice (bogus)"))
    }

    /// `delete events` without `doit` deletes nothing (exit 51); with it the event is gone, a second delete is Google's 410,
    /// and reading it by ID returns it cancelled. Every record the data holds is GAM's shape: base32hex ids, keys sorted.
    @Test func anEventDeleteNeedsDoitAndStays() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        let id = "0a1b2c3d4e5f6g7h8i9j"
        let dry = try await run(GamCommands.deleteEvent(calendarID: Self.team, eventID: id, doit: false).argv, state: state)
        #expect(dry.exitCode == 51)
        let gone = try await run(GamCommands.deleteEvent(calendarID: Self.team, eventID: id).argv, state: state)
        #expect(gone.exitCode == 0 && gone.stdout == "Calendar: \(Self.team), Delete 1 Event\n  Calendar: \(Self.team), Event: \(id), Deleted\n")
        let again = try await run(GamCommands.deleteEvent(calendarID: Self.team, eventID: id).argv, state: state)
        #expect(again.exitCode == 50 && again.stderr.contains("Delete Failed: Resource has been deleted"))
        // Google's events.get always returns a deleted event, `status` "cancelled" (Events reference): GAM prints it, exit 0.
        let read = try await run(GamCommands.getEvent(calendarID: Self.team, eventID: id).argv, state: state)
        let original = try #require(try lines("calendar_events/\(Self.team).json").first { $0.contains(id) })
        let cancelled = original.replacingOccurrences(of: #""status": "confirmed""#, with: #""status": "cancelled""#)
        #expect(read.exitCode == 0 && bytes(read.stdout) == bytes(GamOutputTests.gamRow(["calendarId", "id", "JSON"])
            + GamOutputTests.gamRow([Self.team, id, cancelled])), "\(read.stdout)\(read.stderr)")
        // events.list leaves it out.
        let listed = try await run(GamCommands.printEvents(calendarID: Self.team, query: "all hands").argv, state: state)
        #expect(listed.exitCode == 60)
        for line in try lines("calendar_events/\(Self.team).json") {
            let event = try #require(JSONValue.parse(line))
            #expect(Self.sortedKeys(event), "\(line)")
            let eventID = try value("id", in: line)
            #expect((5...1024).contains(eventID.count) && eventID.unicodeScalars.allSatisfy { ("a"..."v").contains($0) || ("0"..."9").contains($0) },
                    "Google's event ids are base32hex: \(eventID)")
        }
    }

    /// `remove calendars` acts as the data owner: "Removed" one level in; anyone else is refused, a co-owner (an `owner`
    /// rule) too, as is their primary; afterwards the calendar is unknown to every read and leaves each list.
    @Test func aCalendarRemoveActsAsItsOwner() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        let notOwner = try await run(GamCommands.removeCalendar(owner: "bob@example.com", calendarID: Self.team).argv, state: state)
        #expect(notOwner.exitCode == 50 && notOwner.stderr.contains("Remove Failed: Forbidden"))
        try marker("acls/\(Self.team)", in: state, try lines("calendar_acls/\(Self.team).json").joined(separator: "\n")
            + "\n" + #"{"id": "user:carol@example.com", "role": "owner", "scope": {"type": "user", "value": "carol@example.com"}}"# + "\n")
        let coOwner = try await run(GamCommands.removeCalendar(owner: "carol@example.com", calendarID: Self.team).argv, state: state)
        #expect(coOwner.exitCode == 50 && coOwner.stderr.contains("Remove Failed: Forbidden"), "only the data owner deletes it")
        let primary = try await run(GamCommands.removeCalendar(owner: "alice@example.com", calendarID: "alice@example.com").argv, state: state)
        #expect(primary.exitCode == 50)
        let stranger = try await run(GamCommands.removeCalendar(owner: "nobody@example.com", calendarID: Self.team).argv, state: state)
        #expect(stranger.exitCode == 50 && GamError(exitCode: stranger.exitCode, stderr: stranger.stderr).kind == .notFound)
        let removed = try await run(GamCommands.removeCalendar(owner: "alice@example.com", calendarID: Self.team).argv, state: state)
        #expect(removed.exitCode == 0
                && removed.stdout == "User: alice@example.com, Remove 1 Calendar\n  User: alice@example.com, Calendar: \(Self.team), Removed\n")
        let rules = try await run(GamCommands.printCalendarACLs(calendarID: Self.team).argv, state: state)
        #expect(rules.exitCode == 50)
        let bob = try await run(GamCommands.printUserCalendars(email: "bob@example.com").argv, state: state)
        #expect(bob.exitCode == 0 && !bob.stdout.contains(Self.team))
        let twice = try await run(GamCommands.removeCalendar(owner: "alice@example.com", calendarID: Self.team).argv, state: state)
        #expect(twice.exitCode == 50 && twice.stderr.contains("Remove Failed: Not Found"))
    }

    /// `calendars <c> print settings fields id,dataowner formatjson` is `calendarId,JSON` with Google's `dataOwner` (set only for a
    /// secondary calendar), the keys sorted; one with no owner has none; one GAM can't get fails "Print Failed: Not Found",
    /// exit 50, with the titles alone; a handover moves it; only the app's fields are modelled.
    @Test func aCalendarsSettingsNameItsDataOwner() async throws {
        let state = try stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        let team = try await run(GamCommands.printCalendarSettings(calendarID: Self.team).argv, state: state)
        #expect(team.exitCode == 0 && team.stderr.isEmpty)
        #expect(bytes(team.stdout) == bytes(GamOutputTests.gamRow(["calendarId", "JSON"])
            + GamOutputTests.gamRow([Self.team, #"{"dataOwner": "alice@example.com", "id": "c_team@group.calendar.google.com"}"#])))
        #expect(CalendarDeletion.dataOwner(GamOutput.records(team.stdout)) == "alice@example.com")
        let ops = try await run(GamCommands.printCalendarSettings(calendarID: "c_ops@group.calendar.google.com").argv, state: state)
        #expect(CalendarDeletion.dataOwner(GamOutput.records(ops.stdout)) == "carol@example.com")
        let allhands = try await run(GamCommands.printCalendarSettings(calendarID: "c_allhands@group.calendar.google.com").argv, state: state)
        #expect(allhands.exitCode == 0 && CalendarDeletion.dataOwner(GamOutput.records(allhands.stdout)) == nil)
        let unknown = try await run(GamCommands.printCalendarSettings(calendarID: "nosuch@group.calendar.google.com").argv, state: state)
        #expect(unknown.exitCode == 50 && unknown.stdout == "calendarId,JSON\n"
                && unknown.stderr == "Calendar: nosuch@group.calendar.google.com, Print Failed: Not Found\n")
        #expect(GamError(exitCode: unknown.exitCode, stderr: unknown.stderr).kind == .notFound)
        try marker("calendar_owner/\(Self.team)", in: state, "carol@example.com")
        let handed = try await run(GamCommands.printCalendarSettings(calendarID: Self.team).argv, state: state)
        #expect(CalendarDeletion.dataOwner(GamOutput.records(handed.stdout)) == "carol@example.com")
        let other = try await run(["calendars", Self.team, "print", "settings", "fields", "id,summary", "formatjson"])
        #expect(other.exitCode == 2 && other.stderr.contains("isn't modelled"))
    }

    /// `after`/`before` are instants, as getTimeOrDeltaFromNow passes them on: a full time with its offset, or a bare day as
    /// midnight UTC. Google keeps an event ending after `timeMin` and starting before `timeMax`: a 2-3pm meeting (New York) is
    /// on its day either way, and gone from a range that ends as it starts.
    @Test func eventTimesCompareInstants() async throws {
        func ids(_ after: String, _ before: String) async throws -> [String] {
            let result = try await run(GamCommands.printEvents(calendarID: Self.team, after: after, before: before).argv)
            #expect(result.exitCode == 0 || result.exitCode == 60, "\(result.stderr)")
            return GamOutput.records(result.stdout).compactMap { $0["id"]?.string }
        }
        let planning = "q3planning0v1u2t3s4r"
        #expect(try await ids("2026-07-14", "2026-07-15") == [planning])
        #expect(try await ids("2026-07-14T00:00:00-04:00", "2026-07-15T00:00:00-04:00") == [planning])
        #expect(try await ids("2026-07-14T15:00:00-04:00", "2026-07-15T00:00:00-04:00").isEmpty, "it ends as the range begins")
        #expect(try await ids("2026-07-14T00:00:00Z", "2026-07-14T18:00:00Z").isEmpty, "it starts as the range ends")
        #expect(try await ids("2026-07-14T00:00:00Z", "2026-07-14T18:00:01Z") == [planning])
        let odd = try await run(GamCommands.printEvents(calendarID: Self.team, after: "2026-07-14T00:00").argv)
        #expect(odd.exitCode == 2 && odd.stderr.contains("isn't modelled"))
    }

    /// A day the calendar doesn't have is GAM's usage error (getTimeOrDeltaFromNow: strptime, then arrow.get, refuse it),
    /// never a day rolled forward the way macOS `date -j` rolls 2026-02-30 to March 2 (GamGUI's mock did, 2026-11-13).
    @Test func anImpossibleDayIsRefusedAsGamRefusesIt() async throws {
        let bare = try await run(GamCommands.printEvents(calendarID: Self.team, after: "2026-02-30").argv)
        #expect(bare.exitCode == 2 && bare.stderr.contains("ERROR: Invalid argument: Expected <yyyy-mm-dd>\n"), "\(bare.stderr)")
        let full = try await run(GamCommands.printEvents(calendarID: Self.team, after: "2027-02-29T00:00:00-05:00").argv)
        #expect(full.exitCode == 2
            && full.stderr.contains("ERROR: Invalid argument: Expected <yyyy-mm-ddThh:mm:ss[.fff](Z|(+|-(hh:mm)))>\n"), "\(full.stderr)")
        for day in ["2028-02-29", "2026-12-31", "2000-02-29"] {
            let read = try await run(GamCommands.printEvents(calendarID: Self.team, after: day).argv)
            #expect(read.exitCode == 0 || read.exitCode == 60, "\(day): \(read.stderr)")
        }
    }
}
