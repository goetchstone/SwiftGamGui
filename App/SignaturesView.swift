import Directory
import GamEngine
import Setup
import Stores
import SwiftUI

/// Signatures: one person's Gmail signature from a template (GamGUI's designer, one person at a time).
/// The template is rendered for the chosen person as it's typed, beside the signature they have now;
/// "Review and Replace…" holds that render as a preview (`SignatureChanges`), and only the confirm sheet
/// runs it, exactly as held. Saved templates load into the editor; the editor saves as a template.
struct SignaturesView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: SignatureChanges
    let access: UserAccess
    let templates: SignatureTemplates
    /// A person another screen asked for (Users' "Change Signature…"), taken once.
    @Binding var requested: String?
    /// Kept per window while the app runs, so leaving the screen doesn't lose what was typed.
    @SceneStorage("signatures.template") private var template = ""
    @SceneStorage("signatures.person") private var personEmail = ""
    /// The template and person last drawn: a moment after the last keystroke, not on every one.
    @State private var drawn = (template: "", person: "")
    @State private var defaultApplied = false
    @State private var debugApplied = false
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let people = changes.activePeople
        let person = people.first { $0.primaryEmail == personEmail }
        VStack(spacing: 0) {
            SignatureResult(changes: changes)
            Form {
                PersonSection(setup: setup, directory: directory, people: people, personEmail: $personEmail)
                TemplateSection(template: $template, templates: templates)
                previewSection(person: person)
                SavedTemplatesSection(template: $template, templates: templates)
            }
            .formStyle(.grouped)
        }
        .toolbar {
            ToolbarItem {
                Button("Read Again", systemImage: "arrow.clockwise") {
                    Task { await access.load(personEmail) }
                }
                .keyboardShortcut("r")
                .disabled(person == nil || access.isReading(personEmail))
                .help("Read the person's current signature again")
                .accessibilityLabel("Read the current signature again")
            }
        }
        // The person's current signature, read when they're chosen and again after a change lands.
        .task(id: "\(person?.primaryEmail ?? "")#\(changes.finished)#\(setup.generation)") {
            guard let person else { return }
            await access.load(person.primaryEmail)
        }
        .task(id: "\(template)#\(personEmail)") {
            // Drawn a moment after typing stops, and at once for a new person.
            if drawn.person == personEmail, (try? await Task.sleep(for: .milliseconds(300))) == nil { return }
            drawn = (template, personEmail)
        }
        .onChange(of: changes.defaultPerson?.primaryEmail, initial: true) { _, admin in
            // The connected admin, once, when nobody is chosen; never whoever sorts first.
            guard !defaultApplied, personEmail.isEmpty, let admin else { return }
            defaultApplied = true
            personEmail = admin
        }
        .onChange(of: requested, initial: true) { _, email in
            guard let email else { return }
            personEmail = email
            requested = nil
        }
        // Another domain: its people aren't this one's.
        .onChange(of: setup.generation) {
            personEmail = ""
            defaultApplied = false
        }
        // After the directory loads: connecting (a new generation) clears the person first.
        .task(id: directory.users?.count ?? -1) { debugSelection() }
        .sheet(item: Binding(get: { changes.sheetPending }, set: { if $0 == nil { changes.dismissPreview() } })) { pending in
            SignaturePreviewSheet(pending: pending, changes: changes)
        }
        // Said once, from the window in front; never the signature itself.
        .onChange(of: changes.announcement) { _, text in
            if let text, appearsActive { AccessibilityNotification.Announcement(text).post() }
        }
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` chooses the person and `SWIFTGAMGUI_TEMPLATE` loads a saved
    /// template, for the snapshots, once the directory is loaded.
    private func debugSelection() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard directory.users != nil, !debugApplied else { return }
        debugApplied = true
        if let email = environment["SWIFTGAMGUI_SELECT"] {
            personEmail = email
            defaultApplied = true
        }
        if let name = environment["SWIFTGAMGUI_TEMPLATE"], let body = templates.body(name) { template = body }
        #endif
    }

    // MARK: the preview

    private func previewSection(person: GamUser?) -> some View {
        let drawnPerson = person.flatMap { $0.primaryEmail == drawn.person ? $0 : nil }
        let render = drawnPerson.map { Signature.render(drawn.template, for: $0) } ?? ""
        return Section("Preview") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current").font(.headline)
                    CurrentSignature(person: person, access: access)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("New").font(.headline)
                    if let drawnPerson, !drawn.template.isBlank {
                        // Rendered: what Gmail will hold (GAM's stored form). HTML: what GAM will be given.
                        SignaturePane(html: render, rendered: Signature.stored(render),
                                      label: "New signature for \(drawnPerson.fullName)",
                                      empty: "This renders empty for \(drawnPerson.fullName).")
                    } else {
                        Text(person == nil ? "Choose a person to preview." : "Write a template, or load a saved one.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            if let drawnPerson, !drawn.template.isBlank {
                ForEach(SignatureChanges.warnings(template: drawn.template, render: render, for: drawnPerson), id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                if let reason = blocked(person: person) {
                    Label(reason, systemImage: "info.circle").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review and Replace…") {
                    guard let person else { return }
                    let current = try? access.lists(for: person.primaryEmail)?.signature.get()
                    let template = template, changes = changes
                    Task { await changes.preview(person: person, template: template, current: current) }
                }
                .disabled(blocked(person: person) != nil)
                .accessibilityHint("Shows exactly what will be set, before anything changes.")
            }
        }
    }

    /// Why there's nothing to review yet, in words; nil when Review and Replace can go ahead.
    private func blocked(person: GamUser?) -> String? {
        if setup.active == nil { return "Connect a domain on Setup first." }
        if directory.users == nil {
            if directory.isLoading { return "The directory is loading…" }
            return directory.problem.map { "The directory couldn't be loaded: \($0.summary)" } ?? "Load the directory on Users first."
        }
        guard let person else { return "Choose a person to preview." }
        if template.isBlank { return "Write a template, or load a saved one." }
        // Their signature now is what Put Back Previous restores: wait for its read.
        if access.isReading(person.primaryEmail) { return "Reading their current signature…" }
        let render = Signature.render(template, for: person)
        if Signature.readAsKeyword(render) != nil { return SignatureChanges.keywordRefusal(render) }
        if changes.isBusy { return "A signature is being set…" }
        return nil
    }
}

/// Who the signature is for: an active person, chosen from the menu (type to jump to a name).
private struct PersonSection: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let people: [GamUser]
    @Binding var personEmail: String

    var body: some View {
        Section("Person") {
            Picker("Person", selection: $personEmail) {
                Text("Choose a person…").tag("")
                ForEach(people) { person in
                    Text(person.fullName == person.primaryEmail ? person.primaryEmail : "\(person.fullName) — \(person.primaryEmail)")
                        .tag(person.primaryEmail)
                }
                // Someone asked for who isn't an active person here: shown as chosen, and said so below.
                if !personEmail.isEmpty, !people.contains(where: { $0.primaryEmail == personEmail }) {
                    Text(personEmail).tag(personEmail)
                }
            }
            .disabled(directory.users == nil)
            if setup.active == nil {
                Text("Connect a domain on Setup first.").foregroundStyle(.secondary)
            } else if directory.users == nil, directory.isLoading {
                HStack { ProgressView().controlSize(.small); Text("Loading the directory…") }
                    .accessibilityElement(children: .combine)
            } else if let problem = directory.problem, directory.users == nil {
                Label(problem.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if !personEmail.isEmpty, directory.users != nil, !people.contains(where: { $0.primaryEmail == personEmail }) {
                Label("\(personEmail) isn't an active person here: a signature is set only for active people.",
                      systemImage: "exclamationmark.triangle.fill")
            }
        }
    }
}

/// The person's signature now, as GAM shows it: reading, none, the signature, or why it couldn't be read.
struct CurrentSignature: View {
    let person: GamUser?
    let access: UserAccess

    var body: some View {
        if let person {
            switch access.lists(for: person.primaryEmail)?.signature {
            case .success(let body)?:
                SignaturePane(html: body, rendered: body, label: "Current signature of \(person.fullName)")
            case .failure(let problem)?:
                Label(problem.summary, systemImage: "exclamationmark.triangle.fill")
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            case nil:
                Group {
                    if let problem = access.problem(for: person.primaryEmail) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                    } else if access.isReading(person.primaryEmail) {
                        HStack { ProgressView().controlSize(.small); Text("Reading their signature…") }
                            .accessibilityElement(children: .combine)
                    } else {
                        Text("Not read.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            }
        } else {
            Text("Choose a person to preview.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        }
    }
}

/// The editor, the variables it can use, and Save As.
private struct TemplateSection: View {
    @Binding var template: String
    let templates: SignatureTemplates
    @State private var naming = false
    @State private var name = ""
    @State private var replacing: String?
    @State private var note: (text: String, problem: Bool)?

    var body: some View {
        Section("Template") {
            SignatureEditor(text: $template, label: "Signature template, HTML")
                .frame(minHeight: 150, idealHeight: 190)
            Text(Signature.variables.map { "\($0.token) \($0.description.lowercasedFirst)" }.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Wrap a part in [[ … ]] to drop it when a variable inside is empty: [[{title} · ]] disappears for someone with no title.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                if let note {
                    Label(note.text, systemImage: note.problem ? "exclamationmark.triangle.fill" : "checkmark.circle")
                }
                Spacer()
                Button("Save As…") {
                    name = ""
                    naming = true
                }
                .disabled(templates.store == nil || template.isBlank)
                .accessibilityLabel("Save the template as a saved template")
            }
        }
        .alert("Save Template As", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { save(name, replacing: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved templates are kept on this Mac, for every domain.")
        }
        .confirmationDialog("Replace the saved template “\(replacing ?? "")”?",
                            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })) {
            Button("Replace “\(replacing ?? "")”", role: .destructive) {
                if let replacing { save(replacing, replacing: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its HTML is replaced with the editor's. No copy of the old one is kept.")
        }
    }

    private func save(_ name: String, replacing: Bool) {
        do {
            try templates.save(name, body: template, replacing: replacing)
            note = ("Saved “\(name.trimmingCharacters(in: .whitespacesAndNewlines))”.", false)
        } catch SignatureStore.Problem.exists(let saved) {
            self.replacing = saved
        } catch let problem as SignatureStore.Problem {
            note = (problem.message, true)
        } catch {
            note = ("The template wasn't saved (\(error)).", true)
        }
        if let note { AccessibilityNotification.Announcement(note.text).post() }
    }
}

/// The saved templates: Load or Delete each, the copy from GamGUI, and what opening the store found.
private struct SavedTemplatesSection: View {
    @Binding var template: String
    let templates: SignatureTemplates
    @State private var deleting: String?
    @State private var note: (text: String, problem: Bool)?

    var body: some View {
        Section("Saved templates") {
            if let problem = templates.openProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
            }
            if let moved = templates.quarantined {
                Label("The saved templates couldn't be read, so the file was kept aside as \(moved.lastPathComponent), "
                      + "in \(moved.deletingLastPathComponent().path). These are the starter templates.",
                      systemImage: "exclamationmark.triangle.fill")
                    .textSelection(.enabled)
            }
            if templates.store != nil, templates.names.isEmpty {
                Text("No saved templates.").foregroundStyle(.secondary)
            }
            ForEach(templates.names, id: \.self) { name in
                LabeledContent(name) {
                    HStack {
                        Button("Load") { if let body = templates.body(name) { template = body } }
                            .accessibilityLabel("Load \(name)")
                        Button("Delete…") { deleting = name }
                            .accessibilityLabel("Delete \(name)")
                    }
                }
            }
            if let note {
                Label(note.text, systemImage: note.problem ? "exclamationmark.triangle.fill" : "checkmark.circle")
            }
            if templates.canCopyFromGamGUI {
                Button("Copy Templates from GamGUI") { copy() }
                    .disabled(templates.store == nil)
                    .accessibilityHint("Adds GamGUI's saved templates this app doesn't have. Nothing here is replaced.")
            }
        }
        .confirmationDialog("Delete the saved template “\(deleting ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete “\(deleting ?? "")”", role: .destructive) {
                if let deleting { delete(deleting) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No copy is kept. Signatures already set with it don't change.")
        }
    }

    private func delete(_ name: String) {
        do {
            try templates.delete(name)
            note = ("Deleted “\(name)”.", false)
        } catch let problem as SignatureStore.Problem {
            note = (problem.message, true)
        } catch {
            note = ("The template wasn't deleted (\(error)).", true)
        }
        if let note { AccessibilityNotification.Announcement(note.text).post() }
    }

    private func copy() {
        do {
            let report = try templates.copyFromGamGUI()
            note = (Self.words(report), false)
        } catch let problem as SignatureStore.Problem {
            note = (problem.message, true)
        } catch {
            note = ("GamGUI's templates weren't copied (\(error)).", true)
        }
        if let note { AccessibilityNotification.Announcement(note.text).post() }
    }

    /// The copy's report in words: copied, kept, refused.
    static func words(_ report: SignatureStore.CopyReport) -> String {
        func names(_ list: [String]) -> String { list.map { "“\($0)”" }.joined(separator: ", ") }
        var parts: [String] = []
        parts.append(report.copied.isEmpty ? "Nothing new to copy from GamGUI." : "Copied from GamGUI: \(names(report.copied)).")
        if !report.kept.isEmpty {
            parts.append("Kept this app's version of \(names(report.kept)), saved in GamGUI with other HTML.")
        }
        if !report.refused.isEmpty {
            parts.append("Left out \(names(report.refused)): a blank or too-long name, or no HTML.")
        }
        return parts.joined(separator: " ")
    }
}

/// The last signature change's result, above the screen: running, done (with Put Back Previous), or why
/// it failed, with GAM's own error one click away.
private struct SignatureResult: View {
    let changes: SignatureChanges

    var body: some View {
        switch changes.state {
        case .running(let pending):
            banner(tint: .blue) {
                ProgressView().controlSize(.small)
                Text("\(pending.title)…").frame(maxWidth: .infinity, alignment: .leading)
            }
        case .done(let done):
            banner(tint: .green) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(done.message).frame(maxWidth: .infinity, alignment: .leading)
                if let previous = done.previous {
                    Button("Put Back Previous…") { Task { await changes.previewPutBack(previous: previous) } }
                        .accessibilityLabel("Put back \(previous.person.fullName)'s previous signature")
                        .accessibilityHint("Shows the signature they had before, to set it again.")
                }
                dismiss
            }
        case .problem(let problem):
            banner(tint: .orange) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(problem.summary)
                    if let detail = problem.detail {
                        DisclosureGroup("GAM's error") {
                            Text(detail).font(.callout.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                dismiss
            }
        case .idle, .previewing:
            EmptyView()
        }
    }

    private var dismiss: some View {
        Button { changes.dismiss() } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
    }

    private func banner(tint: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) { content() }
            .padding(10)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .padding([.horizontal, .top])
    }
}

extension SignatureChanges {
    /// What the result banner says, for the one announcement of it.
    var announcement: String? {
        switch state {
        case .done(let done): done.message
        case .problem(let problem): problem.summary
        case .idle, .previewing, .running: nil
        }
    }
}
