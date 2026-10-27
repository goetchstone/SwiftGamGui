import Foundation
import Testing
@testable import Assist

/// Narrow first (docs/plans/2026-10-22-incidents.md, slice 7; the operator, 2026-10-27, of every account's Gmail: "with a
/// larger tenant it would take days"): each attacker address the reader found is a to-do item to read every account's logs
/// from it, Google filtering on the address before it reads; never a shared one; done once a read of every account from it was
/// made. On the log reader's own made-up incident (`LogReadingTests`).
@Suite("Narrow first")
struct NarrowFirstTests {
    typealias Reading = LogReadingTests

    static func sweeps(_ events: [LogReading.Event], swept: Set<String> = []) -> [LogReading.Task] {
        LogReading.read(events, context: LogReading.Context(domains: ["example.com"], swept: swept)).toDo.filter { $0.kind == .sweep }
    }

    /// The attacker's address: one item, with the address for its button, said in words; gone once swept.
    @Test func eachAttackerAddressIsReadForEveryAccount() throws {
        let sweep = try #require(Self.sweeps(Reading.incident).first)
        #expect(Self.sweeps(Reading.incident).count == 1 && sweep.sweeps == Reading.attacker)
        #expect(sweep.words.hasPrefix("Read every account's logs from \(Reading.attacker), over the window shown"))
        #expect(sweep.accounts.isEmpty && sweep.drafts.isEmpty && sweep.pullsAgain.isEmpty)
        #expect(Self.sweeps(Reading.incident, swept: [Reading.attacker]).isEmpty, "swept already: done")
        // Its place among the urgent ones: after pulling again, before undoing what the attacker added.
        let kinds = LogReading.Task.Kind.allCases
        #expect(kinds.firstIndex(of: .sweep)! == kinds.firstIndex(of: .pullAgain)! + 1)
    }

    /// An address many accounts signed in from (an office, a VPN) is set aside as shared: sweeping it would read everyone's
    /// events again, so it gets no item.
    @Test func neverASharedAddress() {
        let office = "192.0.2.80"
        let crowd = (0...LogReading.shared).flatMap { n in
            [Reading.event("login", "user\(n)@example.com", "login_success", ip: office, at: 30 + n)]
        } + [Reading.event("login", "carol@example.com", "suspicious_login", ip: office, flagged: true, at: 29)]
        let sweeps = Self.sweeps(Reading.incident + crowd)
        #expect(sweeps.map(\.sweeps) == [Reading.attacker], "the office isn't swept")
    }
}
