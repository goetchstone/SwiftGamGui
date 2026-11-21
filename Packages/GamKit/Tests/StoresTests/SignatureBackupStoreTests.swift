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
        let run = try store.start(what: what, domain: example, restoring: [])
        for email in emails { try run.keep(email: email, previous: "old", setting: "new") }
        run.close()
        return run.id
    }

    @Test func aRunKeepsEachSignatureByteForByteAndPrivately() throws {
        let store = SignatureBackupStore(folder: folder)
        let run = try store.start(what: "Signature for sales@example.com \u{2014} 2 users", domain: example, restoring: [])
        try run.keep(email: Self.alice, previous: Self.tricky, setting: "<b>new</b>")
        // No signature before: kept as empty, put back as empty.
        try run.keep(email: Self.carol, previous: "", setting: "<b>new</b>")
        #expect(run.keptCount == 2)
        run.close()
        let listed = try store.runs()
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
        let run = try store.start(what: "everyone", domain: example, restoring: [])
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
        #expect(try store.runs().map(\.id) == [third, second, first])
        #expect(first.hasPrefix("0000001000000-") && second.hasPrefix("0000001000001-") && third.hasPrefix("0000001000002-"))
        #expect(SignatureBackupStore.milliseconds("0000000000002-empty") == 2 && SignatureBackupStore.milliseconds("nope") == nil)
    }

    @Test func onlyTheLastRunsAreKept() throws {
        let store = SignatureBackupStore(folder: folder)
        var ids: [String] = []
        for index in 0..<(SignatureBackupStore.keptRuns + 2) {
            ids.append(try keptRun(store, "run \(index)", keeping: ["p\(index)@example.com"]))
        }
        // Listed outside the expectation: a listing that throws is reported with its reason, not "<not evaluated>".
        let listed = try store.runs().map(\.id)
        #expect(listed == Array(ids.sorted(by: >).prefix(SignatureBackupStore.keptRuns)))
    }

    @Test func aRunThatCantBeReadWholeIsListedNeverDropped() throws {
        let store = SignatureBackupStore(folder: folder)
        let id = try keptRun(store, "x", keeping: [Self.alice])
        let handle = try FileHandle(forWritingTo: file(id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        let listed = try store.runs()
        #expect(listed.count == 1 && listed[0].id == id && listed[0].run == nil && listed[0].problem == "it isn't whole")
        #expect(throws: SignatureBackupStore.Problem("it isn't whole")) { try store.load(id) }
    }

    /// GamGUI's review of #163: a long run's file was deleted by five shorter runs started meanwhile, and its later copies
    /// went to a deleted file without an error.
    @Test func aRunStillBeingWrittenIsNeverPruned() throws {
        let store = SignatureBackupStore(folder: folder)
        let long = try store.start(what: "the whole company", domain: example, restoring: [])
        for index in 0...SignatureBackupStore.keptRuns {
            try keptRun(store, "one person \(index)", keeping: ["p\(index)@example.com"])
        }
        try long.keep(email: Self.alice, previous: "ORIGINAL", setting: "new")
        #expect(FileManager.default.fileExists(atPath: file(long.id).path))
        long.close()
        #expect(try store.load(long.id).entries == [.init(email: Self.alice, previous: "ORIGINAL", set: "new")])
    }

    /// Review of Phase A: pruning when a run started deleted the oldest of five kept runs as its own Put Back began, so whoever
    /// that Put Back didn't restore lost their only copy. The run put back outlives it, until a later run that keeps someone
    /// pushes it out.
    @Test func aPutBackNeverPrunesTheRunItRestores() throws {
        let store = SignatureBackupStore(folder: folder)
        var ids: [String] = []
        for index in 0..<SignatureBackupStore.keptRuns { ids.append(try keptRun(store, "run \(index)", keeping: ["p\(index)@example.com"])) }
        let oldest = ids[0]
        let putBack = try store.start(what: "Put back of run 0", domain: example, restoring: [oldest])
        #expect(try store.load(oldest).entries.count == 1, "still there as the Put Back starts")
        try putBack.keep(email: "p0@example.com", previous: "new", setting: "old")
        putBack.close()
        #expect(try store.load(oldest).entries.count == 1, "and after it ends")
        #expect(try store.runs().count == SignatureBackupStore.keptRuns + 1)
        // A later run that keeps someone makes room as usual: the newest five stay.
        let later = try keptRun(store, "later", keeping: [Self.alice])
        let listed = try store.runs().map(\.id)
        #expect(listed == Array(([later, putBack.id] + ids.reversed()).prefix(SignatureBackupStore.keptRuns)))
    }

    /// Review of Phase A: with five kept runs, an attempt that kept nobody (a sign-in expired, every read refused) still
    /// pruned the oldest as it started, then removed its own empty file. Only a run that keeps someone makes room.
    @Test func aRunThatKeepsNobodyPrunesNothing() throws {
        let store = SignatureBackupStore(folder: folder)
        var ids: [String] = []
        for index in 0..<SignatureBackupStore.keptRuns { ids.append(try keptRun(store, "run \(index)", keeping: ["p\(index)@example.com"])) }
        let attempt = try store.start(what: "an attempt", domain: example, restoring: [])
        #expect(try store.runs().count == SignatureBackupStore.keptRuns + 1, "nothing pruned as it starts")
        attempt.close()
        #expect(try store.runs().map(\.id) == ids.reversed())
    }

    /// Review of Phase A: a folder there that couldn't be opened read as no kept runs, and the screen said none were kept.
    /// It throws, in words; no folder yet is none.
    @Test func aFolderThatCantBeReadIsNeverNone() throws {
        let store = SignatureBackupStore(folder: folder)
        #expect(try store.runs().isEmpty, "no folder yet")
        try keptRun(store, "x", keeping: [Self.alice])
        chmod(folder.path, 0)
        defer { chmod(folder.path, 0o700) }
        #expect(throws: SignatureBackupStore.Problem("their folder couldn't be opened (Permission denied)")) { try store.runs() }
    }

    /// Review of Phase A: a torn last line (power lost while a copy was being appended) made the whole run unreadable, though
    /// every copy before it was whole and that person's write never ran. It's left out; a broken line before a whole one
    /// still isn't.
    @Test func aTornLastLineIsAnAppendThatNeverFinished() throws {
        let store = SignatureBackupStore(folder: folder)
        let id = try keptRun(store, "x", keeping: [Self.alice])
        let handle = try FileHandle(forWritingTo: file(id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"email": "carol@example.com", "previous": "Car"#.utf8) + Data([0xC3]))
        try handle.close()
        #expect(try store.load(id).entries == [.init(email: Self.alice, previous: "old", set: "new")])
        let more = try FileHandle(forWritingTo: file(id))
        try more.seekToEnd()
        try more.write(contentsOf: Data("\n".utf8))
        try more.close()
        #expect(throws: SignatureBackupStore.Problem("it isn't whole")) { try store.load(id) }
        // A header cut off is no run at all.
        try Data(#"{"run": "\#(id)", "wh"#.utf8).write(to: file(id))
        #expect(throws: SignatureBackupStore.Problem("it isn't whole")) { try store.load(id) }
    }

    /// Review of Phase A: the open-run guard was one store's own, so another store on the folder (a second copy of the app)
    /// pruned a run still being written. An open run's file is locked, and every store's pruning skips a locked file.
    @Test func noStorePrunesARunAnotherIsWriting() throws {
        let writing = SignatureBackupStore(folder: folder), other = SignatureBackupStore(folder: folder)
        let long = try writing.start(what: "the whole company", domain: example, restoring: [])
        try long.keep(email: Self.alice, previous: "ORIGINAL A", setting: "new")
        for index in 0...SignatureBackupStore.keptRuns { try keptRun(other, "one person \(index)", keeping: ["p\(index)@example.com"]) }
        #expect(FileManager.default.fileExists(atPath: file(long.id).path))
        try long.keep(email: Self.carol, previous: "ORIGINAL C", setting: "new")
        long.close()
        #expect(try other.load(long.id).entries.map(\.previous) == ["ORIGINAL A", "ORIGINAL C"])
    }

    /// A closed run's lock can outlive its close for a moment (once in three full suite runs, with processes starting beside
    /// it): pruning waits a little for a lock (`lockedNow`) rather than read it as a run being written; one held throughout is
    /// never taken. The window is widened here, so a busy suite's late timer can't decide it.
    @Test func aLockHeldAMomentIsWaitedFor() throws {
        let id = try keptRun(SignatureBackupStore(folder: folder), "x", keeping: [Self.alice])
        let holder = open(file(id).path, O_RDONLY | O_CLOEXEC), pruner = open(file(id).path, O_RDONLY | O_CLOEXEC)
        defer { close(pruner) }
        // The holder rides out a process started beside the suite holding the file for a moment, as pruning does; a single
        // try failed here twice in full runs (failure log 2026-11-21).
        #expect(holder >= 0 && pruner >= 0 && SignatureBackupStore.lockedNow(holder, tries: 250))
        #expect(!SignatureBackupStore.lockedNow(pruner, tries: 2), "held throughout: never taken")
        // Released after the first refused try, at a known point in the wait: no timer to race on a busy machine.
        var released = false
        #expect(SignatureBackupStore.lockedNow(pruner, tries: 250, afterRefused: {
            if !released { released = true; close(holder) }
        }), "released a moment later: taken")
        #expect(released, "the first try was refused: the lock was held when the wait began")
    }

    /// Review of Phase A: a keep into a file someone removed flushed into nothing and said it was kept. It throws, so the
    /// executor stops before that person's write.
    @Test func aCopyIntoAFileThatsGoneIsNotKept() throws {
        let store = SignatureBackupStore(folder: folder)
        let run = try store.start(what: "everyone", domain: example, restoring: [])
        try run.keep(email: Self.alice, previous: "ORIGINAL", setting: "new")
        try FileManager.default.removeItem(at: file(run.id))
        #expect(throws: SignatureBackupStore.Problem("its file was removed while the run went on")) {
            try run.keep(email: Self.carol, previous: "ORIGINAL", setting: "new")
        }
        #expect(run.keptCount == 1)
        run.close()
    }

    /// GamGUI's review of #163: five failed attempts (a sign-in expired, every read refused) used up the slots.
    @Test func runsThatKeptNobodyDontPushOutRealCopies() throws {
        let store = SignatureBackupStore(folder: folder)
        let good = try keptRun(store, "sales", keeping: [Self.alice])
        for _ in 0...SignatureBackupStore.keptRuns { try keptRun(store, "an attempt that kept nobody") }
        #expect(try store.runs().map(\.id) == [good])
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
        #expect(try store.runs().map(\.id) == [id])
        #expect(throws: SignatureBackupStore.Problem("it isn't a kept run")) { try store.load(linked) }
        for _ in 0...SignatureBackupStore.keptRuns { try keptRun(store, "more", keeping: [Self.carol]) }
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))

        let target = base.appending(path: "target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let linkedFolder = base.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: target)
        let throughLink = SignatureBackupStore(folder: linkedFolder)
        #expect(throws: (any Error).self) { try throughLink.start(what: "x", domain: example, restoring: []) }
        #expect(throws: SignatureBackupStore.Problem("their folder couldn't be opened (Not a directory)")) {
            try throughLink.runs()
        }
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
        let run = try store.start(what: "everyone", domain: example, restoring: [])
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
        let run = try store.start(what: "y", domain: example, restoring: [])
        #expect(mode(folder) == 0o700)
        run.close()
        #expect(throws: SignatureBackupStore.Problem("the run has ended")) { try run.keep(email: Self.carol, previous: "", setting: "x") }
        #expect(try store.runs().map(\.id) == [id])
    }
}
