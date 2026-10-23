@testable import Stores
import Darwin
import Foundation
import GamEngine
import Testing

/// The emails Phishing's Find showed nobody here has (phishing.md D14): native. Its file is handled as the marked sign-ins'
/// is (`SignatureStore.load`, `writeFile`), so these hold the format, the per-domain checks, the newest replacing an older
/// one, the cap, and the rule that only a Message-ID Phishing can search by is kept or read.
@Suite("Nobody-has store")
struct NobodyHasStoreTests {
    let base: URL
    /// The store's folder, not made yet: the store makes it.
    let root: URL
    var file: URL { root.appending(path: NobodyHasStore.fileName) }

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-nobody-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        root = base.appending(path: "SwiftGamGui")
    }

    func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    static let moment = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
                                       year: 2026, month: 10, day: 23, hour: 11, minute: 2).date!

    /// Nothing is written until a check; a check is saved `0600` in a `0700` folder, bare, read back by a new store, kept per
    /// domain, and the same email checked again replaces it. One Phishing couldn't search by, or a bad domain or admin,
    /// keeps nothing.
    @Test func aCheckIsSavedPerDomainAndReplacedByANewerOne() throws {
        var store = try NobodyHasStore(root: root)
        #expect(store.checks.isEmpty && !FileManager.default.fileExists(atPath: root.path))
        try store.record(domain: "Example.com", messageIDs: ["<phish-1@mail.example.com>", "a b@c", "phish-2@mail.example.com"],
                         by: "Admin@example.com", at: Self.moment)
        try store.record(domain: "example.org", messageIDs: ["phish-1@mail.example.com"], by: "", at: Self.moment)
        try store.record(domain: "not a domain", messageIDs: ["phish-3@mail.example.com"], by: "admin@example.com")
        try store.record(domain: "example.com", messageIDs: ["phish-3@mail.example.com"], by: "not an admin")
        #expect(mode(root) == 0o700 && mode(file) == 0o600)
        let reopened = try NobodyHasStore(root: root)
        #expect(reopened.checks(for: "example.com").map(\.messageID) == ["phish-1@mail.example.com", "phish-2@mail.example.com"])
        #expect(reopened.checks(for: "example.com").allSatisfy { $0.by == "admin@example.com" && $0.at == Self.moment })
        #expect(reopened.checks(for: "example.org").map(\.by) == [""])
        let later = Self.moment.addingTimeInterval(3600)
        try store.record(domain: "example.com", messageIDs: ["phish-2@mail.example.com"], by: "admin@example.com", at: later)
        #expect(try NobodyHasStore(root: root).checks(for: "example.com").map { [$0.messageID, $0.at == later ? "later" : "first"] }
                == [["phish-2@mail.example.com", "later"], ["phish-1@mail.example.com", "first"]])
    }

    /// At most `cap` checks, the oldest dropped: a check is kept by itself, so none is ever refused.
    @Test func theOldestCheckGoesPastTheCap() throws {
        var store = try NobodyHasStore(root: root)
        try store.record(domain: "example.com", messageIDs: (0..<NobodyHasStore.cap).map { "m\($0)@mail.example.com" }, by: "", at: Self.moment)
        try store.record(domain: "example.com", messageIDs: ["newest@mail.example.com"], by: "", at: Self.moment)
        #expect(store.checks.count == NobodyHasStore.cap && store.checks.first?.messageID == "newest@mail.example.com")
        #expect(!store.checks.contains { $0.messageID == "m\(NobodyHasStore.cap - 1)@mail.example.com" })
    }

    /// A file this format can't read, or holding a check it wouldn't save, is moved aside and said, never replaced.
    @Test func anUnreadableFileIsMovedAside() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bad = #"{"version": 1, "checks": [{"domain": "example.com", "message_id": "<a@b.c>", "at": "2026-10-23T11:02:00Z", "by": ""}]}"#
        try Data(bad.utf8).write(to: file)
        let store = try NobodyHasStore(root: root, now: Self.moment)
        #expect(store.checks.isEmpty && store.quarantined == root.appending(path: "nobody-has.json.unreadable-2026-10-23T110200Z"))
    }
}
