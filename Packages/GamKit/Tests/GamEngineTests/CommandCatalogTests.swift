import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The Builder's catalog (invariants 1, 3 and 11): GAM's vendored catalog loaded, every command GamGUI's generic read builder
/// makes runnable made runnable here with the same slots and the same argv (`Tests/Fixtures/catalog_reads.json`, generated
/// from frozen GamGUI by `scripts/gen_catalog_reads.py`), nothing else, and no catalog edit able to make a write runnable.
@Suite("Command catalog")
struct CommandCatalogTests {
    static let catalog = try! CommandCatalog(json: Data(contentsOf: Fixtures.repoRoot.appending(path: "Vendor/gam7/command_catalog.json")))

    struct Read: Decodable {
        struct Slot: Decodable { let key, label, kind, placeholder: String; let required: Bool }
        let id: String
        let slots: [Slot]
        let argv: [String]
        let argvRequired: [String]
        let sensitive: Bool
    }

    struct Reads: Decodable {
        struct Source: Decodable { let gam_version: String }
        let source: Source
        let reads: [Read]
    }

    /// Secrets GAM added after GamGUI froze, browse-only here though GamGUI's list would run them (GAM 7.49.00).
    static let sensitiveHereOnly: Set = ["gam info browsertoken <TokenPermanentID>"]

    static let reads = try! JSONDecoder().decode(Reads.self, from: Data(contentsOf: Fixtures.directory.appending(path: "catalog_reads.json")))

    /// The verb rule here is GamGUI's: the fixture carries GamGUI's own sets.
    @Test func theVerbRuleIsGamGUIs() {
        #expect(CommandCatalog.readVerbs == CommandKindTests.verbSets.read)
        #expect(CommandCatalog.destructiveVerbs == CommandKindTests.verbSets.destructive)
        #expect(CommandCatalog.lowVerbs == CommandKindTests.verbSets.low)
    }

