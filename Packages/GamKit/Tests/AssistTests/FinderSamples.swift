import Foundation
import GamEngine
import TestSupport
@testable import Assist

/// What the finder's tests and evals pick from: the Builder's commands as the app hands them over (`App/PlainEnglishFinder.swift`
/// makes the same field copy: change both), the vendored catalog's runnable reads and GamGUI's curated commands.
enum FinderMenu {
    static let catalog: CommandCatalog = try! CommandCatalog(json: Data(contentsOf: Fixtures.catalogJSON))

    static func commands(_ catalog: CommandCatalog) -> [CommandFinder.Command] {
        CuratedCommand.all.map { command in
            CommandFinder.Command(id: command.id, category: command.category, subcategory: command.subcategory, words: command.name, curated: true,
                                  changes: !command.reads, slots: command.fields.map {
                                      .init(key: $0.key, label: $0.label, gamKind: $0.kind.rawValue, required: $0.required, choices: $0.choices,
                                            hint: $0.placeholder)
                                  })
        } + catalog.commands.filter(\.runnable).map { command in
            CommandFinder.Command(id: command.id, category: command.category, subcategory: command.subcategory, words: command.gloss, curated: false,
                                  changes: false, slots: command.slots.map {
                                      .init(key: $0.key, label: $0.label, gamKind: $0.kind.rawValue, required: $0.required, hint: $0.placeholder)
                                  })
        }
    }

    static let menu = CommandFinder.Menu(commands(catalog))

    /// The directory the samples name: the strict mock's people and groups (`Tests/Fixtures/mock_gam`), and Erin.
    static let directory = CommandFinder.Directory(
        people: [
            .init(address: "admin@example.com", names: ["IT Admin", "IT", "Admin"]),
            .init(address: "alice@example.com", names: ["a.anders@example.com", "Alice Anders", "Alice", "Anders"]),
            .init(address: "bob@example.com", names: ["Bob Brown", "Bob", "Brown"]),
            .init(address: "carol@example.com", names: ["Carol Clark", "Carol", "Clark"]),
            .init(address: "dana@example.com", names: ["Dana \"DJ\" Zoë 😀", "Dana \"DJ\"", "Zoë 😀"]),
            .init(address: "erin@example.com", names: ["Erin Evans", "Erin", "Evans"]),
        ],
        groups: [
            .init(address: "allhands@example.com", names: ["All Hands"]),
            .init(address: "empty-group@example.com", names: ["Empty Group"]),
            .init(address: "it@example.com", names: ["IT"]),
            .init(address: "sales@example.com", names: ["Sales"]),
            .init(address: "staff@example.com", names: ["Staff"]),
            .init(address: "team@example.com", names: ["Team"]),
        ])
}

/// One request, as the operator might type it, and what it asks for. The same shape holds the finder's answer.
struct FinderCase: Codable, Sendable {
    var id: String
    /// The operator's kind of request: user lookup, group membership, licenses, signatures, offboarding, devices, shared drives.
    var kind: String
    /// Apple's kinds of sample: golden (plain words), edge (odd phrasing, a slot the words can't fill), adversarial (nothing
    /// listed fits, or a person the directory doesn't hold).
    var category: String
    var input: String
    /// The commands that do what it asks (alike ones all listed); empty when nothing the Builder runs fits.
    var accept: [String]
    /// Each slot's right value, by label; a slot not named must be left empty unless `allow` names it.
    var values: [String: String]
    /// A slot that may be filled: with one of these values, or any copied words ("*").
    var allow: [String: [String]]?
    var note: String?

    // The answer.
    var found: String?
    /// The commands of the other choice a sample picked, when the samples split.
    var alternative: [String]?
    var filled: [String: String]?
    var notes: [String]?
    var picks: [String]?
    var seconds: Double?

