@testable import Stores
import Darwin
import Foundation
import GamEngine
import Testing

/// The marked sign-ins ("That was them", docs/plans/2026-10-22-incidents.md): native. Its file is handled as the
/// signature templates' is (`SignatureStore.load`, `writeFile`), so these hold the format, the per-domain marks, and the
/// rule that only one account and one IP address with a note is saved or read.
@Suite("Known sign-in store")
struct KnownSignInStoreTests {
    let base: URL
    /// The store's folder, not made yet: the store makes it.
    let root: URL
    var file: URL { root.appending(path: KnownSignInStore.fileName) }

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-known-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        root = base.appending(path: "SwiftGamGui")
    }

    func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    static let moment = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
                                       year: 2026, month: 10, day: 22, hour: 9, minute: 5).date!

    /// Nothing is written until a mark; a mark is saved `0600` in a `0700` folder, read back by a new store, kept per
    /// domain, and the same sign-in marked again replaces its note. Undo removes it, for good.
    @Test func aMarkIsSavedPerDomainAndUndone() throws {
        var store = try KnownSignInStore(root: root)
        #expect(store.marks.isEmpty && !FileManager.default.fileExists(atPath: root.path))
        try store.mark(domain: "Example.com", account: "Alice@example.com", address: "2001:DB8::15", note: "  Her passkey, via a relay. ",
                       at: Self.moment)
        try store.mark(domain: "example.org", account: "bob@example.org", address: "192.0.2.80", note: "Hotel Wi-Fi", at: Self.moment)
        #expect(mode(root) == 0o700 && mode(file) == 0o600)
        let reopened = try KnownSignInStore(root: root)
        let alice = try #require(reopened.marks(for: "example.com").first)
        #expect(reopened.marks(for: "example.com").count == 1 && alice.account == "alice@example.com" && alice.address == "2001:db8::15")
        #expect(alice.note == "Her passkey, via a relay." && alice.at == Self.moment && alice.id == "example.com|alice@example.com|2001:db8::15")
        try store.mark(domain: "example.com", account: "alice@example.com", address: "2001:db8::15", note: "Checked with her")
        #expect(store.marks(for: "example.com").map(\.note) == ["Checked with her"])
        try store.unmark(alice.id)
        #expect(try KnownSignInStore(root: root).marks(for: "example.com").isEmpty)
        #expect(try KnownSignInStore(root: root).marks(for: "example.org").count == 1)
    }

    /// Only one account and one IP address, with a note of 1 to 500 characters: anything else is refused in words and
    /// nothing is written. At most `cap` marks.
    @Test func onlyOneAccountAndOneAddressWithANote() throws {
        var store = try KnownSignInStore(root: root)
        for (account, address, note) in [("alice@example.com", "192.0.2.80", ""), ("alice@example.com", "192.0.2.80", String(repeating: "x", count: 501)),
                                         ("alice", "192.0.2.80", "n"), ("a@example.com,b@example.com", "192.0.2.80", "n"),
                                         ("alice@example.com", "192.0.2.0/24", "n"), ("alice@example.com", "example.com", "n")] {
            #expect(throws: KnownSignInStore.Problem.self, "\(account) \(address)") {
                try store.mark(domain: "example.com", account: account, address: address, note: note)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        for index in 0..<KnownSignInStore.cap {
            try store.mark(domain: "example.com", account: "u\(index)@example.com", address: "192.0.2.1", note: "n", at: Self.moment)
        }
        #expect(throws: KnownSignInStore.Problem.full) {
            try store.mark(domain: "example.com", account: "one-more@example.com", address: "192.0.2.1", note: "n")
        }
        #expect(store.marks.count == KnownSignInStore.cap)
    }

    /// A file this format can't read, or holding a mark it wouldn't save, is moved aside and said, never replaced.
    @Test func anUnreadableFileIsMovedAside() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bad = #"{"version": 1, "marks": [{"domain": "example.com", "account": "a@example.com", "address": "not an ip", "note": "n", "at": "2026-10-22T09:05:00Z"}]}"#
        try Data(bad.utf8).write(to: file)
        let store = try KnownSignInStore(root: root, now: Self.moment)
        #expect(store.marks.isEmpty && store.quarantined == root.appending(path: "known-sign-ins.json.unreadable-2026-10-22T090500Z"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
