import AppIntents

/// "Change a title in GamGUI": Siri asks whose and what, then opens the app with the change drafted on
/// Users. It only drafts (invariant 10): the operator checks the preview and clicks Save. This file hands
/// the words to `SiriDrafts` and nothing else; `WriteRouteTests` keeps it away from every write.
struct ChangeTitleIntent: AppIntent {
    static let title: LocalizedStringResource = "Change a Title"
    static let description = IntentDescription(
        "Opens GamGUI with a person's new title, and department if you give one, drafted for you to check. Nothing changes until you click Save.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Person", requestValueDialog: "Whose title?")
    var person: String

    @Parameter(title: "Title", requestValueDialog: "What's the new title?")
    var title: String

    @Parameter(title: "Department")
    var department: String?

    @Dependency private var drafts: SiriDrafts

    static var parameterSummary: some ParameterSummary {
        Summary("Change \(\.$person)'s title to \(\.$title)") {
            \.$department
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // A blank value from Shortcuts would draft an erase: ask again, or keep the department.
        let person = person.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !person.isEmpty else { throw $person.needsValueError("Whose title?") }
        guard !title.isEmpty else { throw $title.needsValueError("What's the new title?") }
        let department = department?.trimmingCharacters(in: .whitespacesAndNewlines)
        drafts.titleChange = SiriDrafts.TitleChange(person: person, title: title,
                                                    department: department?.isEmpty == false ? department : nil)
        return .result(dialog: "Opening GamGUI with the change for you to check.")
    }
}

/// The phrases Siri listens for. Each names the app, as Siri requires.
struct GamGUIShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ChangeTitleIntent(), phrases: [
            "Change a title in \(.applicationName)",
            "Change someone's title in \(.applicationName)",
            "Update a job title in \(.applicationName)",
        ], shortTitle: "Change a Title", systemImageName: "person.text.rectangle")
    }
}

/// How the app gives the intents what they reach: Siri's drafts, and nothing that can write.
enum SiriIntents {
    @MainActor
    static func register(_ drafts: SiriDrafts) {
        AppDependencyManager.shared.add(dependency: drafts)
    }
}
