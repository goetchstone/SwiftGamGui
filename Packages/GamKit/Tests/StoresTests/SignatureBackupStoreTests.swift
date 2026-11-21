import ChangeCore
import Darwin
import Foundation
import GamEngine
@testable import Stores
import Synchronization
import Testing
import Vault

/// Signature backups (GamGUI's `tests/test_signature_backups.py`, its store half): each person's signature as it was, kept
/// byte for byte and privately before a run replaces it; the last five runs kept, never one still being written, and a
/// run that kept nobody removed; a run read whole or listed as unreadable, never in part; and only a kept run's own id
/// loads, never through a link. Plus this app's own: the domain in the header, a keep past the cap refused with the copies
/// before it still whole.
@Suite("Signature backups")
struct SignatureBackupStoreTests {
    let base: URL
    /// The store's folder, not made yet: the store makes it.
    let folder: URL
    let example = Domain("example.com")!

    static let alice = "alice@example.com", carol = "carol@example.com"
    /// Leading spaces, a trailing newline, a tab, non-ASCII and curly quotes (GamGUI's TRICKY), and a trailing space.
    static let tricky = "  <div dir=\"ltr\">\u{DC}n\u{EF}code &amp; \u{201C}quotes\u{201D}\n\tand a tab</div>\n "

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-kept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        folder = base.appending(path: "SwiftGamGui/signature-backups")
    }

    func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    func file(_ id: String) -> URL { folder.appending(path: "\(id).jsonl") }

    /// One run that keeps `emails`' signatures, closed.
    @discardableResult
    func keptRun(_ store: SignatureBackupStore, _ what: String, keeping emails: [String] = []) throws -> String {
        let run = try store.start(what: what, domain: example)
        for email in emails { try run.keep(email: email, previous: "old", setting: "new") }
        run.close()
        return run.id
    }

    @Test func aRunKeepsEachSignatureByteForByteAndPrivately() throws {
        let store = SignatureBackupStore(folder: folder)
        let run = try store.start(what: "Signature for sales@example.com \u{2014} 2 users", domain: example)
        try run.keep(email: Self.alice, previous: Self.tricky, setting: "<b>new</b>")
        // No signature before: kept as empty, put back as empty.
        try run.keep(email: Self.carol, previous: "", setting: "<b>new</b>")
        #expect(run.keptCount == 2)
        run.close()
        let listed = store.runs()
        #expect(listed.count == 1 && listed[0].problem == nil)
        let loaded = try #require(listed[0].run)
        #expect(loaded.id == run.id && loaded.what == "Signature for sales@example.com \u{2014} 2 users" && loaded.domain == "example.com")
        #expect(loaded.entries == [.init(email: Self.alice, previous: Self.tricky, set: "<b>new</b>"),
                                   .init(email: Self.carol, previous: "", set: "<b>new</b>")])
        #expect(loaded.entries[0].previous.utf8.elementsEqual(Self.tricky.utf8))
        #expect(abs(loaded.when.timeIntervalSinceNow) < 60)
        #expect(mode(folder) == 0o700 && mode(file(run.id)) == 0o600)
        // GamGUI's run id: 13 digits of milliseconds, a dash, 8 hex digits.
        #expect(run.id.wholeMatch(of: /[0-9]{13}-[0-9a-f]{8}/) != nil)
    }

    /// Each line is on disk before the write it's for: a new store reads a run still open.
    @Test func eachCopyIsOnDiskBeforeTheRunEnds() throws {
        let store = SignatureBackupStore(folder: folder)
        let run = try store.start(what: "everyone", domain: example)
        try run.keep(email: Self.alice, previous: "ORIGINAL", setting: "new")
        #expect(try SignatureBackupStore(folder: folder).load(run.id).entries == [.init(email: Self.alice, previous: "ORIGINAL", set: "new")])
        run.close()
    }

    /// Review of Phase A: a run's id was the clock's alone, so after the clock went back the newest run sorted as the oldest
    /// (and was the next one pruned). Ids only go forward; runs in one millisecond keep the order they were made in.
    @Test func runIDsOnlyGoForward() throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000))
        let store = SignatureBackupStore(folder: folder, now: { clock.withLock { $0 } })
        let first = try keptRun(store, "first", keeping: [Self.alice])
        clock.withLock { $0 = Date(timeIntervalSince1970: 500) }
        let second = try keptRun(store, "second", keeping: [Self.alice])
        let third = try keptRun(store, "third", keeping: [Self.alice])
        #expect(store.runs().map(\.id) == [third, second, first])
        #expect(first.hasPrefix("0000001000000-") && second.hasPrefix("0000001000001-") && third.hasPrefix("0000001000002-"))
        #expect(SignatureBackupStore.milliseconds("0000000000002-empty") == 2 && SignatureBackupStore.milliseconds("nope") == nil)
    }

    @Test func onlyTheLastRunsAreKept() throws {
        let store = SignatureBackupStore(folder: folder)
        var ids: [String] = []
        for index in 0..<(SignatureBackupStore.keptRuns + 2) {
            ids.append(try keptRun(store, "run \(index)", keeping: ["p\(index)@example.com"]))
        }
        #expect(store.runs().map(\.id) == Array(ids.sorted(by: >).prefix(SignatureBackupStore.keptRuns)))
    }

    @Test func aRunThatCantBeReadWholeIsListedNeverDropped() throws {
        let store = SignatureBackupStore(folder: folder)
        let id = try keptRun(store, "x", keeping: [Self.alice])
        let handle = try FileHandle(forWritingTo: file(id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        let listed = store.runs()
        #expect(listed.count == 1 && listed[0].id == id && listed[0].run == nil && listed[0].problem == "it isn't whole")
        #expect(throws: SignatureBackupStore.Problem("it isn't whole")) { try store.load(id) }
    }

    /// GamGUI's review of #163: a long run's file was deleted by five shorter runs started meanwhile, and its later copies
    /// went to a deleted file without an error.
    @Test func aRunStillBeingWrittenIsNeverPruned() throws {
        let store = SignatureBackupStore(folder: folder)
        let long = try store.start(what: "the whole company", domain: example)
        for index in 0...SignatureBackupStore.keptRuns {
            try keptRun(store, "one person \(index)", keeping: ["p\(index)@example.com"])
        }
        try long.keep(email: Self.alice, previous: "ORIGINAL", setting: "new")
        #expect(FileManager.default.fileExists(atPath: file(long.id).path))
        long.close()
        #expect(try store.load(long.id).entries == [.init(email: Self.alice, previous: "ORIGINAL", set: "new")])
    }

    /// GamGUI's review of #163: five failed attempts (a sign-in expired, every read refused) used up the slots.
    @Test func runsThatKeptNobodyDontPushOutRealCopies() throws {
        let store = SignatureBackupStore(folder: folder)
        let good = try keptRun(store, "sales", keeping: [Self.alice])
        for _ in 0...SignatureBackupStore.keptRuns { try keptRun(store, "an attempt that kept nobody") }
        #expect(store.runs().map(\.id) == [good])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["\(good).jsonl"])
    }

    @Test(arguments: ["", "../escape", "a/b", ".hidden", "run\0id", "nope"])
    func onlyAKeptRunsIDLoads(_ bad: String) throws {
        let store = SignatureBackupStore(folder: folder)
        try keptRun(store, "x", keeping: [Self.alice])
        #expect(throws: SignatureBackupStore.Problem("it isn't a kept run")) { try store.load(bad) }
    }

    /// A link is never read, listed or pruned, and the folder is never one: a run's file planted as a link to another file
    /// isn't a kept run, and a folder that is a link keeps nothing.
    @Test func aLinkIsNeverFollowed() throws {
        let store = SignatureBackupStore(folder: folder)
        let id = try keptRun(store, "x", keeping: [Self.alice])
        let elsewhere = base.appending(path: "elsewhere.jsonl")
        try FileManager.default.copyItem(at: file(id), to: elsewhere)
        let linked = "0000000000001-0000link"
        try FileManager.default.createSymbolicLink(at: file(linked), withDestinationURL: elsewhere)
        #expect(store.runs().map(\.id) == [id])
        #expect(throws: SignatureBackupStore.Problem("it isn't a kept run")) { try store.load(linked) }
        for _ in 0...SignatureBackupStore.keptRuns { try keptRun(store, "more", keeping: [Self.carol]) }
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))

        let target = base.appending(path: "target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let linkedFolder = base.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: target)
        let throughLink = SignatureBackupStore(folder: linkedFolder)
        #expect(throws: (any Error).self) { try throughLink.start(what: "x", domain: example) }
        #expect(throughLink.runs().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    /// The header names the run: a file renamed to another run's id, or missing its domain, isn't whole.
    @Test func aRunIsOnlyWhatItsHeaderSays() throws {
        let store = SignatureBackupStore(folder: folder)
        let id = try keptRun(store, "x", keeping: [Self.alice])
        let renamed = "0000000000002-0000beef"
        try FileManager.default.moveItem(at: file(id), to: file(renamed))
        #expect(throws: SignatureBackupStore.Problem("it isn't whole")) { try store.load(renamed) }
        let noDomain = "0000000000003-0000cafe"
        try Data(#"{"run": "0000000000003-0000cafe", "when": 1.0, "what": "carol"}"#.utf8 + [10]
                 + #"{"email": "carol@example.com", "previous": "", "set": "x"}"#.utf8 + [10]).write(to: file(noDomain))
        #expect(throws: SignatureBackupStore.Problem("it isn't whole")) { try store.load(noDomain) }
        let whole = "0000000000004-0000f00d"
        try Data(#"{"run": "0000000000004-0000f00d", "when": 1.0, "what": "carol", "domain": "example.com"}"#.utf8 + [10]
                 + #"{"email": "carol@example.com", "previous": "", "set": "Carol\nClark"}"#.utf8 + [10]).write(to: file(whole))
        #expect(try store.load(whole).entries == [.init(email: Self.carol, previous: "", set: "Carol\nClark")])
    }

    /// A copy that would take the file past what a load reads is refused, and the run's copies before it stay whole: a run
    /// stops rather than keep one nothing could give back.
    @Test func aCopyPastTheCapIsRefusedAndTheRestStayWhole() throws {
        let store = SignatureBackupStore(folder: folder, cap: 600)
        let run = try store.start(what: "everyone", domain: example)
        try run.keep(email: Self.alice, previous: "ORIGINAL", setting: "new")
        #expect(throws: SignatureBackupStore.Problem("it would be larger than this app reads")) {
            try run.keep(email: Self.carol, previous: String(repeating: "x", count: 600), setting: "new")
        }
        run.close()
        #expect(try store.load(run.id).entries == [.init(email: Self.alice, previous: "ORIGINAL", set: "new")])
        // A file larger than the cap, however it got there, isn't read.
        let handle = try FileHandle(forWritingTo: file(run.id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(repeating: " ", count: 600).utf8))
        try handle.close()
        #expect(throws: SignatureBackupStore.Problem("it's larger than this app reads")) { try store.load(run.id) }
    }

    /// The folder is made `0700` and set back to it when loosened; a run ended keeps nothing more.
    @Test func theFolderIsPrivateAndAnEndedRunKeepsNothing() throws {
        let store = SignatureBackupStore(folder: folder)
        let id = try keptRun(store, "x", keeping: [Self.alice])
        chmod(folder.path, 0o755)
        let run = try store.start(what: "y", domain: example)
        #expect(mode(folder) == 0o700)
        run.close()
        #expect(throws: SignatureBackupStore.Problem("the run has ended")) { try run.keep(email: Self.carol, previous: "", setting: "x") }
        #expect(store.runs().map(\.id) == [id])
    }
}
