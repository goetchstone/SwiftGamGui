import Directory
import GamEngine
import Setup
import Stores
import SwiftUI

/// Signatures: Gmail signatures from a template (GamGUI's designer). For one person, the template is rendered for them
/// as it's typed, beside the signature they have now; "Review and Replace…" holds that render as a preview
/// (`SignatureChanges`), and only the confirm sheet runs it, exactly as held. For a group's members, an org unit or the
/// whole company, the review holds one write per person; the run is in the jobs tray and on this screen with Stop, and
/// "Retry the N That Failed…" reviews exactly those again. Saved templates load into the editor; the editor saves as a
/// template.
struct SignaturesView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: SignatureChanges
    let access: UserAccess
    let templates: SignatureTemplates
    /// The tenant's groups, for a group's members.
    let groups: GroupStore
    /// The onboarding roles: deleting a template says which roles name it.
    let roles: OnboardRoles
    /// A person another screen asked for (Users' "Change Signature…"), taken once.
    @Binding var requested: String?
    /// Kept per window while the app runs, so leaving the screen doesn't lose what was typed.
    @SceneStorage("signatures.template") private var template = ""
    @SceneStorage("signatures.person") private var personEmail = ""
    /// Who it's for (`SignatureScope.Kind`), and the group or org unit when it's one of those. One person by default:
    /// GamGUI's designer once opened on the whole company, and Preview then Apply overwrote everyone.
    @SceneStorage("signatures.scope") private var scopeKind = SignatureScope.Kind.person.rawValue
    @SceneStorage("signatures.scopeValue") private var scopeValue = ""
    /// The template and person last drawn: a moment after the last keystroke, not on every one.
    @State private var drawn = (template: "", person: "")
    @State private var defaultApplied = false
    @State private var debugApplied = false
    @Environment(\.appearsActive) private var appearsActive

    private var kind: SignatureScope.Kind { SignatureScope.Kind(rawValue: scopeKind) ?? .person }

    var body: some View {
        let people = changes.activePeople
        let person = kind == .person ? people.first { $0.primaryEmail == personEmail } : nil
        VStack(spacing: 0) {
            SignatureResult(changes: changes)
            ScrollViewReader { scroller in
                Form {
                    ScopeSection(setup: setup, directory: directory, groups: groups, kind: $scopeKind, value: $scopeValue)
                        .id(Self.top)
                    if kind == .person {
                        PersonSection(setup: setup, directory: directory, people: people, personEmail: $personEmail)
                    }
                    // What will change comes first, with Review and Replace, then the template that makes it.
                    if kind == .person {
                        previewSection(person: person)
                    } else {
                        scopePreviewSection(SignatureScope(kind: kind, value: scopeValue))
                    }
                    TemplateSection(template: $template, templates: templates)
                    SavedTemplatesSection(template: $template, templates: templates, roles: roles)
                }
                .formStyle(.grouped)
                // The editor takes the keyboard when the screen opens, and AppKit scrolls the form down to it,
                // past the preview. Back to the top once that has settled, and for each person chosen: what
                // will change is what the screen is for. The editor keeps the keyboard.
                .task(id: personEmail) {
                    guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
                    scroller.scrollTo(Self.top, anchor: .top)
                }
            }
        }
        // Long text wraps rather than widen the screen past the smallest window (ColumnWidths).
        .frame(minWidth: 0, maxWidth: .infinity)
        .toolbar {
            ToolbarItem {
                Button("Read Again", systemImage: "arrow.clockwise") {
                    Task { await access.load(personEmail) }
                }
                .keyboardShortcut("r")
                .disabled(kind != .person || person == nil || access.isReading(personEmail))
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
            scopeKind = SignatureScope.Kind.person.rawValue
            personEmail = email
            requested = nil
        }
        // Another domain: its people aren't this one's.
        .onChange(of: setup.generation) {
            personEmail = ""
            scopeValue = ""
            defaultApplied = false
        }
        // After the directory loads: connecting (a new generation) clears the person first.
        .task(id: directory.users?.count ?? -1) { debugSelection() }
        .sheet(item: Binding(get: { changes.sheetPending }, set: { if $0 == nil { changes.dismissPreview() } })) { pending in
            if pending.isScoped {
                SignatureScopePreviewSheet(pending: pending, changes: changes)
            } else {
                SignaturePreviewSheet(pending: pending, changes: changes)
            }
        }
        // A preview is of what the screen said when it was made: an edit since drops it (GamGUI refuses an Apply whose
        // form changed after its Preview).
        .onChange(of: "\(scopeKind)#\(scopeValue)#\(personEmail)#\(template)") { changes.edited() }
        // A group's members are chosen from the tenant's groups.
        .task(id: "\(scopeKind)#\(setup.generation)") {
            if kind == .group, groups.groups == nil, !groups.isLoading { await groups.load() }
        }
        // Said once, from the window in front; never the signature itself.
        .onChange(of: changes.announcement) { _, text in
            if let text, appearsActive { AccessibilityNotification.Announcement(text).post() }
        }
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` chooses the person and `SWIFTGAMGUI_TEMPLATE` loads a saved
    /// template, for the snapshots, once the directory is loaded. `SWIFTGAMGUI_TAB` names a scope's kind
    /// (`orgUnit`, `group`, `company`), and `SWIFTGAMGUI_SELECT` is then its unit or group.
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
        // `<kind>+confirm` then reviews the scope (the confirm sheet, held, never run); `<kind>+result` shows a made-up
        // finished run with failures and its Retry (no gam). After the edits above have settled: they drop a preview.
        let tab = (environment["SWIFTGAMGUI_TAB"] ?? "").split(separator: "+").map(String.init)
        if let kind = tab.first.flatMap(SignatureScope.Kind.init(rawValue:)), kind != .person {
            scopeKind = kind.rawValue
            scopeValue = environment["SWIFTGAMGUI_SELECT"] ?? ""
            personEmail = ""
            let scope = SignatureScope(kind: kind, value: environment["SWIFTGAMGUI_SELECT"] ?? "")
            let body = environment["SWIFTGAMGUI_TEMPLATE"].flatMap(templates.body) ?? template, changes = changes
            switch tab.dropFirst().first {
            case "confirm":
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    await changes.previewScope(scope, template: body)
                }
            case "result":
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    changes.showDemoResult(scope, template: body)
                }
            default: break
            }
        }
        #endif
    }

    // MARK: the preview

    private func previewSection(person: GamUser?) -> some View {
        let drawnPerson = person.flatMap { $0.primaryEmail == drawn.person ? $0 : nil }
        let render = drawnPerson.map { Signature.render(drawn.template, for: $0) } ?? ""
        let current = VStack(alignment: .leading, spacing: 4) {
            Text("Current").font(.headline)
            CurrentSignature(person: person, access: access)
        }
        let new = VStack(alignment: .leading, spacing: 4) {
            Text("New").font(.headline)
            if let drawnPerson, !drawn.template.isBlank {
                // Rendered: what Gmail will hold (GAM's stored form). HTML: what GAM will be given.
                SignaturePane(html: render, rendered: Signature.stored(render),
                              label: "New signature for \(drawnPerson.fullName)",
                              empty: "This renders empty for \(drawnPerson.fullName).")
            } else {
                Text(person == nil ? "Choose a person to preview." : "Write a template, or load a saved one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: SignaturePane.standardHeight, alignment: .topLeading)
            }
        }
        return Section("Preview") {
            // Side by side while each has room for a signature as wide as Gmail draws most; one above the
            // other, each the full width, in a narrower window.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    current.frame(minWidth: 0, idealWidth: Self.columnWidth, maxWidth: .infinity, alignment: .leading)
                    new.frame(minWidth: 0, idealWidth: Self.columnWidth, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 16) {
                    current.frame(maxWidth: .infinity, alignment: .leading)
                    new.frame(maxWidth: .infinity, alignment: .leading)
                }
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

    /// A scope's preview: how many it reaches, the template rendered for the first of them (a sample: each person gets their
    /// own), what to know first, and "Review for N People…", which holds one write per person.
    private func scopePreviewSection(_ scope: SignatureScope) -> some View {
        // An org unit's or the company's people are known from the directory; a group's are read when it's reviewed.
        let matched = scope.kind == .group ? nil : directory.users.map { SignatureScope.match($0, scope) }
        let sample = matched?.first
        return Section("Preview") {
            VStack(alignment: .leading, spacing: 4) {
                Text("New").font(.headline)
                if let sample, !drawn.template.isBlank {
                    let render = Signature.render(drawn.template, for: sample)
                    SignaturePane(html: render, rendered: Signature.stored(render), label: "New signature as rendered for \(sample.fullName)",
                                  empty: "This renders empty for \(sample.fullName).")
                    Text("Rendered for \(sample.fullName), the first of them. Each person gets their own.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(scope.kind == .group ? "Each member's signature is rendered for them; the review shows the first."
                         : "Write a template, or load a saved one.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: SignaturePane.standardHeight, alignment: .topLeading)
                }
            }
            let quote = Signature.smartQuoteWarning(drawn.template)
            if !quote.isEmpty {
                Label(quote, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            HStack(alignment: .firstTextBaseline) {
                if let reason = blocked(scope: scope, matched: matched) {
                    Label(reason, systemImage: "info.circle").foregroundStyle(.secondary)
                }
                Spacer()
                Button(matched.map { "Review for \($0.count) \($0.count == 1 ? "Person" : "People")\u{2026}" } ?? "Review\u{2026}") {
                    let template = template, changes = changes
                    Task { await changes.previewScope(scope, template: template) }
                }
                .disabled(blocked(scope: scope, matched: matched) != nil)
                .accessibilityHint("Shows how many signatures will be replaced and one of them, before anything changes.")
            }
        }
    }

    /// Why a scope has nothing to review yet, in words; nil when Review can go ahead.
    private func blocked(scope: SignatureScope, matched: [GamUser]?) -> String? {
        if setup.active == nil { return "Connect a domain on Setup first." }
        if directory.users == nil {
            if directory.isLoading { return "The directory is loading…" }
            return directory.problem.map { "The directory couldn't be loaded: \($0.summary)" } ?? "Load the directory on Users first."
        }
        switch scope {
        case .group(let value) where value.isBlank: return "Choose a group."
        case .orgUnit(let value) where value.isBlank: return "Choose an org unit."
        default: break
        }
        if template.isBlank { return "Write a template, or load a saved one." }
        if matched?.isEmpty == true { return "No active users match this scope." }
        if changes.isBusy { return "Signatures are being set…" }
        return nil
    }

    /// The screen's first section, scrolled to when it opens.
    private static let top = "signatures.top"

    /// The narrowest a preview stands beside the other: a typical signature (a name, a title, a phone and a
    /// small logo) is about this wide in Gmail.
    static let columnWidth: CGFloat = 380

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

/// Whom the signature is for: one person (chosen below), a group's members, everyone in an org unit, or the whole company.
/// Suspended accounts are never in scope.
private struct ScopeSection: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let groups: GroupStore
    @Binding var kind: String
    @Binding var value: String

    var body: some View {
        Section("Who") {
            // Another kind clears the group or unit chosen for the last one.
            Picker("Set it for", selection: Binding(get: { kind }, set: { if $0 != kind { kind = $0; value = "" } })) {
                ForEach(SignatureScope.Kind.allCases) { Text($0.label).tag($0.rawValue) }
            }
            switch SignatureScope.Kind(rawValue: kind) ?? .person {
            case .person:
                EmptyView()
            case .group:
                let listed = groups.groups ?? []
                Picker("Group", selection: $value) {
                    Text("Choose a group\u{2026}").tag("")
                    ForEach(listed) { group in
                        Text(group.name.isEmpty || group.name == group.email ? group.email : "\(group.name) \u{2014} \(group.email)")
                            .tag(group.email)
                    }
                    if !value.isEmpty, !listed.contains(where: { $0.email == value }) { Text(value).tag(value) }
                }
                .disabled(groups.groups == nil)
                if groups.groups == nil, groups.isLoading {
                    HStack { ProgressView().controlSize(.small); Text("Loading the groups\u{2026}") }
                        .accessibilityElement(children: .combine)
                } else if let problem = groups.problem, groups.groups == nil {
                    Label(problem.summary, systemImage: "exclamationmark.triangle.fill")
                }
                Text("Its members with an active account, read when you review. A group inside it, and suspended accounts, are left out.")
                    .font(.callout).foregroundStyle(.secondary)
            case .orgUnit:
                let units = SignatureScope.orgUnits(directory.users ?? [])
                Picker("Org unit", selection: $value) {
                    Text("Choose an org unit\u{2026}").tag("")
                    ForEach(units, id: \.self) { Text($0).tag($0) }
                    if !value.isEmpty, !units.contains(value) { Text(value).tag(value) }
                }
                .disabled(directory.users == nil)
                Text("Everyone active in that unit and the units inside it. Suspended accounts are left out.")
                    .font(.callout).foregroundStyle(.secondary)
            case .company:
                Text("Everyone active in the directory. Suspended accounts are left out.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
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
                    .frame(maxWidth: .infinity, minHeight: SignaturePane.standardHeight, alignment: .topLeading)
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
                .frame(maxWidth: .infinity, minHeight: SignaturePane.standardHeight, alignment: .topLeading)
            }
        } else {
            Text("Choose a person to preview.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: SignaturePane.standardHeight, alignment: .topLeading)
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
                .frame(minHeight: 240, idealHeight: 320)
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
    let roles: OnboardRoles
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
            let using = deleting.map { roles.roles(usingSignature: $0) } ?? []
            Text("No copy is kept. Signatures already set with it don't change."
                 + (using.isEmpty ? "" : " Onboarding role\(using.count == 1 ? "" : "s") \(using.joined(separator: ", ")) "
                    + "name\(using.count == 1 ? "s" : "") it: a new account there would get no signature until you pick another."))
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
        case .running(let pending) where pending.isScoped:
            ScopeProgress(pending: pending, changes: changes)
        case .running(let pending):
            banner(tint: .blue) {
                ProgressView().controlSize(.small)
                Text("\(pending.title)…").frame(maxWidth: .infinity, alignment: .leading)
            }
        case .done(let done) where done.partial:
            banner(tint: .orange) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(done.message)
                    if done.failedCount > 0 {
                        // A bounded box that scrolls (GamGUI's `max-h-24` failures list): the banner never pushes the
                        // template off a small window, however many failed. Every one is in the jobs tray and Audit.
                        DisclosureGroup("Failed (\(done.failedCount))") {
                            ScrollView {
                                Text(done.failures.joined(separator: "\n")
                                     + (done.failedCount > done.failures.count
                                        ? "\n\u{2026}and \(done.failedCount - done.failures.count) more, in the jobs tray and Audit" : ""))
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)
                        }
                    }
                    if let retry = done.retry {
                        Button("Retry the \(retry.failed.count) That Failed\u{2026}") { Task { await changes.previewRetry(retry) } }
                            .accessibilityHint("Shows exactly those people, with the same template, before anything changes.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                dismiss
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

/// A scope's run as it goes (GamGUI's `_sig_apply.html` while running): how many of how many, set and failed, who is
/// being set now, and Stop, which asks first: the write in flight finishes, and the rest aren't attempted.
private struct ScopeProgress: View {
    let pending: SignatureChanges.Pending
    let changes: SignatureChanges
    @State private var asking = false

    var body: some View {
        let progress = changes.progress ?? SignatureChanges.Progress(total: pending.people.count)
        let current = progress.done < pending.people.count ? pending.people[progress.done].primaryEmail : nil
        HStack(alignment: .firstTextBaseline) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.stopping ? "Stopping after this signature\u{2026}" : "Applying the signature\u{2026}")
                Text("\(progress.done) of \(progress.total) \u{B7} \(progress.applied) set"
                     + (progress.failed > 0 ? " \u{B7} \(progress.failed) failed" : "") + (current.map { " \u{B7} \($0)" } ?? ""))
                    .font(.callout).foregroundStyle(.secondary)
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .accessibilityLabel("Signatures done")
                    .accessibilityValue("\(progress.done) of \(progress.total)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop\u{2026}") { asking = true }
                .disabled(progress.stopping)
                .accessibilityLabel("Stop setting signatures")
        }
        .padding(10)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .padding([.horizontal, .top])
        .confirmationDialog("Stop after this signature?", isPresented: $asking) {
            Button("Stop After This Signature") { Task { await changes.stop() } }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The signature being set now finishes. The rest aren't set, and the ones already set stay set.")
        }
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
