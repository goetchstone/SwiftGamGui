import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The Chrome reads against the strict mock: Chrome's log by the account signed in to the profile, and a person's Chrome
/// profiles, each failing as GAM 7.48.30 fails (docs/domains/compromised-account.md, "Chrome").
@Suite("Chrome reads")
struct ChromeReadsTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    private func run(_ argv: [String], state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        let result = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
        // A fresh config folder's own lines, as the real build prints them, aren't the command's output.
        let stdout = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.hasPrefix("Created: ") && !$0.hasPrefix("Config File: ") }.joined(separator: "\n")
        return GamResult(exitCode: result.exitCode, stdout: stdout, stderr: result.stderr, stdoutTruncated: result.stdoutTruncated,
                         stderrTruncated: result.stderrTruncated)
    }

    private func rows(_ result: GamResult) -> [ActivityLogs.Row] {
        ActivityLogs.rows(result.stdout, application: .chrome)
    }

    private func log(_ users: [String] = [], ip: String = "", match: GamCommands.ChromeMatch = .profile) async throws -> [ActivityLogs.Row] {
        let result = try await run(try GamCommands.reportActivity(.chrome, users: users, hours: 72, ip: ip, maxActivities: 1000,
                                                                  chrome: match).argv)
        #expect(result.exitCode == 0, "\(result.stderr)")
        return rows(result)
    }

    /// GAM matches a named user to `DEVICE_USER`, on a Mac the computer's own login name: a work address finds none of a
    /// Mac's events, though a Chromebook's it does. The profile's account finds the Mac's, in words, Chrome's warnings flagged.
    @Test func chromesLogIsReadByTheProfilesAccount() async throws {
        #expect(try await log(["carol@example.com"], match: .device).isEmpty, "GAM's own match: carol's Mac says “carol”")
        let chromebook = try await log(["dana@example.com"], match: .device)
        #expect(chromebook.map(\.event) == ["PASSWORD_BREACH", "CHROME_OS_LOGIN_FAILURE_EVENT"])
        #expect(chromebook.allSatisfy { $0.who == "dana@example.com" }, "a Chromebook's sign-in names no profile: its device user")
        let carol = try await log(["carol@example.com"])
        #expect(carol.map(\.event) == ["PASSWORD_REUSE", "LOGIN_EVENT"] && carol.allSatisfy { $0.who == "carol@example.com" })
        #expect(carol[0].words == "Typed a protected password on another website" && carol[0].flagged)
        #expect(carol[0].details == ["https://login-check.example.net/signin", "on CAROL-MBP (Mac OS X)", "warned", "on a phishing site"])
        #expect(carol[1].words == "Signed in to a website in Chrome" && !carol[1].flagged)
        #expect(carol[1].details == ["https://erp.example.net/login", "as carol", "on CAROL-MBP (Mac OS X)"])
        let everyone = try await log()
        #expect(everyone.count == 7 && everyone.map(\.time) == everyone.map(\.time).sorted(by: >))
        #expect(everyone.last?.event == "EXTENSION_REQUEST" && everyone.last?.who == "carol", "a Mac's own event: its login name")
        #expect(everyone[0].words == "Chrome warned of an unsafe website" && everyone[0].who == "dana@example.com")
        #expect(everyone[0].details == ["https://login-check.example.net/view", "on DANA-MBA (Mac OS X)", "warned, and went on anyway",
                                        "a phishing site"])
        #expect(try await log(ip: "198.51.100.23").isEmpty, "Chrome's events carry no IP address here: `ip` keeps none")
        // GAM passes a filter as given, and Google may match it exactly: the app sends the address lowercased.
        let upper = try await run(["report", "chrome", "user", "all", "filter", "PROFILE_USER_NAME==CAROL@EXAMPLE.COM", "start", "-72h",
                                   "end", "now", "maxactivities", "1000"])
        #expect(upper.exitCode == 0 && rows(upper).isEmpty)
        #expect(try await log(["Carol@Example.com"]).count == 2)
    }

    /// Only the shape the app sends: another filter, a named user with a filter, or Chrome's `select` is refused.
    @Test func theMockRefusesAChromeReadTheAppDoesntSend() async throws {
        let tail = ["start", "-72h", "end", "now", "maxactivities", "1"]
        for argv in [["report", "chrome", "user", "all", "filter", "DEVICE_USER==carol"] + tail,
                     ["report", "chrome", "user", "carol@example.com", "filter", "PROFILE_USER_NAME==carol@example.com"] + tail,
                     ["report", "chrome", "select", "users", "carol@example.com,dana@example.com"] + tail,
                     ["report", "login", "user", "all", "filter", "PROFILE_USER_NAME==carol@example.com"] + tail] {
            let result = try await run(argv)
            #expect(result.exitCode == 2 && result.stderr.contains("isn't modelled"), "\(argv)")
        }
    }

    /// A person's profiles, the most recently used first; none for someone signed in to no Chrome profile.
    @Test func aPersonsChromeProfilesAreTheirsMostRecentFirst() async throws {
        let read = try GamCommands.printChromeProfiles(user: "carol@example.com")
        let result = try await run(read.argv)
        let profiles = try ChromeProfiles.profiles(result, argv: read.argv)
        #expect(profiles.map(\.device) == ["CAROL-MBP", "OptiPlex 7010"], "the hostname, or the model without one")
        #expect(profiles.allSatisfy { $0.userEmail == "carol@example.com" })
        #expect(profiles[0].displayName == "Work" && profiles[0].system == "macOS 15.6.1" && profiles[1].system == "Windows 10.0.22631" && profiles[0].browser == "141.0.7390.66 (stable)")
        #expect(profiles[0].lastActive == (try? Date("2026-10-19T08:55:12Z", strategy: .iso8601)) && !profiles[0].onManagedDevice)
        #expect(profiles[1].onManagedDevice && profiles[1].firstEnrolled != nil)
        let alice = try GamCommands.printChromeProfiles(user: "alice@example.com")
        let none = try await run(alice.argv)
        #expect(none.exitCode == 0)
        #expect(try ChromeProfiles.profiles(none, argv: alice.argv).isEmpty, "the titles alone")
    }

    /// No Chrome Management scope at all is GAM's exit 15 before any request; the API's refusal (no Profiles scope) is 50.
    /// Each is GAM's words, never "no profiles".
    @Test func aMissingScopeIsSaidNotTakenAsNone() async throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-chrome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let read = try GamCommands.printChromeProfiles(user: "carol@example.com")
        try FileManager.default.createDirectory(at: state.appending(path: "denied"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "denied/chromeprofiles").path, contents: Data())
        let denied = try await run(read.argv, state: state)
        #expect(denied.exitCode == 50)
        #expect(throws: GamError.self) { try ChromeProfiles.profiles(denied, argv: read.argv) }
        #expect((try? ChromeProfiles.profiles(denied, argv: read.argv)) == nil)
        try FileManager.default.createDirectory(at: state.appending(path: "noscope"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "noscope/chromemanagement").path, contents: Data())
        let noScope = try await run(read.argv, state: state)
        #expect(noScope.exitCode == 15 && noScope.stderr.contains("There are no scopes authorized for the API(s): Chrome Management API"))
        do {
            _ = try ChromeProfiles.profiles(noScope, argv: read.argv)
            Issue.record("a missing scope read as profiles")
        } catch let error as GamError {
            #expect(error.message.contains("Chrome Management API"), "\(error.message)")
        }
    }

    /// A person's phones and tablets (the compromised-account check): each in words, how it syncs, and a refusal as GAM's
    /// exit 12, never "no devices". The mock takes only an owner's query, the grammar's fields, and `resourceid` among them.
    @Test func aPersonsDevicesAreTheirsAndARefusalIsSaid() async throws {
        let read = try GamCommands.printMobileDevices(user: "carol@example.com")
        let result = try await run(read.argv)
        #expect(result.exitCode == 0, "\(result.stderr)")
        let listed = GamOutput.records(result.stdout).map(Compromised.MobileDevice.init(record:))
        // The API's `email:` matches a prefix: carol@example.com.au's phone comes too, and only an exact owner is hers.
        #expect(listed.map(\.owners) == [["carol@example.com"], ["carol@example.com"], ["carol@example.com.au"]])
        let devices = listed.filter { $0.owners.contains("carol@example.com") }
        #expect(devices.map(\.words) == ["Pixel 8, Android 15 (Android)", "A device (Exchange sync (Google Sync))"])
        #expect(devices[1].firstSynced != nil)
        #expect(devices[0].lastSynced != nil && !devices.contains(where: \.reportsCompromise))
        let none = try await run(try GamCommands.printMobileDevices(user: "dana@example.com").argv)
        #expect(none.exitCode == 0 && GamOutput.records(none.stdout).isEmpty)
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-mobile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        try FileManager.default.createDirectory(at: state.appending(path: "denied"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appending(path: "denied/mobile").path, contents: Data())
        let denied = try await run(read.argv, state: state)
        #expect(denied.exitCode == 12 && denied.stderr.contains("Reauthentication is needed"))
        for argv in [["print", "mobile", "query", "status:APPROVED", "fields", "resourceid", "formatjson"],
                     ["print", "mobile", "query", "email:carol@example.com", "fields", "model", "formatjson"],
                     ["print", "mobile", "query", "email:carol@example.com", "fields", "resourceid"]] {
            let refused = try await run(argv)
            #expect(refused.exitCode == 2 && refused.stderr.contains("isn't modelled"), "\(argv)")
        }
        #expect(try await run(["print", "mobile", "query", "email?", "formatjson"]).exitCode == 2, "GAM's usage error")
        #expect(try await run(["print", "mobile", "query", "email:carol@example.com", "fields", "passwords", "formatjson"]).exitCode == 2)
    }

    /// The mock takes only the app's filter and the grammar's fields.
    @Test func theMockHoldsTheProfileReadToTheGrammar() async throws {
        let fields = ["fields", "displayname,useremail", "formatjson"]
        for argv in [["print", "chromeprofiles", "filter", "userEmail=carol@example.com"] + fields,
                     ["print", "chromeprofiles", "filter", "user_email=\"*@example.com\""] + fields,
                     ["print", "chromeprofiles", "filter", "user_email=\"carol@example.com\"", "fields", "displayname"],
                     ["print", "chromeprofiles", "fields", "displayname", "formatjson"]] {
            let result = try await run(argv)
            #expect(result.exitCode == 2 && result.stderr.contains("isn't modelled"), "\(argv)")
        }
        let badField = try await run(["print", "chromeprofiles", "filter", "user_email=\"carol@example.com\"", "fields", "passwords",
                                      "formatjson"])
        #expect(badField.exitCode == 2 && badField.stderr.contains("Invalid choice (passwords)"))
    }
}