    /// Every command GamGUI promotes is promoted here, and no other; each with GamGUI's slots, argv (every slot filled, and only
    /// the required ones) and sensitivity. Made from this catalog, for this GAM.
    @Test func everyReadIsGamGUIs() throws {
        #expect(Self.reads.source.gam_version == Self.catalog.version && Self.catalog.version == GamVersion.expected)
        let promoted = Self.catalog.commands.filter(\.promoted)
        #expect(Set(promoted.map(\.id)) == Set(Self.reads.reads.map(\.id)))
        #expect(promoted.count == 515 && promoted.filter(\.sensitive).count == 14 && Self.catalog.commands.count == 1_052)
        let byID = Dictionary(uniqueKeysWithValues: promoted.map { ($0.id, $0) })
        for read in Self.reads.reads {
            let command = try #require(byID[read.id])
            #expect(command.slots.map { [$0.key, $0.label, $0.kind.rawValue, $0.placeholder, String($0.required)] }
                    == read.slots.map { [$0.key, $0.label, $0.kind, $0.placeholder, String($0.required)] }, "\(read.id) \(command.syntax)")
            #expect(command.sensitive == (read.sensitive || Self.sensitiveHereOnly.contains(command.syntax)), "\(read.id)")
            guard command.runnable else { continue }
            let every = Dictionary(uniqueKeysWithValues: command.slots.map { ($0.key, "<\($0.key)>") })
            let required = Dictionary(uniqueKeysWithValues: command.slots.filter(\.required).map { ($0.key, "<\($0.key)>") })
            #expect(try GamCommands.catalogRead(command, values: every).argv == read.argv, "\(read.id) \(command.syntax)")
            #expect(try GamCommands.catalogRead(command, values: required).argv == read.argvRequired, "\(read.id)")
        }
    }

    /// Every runnable command's argv is a read by the rule every typed read is held to (`CommandKindTests`): the first known verb
    /// is a read verb, from the grammar's own words, never a value's.
    @Test func everyRunnableCommandOnlyReads() throws {
        for command in Self.catalog.commands where command.runnable {
            let values = Dictionary(uniqueKeysWithValues: command.slots.map { ($0.key, "<\($0.key)>") })
            let argv = try GamCommands.catalogRead(command, values: values).argv
            #expect(CommandKindTests.verb(argv).map(CommandKindTests.readVerbs.contains) == true, "\(command.id): \(argv)")
        }
    }

    /// The door refuses what isn't runnable: a write, an uncertain command, a sensitive read; and a required value left empty.
    /// A value is one argv element however it's written.
    @Test func theDoorRunsOnlyReads() throws {
        func command(_ prefix: String) throws -> CommandCatalog.Command {
            try #require(Self.catalog.commands.first { $0.syntax.hasPrefix(prefix) })
        }
        let delete = try command("gam delete user")
        #expect(!delete.runnable && delete.risk == .destructive)
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.catalogRead(delete, values: [:]) }
        let codes = try #require(Self.catalog.commands.first { $0.syntax.contains("show backupcodes") })
        #expect(codes.promoted && codes.sensitive && !codes.runnable)
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.catalogRead(codes, values: ["a0": "pat@example.com"]) }
        #expect(!Self.catalog.commands.contains { $0.uncertain && $0.runnable })

        let info = try #require(Self.catalog.commands.first { $0.syntax == "gam info user [<UserItem>] [quick]" || $0.syntax.hasPrefix("gam info user ") })
        #expect(info.runnable)
        let user = try #require(Self.catalog.commands.first { $0.runnable && $0.slots.first?.kind == .targetUser && $0.slots.first?.required == true })
        #expect(throws: GamCommands.Invalid.argument("Fill in User")) { try GamCommands.catalogRead(user, values: ["a0": "  "]) }
        let argv = try GamCommands.catalogRead(user, values: ["a0": " pat@example.com todrive delete "]).argv
        #expect(argv.contains("pat@example.com todrive delete") && argv.filter { $0 == "delete" }.isEmpty, "trimmed, and one element")
    }

    /// An edited catalog can't make a write runnable: the verb rule is checked again here, whatever the file says.
    @Test func anEditedCatalogPromotesNoWrite() throws {
        let edited = """
            {"version": "x", "commands": [
              {"id": "w1", "category": "Users", "raw_syntax": "gam delete user <UserItem>", "verb": "print", "risk": 0, "uncertain": false},
              {"id": "w2", "category": "Users", "raw_syntax": "gam <UserTypeEntity> update photo <FileName>", "verb": "print", "risk": 0},
              {"id": "w3", "category": "Users", "raw_syntax": "gam frobnicate users", "verb": "frobnicate", "risk": 0},
              {"id": "w4", "category": "Users", "raw_syntax": "gam PRINT update user <UserItem> suspended on", "verb": "print", "risk": 0},
              {"id": "w5", "category": "Users", "raw_syntax": "gam update|print user <UserItem> suspended on", "verb": "print", "risk": 0},
              {"id": "w6", "category": "Users", "raw_syntax": "gam x)|print update user <UserItem> suspended on", "verb": "print", "risk": 0},
              {"id": "w7", "category": "Users", "raw_syntax": "gam <UserTypeEntity> get drivefile <DriveFileEntity>", "verb": "x", "risk": 0},
              {"id": "w8", "category": "Users", "raw_syntax": "gam print users To_Drive", "verb": "print", "risk": 0},
              {"id": "w9", "category": "Users", "raw_syntax": "gam print users todrive", "verb": "print", "risk": 0},
              {"id": "r1", "category": "Users", "raw_syntax": "gam print users [query <QueryUser>]", "verb": "print", "risk": 0}
            ]}
            """
        // Review 2026-10-28: the argv's own keywords are judged, not only the grammar's words (the template keeps a first
        // alternative and passes over fragments), and a download is known by the grammar line, never the file's `verb`.
        let catalog = try CommandCatalog(json: Data(edited.utf8))
        #expect(catalog.commands.filter(\.runnable).map(\.id) == ["w8", "r1"])
        let mixedCase = try #require(catalog.commands.first { $0.id == "w8" })
        #expect(try GamCommands.catalogRead(mixedCase, values: [:]).argv == ["print", "users"], "a word the template doesn't emit isn't sent")
        #expect(catalog.commands.first { $0.id == "w7" }?.sensitive == true)
        #expect(try GamCommands.catalogRead(catalog.commands.last!, values: [:]).argv == ["print", "users"], "an optional group is dropped")
    }

    /// A value is never GAM's `todrive` or `doit`, however written: a read whose required field sits where GAM reads options
    /// (`print events <EventDisplayProperty>*`) would otherwise upload its result to the admin's Drive (review 2026-10-28). A value
    /// is trimmed as Python trims, the separator characters too.
    @Test func aValueIsNeverAKeywordThatWrites() throws {
        let events = try #require(Self.catalog.commands.first { $0.runnable && $0.syntax.contains("print events") && $0.slots.contains { $0.placeholder == "<EventDisplayProperty>" } })
        let property = try #require(events.slots.first { $0.placeholder == "<EventDisplayProperty>" })
        var values = Dictionary(uniqueKeysWithValues: events.slots.map { ($0.key, "c@example.com") })
        for keyword in ["todrive", " ToDrive ", "to_drive", "DOIT", "do_it"] {
            values[property.key] = keyword
            #expect(throws: GamCommands.Invalid.self, "\(keyword)") { try GamCommands.catalogRead(events, values: values) }
        }
        values[property.key] = "alwaysincludeemail"
        #expect(try GamCommands.catalogRead(events, values: values).argv.contains("alwaysincludeemail"))
        let user = try #require(Self.catalog.commands.first { $0.runnable && $0.slots.first?.kind == .targetUser && $0.slots.first?.required == true })
        #expect(try GamCommands.catalogRead(user, values: ["a0": "\u{1F}bob@example.com\u{1C}"]).argv.contains("bob@example.com"))
    }

    /// The list: every command in an area, a category listed nowhere in Other (a Chrome one in Devices), and a search over name
    /// and grammar line, runnable first in each section.
    @Test func theListIsGroupedAndSearched() {
        #expect(Self.catalog.commands.allSatisfy { CommandCatalog.areas.contains($0.area) })
        #expect(CommandCatalog.area(of: "Chrome Browser Cloud Management") == "Devices" && CommandCatalog.area(of: "Nothing") == "Other")
        let found = Self.catalog.search("PRINT USERS")
        #expect(!found.isEmpty && found.allSatisfy { $0.name.lowercased().contains("print users") || $0.syntax.lowercased().contains("print users") })
        #expect(Self.catalog.search("").count == Self.catalog.commands.count)
        for (a, b) in zip(found, found.dropFirst()) where a.category == b.category && a.subcategory == b.subcategory {
            #expect(a.runnable || !b.runnable, "runnable first in a section")
        }
    }
}
