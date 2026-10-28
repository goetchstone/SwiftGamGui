import Foundation
import GamEngine
import Testing
import TestSupport

/// The Builder's curated commands (invariants 1 and 11): GamGUI's `_curated()`, each with its fields and the argv its builder makes
/// from the same values (`Tests/Fixtures/catalog_curated.json`, generated from frozen GamGUI by `scripts/gen_catalog_reads.py`), but
/// for the two another screen runs; and the form's rules: trimmed, required, one address, a choice from its list.
@Suite("Curated commands")
struct CuratedCommandTests {
    struct Curated: Decodable {
        struct Slot: Decodable {
            let key, label, kind, `default`, placeholder, hintNote: String
            let required: Bool
            let choices, hints: [String]
        }
        struct Case: Decodable {
            let values: [String: String]
            let argv: [String]
        }
        let id, category, subcategory, name, raw, description: String
        let risk: Int
        let slots: [Slot]
        let cases: [Case]
    }

    struct File: Decodable {
        struct Source: Decodable { let gam_version: String }
        let source: Source
        let commands: [Curated]
    }

    static let file = try! JSONDecoder().decode(File.self, from: Data(contentsOf: Fixtures.directory.appending(path: "catalog_curated.json")))
    /// Raised to ChangeCore's floor for their write here (`BuilderChangesTests` holds the floor).
    static let raised: Set = ["build.reset_password", "build.delete_alias"]

    /// Compared as bytes: `String ==` would take "é" and "e" + U+0301 as the same argument.
    static func bytes(_ argv: [String]) -> [[UInt8]] { argv.map { Array($0.utf8) } }

    static func command(_ id: String) throws -> CuratedCommand {
        try #require(CuratedCommand.all.first { $0.id == id })
    }

    /// GamGUI's commands in its order, each here or run from another screen, said why; and no other.
    @Test func theCommandsAreGamGUIs() {
        #expect(Self.file.source.gam_version == GamVersion.expected)
        let gamgui = Self.file.commands.map(\.id)
        #expect(gamgui.count == 26)
        #expect(CuratedCommand.all.map(\.id) == gamgui.filter { CuratedCommand.elsewhere[$0] == nil })
        #expect(Set(CuratedCommand.elsewhere.keys) == ["build.set_signature", "build.delete_user"])
        #expect(Set(CuratedCommand.elsewhere.keys).isSubset(of: Set(gamgui)))
    }

