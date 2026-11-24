@testable import Stores
import Darwin
import Foundation
import GamEngine
import Testing

/// The files this app saved through a save panel (plan F4's Files, a listed difference from GamGUI): kept as the other small
/// stores keep theirs, `0600` in a `0700` folder, newest first, the same path listed once, bounded, and only a path this store
/// would keep.
@Suite("Saved files store")
struct SavedFilesStoreTests {
    let base = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-saved-files-\(UUID().uuidString)")
    var root: URL { base.appending(path: "SwiftGamGui") }

    @Test func aSavedFileIsListedNewestFirstOnce() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var store = try SavedFilesStore(root: root)
        #expect(store.files.isEmpty && !FileManager.default.fileExists(atPath: root.path))
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        try store.record(URL(filePath: "/Users/Shared/a.csv"), what: "Builder table", at: at)
        try store.record(URL(filePath: "/Users/Shared/b.csv"), what: "Audit log", at: at + 1)
        try store.record(URL(filePath: "/Users/Shared/a.csv"), what: "Builder table", at: at + 2)
        #expect(store.files.map(\.path) == ["/Users/Shared/a.csv", "/Users/Shared/b.csv"])
        var info = stat()
        #expect(lstat(root.appending(path: SavedFilesStore.fileName).path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(lstat(root.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        let reread = try SavedFilesStore(root: root)
        #expect(reread.files == store.files && reread.files.first?.at == at + 2)
        // Not a file this store keeps: nothing listed.
        try store.record(URL(string: "https://example.com/x.csv")!, what: "x")
        try store.record(URL(filePath: "/tmp/a\nb.csv"), what: "x")
        #expect(store.files.count == 2)
    }

    @Test func theListIsBounded() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var store = try SavedFilesStore(root: root)
        for i in 0..<(SavedFilesStore.cap + 3) { try store.record(URL(filePath: "/Users/Shared/\(i).csv"), what: "Builder table") }
        #expect(store.files.count == SavedFilesStore.cap && store.files.first?.path == "/Users/Shared/\(SavedFilesStore.cap + 2).csv")
    }

    /// A file this format can't read is moved aside and said, never saved over.
    @Test func anUnreadableListIsSetAside() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version": 2, "files": []}"#.utf8).write(to: root.appending(path: SavedFilesStore.fileName))
        let store = try SavedFilesStore(root: root)
        #expect(store.files.isEmpty && store.quarantined != nil)
    }
}
