import Foundation

/// Loading the vendored catalog and searching it: Foundation's, so outside the platform-free sources `scripts/fuzz.sh` compiles.
extension CommandCatalog {
    /// The catalog in `data` (the vendored JSON). Throws when it isn't one.
    public init(json data: Data) throws {
        struct Entry: Decodable {
            let id: String
            let category: String?
            let subcategory: String?
            let name: String?
            let raw_syntax: String?
            let verb: String?
            let risk: Int?
            let uncertain: Bool?
        }
        struct File: Decodable {
            let version: String?
            let commands: [Entry]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        self.init(version: file.version ?? "", entries: file.commands.map {
            CommandCatalog.Entry(id: $0.id, category: $0.category ?? "Other", subcategory: $0.subcategory ?? "", name: $0.name ?? "",
                                 syntax: $0.raw_syntax ?? "", verb: $0.verb ?? "", risk: $0.risk ?? 1, uncertain: $0.uncertain ?? false)
        })
    }

    /// The commands `text` finds (`Search`), by section; every command for none.
    public func search(_ text: String) -> [Command] {
        let search = Search(text)
        return Self.bySection(search.isEmpty ? commands : commands.filter { search.finds(name: $0.name, syntax: $0.syntax, does: $0.gloss) })
    }

    /// What the Builder's search looks for: the text as typed, trimmed and case aside, and its words. It finds what GamGUI's
    /// `Catalog.search` finds (the text in the name or the grammar line), and a command whose words for what it does hold every
    /// word of it (plan F5a): "backup codes" finds `print backupcodes` ("List a user's backup verification codes."). Each word
    /// alone, never across the grammar line, so a grammar search stays as narrow as GamGUI's ("info user" isn't every `info`
    /// that names a user).
    public struct Search: Sendable {
        let text: String
        let words: [Substring]

        public init(_ typed: String) {
            text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            words = text.split(whereSeparator: \.isWhitespace)
        }

        /// Nothing to look for: every command is listed.
        public var isEmpty: Bool { text.isEmpty }

        /// A command with this name, grammar line and words for what it does (a catalog command's gloss, a curated one's
        /// description) is found.
        public func finds(name: String, syntax: String, does: String) -> Bool {
            if name.lowercased().contains(text) || syntax.lowercased().contains(text) { return true }
            let does = does.lowercased()
            return words.allSatisfy { does.contains($0) }
        }
    }

    /// Sorted so a category and subcategory are together, runnable first in each (GamGUI's `_by_section`).
    static func bySection(_ commands: [Command]) -> [Command] {
        commands.sorted {
            ($0.category.lowercased(), $0.subcategory.lowercased(), $0.runnable ? 0 : 1, $0.name.lowercased())
                < ($1.category.lowercased(), $1.subcategory.lowercased(), $1.runnable ? 0 : 1, $1.name.lowercased())
        }
    }
}
