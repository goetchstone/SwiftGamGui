import Foundation
@testable import Stores
import Testing

/// The ZIP reader where it is stricter than `zipfile` (docs/domains/classroom.md, Deviations), and its pieces. Everything
/// GamGUI's reader does, it does the same: that's `RosterParityTests`.
@Suite("Roster ZIP reader")
struct RosterZipTests {
    /// A good stored package from the fixture, to damage.
    static func stored() throws -> [UInt8] {
        let item = try #require(RosterParityTests.cases.first { $0.name == "stored, not deflated" })
        return item.uploads[0].bytes
    }

    /// The offsets of each central-directory entry, by name.
    static func central(_ bytes: [UInt8]) -> [String: Int] {
        var found: [String: Int] = [:]
        var at = 0
        while at + 46 <= bytes.count {
            if bytes.matches("PK\u{01}\u{02}", at: at) {
                let length = Int(bytes.u16(at + 28))
                found[String(decoding: bytes[(at + 46)..<(at + 46 + length)], as: UTF8.self)] = at
            }
            at += 1
        }
        return found
    }

    static func put(_ value: UInt32, _ bytes: inout [UInt8], at: Int) {
        for index in 0..<4 { bytes[at + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))) }
    }

    @Test func aFullThirtyTwoBitSizeIsZIP64AndRefused() throws {
        var bytes = try Self.stored()
        let users = try #require(Self.central(bytes)["users.csv"])
        Self.put(0xFFFF_FFFF, &bytes, at: users + 20)
        #expect(throws: PackageError.self) { try RosterZip.open(bytes, caps: .standard) }
        #expect(Roster.refusal([.init(name: "x.zip", bytes: bytes)]) == RosterZip.zip64.message)
    }

    @Test func aZIP64EndRecordIsRefusedAfterItsSizeIsChecked() {
        // GamGUI's `_directory_only(1, "zip64")`: one entry, a ZIP64 record and locator, and an end record that defers to them.
        var entry = Array("PK\u{01}\u{02}".utf8) + [UInt8](repeating: 0, count: 24) + [1, 0] + [UInt8](repeating: 0, count: 16)
        entry += Array("x".utf8)
        func le(_ value: UInt64, _ width: Int) -> [UInt8] { (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) } }
        let record = Array("PK\u{06}\u{06}".utf8) + le(44, 8) + le(45, 2) + le(45, 2) + le(0, 4) + le(0, 4)
            + le(1, 8) + le(1, 8) + le(UInt64(entry.count), 8) + le(0, 8)
        let locator = Array("PK\u{06}\u{07}".utf8) + le(0, 4) + le(UInt64(entry.count), 8) + le(1, 4)
        let end = Array("PK\u{05}\u{06}".utf8) + le(0, 2) + le(0, 2) + le(0xFFFF, 2) + le(0xFFFF, 2) + le(46, 4) + le(0, 4) + le(0, 2)
        let bytes = entry + record + locator + end
        #expect(Roster.refusal([.init(name: "x.zip", bytes: bytes)]) == RosterZip.zip64.message)
        var small = RosterCaps()
        small.members = 0
        #expect(Roster.refusal([.init(name: "x.zip", bytes: bytes)], caps: small)
                == "The ZIP lists far more entries than a roster export holds. Check it's the right file.", "the size first")
    }

    @Test func twoEntriesSharingOneHeaderAreRefused() throws {
        // demographics.csv (never unpacked) pointed at users.csv's header: `zipfile` warns and reads users.csv.
        let item = try #require(RosterParityTests.cases.first { $0.name == "an optional file is named but never unpacked" })
        var bytes = item.uploads[0].bytes
        let entries = Self.central(bytes)
        let users = try #require(entries["users.csv"]), other = try #require(entries["demographics.csv"])
        Self.put(bytes.u32(users + 42), &bytes, at: other + 42)
        #expect(Roster.refusal([.init(name: "x.zip", bytes: bytes)]) == "users.csv couldn't be unpacked from the ZIP. Export the roster again.")
    }

    @Test func crcAndCodePage() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(RosterZip.cp437High.count == 128 && RosterZip.cp437High.last == "\u{A0}")
        #expect(RosterZip.decodeName([0x80, 0x41], utf8: false) == "ÇA")
        #expect(RosterZip.decodeName([0xC3, 0x28], utf8: true) == nil, "strict UTF-8")
    }

    @Test func aPartialCharacterIsHeldAcrossAChunkAndRefusedAtTheEnd() {
        #expect(UTF8Check.wholeCharacters([0x61, 0xE2, 0x82], from: 0, to: 3) == .through(1))
        #expect(UTF8Check.wholeCharacters([0x61, 0xE2, 0x28], from: 0, to: 3) == .invalid)
        #expect(UTF8Check.wholeCharacters([0xED, 0xA0, 0x80], from: 0, to: 3) == .invalid, "a surrogate")
        #expect(UTF8Check.wholeCharacters([0xC0, 0x80], from: 0, to: 2) == .invalid, "an overlong NUL")
    }
}

private extension Roster {
    /// The read's refusal, in words, or nil when it read.
    static func refusal(_ uploads: [Upload], caps: RosterCaps = .standard) -> String? {
        do {
            _ = try read(uploads, caps: caps)
            return nil
        } catch {
            return error.message
        }
    }
}
