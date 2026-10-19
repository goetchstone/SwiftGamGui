import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The compromised-account core (docs/plans/2026-10-19-compromised-account.md): the lock is offboarding's builders, the
/// picks one step each, and the reads said in words. No GamGUI builder holds these: each argv is held here and in
/// `NativeArgvTests`, against the grammar and GAM 7.48.30's source.
@Suite("Compromised account")
struct CompromisedTests {
    private func filter(_ json: String) throws -> Compromised.Filter {
        Compromised.Filter(record: try #require(JSONValue.parse(json)?.object))
    }

    @Test func theLockRunsInOrderWithThePicks() throws {
        let filters = [try filter(#"{"id": "F1", "criteria": {"from": "x@example.org"}, "action": {"addLabelIds": ["TRASH"]}}"#)]
        let steps = try Compromised.steps(user: "carol@example.com", switchedOn: [.imapOff, .popOff, .clearRecovery], filters: filters,
                                          delegates: ["helpdesk@example.com"], sendAs: ["billing.desk@example.net"],
                                          recovery: ("carol.recovery@example.net", ""))
        #expect(steps.map(\.write.argv) == [
            ["update", "user", "carol@example.com", "password", "random", "changepassword", "off"],
            ["update", "user", "carol@example.com", "recoveryemail", "", "recoveryphone", ""],
            ["user", "carol@example.com", "deprovision", "signout"],
            ["user", "carol@example.com", "forward", "off"],
            ["user", "carol@example.com", "delete", "filters", "F1"],
            ["user", "carol@example.com", "delete", "delegate", "helpdesk@example.com"],
            ["user", "carol@example.com", "delete", "sendas", "billing.desk@example.net"],
            ["user", "carol@example.com", "imap", "off"],
            ["user", "carol@example.com", "pop", "off"],
        ])
        #expect(steps.map(\.key) == [.password, .clearRecovery, .revoke, .forward, .filters, .delegate, .sendAs, .imapOff, .popOff])
        #expect(steps[1].summary.contains("now email carol.recovery@example.net"))
        #expect(steps[4].summary.contains("“From x@example.org: deletes it (to Trash)”"))
    }

    /// The defaults: IMAP and POP off are part of the lock; clearing recovery waits for the operator.
    @Test func theDefaultsAreTheLockAndNothingPicked() throws {
        let steps = try Compromised.steps(user: "p@example.com", switchedOn: Compromised.Step.onByDefault)
        #expect(steps.map(\.key) == [.password, .revoke, .forward, .imapOff, .popOff])
        #expect(Compromised.whatStopsWhat(resetRuns: true).hasPrefix("If “Reset password” fails, nothing after it runs."))
        #expect(Compromised.header(user: "p@example.com", runs: 4, total: 5) == "Securing p@example.com — 4 of 5 steps (1 ticked as already done)")
        #expect(Compromised.header(user: "p@example.com", runs: 1, total: 1) == "Securing p@example.com — 1 step")
    }

    /// A pick that wouldn't be one argv element is refused, never sent: GAM splits a delegate or send-as on commas and
    /// whitespace, and a switched step is only one of the switchable three.
    @Test func aPickThatIsntOneAddressIsRefused() {
        // The last three stay one element but GAM acts on another address: `Name <a@b>` reads as `a@b`, `id:` and `uid:` as IDs.
        for bad in ["a@example.com,b@example.com", "a b@example.com", " a@example.com", "file", "x<victim@example.com>",
                    "id:victim@example.com", "UID:victim@example.com"] {
            #expect(throws: GamCommands.Invalid.self) { try Compromised.steps(user: "p@example.com", switchedOn: [], delegates: [bad]) }
            #expect(throws: GamCommands.Invalid.self) { try Compromised.steps(user: "p@example.com", switchedOn: [], sendAs: [bad]) }
        }
        #expect(throws: GamCommands.Invalid.self) { try Compromised.steps(user: "p@example.com", switchedOn: [.revoke]) }
    }

    /// A filter in words: what it matches, what it does, and whether it's what an attacker's filter does.
    @Test func aFilterIsSaidInWords() throws {
        let hiding = try filter(#"""
            {"id": "F2", "criteria": {"query": "invoice OR payment", "hasAttachment": true},
             "action": {"removeLabelIds": ["INBOX", "UNREAD"], "forward": "x@example.net"}}
            """#)
        #expect(hiding.words == "Mail matching “invoice OR payment”, has an attachment: forwards it to x@example.net, "
            + "archives it (skips the inbox), marks it read")
        #expect(hiding.hidesOrForwards)
        let label = try filter(#"{"id": "F3", "criteria": {"from": "news@example.org"}, "action": {"addLabelIds": ["Label_7", "STARRED"]}}"#)
        #expect(label.words == "From news@example.org: adds the label Label_7, stars it" && !label.hidesOrForwards)
        #expect(try filter(#"{"id": "F4", "criteria": {}, "action": {}}"#).words == "Every message: does nothing Gmail shows")
    }

    @Test func theFindingsSayWhatToLookAt() {
        let user = GamUser(record: ["primaryEmail": .string("carol@example.com"), "isEnrolledIn2Sv": .bool(false),
                                    "recoveryEmail": .string("r@example.net"), "recoveryPhone": .string("+15555550123")])
        let said = Compromised.findings(account: Compromised.Account(user), forwarding: Compromised.Forwarding(enabled: true, to: "x@example.net"),
                                        filters: [], delegates: ["helpdesk@example.com"], sendAs: [], roles: [])
        #expect(said.count == 4, "\(said)")
        #expect(said[0].hasPrefix("Forwarding is on, to x@example.net"))
        #expect(said[1].hasPrefix("1 person can read carol@example.com's mail as a delegate"))
        #expect(said[2].hasPrefix("Recovery email r@example.net and phone +15555550123: check with carol@example.com"))
        #expect(said[3].hasPrefix("2-Step Verification is off"))
        // A read that failed (nil) says nothing here: its own list says why.
        let quiet = GamUser(record: ["primaryEmail": .string("a@example.com"), "isEnrolledIn2Sv": .bool(true)])
        #expect(Compromised.findings(account: Compromised.Account(quiet), forwarding: nil, filters: nil, delegates: nil, sendAs: nil,
                                     roles: nil).isEmpty)
    }
}

/// The strict mock answers the check's reads, and its new writes, as GAM 7.48.30's source does (printShowForward,
/// printShowForwardingAddresses, printShowSendAs, deleteInfoSendAs, doPrintShowAdmins, processDelegates).
@Suite("Mock compromised account")
struct MockCompromisedTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    private func run(_ argv: [String], state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        return try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
    }

    private func withState(_ body: (URL) async throws -> Void) async throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-compromised-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try await body(state)
    }

    private func records(_ result: GamResult) -> [GamOutput.Record] {
        GamOutput.records(result.stdout.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("Created: ") && !$0.hasPrefix("Config File: ") }.joined(separator: "\n"))
    }

    @Test func forwardingIsReadAndForwardOffShowsInTheNextRead() async throws {
        try await withState { state in
            let before = try await run(GamCommands.printForward(email: "carol@example.com").argv, state: state)
            #expect(before.exitCode == 0 && before.stderr.contains("Getting Forward Enabled for carol@example.com"))
            #expect(Compromised.Forwarding(records: records(before)) == Compromised.Forwarding(enabled: true, to: "carol.home@example.org",
                                                                                               disposition: "leaveInInbox"))
            #expect(try await run(GamCommands.forwardOff(email: "carol@example.com").argv, state: state).exitCode == 0)
            let after = try await run(GamCommands.printForward(email: "carol@example.com").argv, state: state)
            #expect(Compromised.Forwarding(records: records(after))?.enabled == false)
            #expect(Compromised.Forwarding(records: records(try await run(GamCommands.printForward(email: "alice@example.com").argv)))?
                .enabled == false)
        }
    }

    /// Each read acts as the person: one who isn't a user fails at the token (exit 50), Gmail off is exit 73 with the
    /// titles alone, and an option the app doesn't send isn't answered.
    @Test func eachGmailReadFailsAsGamDoes() async throws {
        try await withState { state in
            try FileManager.default.createDirectory(at: state.appending(path: "nogmail"), withIntermediateDirectories: true)
            try Data().write(to: state.appending(path: "nogmail/carol@example.com"))
            for read in [GamCommands.printForward(email:), GamCommands.printForwardingAddresses(email:), GamCommands.printSendAs(email:)] {
                let off = try await run(read("carol@example.com").argv, state: state)
                #expect(off.exitCode == 73 && off.stderr.contains("Gmail Service/App not enabled") && records(off).isEmpty, "\(read("x").argv)")
                #expect(try await run(read("stranger@example.com").argv).exitCode == 50)
            }
        }
        #expect(try await run(["user", "carol@example.com", "print", "forward", "enabledonly"]).exitCode == 2)
        #expect(try await run(["user", "carol@example.com", "print", "sendas"]).exitCode == 2)
    }

    @Test func forwardingAddressesAndSendAsAreTheirsAlone() async throws {
        let addresses = records(try await run(GamCommands.printForwardingAddresses(email: "carol@example.com").argv))
            .map(Compromised.ForwardingAddress.init(record:))
        #expect(addresses.map(\.address) == ["carol.home@example.org", "mailbox.backup@example.net"])
        #expect(addresses.map(\.status) == ["accepted", "pending"])
        #expect(records(try await run(GamCommands.printForwardingAddresses(email: "alice@example.com").argv)).isEmpty)
        let sendAs = records(try await run(GamCommands.printSendAs(email: "carol@example.com").argv)).map(Compromised.SendAs.init(record:))
        #expect(sendAs.map(\.address) == ["carol@example.com", "billing.desk@example.net"])
        #expect(sendAs.map(\.isPrimary) == [true, false] && sendAs[1].status == "accepted")
    }

    /// deleteInfoSendAs: the address goes, and the next read leaves it out; again, or one Gmail doesn't list, is "Not
    /// Found" (exit 50); the primary can't be removed.
    @Test func aSendAsAddressIsRemovedAsGamRemovesIt() async throws {
        try await withState { state in
            let delete = try GamCommands.deleteSendAs(email: "carol@example.com", address: "billing.desk@example.net").argv
            let removed = try await run(delete, state: state)
            #expect(removed.exitCode == 0, "\(removed.stderr)")
            #expect(removed.stdout.contains("User: carol@example.com, Delete 1 SendAs Address")
                    && removed.stdout.contains("  User: carol@example.com, SendAs Address: billing.desk@example.net, Deleted"))
            let left = records(try await run(GamCommands.printSendAs(email: "carol@example.com").argv, state: state))
            #expect(left.map(Compromised.SendAs.init(record:)).map(\.address) == ["carol@example.com"])
            let again = try await run(delete, state: state)
            #expect(again.exitCode == 50 && again.stderr.contains("Delete Failed: Not Found"))
            let primary = try await run(try GamCommands.deleteSendAs(email: "carol@example.com", address: "carol@example.com").argv)
            #expect(primary.exitCode == 50 && primary.stderr.contains("primary"))
        }
    }

    /// A delegate the person doesn't have: Gmail's delete is notFound. Until 2026-10-19 the mock passed any removal.
    @Test func removingADelegateTheyDontHaveFails() async throws {
        let result = try await run(GamCommands.removeDelegate(email: "carol@example.com", delegate: "alice@example.com").argv)
        #expect(result.exitCode == 50 && result.stderr.contains("Delegate: alice@example.com, Delete Failed"))
        #expect(try await run(GamCommands.removeDelegate(email: "carol@example.com", delegate: "helpdesk@example.com").argv).exitCode == 0)
    }

    @Test func adminRolesAreThePersonsOwn() async throws {
        let alice = records(try await run(GamCommands.printAdmins(user: "alice@example.com").argv)).map(Compromised.AdminRole.init(record:))
        #expect(alice.map(\.words) == ["Super Admin, for the whole domain"])
        #expect(records(try await run(GamCommands.printAdmins(user: "carol@example.com").argv)).isEmpty)
        let stranger = try await run(GamCommands.printAdmins(user: "stranger@example.com").argv)
        #expect(stranger.exitCode == 56 && stranger.stderr.contains("Administrator: stranger@example.com, Does not exist"))
    }

    @Test func theAccountReadHasItsRecoveryDetails() async throws {
        let read = try await run(GamCommands.infoUser(email: "carol@example.com", fields: Compromised.accountFields).argv)
        let account = Compromised.Account(GamUser(record: try #require(records(read).first)))
        #expect(account.recoveryEmail == "carol.recovery@example.net" && account.recoveryPhone == "+15555550123")
        #expect(!account.enrolledIn2SV && !account.enforcedIn2SV && !account.isAdmin)
    }
}
