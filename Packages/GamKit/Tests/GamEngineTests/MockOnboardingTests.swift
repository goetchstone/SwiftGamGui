import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock fails onboarding's writes the way GAM 7.48.22 fails them, as read from its source
/// (gam/__init__.py) and checked against the vendored grammar. Each case once passed here and would have
/// broken live: a duplicate create printed a 409 GAM never prints, a bad org unit created the account, a
/// task went on anyone's list by one fixed id, and a task list or calendar for a non-user succeeded.
@Suite("Mock onboarding")
struct MockOnboardingTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    private func withState(lag: Int? = nil, _ body: (URL) async throws -> Void) async throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-onb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        if let lag { try Data("\(lag)\n".utf8).write(to: state.appending(path: "new_account_lag")) }
        try await body(state)
    }

    private func run(_ write: GamWrite, state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        return try await mock.runRaw(write.argv, configDirectory: config, extraEnvironment: environment)
    }

    private func create(_ email: String, orgUnit: String = "", first: String = "Jordan") -> GamWrite {
        GamCommands.createUser(email: email, firstName: first, lastName: "Lee", password: "Xk7m-Qp9r-2Tzv", orgUnit: orgUnit)
    }

    private func list(_ assignee: String) -> GamWrite { GamCommands.createTaskList(assignee: assignee, title: "Onboard Jordan Lee") }

    private func task(_ assignee: String, on id: String) -> GamWrite {
        GamCommands.createTask(assignee: assignee, taskListID: id, title: "Order a laptop")
    }

    /// The id `returnidonly` printed: the last non-empty line (a fresh config folder's banner comes first).
    private func printedID(_ result: GamResult) -> String {
        PythonText.lines(result.stdout).map { PythonText.strip($0) }.last { !$0.isEmpty } ?? ""
    }

    /// F1: doCreateUser's `except GAPI.duplicate` names what holds the address and exits 57, whether it's a
    /// user, a user's alias, a group or an account made a moment ago.
    @Test func aDuplicateCreateFailsAsGamDoes() async throws {
        for (email, held) in [("alice@example.com", "User: alice@example.com"), ("ALICE@example.com", "User: alice@example.com"),
                              ("a.anders@example.com", "User Alias: a.anders@example.com, User: alice@example.com"),
                              ("sales@example.com", "Group: sales@example.com"), ("exists@example.com", "User: exists@example.com")] {
            let result = try await run(create(email))
            #expect(result.exitCode == 57, "\(email)")
            let address = email.lowercased()
            #expect(result.stderr == "User: \(address), Create Failed: Duplicate, \(held)\n", "\(email)")
            #expect(GamError(exitCode: result.exitCode, stderr: result.stderr).message.contains("Create Failed: Duplicate"))
        }
        try await withState { state async throws in
            #expect(try await run(create("new@example.com"), state: state).exitCode == 0)
            let again = try await run(create("new@example.com"), state: state)
            #expect(again.exitCode == 57 && again.stderr.contains("Create Failed: Duplicate, User: new@example.com"))
        }
    }

    /// F2: an org unit that doesn't exist fails the whole create (entityActionFailedExit, exit 50), and no
    /// account is made.
    @Test func aBadOrgUnitFailsAsGamDoes() async throws {
        try await withState { state async throws in
            let result = try await run(create("new@example.com", orgUnit: "/Missing"), state: state)
            #expect(result.exitCode == 50)
            #expect(result.stderr == "\nERROR: User: new@example.com, Create Failed: Invalid Organizational Unit\n")
            #expect(try await run(create("new@example.com", orgUnit: "/Sales"), state: state).exitCode == 0, "nothing was made")
        }
    }

    /// GAM refuses a first or last name over 60 characters while parsing (`getString(maxLen=60)`): a usage
    /// error that echoes the whole command line, password included.
    @Test func aNameOverSixtyCharactersIsAUsageError() async throws {
        let long = try await run(create("new@example.com", first: String(repeating: "\u{E9}", count: 61)))
        #expect(long.exitCode == 2)
        #expect(long.stderr.contains("Command: gam create user new@example.com") && long.stderr.contains("Xk7m-Qp9r-2Tzv"))
        #expect(long.stderr.contains("Expected <string length 0<=x<=60 for String>"))
        #expect(try await run(create("new@example.com", first: String(repeating: "\u{E9}", count: 60))).exitCode == 0)
    }

    /// M6: a task goes only on a list made for the same user; any other id fails as processTasks reports it.
    @Test func aTaskOnAnotherUsersListFails() async throws {
        try await withState { state async throws in
            let id = printedID(try await run(list("alice@example.com"), state: state))
            let elsewhere = try await run(task("bob@example.com", on: id), state: state)
            #expect(elsewhere.exitCode == 50)
            #expect(elsewhere.stderr == "  User: bob@example.com, Tasklist: \(id), Task: Order a laptop, Create Failed: Not Found\n")
            #expect(GamError(exitCode: elsewhere.exitCode, stderr: elsewhere.stderr).kind == .notFound)
            #expect(try await run(task("alice@example.com", on: id), state: state).exitCode == 0)
            #expect(try await run(task("alice@example.com", on: "MockTasklist_abc123"), state: state).exitCode == 50, "an id never made")
        }
        let alices = printedID(try await run(list("alice@example.com")))
        #expect(try await run(task("alice@example.com", on: alices)).exitCode == 0)
        #expect(try await run(task("carol@example.com", on: alices)).exitCode == 50, "without state too")
    }

    @Test func eachTaskListHasItsOwnId() async throws {
        try await withState { state async throws in
            let first = printedID(try await run(list("alice@example.com"), state: state))
            let second = printedID(try await run(list("alice@example.com"), state: state))
            #expect(!first.isEmpty && first != second)
            #expect(try await run(task("alice@example.com", on: first), state: state).exitCode == 0)
            #expect(try await run(task("alice@example.com", on: second), state: state).exitCode == 0)
        }
        #expect(printedID(try await run(list("alice@example.com"))) != printedID(try await run(list("carol@example.com"))))
    }

    /// M5: every per-user call acts as the user, so for an address that isn't one GAM's token request fails.
    @Test func aTasksCallForANonUserFailsOnItsToken() async throws {
        for write in [list("nobody@example.com"), task("nobody@example.com", on: "x"),
                      GamCommands.subscribeCalendar(email: "nobody@example.com", calendarID: "c_allhands@group.calendar.google.com")] {
            let result = try await run(write)
            #expect(result.exitCode == 50, "\(write.argv)")
            #expect(result.stderr.contains("invalid_grant: Invalid email or User ID"), "\(result.stderr)")
            #expect(GamError(exitCode: result.exitCode, stderr: result.stderr).kind == .notFound)
        }
        try await withState { state async throws in
            #expect(try await run(create("new@example.com"), state: state).exitCode == 0)
            #expect(try await run(list("new@example.com"), state: state).exitCode == 0, "an account made in this state is a user")
        }
    }

    /// M7: a calendar that doesn't exist fails as _processCalendarList reports GAPI.notFound.
    @Test func aMissingCalendarFailsAsGamDoes() async throws {
        let result = try await run(GamCommands.subscribeCalendar(email: "alice@example.com", calendarID: "missing@group.calendar.google.com"))
        #expect(result.exitCode == 50)
        #expect(result.stderr == "  User: alice@example.com, Calendar: missing@group.calendar.google.com, Add Failed: Not Found\n")
        #expect(GamError(exitCode: result.exitCode, stderr: result.stderr).kind == .notFound)
    }

    /// M4: Google's lag is per account, so each per-user call on a new account (signature, calendar, task
    /// list, task) meets it in turn; a group add and the welcome email never do (live 2026-09-30).
    @Test func aNewAccountLagsEachPerUserCall() async throws {
        try await withState(lag: 4) { state async throws in
            let email = "new@example.com"
            #expect(try await run(create(email), state: state).exitCode == 0)
            #expect(try await run(GamCommands.addGroupMember(group: "sales@example.com", member: email), state: state).exitCode == 0)
            #expect(try await run(GamCommands.sendEmail(to: email, subject: "Hi", body: "Welcome"), state: state).exitCode == 0)
            var lagged: [GamResult] = []
            for write in [GamCommands.setSignature(email: email, signature: "<b>J</b>"),
                          GamCommands.subscribeCalendar(email: email, calendarID: "c_allhands@group.calendar.google.com"),
                          list(email), task(email, on: "MockTasklist_1")] {
                lagged.append(try await run(write, state: state))
            }
            #expect(lagged.map(\.exitCode) == [50, 73, 50, 50])
            #expect(lagged.allSatisfy { GamError(exitCode: $0.exitCode, stderr: $0.stderr).saysNewAccountNotReady }, "\(lagged.map(\.stderr))")
            let id = printedID(try await run(list(email), state: state))
            #expect(try await run(task(email, on: id), state: state).exitCode == 0, "ready now")
        }
    }
}
