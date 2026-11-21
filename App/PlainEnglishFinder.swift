import Assist
import Directory
import GamEngine
import SwiftUI

/// A command found from the operator's own words (plan F5b): which command, and its fields' values. The Builder fills its
/// fields with them, shows the exact command, and runs a read only on the operator's Run, a curated change only after its
/// preview and confirm (invariant 10). It holds words only, never a command; only the Ask sheet makes one.
struct FinderDraft: Equatable, Identifiable {
    let id = UUID()
    let command: String
    let values: [String: String]
}

/// Ask in Plain English (plan F5b): Apple's on-device model narrows GAM's commands to one in small picks from lists made here
/// and copies the operator's words into its fields; code checks each value against the cached directory (`CommandFinder`).
/// The model reads only the sentence typed here. What it finds is shown with what code left empty and why, and opens in the
/// Builder only on the operator's word: nothing runs from this sheet.
struct PlainEnglishSheet: View {
    let catalog: CommandCatalog
    let directory: DirectoryStore
    let groups: GroupStore
    let open: (FinderDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appearsActive) private var appearsActive
    @State private var sentence = ""
    @State private var phase = Phase.idle

    enum Phase {
        case idle, finding
        case found(asked: String, CommandFinder.Finding)
        case failed(String)
    }

    /// The commands the finder picks from: the Builder's runnable reads and GamGUI's curated commands, as plain words.
    /// `AssistTests/FinderSamples.swift` (`FinderMenu.commands`) makes the same field copy for the measured samples: change both.
    static func menu(_ catalog: CommandCatalog) -> CommandFinder.Menu {
        CommandFinder.Menu(CuratedCommand.all.map { command in
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

    /// The cached directory as far as it's read, for code's checks only: the model never reads it.
    @MainActor static func known(_ directory: DirectoryStore, _ groups: GroupStore) -> CommandFinder.Directory {
        CommandFinder.Directory(
            people: directory.users?.map { user in
                .init(address: user.primaryEmail,
                      names: user.aliases + user.nonEditableAliases + [user.fullName, user.givenName, user.familyName].filter { !$0.isEmpty })
            },
            groups: groups.groups?.map { group in .init(address: group.email, names: group.name.isEmpty ? [] : [group.name]) })
    }

    private var busy: Bool { if case .finding = phase { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("What to see or change", text: $sentence, prompt: Text("Who has delegate access to Carol's mailbox?"), axis: .vertical)
                        .lineLimit(1...4)
                        .onSubmit(find)
                        .disabled(busy)
                    Text("Apple's on-device model picks one of the Builder's commands and copies your words into its fields; names are "
                         + "checked against the directory. Nothing runs from here: the Builder opens with the command filled in, and "
                         + "you run it, or preview and confirm a change, there.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let unavailable = CommandFinder.unavailable {
                        Label(unavailable, systemImage: "sparkles").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Ask in Plain English").accessibilityAddTraits(.isHeader)
                }
                result
            }
            .formStyle(.grouped)
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Finding a command…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Find", action: find)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || CommandFinder.unavailable != nil)
                    .accessibilityHint("Asks the on-device model for a command. Nothing runs.")
            }
            .padding()
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 320)
    }

    @ViewBuilder private var result: some View {
        switch phase {
        case .idle, .finding:
            EmptyView()
        case .failed(let why):
            Section {
                Label(why, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).textSelection(.enabled)
            }
        case .found(let asked, let finding):
            if let chosen = finding.chosen, let alternative = finding.alternative {
                Section {
                    Text("The model wasn't sure which of these you meant.")
                    Button("Open \u{201C}\(chosen.label)\u{201D}") { open(finding, asked: asked) }
                    Button("Open \u{201C}\(alternative.label)\u{201D}") { openOther(alternative, asked: asked) }
                } header: {
                    Text("Which One?").accessibilityAddTraits(.isHeader)
                }
            } else if let chosen = finding.chosen {
                Section {
                    LabeledContent("Command", value: chosen.label)
                    ForEach(finding.notes, id: \.self) { note in
                        Label("\(note.slot): \(note.text)", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    }
                    Button("Open in Builder") { open(finding, asked: asked) }
                        .accessibilityHint("Fills the command's fields in the Builder. Nothing runs until you run it there.")
                } header: {
                    Text("Found").accessibilityAddTraits(.isHeader)
                }
            } else {
                Section {
                    Label(finding.picks.first == CommandFinder.Intent.change.rawValue
                          ? "None of the Builder's changes fits. The Builder changes only GamGUI's curated commands; the rest have their own screens."
                          : "No command the Builder runs fits. Try other words, or search the Builder.", systemImage: "questionmark.circle")
                }
            }
        }
    }

    private func find() {
        let asked = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !busy, CommandFinder.unavailable == nil else { return }
        phase = .finding
        let menu = Self.menu(catalog), known = Self.known(directory, groups)
        Task {
            do {
                let finding = try await CommandFinder.find(asked, in: menu, directory: known, using: CommandFinder.OnDevice())
                phase = .found(asked: asked, finding)
                if appearsActive {
                    let said = finding.alternative != nil ? "Two commands might fit: pick one."
                        : finding.chosen.map { "Found: \($0.label)" } ?? "No command fits."
                    AccessibilityNotification.Announcement(said).post()
                }
            } catch {
                phase = .failed("No command was found: " + OnDeviceModel.failure(error))
                if appearsActive { AccessibilityNotification.Announcement("No command was found.").post() }
            }
        }
    }

    private func open(_ finding: CommandFinder.Finding, asked: String) {
        guard let command = finding.command else { return }
        open(FinderDraft(command: command, values: finding.values))
        dismiss()
    }

    /// The other command a sample picked: its fields filled from the same words, then opened.
    private func openOther(_ option: CommandFinder.Option, asked: String) {
        phase = .finding
        let known = Self.known(directory, groups)
        Task {
            do {
                let filled = try await CommandFinder.fill(asked, option, directory: known, using: CommandFinder.OnDevice())
                open(FinderDraft(command: filled.command, values: filled.values))
                dismiss()
            } catch {
                phase = .failed("Its fields weren't filled: " + OnDeviceModel.failure(error))
            }
        }
    }
}