    /// Each with GamGUI's name, place, line, words, risk and fields, and the argv GamGUI's builder makes from each case's values:
    /// every field filled (once per choice), and only the required ones.
    @Test func eachIsGamGUIs() throws {
        for expected in Self.file.commands where CuratedCommand.elsewhere[expected.id] == nil {
            let command = try Self.command(expected.id)
            #expect([command.category, command.subcategory, command.name, command.syntax, command.description]
                    == [expected.category, expected.subcategory, expected.name, expected.raw, expected.description], "\(expected.id)")
            #expect(command.risk.rawValue == expected.risk || (Self.raised.contains(expected.id) && command.risk == .destructive),
                    "\(expected.id)")
            #expect(command.fields.map { [$0.key, $0.label, $0.kind.rawValue, String($0.required), $0.defaultValue, $0.placeholder, $0.hintNote] }
                    == expected.slots.map { [$0.key, $0.label, $0.kind, String($0.required), $0.default, $0.placeholder, $0.hintNote] },
                    "\(expected.id)")
            #expect(command.fields.map(\.choices) == expected.slots.map(\.choices), "\(expected.id)")
            #expect(command.fields.map(\.hints) == expected.slots.map(\.hints), "\(expected.id)")
            #expect(!expected.cases.isEmpty)
            for test in expected.cases {
                if let why = test.values.lazy.compactMap({ CuratedCommand.notYet[expected.id]?[$0.key]?[$0.value] }).first {
                    #expect(throws: GamCommands.Invalid.argument(why)) { try command.built(test.values) }
                    continue
                }
                switch try command.built(test.values) {
                case .read(let read):
                    #expect(expected.risk == 0 && Self.bytes(read.argv) == Self.bytes(test.argv), "\(expected.id) \(test.values)")
                case .write(let write):
                    #expect(expected.risk > 0 && Self.bytes(write.argv) == Self.bytes(test.argv), "\(expected.id) \(test.values)")
                }
            }
        }
    }

    /// Values are trimmed as Python's `strip()` trims, and a choice left empty is its default.
    @Test func valuesAreTheFormsAsLeft() throws {
        let forward = try Self.command("build.set_forward")
        guard case .write(let write) = try forward.built(["email": "  carol@example.com\n", "address": "\tdan@example.com ", "action": ""])
        else { Issue.record("a write"); return }
        #expect(write.argv == ["user", "carol@example.com", "forward", "on", "keep", "dan@example.com"])
    }

    /// A required field left empty, an address field holding anything but one address, and a choice GamGUI doesn't list are
    /// refused, in words, before anything is built.
    @Test func theFormIsChecked() throws {
        let add = try Self.command("build.add_group_member")
        func refusal(_ values: [String: String]) -> String? {
            do { _ = try add.built(values); return nil } catch { if case .argument(let why) = error { return why }; return nil }
        }
        #expect(refusal(["group": "sales@example.com", "member": "  "]) == "Fill in Member")
        #expect(refusal(["group": "sales@example.com", "member": "Carol Clark"])?.hasPrefix("“Carol Clark” isn't one plain email address") == true)
        for many in ["carol@example.com, dan@example.com", "carol@example.com dan@example.com", "oauthuser", "carol@example",
                     "uid:carol@example.com", "ID:carol@example.com", "<carol@example.com>", "Carol <carol@example.com>", "uid:123"] {
            #expect(refusal(["group": "sales@example.com", "member": many]) != nil, "\(many)")
        }
        #expect(refusal(["group": "sales@example.com", "member": "carol@example.com", "role": "admin"])
                == "Role can't be “admin”: pick one of member, manager, owner")
        #expect(refusal(["group": "sales@example.com", "member": "carol@example.com", "role": "owner"]) == nil)
        // Text is any text, one argv element: a query may hold spaces, quotes and a keyword.
        let find = try Self.command("build.find_users")
        guard case .read(let read) = try find.built(["query": "orgUnitPath='/Sales/Field Reps' todrive"]) else {
            Issue.record("a read"); return
        }
        #expect(read.argv.contains("orgUnitPath='/Sales/Field Reps' todrive"))
    }

    /// An undeleted account may be named by its unique ID (GAM's remedy when deleted accounts share an address), and only there.
    @Test func anUndeleteTakesAUniqueID() throws {
        let undelete = try Self.command("build.undelete_user")
        guard case .write(let write) = try undelete.built(["email": "uid:112233445566778899000"]) else { Issue.record("a write"); return }
        #expect(write.argv == ["undelete", "user", "uid:112233445566778899000"])
        for wrong in ["uid:", "uid:12a", "id:1122", "UID:1122", "uid: 1122", "uid:1122,3344"] {
            #expect(throws: GamCommands.Invalid.self, "\(wrong)") { try undelete.built(["email": wrong]) }
        }
        #expect(throws: GamCommands.Invalid.self) { try Self.command("build.suspend_user").built(["email": "uid:1122"]) }
    }

    /// A search shows no message bodies until a read can be audited: GamGUI's choice is listed, and refused in words.
    @Test func aSearchShowsNoBodiesYet() throws {
        let search = try Self.command("build.search_messages")
        #expect(search.fields.first { $0.key == "detail" }?.choices.contains("Headers + body") == true)
        #expect(throws: GamCommands.Invalid.self) {
            try search.built(["email": "carol@example.com", "query": "from:x", "detail": "Headers + body"])
        }
        _ = try search.built(["email": "carol@example.com", "query": "from:x", "detail": "Summary"])
    }

    /// Whom the change is for: GamGUI's first person or group given, else the first address, else "(command)".
    @Test func theTargetIsWhomItsFor() throws {
        let values = ["email": "new@example.com", "group": "sales@example.com", "member": "carol@example.com", "alias": "c@example.com",
                      "old_owner": "leaver@example.com", "new_owner": "boss@example.com"]
        #expect(try Self.command("build.add_group_member").target(values) == "sales@example.com")
        #expect(try Self.command("build.create_alias").target(values) == "new@example.com")
        #expect(try Self.command("build.create_group").target(values) == "new@example.com")
        #expect(try Self.command("build.undelete_user").target(values) == "new@example.com")
        #expect(try Self.command("build.delete_alias").target(values) == "c@example.com")
        #expect(try Self.command("build.transfer_data").target(values) == "leaver@example.com")
        #expect(try Self.command("build.find_users").target(values) == "(command)")
    }
}
