import Foundation
import Testing
@testable import Assist

/// What's still to do once it's done (asked 2026-10-28, after a run through Respond on a real incident: done items kept
/// asking): a tick for what no log can show, matched by what the item stands on; a mark that answers "is this address theirs"
/// for its IPv6 network but never clears the attacker; one item to warn everyone the attacker's emails got to; Pull Again only
/// for a mailbox the pull doesn't hold; and the summary's draft holding no number the facts don't. On the log reader's own
/// made-up incident (`LogReadingTests`).
@Suite("Still to do, once done")
struct StillToDoTests {
    typealias Log = LogReadingTests

    static func at(_ minute: Int) -> Date { Date(timeIntervalSince1970: 1_792_400_000 + Double(minute) * 60) }

    static func tick(_ task: LogReading.Task, how: String = "Done with them.", by: String = "pat@example.com") -> LogReading.Ticked {
        LogReading.Ticked(kind: task.kind.rawValue, words: task.words, basis: task.basis, how: how, at: at(100), by: by)
    }

    /// A sender unblocked with the person shows in no log: ticked, it's done by hand, with how, when and by whom, and both lists
    /// are numbered again. A lock, recovery details cleared, a computer and a read are the logs' or this app's to show, never a
    /// tick's; a tick of other words counts for nothing.
    @Test func aTickMovesWhatNoLogShowsToDone() throws {
        let reading = LogReading.read(Log.incident + [
            Log.event("login", "carol@example.com", "blocked_sender", ip: Log.attacker, at: 29, ["affected_email_address": "bounce@example.net"]),
        ])
        let unblock = try #require(reading.toDo.first { $0.kind == .unblockSender })
        let secure = try #require(reading.toDo.first { $0.kind == .secure })
        #expect(LogReading.Task.Kind.allCases.filter { !$0.tickable }
                == [.secureAgain, .secure, .finishLock, .pullAgain, .sweep, .readDirectory, .clearRecovery, .deleteDevice])
        let ticked = reading.ticking([Self.tick(unblock, how: "Unblocked it with them on a call."), Self.tick(secure),
                                      LogReading.Ticked(kind: "checkPassword", words: "Words the logs no longer say.", basis: "", how: "x", at: Self.at(100), by: "")])
        #expect(!ticked.toDo.contains { $0.kind == .unblockSender })
        #expect(ticked.toDo.contains { $0.words == secure.words }, "a lock shows done in Google's logs whoever did it")
        #expect(ticked.toDo.count == reading.toDo.count - 1 && ticked.toDo.map(\.id) == (1...ticked.toDo.count).map { "T\($0)" })
        let done = try #require(ticked.done.last)
        #expect(done.id == "D\(ticked.done.count)" && done.words == unblock.words)
        #expect(done.done == LogReading.Done(how: .byHand("Unblocked it with them on a call."), at: Self.at(100), by: "pat@example.com"))
        #expect(reading.ticking([]) == reading)
        let other = LogReading.Ticked(kind: unblock.kind.rawValue, words: unblock.words + " More.", basis: unblock.basis, how: "x", at: Self.at(100), by: "")
        #expect(reading.ticking([other]) == reading)
    }

    /// A tick holds only while what the item stands on does (review 2026-10-28): the attacker's second passkey leaves "remove
    /// what the attacker added" worded the same, and it's to do again; so is the warn item when who's to warn changes at the
    /// same count.
    @Test func aTickComesBackWhenTheEvidenceGrows() throws {
        let one = Log.incident + [Log.event("login", "carol@example.com", "passkey_enrolled", ip: Log.attacker, at: 13)]
        let added = try #require(LogReading.read(one).toDo.first { $0.kind == .removeAdded })
        #expect(!LogReading.read(one).ticking([Self.tick(added)]).toDo.contains { $0.kind == .removeAdded })
        let two = LogReading.read(one + [Log.event("login", "carol@example.com", "passkey_enrolled", ip: Log.attacker, at: 14)])
        let again = try #require(two.toDo.first { $0.kind == .removeAdded })
        #expect(again.words == added.words && again.basis != added.basis)
        #expect(two.ticking([Self.tick(added)]).toDo.contains { $0.kind == .removeAdded }, "a second passkey: to do again")

        func warn(_ reading: LogReading.Reading) throws -> LogReading.Task { try #require(reading.toDo.first { $0.words.hasPrefix("Warn the ") }) }
        // Warned by bob@'s warning, dana@ is still to warn; by alice@'s lunch to dana@, alice@ is instead: five either way.
        let before = Log.reaching(["warn-1@mail.example.com"]), after = Log.reaching(["lunch@mail.example.com"])
        let (was, now) = (try warn(before), try warn(after))
        #expect(was.words == now.words && was.words.hasPrefix("Warn the 5 people") && was.basis != now.basis, "five both times, not the same five")
        #expect(after.ticking([Self.tick(was)]).toDo.contains { $0.words == now.words }, "the tick of the other five doesn't count")
    }

    /// A phone's sign-ins after the lock come from new IPv6 addresses in one /64: asked about once a network, and a mark on one
    /// (That Was Them, from the item itself) covers the next, so it isn't asked again (2026-10-28). Never a network an attacker's
    /// address shares (a relay's, a VPN's: review 2026-10-28): there a mark is the very address, and it never clears a suspect.
    @Test func aMarkAnswersForItsNetworkButNeverTheAttackers() throws {
        let phone = "2600:387:1:2::a1", phoneLater = "2600:387:1:2:9::b2", elsewhere = "2600:387:9:9::c3"
        let events = Log.incident + [
            Log.done("CHANGE_PASSWORD", at: 60), Log.done("RESET_SIGNIN_COOKIES", at: 61),
            Log.event("login", "carol@example.com", "login_success", ip: phone, at: 80),
            Log.event("login", "carol@example.com", "login_success", ip: phoneLater, at: 85),
            Log.event("login", "carol@example.com", "login_success", ip: elsewhere, at: 86),
        ]
        let question = try #require(LogReading.read(events).toDo.first { $0.kind == .confirmAddress })
        #expect(question.theirs == [phone, elsewhere], "one address a network, each to mark")
        func reading(_ events: [LogReading.Event], marked: [String]) -> LogReading.Reading {
            LogReading.read(events, context: LogReading.Context(theirs: Set(marked.map { LogReading.key(account: "Carol@Example.com", address: $0) })))
        }
        #expect(reading(events, marked: [phone]).statuses[0].newAddresses == [elsewhere], "the mark covers the phone's later address")
        #expect(!reading(events, marked: [phoneLater, elsewhere]).toDo.contains { $0.kind == .confirmAddress })

        // The attacker flagged from 2001:db8:aa:1::66; carol after the lock from ::77 in the same /64, marked as hers.
        let relay = "2001:db8:aa:1::66", hers = "2001:db8:aa:1::77", next = "2001:db8:aa:1::88"
        let shared = [
            Log.event("login", "carol@example.com", "login_success", ip: relay, flagged: true, at: 10, ["is_suspicious": "true"]),
            Log.done("CHANGE_PASSWORD", at: 60), Log.done("RESET_SIGNIN_COOKIES", at: 61),
            Log.event("login", "carol@example.com", "login_success", ip: hers, at: 80),
            Log.event("login", "carol@example.com", "login_success", ip: next, at: 85),
        ]
        let markedShared = reading(shared, marked: [hers])
        #expect(markedShared.statuses.first?.attackedAt == Self.at(10), "the attacker's address is still a suspect")
        #expect(markedShared.statuses.first?.newAddresses == [next], "only the very address marked; the next is asked")
    }

    /// The network of an address, for every way IPv6 is written: `::` anywhere, an IPv4 address inside it or as it, a zone.
    @Test func everyFormOfAnAddressHasItsNetwork() {
        #expect(LogReading.network("2001:DB8:aa:1::5") == "2001:db8:aa:1" && LogReading.network("2001:db8:aa:1:9::7") == "2001:db8:aa:1")
        #expect(LogReading.network("2001::1:2:3:4:5") == LogReading.network("2001:0:0:1:2:3:4:5"))
        #expect(LogReading.network("::ffff:198.51.100.7") == "198.51.100.7" && LogReading.network("::ffff:203.0.113.5") == "203.0.113.5")
        #expect(LogReading.network("fe80::1%en0") == "fe80:0:0:0" && LogReading.network("::1") == "0:0:0:0")
        #expect(LogReading.network("64:ff9b::198.51.100.7") == "64:ff9b:0:0" && LogReading.network("192.0.2.1") == "192.0.2.1")
        #expect(LogReading.key(account: "A@X.example", address: "2001:DB8::1") == "a@x.example|2001:db8::1", "a mark's key is the very address")
    }

    /// dana@'s mailbox shows nothing after the phish. Pull Again asks for it, once across the emails, only while the pull doesn't
    /// hold her Gmail log past the phish: a read of every account's from before it to after holds it, and quiet is quiet
    /// (2026-10-28). A read of others', or one that ends before the phish, doesn't.
    @Test func pullAgainOnlyForAMailboxThePullDoesntHold() {
        let events = Log.reachEvents.filter { !($0.who == "dana@example.com" && $0.parameters["event_info.mail_event_type"] == "2") }
        func reading(_ whole: [LogReading.Whole]) -> LogReading.Reading {
            LogReading.read(events, context: LogReading.Context(domains: ["example.com"], people: Log.people,
                                                                 warnings: ["phish-1@mail.example.com": ["warn-1@mail.example.com"]], gmailWhole: whole))
        }
        let unknown = reading([])
        #expect(unknown.reaches.first?.unread == ["dana@example.com"])
        #expect(unknown.toDo.filter { $0.kind == .pullAgain }.map(\.accounts) == [["dana@example.com"]])
        let everyone = reading([LogReading.Whole(accounts: nil, from: Self.at(0), to: Self.at(100))])
        #expect(everyone.reaches.allSatisfy(\.unread.isEmpty) && !everyone.toDo.contains { $0.kind == .pullAgain })
        #expect(everyone.toDo.contains { $0.words.hasPrefix("Warn the ") }, "her mailbox read and quiet: still to warn")
        #expect(reading([LogReading.Whole(accounts: ["alice@example.com"], from: Self.at(0), to: Self.at(100))]).reaches.first?.unread == ["dana@example.com"])
        #expect(reading([LogReading.Whole(accounts: nil, from: Self.at(0), to: Self.at(20))]).reaches.first?.unread == ["dana@example.com"],
                "read only to before the phish")
    }

    /// The summary's draft: the rundown's sentences without the to-do IDs, the report's numbers told; a sentence holding a
    /// number written nowhere in the facts, in any script, is dropped and counted, as a point citing no to-do item is.
    @Test func theSummaryDraftHoldsOnlyNumbersTheFactsDo() async throws {
        let reading = LogReading.read(Log.incident)
        let stub = Log.Stub(answer: LogExplainer.Answer(
            overview: "The attacker got into 2 accounts. They sent 40 emails. Carol was first. ٤٠ more.", done: " Nothing is done yet. ",
            left: [LogExplainer.AnswerPoint(text: "Secure carol first.", cites: ["T1"]), LogExplainer.AnswerPoint(text: "Invented.", cites: ["T99"])]))
        let draft = try await LogExplainer.summary(reading, numbers: [("Accounts the attacker touched", 2)], when: { _ in "then" }, using: stub)
        #expect(draft.text == "The attacker got into 2 accounts. Carol was first.\n\nNothing is done yet.\n\nSecure carol first.")
        #expect(draft.dropped == 2, "40, and 40 in Arabic-Indic digits, aren't among the facts")
        #expect(LogExplainer.sentences("One. Two 2.5 three! Four") == ["One.", "Two 2.5 three!", "Four"])
    }

    /// What's done is in the model's facts too, a tick said as one, never how it was done (that's typed).
    @Test func thePromptSaysWhatsDone() throws {
        let reading = LogReading.read(Log.incident + [
            Log.event("login", "carol@example.com", "blocked_sender", ip: Log.attacker, at: 29, ["affected_email_address": "bounce@example.net"]),
        ])
        let unblock = try #require(reading.toDo.first { $0.kind == .unblockSender })
        let prompt = LogExplainer.prompt(reading.ticking([Self.tick(unblock, how: "Secret detail.")]))
        #expect(prompt.contains("Already done, as this app's records show:\n- Done: have the person unblock the sender the attacker blocked in "
                                + "Gmail (marked done by hand). Accounts: carol@example.com."))
        #expect(!prompt.contains("Secret detail") && !prompt.contains("bounce@example.net"))
    }
}
