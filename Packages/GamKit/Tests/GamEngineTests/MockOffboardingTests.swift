import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock runs offboarding's writes the way GAM runs them, as read from its source (gam/__init__.py at
/// 7.48.22) and the messages read from the vendored build. Each case was more permissive here than GAM, and a
/// green run would have hidden a live break (the offboarding plan's M1, M2, M3, M5 and M8).
@Suite("Mock offboarding")
struct MockOffboardingTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    private func withState(_ body: (URL) async throws -> Void) async throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-off-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try await body(state)
    }

    private func run(_ write: GamWrite, state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        return try await mock.runRaw(write.argv, configDirectory: config, extraEnvironment: environment)
    }

    private func read(_ read: GamRead, state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        return try await mock.runRaw(read.argv, configDirectory: config, extraEnvironment: environment)
    }

    private func transfer(_ old: String, to new: String) -> GamWrite {
        GamCommands.createDataTransfer(oldOwner: old, service: Offboarding.transferServices, newOwner: new,
                                       privacy: Offboarding.transferPrivacy)
    }

    /// Lines without the fresh config folder's first-run banner.
    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Created: ") && !$0.hasPrefix("Config File: ") }
    }

    /// M3: GAM's success is "Transfer Request Performed" and the transfer's ID, services, From and To, not the
    /// mock's old sentence.
    @Test func mockTransferPrintsWhatGamPrints() async throws {
        let result = try await run(transfer("carol@example.com", to: "alice@example.com"))
        #expect(result.exitCode == 0, "\(result.stderr)")
        let printed = lines(result.stdout)
        #expect(printed.count == 5 && printed[0] == "Transfer Request Performed", "\(printed)")
        #expect(printed[1].hasPrefix("  Transfer ID: "))
        #expect(Array(printed[2...]) == ["  Service: Drive and Docs,Calendar", "  From: carol@example.com", "  To: alice@example.com"])
    }

    /// M1: the two owners are compared as user IDs, after an alias resolves: the same account twice is a usage
    /// error (NEW_OWNER_MUST_DIFFER_FROM_OLD_OWNER), alice@ and her alias a.anders@ included.
    @Test func mockTransferToTheSameOwnerIsAUsageError() async throws {
        for (old, new) in [("carol@example.com", "carol@example.com"), ("alice@example.com", "a.anders@example.com"),
                           ("A.Anders@example.com", "ALICE@example.com")] {
            let result = try await run(transfer(old, to: new))
            #expect(result.exitCode == 2, "\(old) → \(new)")
            #expect(result.stderr.hasSuffix("ERROR: New owner must differ from old owner\n"), "\(result.stderr)")
        }
    }

    /// M2: an owner that isn't a user ends the command while GAM reads it, before any transfer: "User: x, Does not
    /// exist", ENTITY_DOES_NOT_EXIST_RC (56). Not only for a `*missing*` address.
    @Test func mockTransferToANonUserFailsBeforeAnyTransfer() async throws {
        try await withState { state in
            for (old, new, nobody) in [("nobody@example.com", "alice@example.com", "nobody@example.com"),
                                       ("carol@example.com", "nobody@example.com", "nobody@example.com"),
                                       ("carol@example.com", "sales@example.com", "sales@example.com")] {
                let result = try await run(transfer(old, to: new), state: state)
                #expect(result.exitCode == 56, "\(old) → \(new)")
                #expect(result.stderr.hasSuffix("ERROR: User: \(nobody), Does not exist\n"), "\(result.stderr)")
                // GAM echoes the command line first. GamError, as GamGUI's reader, takes its message from that echo (an
                // unknown line outranks the not-found one): a reader defect of its own, not the mock's.
            }
            #expect(!FileManager.default.fileExists(atPath: state.appending(path: "transfers").path), "nothing was transferred")
        }
    }

    /// M3: a transfer for an old owner stays in progress, and a second one while it runs is Google's 409, which GAM
    /// doesn't expect there: HTTP_ERROR_RC (9). The CONFLICT409 trigger still gives it without state.
    @Test func mockASecondTransferWhileOneRunsIs409() async throws {
        try await withState { state in
            #expect(try await run(transfer("carol@example.com", to: "alice@example.com"), state: state).exitCode == 0)
            let again = try await run(transfer("CAROL@example.com", to: "dana@example.com"), state: state)
            #expect(again.exitCode == 9)
            #expect(again.stderr == "ERROR: 409: conflict - Data transfer already in progress for the user.\n")
            #expect(try await run(transfer("dana@example.com", to: "alice@example.com"), state: state).exitCode == 0,
                    "another leaver's transfer is their own")
        }
        #expect(try await run(transfer("CONFLICT409@example.com", to: "alice@example.com")).exitCode == 9)
    }

    /// M5: a suspended user's backup codes aren't touched (checkUserSuspended): when they have codes GAM says so on
    /// stderr, still deletes the tokens and signs out, and exits ACTION_NOT_PERFORMED_RC (51). An active user, or a
    /// suspended one without codes, exits 0.
    @Test func mockDeprovisionOfASuspendedUserExits51() async throws {
        let bob = try await run(GamCommands.deprovisionUser(email: "bob@example.com"))
        #expect(bob.exitCode == 51)
        #expect(bob.stderr.contains("User: bob@example.com, Backup Verification Codes Not Deprovisioned: User is suspended. "
            + "You must unsuspend to process backupcodes\n"))
        #expect(lines(bob.stdout).last == "User: bob@example.com, Deprovisioned", "the other parts still ran")
        #expect(try await run(GamCommands.deprovisionUser(email: "carol@example.com")).exitCode == 0)
        // Only when they have codes (`if jcount > 0`, :74220): a suspended user without any exits 0, unsaid.
        try await withState { state in
            try FileManager.default.createDirectory(at: state.appending(path: "nobackupcodes"), withIntermediateDirectories: true)
            try Data().write(to: state.appending(path: "nobackupcodes/bob@example.com"))
            let none = try await run(GamCommands.deprovisionUser(email: "bob@example.com"), state: state)
            #expect(none.exitCode == 0 && !none.stderr.contains("Not Deprovisioned"), "\(none.stderr)")
        }
    }

    /// M8: the default sweep is GAM's walk of every active user: the progress lines, each user's header and rule,
    /// "Not Found" where they never shared with the leaver and the leaver's own calendar refused, exit 50, every
    /// error line one the sweep tolerates. A leaver who isn't active isn't visited.
    @Test func mockTheDefaultSweepIsGamsShape() async throws {
        let result = try await run(GamCommands.removeAllCalendarACLs(email: "carol@example.com"))
        #expect(result.exitCode == 50)
        let errors = lines(result.stderr)
        #expect(errors.prefix(2) == ["Getting all Users, may take some time on a large Google Workspace Account...",
                                     "Got 3 Users: alice@example.com - dana@example.com"])
        #expect(errors.contains("    Calendar: carol@example.com, Calendar ACL: (Scope: user:carol@example.com), Delete Failed: "
            + "Cannot change your own access level."))
        #expect(errors.contains("    Calendar: alice@example.com, Calendar ACL: (Scope: user:carol@example.com), Delete Failed: Not Found"))
        #expect(lines(result.stdout).filter { $0.hasPrefix("User: ") }.map { $0.split(separator: ",")[0] }
                == ["User: alice@example.com", "User: carol@example.com", "User: dana@example.com"], "bob@ is suspended")
        let error = GamError(exitCode: result.exitCode, stderr: result.stderr)
        #expect(error.kinds == [.notFound, .ownACL], "\(error.kinds)")
        #expect(error.lineCounts == [.notFound: 2, .ownACL: 1])
        let suspended = try await run(GamCommands.removeAllCalendarACLs(email: "bob@example.com"))
        #expect(GamError(exitCode: suspended.exitCode, stderr: suspended.stderr).kinds == [.notFound])
    }

    // MARK: the added steps' commands and reads (docs/plans/2026-10-13-offboarding-options.md)

    /// `update user … gal [<Boolean>]` and empty recovery values: GAM's optional Boolean and its empty strings.
    @Test func theAddedStepsAreGamsUserAttributes() async throws {
        #expect(try await run(GamCommands.hideFromDirectory(email: "carol@example.com")).exitCode == 0)
        #expect(try await run(GamCommands.clearRecovery(email: "carol@example.com")).exitCode == 0)
    }

    /// printShowUserVaultHolds: its titles in their given order, the header alone for none, a Vault refusal before
    /// anything prints (exit 50), and a person who isn't a user as the Directory says so (exit 56, with the echo).
    @Test func vaultHoldsAreGamsShape() async throws {
        let held = try await read(GamCommands.printVaultHolds(email: "dana@example.com"))
        #expect(held.exitCode == 0)
        #expect(lines(held.stdout) == ["User,matterId,matterName,holdId,name,orgUnitId,orgUnitPath",
                                       "dana@example.com,m_audit,Contract audit,h_mail,Mail and Drive,,"])
        #expect(lines(try await read(GamCommands.printVaultHolds(email: "carol@example.com")).stdout)
                == ["User,matterId,matterName,holdId,name,orgUnitId,orgUnitPath"])
        let nobody = try await read(GamCommands.printVaultHolds(email: "nobody@example.com"))
        #expect(nobody.exitCode == 56 && nobody.stderr.hasSuffix("ERROR: User: nobody@example.com, Does not exist\n"))
        try await withState { state in
            try Data().write(to: state.appending(path: "novault"))
            let refused = try await read(GamCommands.printVaultHolds(email: "dana@example.com"), state: state)
            #expect(refused.exitCode == 50 && refused.stderr.hasPrefix("Vault Hold Print Failed: ") && lines(refused.stdout).isEmpty)
        }
    }

    /// `ownedsecondary` keeps the calendars the person owns; hidden ones only with `showhidden`, as calendarList.list.
    @Test func ownedSecondaryCalendarsIncludeHiddenOnlyWhenAsked() async throws {
        func labels(_ read: GamRead) async throws -> [String] {
            let result = try await self.read(read)
            #expect(result.exitCode == 0, "\(result.stderr)")
            return GamOutput.records(lines(result.stdout).joined(separator: "\n")).map(UserCalendar.init(record:)).map(\.label)
        }
        #expect(try await labels(GamCommands.printOwnedSecondaryCalendars(email: "carol@example.com")) == ["Operations", "Old projects"])
        #expect(try await labels(GamRead(["user", "carol@example.com", "print", "calendars", "ownedsecondary", "fields", "id,summary",
                                          "formatjson"])) == ["Operations"])
        #expect(try await labels(GamCommands.printOwnedSecondaryCalendars(email: "alice@example.com")).isEmpty)
    }
}
