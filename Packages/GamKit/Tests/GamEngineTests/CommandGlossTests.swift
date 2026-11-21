import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// What each catalog command does, in words (plan F5a, invariant 11): GamGUI's `gloss()` ported, every command's held byte for
/// byte to GamGUI's own run over this repo's catalog (`Tests/Fixtures/catalog_glosses.json`, made by
/// `scripts/gen_catalog_glosses.py` from a GamGUI clone pinned at its commit), the noun table to GamGUI's lookup, and the
/// Builder's search on them (this app's, no fixture).
@Suite("Command glosses")
struct CommandGlossTests {
    struct File: Decodable {
        struct Source: Decodable { let gam_version: String }
        struct Gloss: Decodable {
            let id: String
            let gloss: String
        }

        let source: Source
        let nouns: [String: String]
        let glosses: [Gloss]
    }

    static let file = try! JSONDecoder().decode(File.self, from: Data(contentsOf: Fixtures.directory.appending(path: "catalog_glosses.json")))

    /// Every command has GamGUI's gloss, byte for byte, in the catalog's order. Made from this catalog, for this GAM.
    @Test func everyGlossIsGamGUIs() {
        let catalog = CommandCatalogTests.catalog
        #expect(Self.file.source.gam_version == catalog.version && catalog.version == GamVersion.expected)
        #expect(Self.file.glosses.map(\.id) == catalog.commands.map(\.id) && catalog.commands.count == 1_052)
        for (command, wanted) in zip(catalog.commands, Self.file.glosses) {
            #expect(Array(command.gloss.utf8) == Array(wanted.gloss.utf8), "\(command.id) \(command.syntax)")
        }
        #expect(catalog.commands.allSatisfy { !$0.gloss.isEmpty })
    }

    /// The noun table is GamGUI's three merged as its `_humanize` reads them: the same nouns, each the same phrase, so a noun a
    /// GAM bump brings into use is already GamGUI's.
    @Test func theNounTableIsGamGUIs() {
        #expect(Set(CommandCatalog.glossNouns.keys.map { Array($0.utf8) }) == Set(Self.file.nouns.keys.map { Array($0.utf8) }))
        for (noun, phrase) in Self.file.nouns {
            #expect(Array(CommandCatalog.nounPhrase(noun).utf8) == Array(phrase.utf8), "\(noun)")
        }
    }

    /// Search finds what GamGUI's finds (the text in the name or the grammar line), and a command whose gloss holds every word
    /// typed, each anywhere in it; words are never matched across the grammar line, so a grammar search stays as narrow as
    /// GamGUI's.
    @Test func searchFindsWhatACommandDoes() throws {
        let catalog = CommandGlossTests.catalog
        func gamguis(_ text: String) -> Set<String> {
            Set(catalog.commands.filter { $0.name.lowercased().contains(text) || $0.syntax.lowercased().contains(text) }.map(\.id))
        }
        #expect(!gamguis("print users").isEmpty && Set(catalog.search("PRINT USERS").map(\.id)) == gamguis("print users"))
        #expect(Set(catalog.search("info user").map(\.id)) == gamguis("info user"), "not every info that names a user")
        // Plain words: GAM writes `backupcodes` and `cros`; the glosses say "backup verification codes" and "ChromeOS devices".
        let codes = catalog.search("  Backup  CODES ")
        #expect(gamguis("backup codes").isEmpty && !codes.isEmpty && codes.allSatisfy { $0.syntax.contains("backupcodes") })
        let printCros = try #require(catalog.commands.first { $0.syntax.hasPrefix("gam print cros ") })
        #expect(printCros.gloss == "List ChromeOS devices." && catalog.search("chrome devices").contains { $0.id == printCros.id })
        #expect(catalog.search("vault holds").contains { $0.syntax.hasPrefix("gam print vaultholds") })
        // A curated command is searched the same way, its description read as its gloss (the Builder's rows).
        let delegate = try #require(CuratedCommand.all.first { $0.id == "build.add_delegate" })
        func finds(_ text: String) -> Bool {
            CommandCatalog.Search(text).finds(name: delegate.name, syntax: delegate.syntax, does: delegate.description)
        }
        #expect(finds("MAILBOX delegate") && finds("add delegate") && finds("another person mailbox"))
        #expect(!finds("mail delegate") && !finds("another person calendar"))
    }

    static var catalog: CommandCatalog { CommandCatalogTests.catalog }

    /// `PythonText.capitalize` and `split` held to Python's own answers (3.14, Unicode 16.0, run 2026-11-21). The gloss
    /// fixture can't catch them: every catalog verb is ASCII, and `gloss` capitalizes its first scalar again (review
    /// 2026-11-21: six broken versions of the two passed it).
    @Test(arguments: [
        ("\u{01C6}emal", "\u{01C5}emal"),  // a digraph: titlecase, not uppercase
        ("\u{00DF}x", "Ssx"),               // ß expands
        ("\u{FB01}x", "Fix"),               // the fi ligature expands
        ("\u{0391}\u{03A3}", "\u{0391}\u{03C2}"),         // final sigma
        ("\u{03A3}\u{0391}\u{03A3}", "\u{03A3}\u{03B1}\u{03C2}"),
        ("hello WORLD", "Hello world"),     // the rest lowercased
        ("", ""),
    ])
    func capitalizeIsPythons(_ text: String, _ python: String) {
        #expect(Array(PythonText.capitalize(text).utf8) == Array(python.utf8))
    }

    @Test func splitIsPythons() {
        #expect(PythonText.split("a\u{1C}b\u{3000}c  d") == ["a", "b", "c", "d"])
        #expect(PythonText.split(" \u{85}x\u{2028}y\u{A0} ") == ["x", "y"])
        #expect(PythonText.split("") == [] && PythonText.split("   ") == [])
    }
}
