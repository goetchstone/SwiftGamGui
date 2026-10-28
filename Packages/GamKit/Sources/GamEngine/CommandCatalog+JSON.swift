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

    /// Commands whose name or grammar line holds `text`, case aside, by section (GamGUI's `Catalog.search`); every command for none.
    public func search(_ text: String) -> [Command] {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.bySection(wanted.isEmpty ? commands : commands.filter {
            $0.name.lowercased().contains(wanted) || $0.syntax.lowercased().contains(wanted)
        })
    }

    /// Sorted so a category and subcategory are together, runnable first in each (GamGUI's `_by_section`).
    static func bySection(_ commands: [Command]) -> [Command] {
        commands.sorted {
            ($0.category.lowercased(), $0.subcategory.lowercased(), $0.runnable ? 0 : 1, $0.name.lowercased())
                < ($1.category.lowercased(), $1.subcategory.lowercased(), $1.runnable ? 0 : 1, $1.name.lowercased())
        }
    }
}
