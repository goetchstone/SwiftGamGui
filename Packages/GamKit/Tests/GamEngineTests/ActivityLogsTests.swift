import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The activity logs (docs/plans/2026-10-19-compromised-account.md slice 2): every log in one row shape, each event in
/// words, what Google flagged, the addresses to filter by, and the mock answering as GAM's doReport prints.
@Suite("Activity logs")
struct ActivityLogsTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    private func report(_ read: GamRead, state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        return try await mock.runRaw(read.argv, configDirectory: config, extraEnvironment: environment)
    }

    private func rows(_ result: GamResult, _ application: ActivityLogs.Application) -> [ActivityLogs.Row] {
        ActivityLogs.rows(result.stdout.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("Created: ") && !$0.hasPrefix("Config File: ") }.joined(separator: "\n"), application: application)
    }

    private func read(_ application: ActivityLogs.Application, users: [String] = [], ip: String = "") async throws -> [ActivityLogs.Row] {
        let result = try await report(try GamCommands.reportActivity(application, users: users, hours: 72, ip: ip, maxActivities: 1000))
        #expect(result.exitCode == 0, "\(result.stderr)")
        return rows(result, application)
    }

    @Test func aPersonsSignInsAreTheirsNewestFirstInWords() async throws {
        let result = try await report(try GamCommands.reportActivity(.login, users: ["carol@example.com"], hours: 720, maxActivities: 1000))
        #expect(result.exitCode == 0 && result.stderr.contains("Getting all Activities for carol@example.com"), "\(result.stderr)")
        let read = rows(result, .login)
        #expect(read.map(\.who).allSatisfy { $0 == "carol@example.com" } && read.count == 7)
        #expect(read.map(\.time) == read.map(\.time).sorted(by: >))
        // After the lock the attacker's address tried her old password; before it, it blocked the bounce address and added a
        // passkey. Google's own warning has no actor, so a read of her account leaves it out (the mock's strict guess).
        #expect(read[0].words == "Sign-in failed" && read[0].ip == "198.51.100.23" && !read[0].flagged)
        #expect(read[1].words == "Blocked a sender in Gmail" && read[1].details == ["blocked: mailer-daemon@googlemail.com"])
        #expect(read[2].words == "Added a passkey" && read[2].ip == "198.51.100.23")
        #expect(read[3].words == "Signed in" && read[3].ip == "198.51.100.23" && read[3].flagged, "is_suspicious")
        #expect(read[3].details == ["by password", "Google marked it suspicious"])
        #expect(!read.contains { $0.event == "suspicious_login" })
        #expect(read[5].words == "Asked to prove it's them" && read[5].details == ["by password", "challenge: google authenticator",
                                                                                  "challenge passed"] && !read[5].flagged)
        #expect(read[3].date == Date(timeIntervalSince1970: 1_792_419_160), "2026-10-19T14:12:40Z")
        #expect(ActivityLogs.addresses(in: read) == ["198.51.100.23", "203.0.113.10"], "the flagged address first")
    }

    /// Every log filtered by the attacker's address: the same IP in the sign-ins, the app grant, the Gmail send, the
    /// access log and the recovery change, and another account's sign-in from it too.
    @Test func everyLogByTheAttackersAddress() async throws {
        let attacker = "198.51.100.23"
        #expect(Set(try await read(.login, ip: attacker).map(\.who)) == ["carol@example.com", "dana@example.com"])
        #expect(try await read(.token, ip: attacker).map(\.event) == ["authorize"])
        #expect(try await read(.gmail, ip: attacker).map(\.words) == ["Sent a message", "Viewed a message"])
        #expect(try await read(.accessEvaluation, ip: attacker).map(\.event) == ["deny_cookie_validation_request", "allow_token_request"])
        #expect(try await read(.userAccounts, ip: attacker).map(\.words) == ["Changed the recovery phone"])
        #expect(try await read(.chat, ip: attacker).map(\.words) == ["Posted a Chat message"])
        #expect(try await read(.saml, ip: attacker).map(\.words) == ["Signed in to an app through Google"])
        #expect(try await read(.takeout, ip: attacker).map(\.words) == ["Started a Takeout export of the account's data"])
        #expect(try await read(.vault, ip: attacker).isEmpty, "no fixture: GAM's titles alone")
        let all = try await read(.login)
        #expect(Set(all.map(\.who)) == ["carol@example.com", "dana@example.com", "alice@example.com"])
    }

    /// Gmail's parameters are nested: each is named by its chain, as the one shape keeps them. Every Gmail event is
    /// `delivery`: its words are what `event_info.mail_event_type` says happened (Google's "Gmail Activity Events"), and
    /// the type isn't said again in its details.
    @Test func gmailsNestedParametersAreNamedByTheirChain() async throws {
        let read = try await read(.gmail, users: ["carol@example.com"])
        #expect(read.map(\.words) == ["Sent a message", "Viewed a message", "Sent a message"])
        let send = try #require(read.first)
        #expect(send.parameters.contains(ActivityLogs.Parameter(name: "event_info.mail_event_type", value: "1")))
        #expect(send.parameters.contains(ActivityLogs.Parameter(name: "message_info.subject", value: "Shared file: Q4 invoices")))
        #expect(send.parameters.contains(ActivityLogs.Parameter(name: "message_info.num_message_attachments", value: "1")))
        #expect(send.parameters.contains(ActivityLogs.Parameter(name: "type", value: "email")))
        #expect(!send.parameters.contains { $0.name.hasPrefix("parameters") }, "never a raw flattened column")
        #expect(send.details.first == "message_info.subject: Shared file: Q4 invoices")
        #expect(!send.details.contains { $0.contains("mail_event_type") })
        // Each of Google's types in words of its own; one it adds later, or none, still reads.
        #expect((0...35).allSatisfy { !ActivityLogs.gmailWords("\($0)").hasPrefix("A Gmail event") })
        #expect(Set((0...35).map { ActivityLogs.gmailWords("\($0)") }).count == 36)
        #expect(ActivityLogs.gmailWords("29") == "Saved a draft" && ActivityLogs.gmailWords("13") == "Moved a message to Trash")
        #expect(ActivityLogs.gmailWords("36") == "A Gmail event (type 36)" && ActivityLogs.gmailWords("") == "A Gmail event")
    }

    @Test func appGrantsSayTheAppAndItsAccess() async throws {
        let grants = try await read(.token, users: ["carol@example.com"])
        #expect(grants.count == 2 && grants[0].words == "Granted an app access")
        #expect(grants[0].details == ["Mail Sync Pro", "access: mail.google.com, contacts.readonly"])
        #expect(try await read(.token, users: ["alice@example.com"]).isEmpty)
    }

    /// Several accounts are `select users`: each one's rows; an account that isn't a user is GAM's entityUnknownWarning
    /// after the others' rows (exit 56); a log the edition lacks is GAM's systemErrorExit (exit 4); only the app's shape.
    /// A window as two times keeps the events before its end, that second left out (the strict guess); a time that isn't one
    /// (Feb 30, a 13th month) and an end before its start are GAM's usage errors; a relative start with an end time isn't
    /// the app's form; Gmail's 30 days count between the two times.
    @Test func aWindowAsTimesIsReadAsGamReadsIt() async throws {
        func argv(_ start: String, _ end: String, _ application: String = "login") -> GamRead {
            GamRead(["report", application, "user", "all", "start", start, "end", end, "maxactivities", "100"])
        }
        let before = try await report(argv("2026-10-17T00:00:00Z", "2026-10-19T14:21:00Z"))
        let kept = rows(before, .login)
        #expect(before.exitCode == 0 && kept.count == 7 && kept.allSatisfy { $0.time < "2026-10-19T14:21:00Z" }, "\(kept.map(\.time)) \(before.stderr)")
        for (start, end) in [("2026-02-30T00:00:00Z", "2026-10-19T14:21:00Z"), ("2026-10-17T00:00:00Z", "2026-13-01T00:00:00Z"),
                             ("2026-10-19T14:21:00Z", "2026-10-17T00:00:00Z"), ("-72h", "2026-10-19T14:21:00Z")] {
            #expect(try await report(argv(start, end)).exitCode == 2, "\(start) \(end)")
        }
        #expect(try await report(argv("2026-09-01T00:00:00Z", "2026-10-19T14:21:00Z", "gmail")).exitCode == 53, "over 30 days")
    }

    @Test func theMockAnswersOnlyAsGamDoes() async throws {
        let two = try await report(try GamCommands.reportActivity(.login, users: ["carol@example.com", "dana@example.com"], hours: 72,
                                                                  maxActivities: 1000))
        #expect(two.exitCode == 0 && Set(rows(two, .login).map(\.who)) == ["carol@example.com", "dana@example.com"])
        let stranger = try await report(try GamCommands.reportActivity(.login, users: ["carol@example.com", "stranger@example.com"],
                                                                       hours: 3, maxActivities: 5))
        #expect(stranger.exitCode == 56 && stranger.stderr.contains("User: stranger@example.com, Does not exist"))
        #expect(rows(stranger, .login).count == 5, "the others' rows still come")
        #expect(rows(try await report(try GamCommands.reportActivity(.login, users: ["carol@example.com"], hours: 3, maxActivities: 2)),
                     .login).count == 2)
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state.appending(path: "nolog"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try Data().write(to: state.appending(path: "nolog/gmail"))
        let lacking = try await report(try GamCommands.reportActivity(.gmail, hours: 3, maxActivities: 5), state: state)
        #expect(lacking.exitCode == 4 && lacking.stderr.contains("ERROR:"))
        let bare = try await report(GamRead(["report", "login", "user", "carol@example.com", "start", "-3d"]))
        #expect(bare.exitCode == 2 && bare.stderr.contains("isn't modelled"), "no cap is never answered")
    }

    /// The mock is no kinder than GAM (review 2026-10-19): only the app's start form; Gmail over 30 days is the API's bad
    /// request; an address outside the domain is "Service not applicable"; an account listed twice is read once; the
    /// admin log's accounts are the actor only with `userisactor`.
    @Test func theMockRefusesWhatGamRefuses() async throws {
        #expect(try await report(GamRead(["report", "login", "user", "carol@example.com", "start", "-7hd", "end", "now",
                                          "maxactivities", "5"])).exitCode == 2)
        let gmail = try await report(GamRead(["report", "gmail", "user", "carol@example.com", "start", "-4320h", "end", "now",
                                              "maxactivities", "5"]))
        #expect(gmail.exitCode == 56 && gmail.stderr.contains("Does not exist"))
        #expect(try await report(GamRead(["report", "gmail", "user", "all", "start", "-31d", "end", "now", "maxactivities", "5"])).exitCode == 53)
        let outside = try await report(try GamCommands.reportActivity(.login, users: ["someone@example.org"], hours: 3, maxActivities: 5))
        #expect(outside.exitCode == 73 && outside.stderr.contains("Service not applicable"))
        let twice = try await report(GamRead(["report", "login", "select", "users", "carol@example.com,carol@example.com", "start", "-3h",
                                              "end", "now", "maxactivities", "1000"]))
        #expect(rows(twice, .login).count == 7)
        #expect(try await report(GamRead(["report", "login", "user", "carol@example.com", "userisactor", "start", "-3h", "end", "now",
                                          "maxactivities", "5"])).exitCode == 2, "userisactor is the admin log's")
    }

    /// The admin log reads an account two ways, as doReport does: with `userisactor` what it did as an admin; without, the
    /// events naming it (USER_EMAIL), read as `user all` with a filter, so an address that isn't a user reads none, never
    /// "Does not exist". Another person's reset isn't hers.
    @Test func theAdminLogReadsWhatWasDoneToAnAccount() async throws {
        func admin(_ users: [String], _ match: GamCommands.AdminMatch) async throws -> GamResult {
            try await report(try GamCommands.reportActivity(.admin, users: users, hours: 72, maxActivities: 1000, admin: match))
        }
        let done = try await admin(["carol@example.com"], .affected)
        #expect(done.exitCode == 0, "\(done.stderr)")
        let lock = rows(done, .admin)
        #expect(lock.map(\.event) == ["RESET_SIGNIN_COOKIES", "REVOKE_3LO_TOKEN", "DELETE_2SV_SCRATCH_CODES", "CHANGE_PASSWORD"])
        #expect(lock.map(\.words) == ["Signed a person out of every session", "Revoked an app's access",
                                      "Deleted 2-Step Verification backup codes", "Changed a person's password"])
        #expect(lock.allSatisfy { $0.who == "alice@example.com" && $0.ip == "203.0.113.50" })
        #expect(lock[1].details == ["to carol@example.com", "APP_ID: 123456-abc.apps.googleusercontent.com"])
        let acted = try await admin(["carol@example.com"], .actor)
        #expect(acted.exitCode == 0 && rows(acted, .admin).isEmpty, "she did nothing as an admin")
        let stranger = try await admin(["nobody@example.com"], .affected)
        #expect(stranger.exitCode == 0 && rows(stranger, .admin).isEmpty && !stranger.stderr.contains("Does not exist"))
        let notUser = try await admin(["nobody@example.com"], .actor)
        #expect(notUser.exitCode == 56, "as the actor, the API is asked for the account and refuses it")
    }

    /// Google's own account warnings have no actor (a real tenant's log, 2026-10-22): the account they're about is
    /// `affected_email_address`, and the row is that account's. A row with an actor keeps it: there the parameter names
    /// someone else, a blocked sender.
    @Test func googlesOwnWarningIsTheAccountsItsAbout() async throws {
        let all = try await read(.login)
        let warning = try #require(all.first { $0.event == "suspicious_login" })
        #expect(warning.who == "carol@example.com" && warning.words == "Google flagged a suspicious sign-in" && warning.flagged)
        #expect(all.first { $0.event == "blocked_sender" }?.who == "carol@example.com")
    }

    /// One account at the cap is capped though another has none; with no accounts the whole read is one.
    @Test func theCapIsPerAccount() {
        func row(_ who: String, _ index: Int) -> ActivityLogs.Row {
            ActivityLogs.Row(record: ["name": .string("login_success"), "actor.email": .string(who)], application: .login, index: index)
        }
        let full = (0..<ActivityLogs.cap).map { row("a@example.com", $0) }
        #expect(ActivityLogs.capped(full, accounts: ["a@example.com", "b@example.com"]))
        #expect(!ActivityLogs.capped(Array(full.dropLast()), accounts: ["a@example.com", "b@example.com"]))
        #expect(ActivityLogs.capped(full, accounts: []) && ActivityLogs.window(.gmail, asked: 4_320) == 720
                && ActivityLogs.window(.login, asked: 4_320) == 4_320)
    }

    /// Nested parameters in their numeric order (GAM sorts its titles as text), a list's count never a parameter, and one
    /// written both simply and nested said once.
    @Test func parametersAreInOrderOnceEach() {
        var record = JSONObject()
        record["name"] = .string("delivery")
        record["networkInfo.ipAsn"] = .string("2")
        record["networkInfo.ipAsn.0"] = .string("64500")
        record["subject"] = .string("Hi")
        record["parameters"] = .string("1")
        record["parameters.0.multiValue"] = .string("11")
        for index in [0, 1, 10, 2] { record["parameters.0.multiValue.\(index)"] = .string("v\(index)") }
        record["parameters.0.name"] = .string("tags")
        record["parameters.1.name"] = .string("subject")
        record["parameters.1.value"] = .string("Hi")
        let row = ActivityLogs.Row(record: record, application: .gmail, index: 0)
        #expect(row.parameters == [ActivityLogs.Parameter(name: "networkInfo.ipAsn.0", value: "64500"),
                                   ActivityLogs.Parameter(name: "subject", value: "Hi"),
                                   ActivityLogs.Parameter(name: "tags", value: "v0 v1 v2 v10")], "\(row.parameters)")
    }

    @Test func anEventGoogleRaisesIsFlaggedAndTheTableIsTheOneShape() {
        func row(_ fields: [String: String], _ application: ActivityLogs.Application = .login) -> ActivityLogs.Row {
            var record = JSONObject()
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) { record[key] = .string(value) }
            return ActivityLogs.Row(record: record, application: application, index: 0)
        }
        #expect(row(["name": "account_disabled_password_leak"]).flagged)
        #expect(row(["name": "account_disabled_password_leak"]).words == "Google disabled the account: password leaked")
        #expect(row(["name": "login_challenge", "login_challenge_status": "Challenge Failed"]).flagged)
        #expect(!row(["name": "login_success", "is_suspicious": "False"]).flagged)
        #expect(row(["name": "deny_cookie_validation_request"], .accessEvaluation).flagged)
        #expect(row(["name": "titanium_enroll"]).words == "Titanium enroll", "an event not named here is shown as Google names it")
        let table = ActivityLogs.table([row(["name": "login_success", "id.time": "2026-10-19T14:12:40Z", "actor.email": "c@example.com",
                                             "ipAddress": "198.51.100.23", "login_type": "google_password"])])
        #expect(table == [["log", "time", "actor", "event", "ip_address", "flagged", "via", "parameters"],
                          ["login", "2026-10-19T14:12:40Z", "c@example.com", "login_success", "198.51.100.23", "", "",
                           "login_type: google_password"]])
    }

    /// Who acted besides the person: an app (`actor.applicationInfo`) or an AI agent (`isAgenticAction`,
    /// `actor.agentAttributionInfo`), each in words, never among the event's parameters.
    @Test func appsAndAgentsActingAreSaid() async throws {
        let drive = try await read(.drive)
        let download = try #require(drive.first { $0.event == "download" })
        #expect(download.app == "Mail Sync Pro" && download.agent.isEmpty && download.via == "through Mail Sync Pro")
        #expect(download.details.last == "through Mail Sync Pro")
        #expect(!download.parameters.contains { $0.name.hasPrefix("actor.") || $0.name == "isAgenticAction" })
        #expect(drive.first { $0.event == "view" }?.via == "", "the person acted themselves")
        let gemini = try await read(.gemini)
        let agentic = try #require(gemini.first { $0.who == "dana@example.com" })
        #expect(agentic.agent == "the AI agent Inbox Helper (workspace flow), made by dana@example.com" && agentic.words == "Used Gemini")
        #expect(gemini.first { $0.who == "carol@example.com" }?.agent == "")
        let table = ActivityLogs.table([agentic])
        #expect(table[1][6] == "by the AI agent Inbox Helper (workspace flow), made by dana@example.com")
    }

    /// Every log GAM reads the app offers, but Currents' and Jamboard's, whose services have ended; the mock answers each.
    @Test func everyLogGamReadsIsOffered() async throws {
        let offered = Set(ActivityLogs.Application.allCases.map(\.rawValue))
        let gams: Set = ["accessevaluation", "accesstransparency", "admin", "admindataaction", "assignments", "calendar", "chat", "chrome",
                         "classroom", "cloudsearch", "contacts", "contextawareaccess", "datamigration", "datastudio", "directorysync",
                         "drive", "gcp", "geminiinworkspaceapps", "gmail", "graduation", "groups", "groupsenterprise", "keep", "ldap",
                         "login", "meet", "meethardware", "mobile", "profile", "rules", "saml", "takeout", "tasks", "token",
                         "useraccounts", "vault"]
        #expect(offered == gams)
        for application in ActivityLogs.Application.allCases {
            let result = try await report(try GamCommands.reportActivity(application, hours: 24, maxActivities: 5))
            #expect(result.exitCode == 0, "\(application): \(result.stderr)")
        }
    }
}
