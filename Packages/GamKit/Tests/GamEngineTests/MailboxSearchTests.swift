import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// Search a mailbox (docs/plans/2026-10-19-compromised-account.md slice 3): GamGUI's search read one row per message, its
/// recipients by MessageRecipients' rules, against the strict mock, which models only the Gmail terms it can answer.
@Suite("Mailbox search")
struct MailboxSearchTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    private func search(_ email: String, _ query: String) async throws -> (GamResult, [String]) {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        let argv = GamCommands.searchMessages(email: email, query: query, detail: .headers).argv
        var result = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: Fixtures.mockEnvironment)
        // Without the fresh config folder's first-run banner, as a configured run prints.
        let stdout = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.hasPrefix("Created: ") && !$0.hasPrefix("Config File: ") }.joined(separator: "\n")
        result = GamResult(exitCode: result.exitCode, stdout: stdout, stderr: result.stderr, stdoutTruncated: result.stdoutTruncated,
                           stderrTruncated: result.stderrTruncated)
        return (result, argv)
    }

    /// A taken-over account's Sent mail: the phish, its Bcc list read from the sender's own copy.
    @Test func whatTheAccountSentAndToWhom() async throws {
        let (result, argv) = try await search("carol@example.com", MailboxSearch.defaultQuery)
        #expect(result.exitCode == 0, "\(result.stderr)")
        let sent = try MailboxSearch.messages(result, argv: argv)
        #expect(sent.count == 1)
        let phish = try #require(sent.first)
        #expect(phish.subject == "You're invited: Fall party" && phish.from == "Carol Clark <carol@example.com>")
        #expect(phish.to == ["carol@example.com"] && phish.cc.isEmpty && phish.labels == ["SENT"])
        #expect(phish.bcc == ["alice@example.com", "bob@example.com", "DANA@example.com", "pat@partner.example", "guest@example.org",
                              "team@example.net", "ops@alias.example.net"], "\(phish.bcc)")
        #expect(phish.recipients.count == 8 && phish.messageID == "<CAPh1sh+Invite=0001@mail.example.com>")
        #expect(phish.when != nil)
    }

    /// Each modelled term narrows the search as Gmail does; none found is GAM's exit 60, read as no messages.
    @Test func eachTermIsModelledOrRefused() async throws {
        let (spam, spamArgv) = try await search("alice@example.com", "rfc822msgid:CAPh1sh+Invite=0001@mail.example.com in:spam")
        #expect(try MailboxSearch.messages(spam, argv: spamArgv).map(\.id) == ["19a0c0ffee000002"])
        let (none, noneArgv) = try await search("carol@example.com", "in:inbox")
        let nothing = try MailboxSearch.messages(none, argv: noneArgv)
        #expect(none.exitCode == 60 && nothing.isEmpty)
        let (to, toArgv) = try await search("carol@example.com", "in:sent to:pat@partner.example")
        #expect(try MailboxSearch.messages(to, argv: toArgv).count == 1)
        let (from, fromArgv) = try await search("carol@example.com", "from:someone.else@example.com")
        let fromNobody = try MailboxSearch.messages(from, argv: fromArgv)
        #expect(from.exitCode == 60 && fromNobody.isEmpty)
        for query in ["has:attachment", "in:sent *", "newer_than:3x", ""] {
            let (result, _) = try await search("carol@example.com", query)
            #expect(result.exitCode == 2, "\(query): \(result.stderr)")
        }
        let (stranger, strangerArgv) = try await search("stranger@example.com", "in:sent")
        #expect(throws: GamError.self) { try MailboxSearch.messages(stranger, argv: strangerArgv) }
    }

    /// A read cut off at the runner's cap is never taken as all there is.
    @Test func aCutOffSearchIsIncomplete() {
        let cut = GamResult(exitCode: 0, stdout: "User,id\ncarol@example.com,19a0", stderr: "", stdoutTruncated: true, stderrTruncated: false)
        #expect(throws: MessageCopies.Incomplete.self) { try MailboxSearch.messages(cut, argv: []) }
    }
}
