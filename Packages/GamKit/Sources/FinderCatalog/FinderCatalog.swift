import Assist
import GamEngine

/// The commands Ask in Plain English picks from (plan F5b), made once for the app and the measured samples alike: the Builder's
/// runnable catalog reads (each by its gloss) and GamGUI's curated commands (each by its name), field for field. Assist can't
/// see GamEngine's types and GamEngine mustn't reach the model, so this small module joins the two and does nothing else: it
/// names no runner, write or read builder (`WriteRouteTests.theFinderReachesNoRunOrTicket`).
extension CommandFinder.Menu {
    public init(_ catalog: CommandCatalog) {
        self.init(CuratedCommand.all.map { command in
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
        })
    }
}