    static func load(_ split: String) -> [FinderCase] {
        let url = Fixtures.directory.appending(path: "finder/\(split).json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FinderCase].self, from: data)) ?? []
    }

    /// Whether `id` (nil for none) is a right command.
    func rightly(_ id: String?) -> Bool { id.map(accept.contains) ?? accept.isEmpty }

    /// Whether `filled` (by label) is right: every value named, nothing else but what `allow` lets through.
    func rightSlots(_ filled: [String: String]) -> Bool {
        for (label, value) in values where filled[label]?.lowercased() != value.lowercased() { return false }
        for (label, value) in filled where values[label] == nil {
            guard let allowed = allow?[label], allowed.contains("*") || allowed.contains(value) else { return false }
        }
        return true
    }

    /// The filled values no check could stand behind: neither the request's own words nor the address of someone or a group the
    /// request names (by address, the address's name, or a name the directory knows them by).
    func invented(_ filled: [String: String], directory: CommandFinder.Directory = FinderMenu.directory) -> [String] {
        let request = input.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let known = (directory.people ?? []) + (directory.groups ?? [])
        return filled.values.filter { value in
            if request.contains(value.lowercased()) { return false }
            return !known.contains { entry in
                entry.address == value.lowercased() && ([String(entry.address.split(separator: "@")[0])] + entry.names).contains {
                    request.contains($0.lowercased())
                }
            }
        }
    }
}

/// The Builder's own search, as `BuilderView.rows` lists it with Runnable Only on (the default) and every area: GamGUI's curated
/// commands and the catalog's runnable ones that `CommandCatalog.Search` finds, by section, runnable first in each. The ids in
/// that order.
enum BuilderSearch {
    static func ids(_ query: String, catalog: CommandCatalog = FinderMenu.catalog) -> [String] {
        let search = CommandCatalog.Search(query)
        let curated = CuratedCommand.all.filter { search.isEmpty || search.finds(name: $0.name, syntax: $0.syntax, does: $0.description) }
            .map { (id: $0.id, category: $0.category, subcategory: $0.subcategory, runnable: true, name: $0.name) }
        let listed = catalog.search(query).filter(\.runnable)
            .map { (id: $0.id, category: $0.category, subcategory: $0.subcategory, runnable: $0.runnable, name: $0.name) }
        return (curated + listed).sorted {
            ($0.category.lowercased(), $0.subcategory.lowercased(), $0.runnable ? 0 : 1, $0.name.lowercased())
                < ($1.category.lowercased(), $1.subcategory.lowercased(), $1.runnable ? 0 : 1, $1.name.lowercased())
        }.map(\.id)
    }

    /// A fairer search than the Builder's for a whole sentence, to see what the model adds over words alone: each command
    /// ranked by how many of the request's words (three letters or more, not a common function word) its name or plain words
    /// hold, ties in the Builder's order. Not in the app.
    static func ranked(_ query: String, catalog: CommandCatalog = FinderMenu.catalog) -> [String] {
        let common: Set = ["the", "and", "for", "with", "all", "our", "are", "any", "has", "have", "does", "did", "who", "what", "which",
                           "how", "can", "his", "her", "its", "their", "from", "into", "that", "this", "there", "you", "your", "was", "were",
                           "need", "see", "whats", "who's", "what's"]
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").split { !$0.isLetter && $0 != "'" }
                .map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : String($0) }.filter { $0.count >= 3 && !common.contains($0) })
        }
        let asked = words(query)
        let curated = CuratedCommand.all.map { (id: $0.id, words: words($0.name + " " + $0.description)) }
        let listed = catalog.commands.filter(\.runnable).map { (id: $0.id, words: words($0.name + " " + $0.gloss)) }
        let order = Dictionary(uniqueKeysWithValues: ids("", catalog: catalog).enumerated().map { ($1, $0) })
        let scored: [(id: String, score: Int, at: Int)] = (curated + listed).map { entry in
            (entry.id, asked.intersection(entry.words).count, order[entry.id] ?? 0)
        }
        return scored.filter { $0.score > 0 }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.at < $1.at }.map(\.id)
    }
}
