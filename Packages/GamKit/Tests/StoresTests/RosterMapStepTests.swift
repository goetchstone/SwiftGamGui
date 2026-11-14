@testable import Stores
import Foundation
import Testing

/// What the map step (App/RosterMapView.swift) leans on, held by exact text as the reader holds it: Swift's `String ==`
/// takes canonically equivalent spellings (NFC "é" and NFD "e" + U+0301) as one, while the reader, the saved maps and
/// the header's columns keep them apart by their bytes.
@Suite("Roster map step")
struct RosterMapStepTests {
    static let nfc = "\u{E9}l\u{E8}ve"
    static let nfd = "e\u{301}le\u{300}ve"

    @Test func roleWordsAreComparedByExactText() {
        // The trap: Swift's array equality calls these the same, so a guard on `!=` never saw the word change.
        #expect([Self.nfc] == [Self.nfd])
        #expect(!RosterColumnMap.sameWords([Self.nfc], [Self.nfd]))
        #expect(RosterColumnMap.sameWords([Self.nfd, "teacher"], [Self.nfd, "teacher"]))
        #expect(!RosterColumnMap.sameWords(["teacher"], ["teacher", "staff"]))
        // And the reader takes only the spelling the map holds.
        let map = RosterColumnMap(studentWords: [Self.nfc])
        #expect(map.role(of: Self.nfd).isEmpty)
        #expect(map.role(of: Self.nfc) == "student")
    }

    @Test func aNameIsFoundByItsBytes() {
        let names = ["Caf\u{E9}", "Cafe\u{301}"]
        #expect(names.firstIndex(of: "Cafe\u{301}") == 0)            // the trap: String equality finds the other one
        #expect(RosterColumnMap.exactIndex(of: "Cafe\u{301}", in: names) == 1)
        #expect(RosterColumnMap.exactIndex(of: "Caf\u{E9}", in: names) == 0)
        #expect(RosterColumnMap.exactIndex(of: "Cafe", in: names) == nil)
    }

    @Test func theSavedMapsKeepBothSpellingsApart() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-mapstep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var store = try RosterMapStore(root: root)
        try store.save("Caf\u{E9}", RosterColumnMap(classID: "A"))
        try store.save("Cafe\u{301}", RosterColumnMap(classID: "B"))
        #expect(store.names.count == 2)
        // So the picker must name each by its bytes: by String, both tags are one.
        let picked = try #require(RosterColumnMap.exactIndex(of: "Cafe\u{301}", in: store.names))
        #expect(store.map(store.names[picked])?.classID == "B")
    }

    /// An address that isn't one plain address is shown as given and marked, never lowercased into one: lowercasing a
    /// Kelvin sign (U+212A) gives an ASCII k, so the preview said "Teacher" for a row the read leaves out as bad_email.
    @Test func thePreviewShowsAnAddressAsTheReadChecksIt() throws {
        let body = Array("Class ID,Class,Term,Email,Role,Lead\nC1,Bio,Fall,\u{212A}im@x.edu,teacher,yes\nC1,Bio,Fall, Kim@X.edu ,student,\n".utf8)
        let map = RosterColumnMap.guess(["Class ID", "Class", "Term", "Email", "Role", "Lead"])
        let rows = try RosterMapped.preview(name: "s.csv", bytes: body, map: map)
        #expect(rows.count == 2)
        #expect(rows[0][.email] == "\u{212A}im@x.edu")
        #expect(!rows[0].isAddress)
        #expect(rows[1][.email] == "kim@x.edu" && rows[1].isAddress)
        // The read agrees: the first row is left out, the second kept.
        let snap = try RosterMapped.read(name: "s.csv", bytes: body, map: map)
        #expect(snap.issueSample.contains { $0.code == "bad_email" && $0.detail == "\u{212A}im@x.edu" })
        #expect(snap.people.map(\.email) == ["kim@x.edu"])
        #expect(rows[0].leftOut == "not one address" && rows[1].leftOut == nil)
    }

    /// The preview says why the read leaves a row out, by the read's own checks in its order, and only for a field that is
    /// mapped: a half-filled map doesn't flag every row (GamGUI #123, `_left_out`).
    @Test func aRowTheReadLeavesOutSaysWhyOnlyOnceItsFieldIsMapped() throws {
        let body = Array("Class ID,Email,Role\n,a@x.edu,student\nC1,,student\nC1,a b@x.edu,student\nC1,ok@x.edu,student\n".utf8)
        var map = RosterColumnMap()
        map.role = "Role"
        #expect(try RosterMapped.preview(name: "s.csv", bytes: body, map: map, count: 4).allSatisfy { $0.leftOut == nil },
                "nothing mapped that the read checks: nothing flagged")
        map.email = "Email"
        #expect(try RosterMapped.preview(name: "s.csv", bytes: body, map: map, count: 4).map(\.leftOut)
                == [nil, "no address", "not one address", nil], "the class ID isn't mapped yet, so it isn't checked")
        map.classID = "Class ID"
        #expect(try RosterMapped.preview(name: "s.csv", bytes: body, map: map, count: 4).map(\.leftOut)
                == ["no class ID", "no address", "not one address", nil])
    }
}
