@testable import Stores
import Darwin
import Foundation
import GamEngine
import Testing

/// The saved column maps (GamGUI's `core/roster_maps.py`, its tests in tests/test_roster_mapped.py): GamGUI's format and
/// rules, kept as the offboarding templates' file is (`SignatureStore.load`, `writeFile`). The name rules' words are held
/// to GamGUI's by `RosterMappedParityTests`.
@Suite("Saved column maps")
struct RosterMapStoreTests {
    let base: URL
    /// The store's folder, not made yet: the store makes it.
    let root: URL
    var file: URL { root.appending(path: RosterMapStore.fileName) }

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-maps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        root = base.appending(path: "SwiftGamGui")
    }

    static let cmap = RosterColumnMap(classID: "Section ID", className: "Course Title", section: "Term", email: "Email Address",
                                      role: "User Type", primary: "Lead", teacherWords: ["teacher", "staff"], studentWords: ["student"])

    func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    func listing(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    struct Interrupted: Error {}

    @Test func roundTripModesAndNamesIgnoringCase() throws {
        var store = try RosterMapStore(root: root)
        #expect(store.names.isEmpty && !FileManager.default.fileExists(atPath: file.path))
        try store.save("  Aeries  ", Self.cmap)
        try store.save("beta", RosterColumnMap(email: "Mail"))
        try store.save("ALPHA", RosterColumnMap(classID: "x"))
        #expect(store.names == ["Aeries", "ALPHA", "beta"])
        var again = try RosterMapStore(root: root)
        #expect(again.map("Aeries") == Self.cmap && again.map(" beta ") == RosterColumnMap(email: "Mail"))
        #expect(mode(file) == 0o600 && mode(root) == 0o700)
        let text = try String(contentsOf: file, encoding: .utf8)
        let json = try #require(JSONValue.parse(text))
        #expect(json["version"]?.int == 1 && Set(json["maps"]?.object?.keys ?? []) == ["ALPHA", "Aeries", "beta"])
        try again.save("aeries", RosterColumnMap(email: "E"))        // the same name in another case replaces it
        #expect(again.names == ["aeries", "ALPHA", "beta"])
        try again.delete("beta")
        try again.delete("never saved")
        #expect(try RosterMapStore(root: root).names == ["aeries", "ALPHA"])
        #expect(listing(root) == [RosterMapStore.fileName])          // no temporary file left
    }

    @Test func anInterruptedSaveChangesNothing() throws {
        var store = try RosterMapStore(root: root)
        try store.save("one", Self.cmap)
        let before = try Data(contentsOf: file)
        store.interrupt = { _ in throw Interrupted() }
        #expect(throws: RosterMapStore.Problem.self) { try store.save("two", Self.cmap) }
        #expect(try Data(contentsOf: file) == before && store.names == ["one"])
        #expect(listing(root) == [RosterMapStore.fileName])
    }

    @Test(arguments: ["not json", "[]", #"{"version": 2, "maps": {}}"#, #"{"version": 1, "maps": []}"#,
                      #"{"version": 1, "maps": {"a": 3}}"#, #"{"version": 1, "maps": {"a\u0001": {}}}"#, "\u{FF}\u{FE}"])
    func anUnreadableFileIsMovedAsideNeverSavedOver(_ junk: String) throws {
        let bytes = junk == "\u{FF}\u{FE}" ? Data([0xFF, 0xFE]) : Data(junk.utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: file)
        var store = try RosterMapStore(root: root)
        let aside = try #require(store.quarantined)
        #expect(store.names.isEmpty && !FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: aside) == bytes)
        try store.save("fresh", Self.cmap)
        #expect(try Data(contentsOf: aside) == bytes)
        #expect(try RosterMapStore(root: root).names == ["fresh"])
    }

    @Test func moreThanFiftyMapsIsRefused() throws {
        var store = try RosterMapStore(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var maps = JSONObject()
        for index in 0...RosterMapStore.mapsCap { maps["map \(index)"] = .object([:]) }
        try Data(JSONValue.dumps(.object(["version": .number("1"), "maps": .object(maps)])).utf8).write(to: file)
        store = try RosterMapStore(root: root)
        #expect(store.quarantined != nil && store.names.isEmpty)
    }

    @Test func aStoredMapWithJunkFieldsReadsWithoutFailing() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version": 1, "maps": {"m": {"class_id": 9, "email": "Mail", "teacher_words": "x"}}}"#.utf8).write(to: file)
        #expect(try RosterMapStore(root: root).map("m") == RosterColumnMap(email: "Mail"))
    }

    @Test(arguments: [("", "Give the map a name"), ("   ", "Give the map a name"), (String(repeating: "x", count: 61), "at most 60"),
                      ("tab\there", "control"), ("zero\u{200B}width", "control")])
    func aNameThatCantBeKeptIsRefused(_ name: String, _ words: String) throws {
        var store = try RosterMapStore(root: root)
        #expect {
            try store.save(name, Self.cmap)
        } throws: { error in
            (error as? RosterMapStore.Problem)?.message.contains(words) == true
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func atMostFiftyAreKept() throws {
        var store = try RosterMapStore(root: root)
        for index in 0..<RosterMapStore.mapsCap { try store.save("map \(index)", Self.cmap) }
        #expect {
            try store.save("one more", Self.cmap)
        } throws: { error in
            (error as? RosterMapStore.Problem)?.message == "There are 50 saved maps already. Delete one you no longer use first."
        }
        try store.save("MAP 3", RosterColumnMap(email: "E"))        // replacing one is fine
        #expect(try RosterMapStore(root: root).names.count == RosterMapStore.mapsCap)
    }

    @Test func theFileHoldsNoRowData() throws {
        var store = try RosterMapStore(root: root)
        try store.save("m", RosterColumnMap.guess(["Section ID", "Course Title", "Email", "Role"]))
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("@"))
    }

    /// The audit names the fields mapped, sorted, never a column's text.
    @Test func theMappedFieldsAreNamesNotColumns() {
        #expect(Self.cmap.mappedFields == ["class_id", "class_name", "email", "primary", "role", "section"])
        #expect(RosterColumnMap(classID: "Who", email: "Who", role: "R").mappedFields == ["class_id", "email", "role"])
    }
}
