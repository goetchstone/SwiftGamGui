import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// What each catalog command does, in words (plan F5a, invariant 11): GamGUI's `gloss()` ported, every command's held byte for
/// byte to GamGUI's own run over this repo's catalog (`Tests/Fixtures/catalog_glosses.json`, made by
/// `scripts/gen_catalog_glosses.py` from a GamGUI clone pinned at its commit), and the noun table to GamGUI's lookup.
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
}
