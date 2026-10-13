import Directory
import GamEngine
import Stores
import SwiftUI

/// The role editor (onboarding plan O2, W): the saved roles and welcome emails beside the one being edited. A role
/// is a checklist (one step a line), the org unit an account is created in, a saved signature, the groups and
/// calendars a new hire joins, and the welcome email it sends; the store saves it by GamGUI's rules plus this app's
/// (`Onboarding.savable`). A welcome email is a subject and plain text, filled in for each hire. Replacing another
/// and deleting one are asked; switching away from unsaved edits is asked too. GamGUI's roles can be copied in once.
struct OnboardRolesSheet: View {
    let roles: OnboardRoles
    let templates: SignatureTemplates
    let groups: GroupStore
    /// What the editor opens on; the first role when nil.
    var start: Selection? = nil
    let dismiss: () -> Void

    /// What the editor shows: a saved role or welcome email by its name, or a new one.
    @State private var selection: Selection = .newRole
    @State private var draft = RoleDraft()
    /// What the draft was when it was loaded or saved: unsaved edits are the difference.
    @State private var loaded = RoleDraft()
    @State private var letter = WelcomeDraft()
    @State private var letterLoaded = WelcomeDraft()
    @State private var started = false
    @State private var switchTo: Selection?
    @State private var closing = false
    @State private var replacing: String?
    @State private var replacingWelcome: String?
    @State private var deleting: Selection?
    @State private var outcome: (text: String, failed: Bool)?
    @State private var report: RoleStore.CopyReport?
    @Environment(\.appearsActive) private var appearsActive

    /// A list choice.
    enum Selection: Hashable {
        case role(String), newRole, welcome(String), newWelcome

        var isWelcome: Bool {
            switch self {
            case .welcome, .newWelcome: true
            case .role, .newRole: false
            }
        }

        /// The saved name, for a role or welcome email that is saved.
        var saved: String? {
            switch self {
            case .role(let name), .welcome(let name): name
            case .newRole, .newWelcome: nil
            }
        }
    }

    private var dirty: Bool { selection.isWelcome ? letter != letterLoaded : draft != loaded }
    private var shownName: String { selection.isWelcome ? letter.name : draft.name }
    private var isDefault: Bool { selection == .welcome(Onboarding.defaultWelcome) }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 210)
            Divider()
            if selection.isWelcome { welcomeEditor } else { roleEditor }
        }
        .frame(minWidth: 760, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { if dirty { closing = true } else { dismiss() } }
                    .help("Closes the editor")
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            if let start { open(start) } else if let first = roles.roles.first { open(.role(first.name)) }
        }
        .task {
            // The picker's suggestions: the tenant's groups, read once if they aren't yet.
            if groups.groups == nil { await groups.load() }
        }
        .confirmationDialog("Discard the changes to \u{201C}\(shownName)\u{201D}?", isPresented: present($switchTo)) {
            Button("Discard Changes", role: .destructive) { if let switchTo { open(switchTo) } }
            Button("Keep Editing", role: .cancel) {}
        }
        .confirmationDialog("Close without saving \u{201C}\(shownName)\u{201D}?", isPresented: $closing) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .confirmationDialog("Replace the role \u{201C}\(replacing ?? "")\u{201D}?", isPresented: present($replacing)) {
            Button("Replace") { save(replacing: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its checklist, org unit, signature, groups, calendars and welcome email become these. The old ones aren't kept.")
        }
        .confirmationDialog("Replace the welcome email \u{201C}\(replacingWelcome ?? "")\u{201D}?", isPresented: present($replacingWelcome)) {
            Button("Replace") { saveWelcome(replacing: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its subject and body become these. The old ones aren't kept.")
        }
        .confirmationDialog(deletingTitle, isPresented: present($deleting)) {
            Button("Delete", role: .destructive) { if let deleting { delete(deleting) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleting?.isWelcome == true ? "No copy is kept." : "No copy is kept. People already onboarded with it don't change.")
        }
    }

    private var deletingTitle: String {
        switch deleting {
        case .role(let name): "Delete the role \u{201C}\(name)\u{201D}?"
        case .welcome(let name): "Delete the welcome email \u{201C}\(name)\u{201D}?"
        default: ""
        }
    }

    // MARK: the list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { selection }, set: { choose($0) })) {
                Section("Roles") {
                    ForEach(roles.roles, id: \.name) { role in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(role.name)
                            Text("\(role.steps.count) step\(role.steps.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(Selection.role(role.name))
                        .accessibilityElement(children: .combine)
                    }
                    if selection == .newRole {
                        Text(draft.name.isEmpty ? "New role" : draft.name).italic().tag(Selection.newRole)
                    }
                }
                Section("Welcome Emails") {
                    ForEach(roles.welcomeNames, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                            Text(roles.welcome(named: name)?.subject ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(Selection.welcome(name))
                        .accessibilityElement(children: .combine)
                    }
                    if selection == .newWelcome {
                        Text(letter.name.isEmpty ? "New welcome email" : letter.name).italic().tag(Selection.newWelcome)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("New Role") { choose(.newRole) }
                    Button("Duplicate") { duplicate() }
                        .disabled(selection.saved == nil)
                        .help("A new one with this one's contents")
                }
                Button("New Welcome Email") { choose(.newWelcome) }
                if roles.canCopyFromGamGUI {
                    Button("Copy Roles from GamGUI") { copy() }
                        .disabled(roles.store == nil)
                        .help("Adds GamGUI's roles and welcome emails this app doesn't have. Nothing here is replaced.")
                }
                if let report { CopyReportView(report: report) }
            }
            .padding(10)
        }
    }

    // MARK: the editors

    @ViewBuilder private var storeNotes: some View {
        if let problem = roles.openProblem {
            Label("Roles can't be saved: \(problem)", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        } else if let aside = roles.quarantined {
            Label("The saved roles couldn't be read, so they were moved aside to \(aside.lastPathComponent) in the app's "
                  + "folder, untouched. The starter role is shown instead.", systemImage: "info.circle")
        }
    }

    private var roleEditor: some View {
        Form {
            storeNotes
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Warehouse"))
                    .accessibilityHint("The role's name, as the Onboard screen offers it")
            } header: {
                Text(selection == .newRole ? "New role" : "Role").accessibilityAddTraits(.isHeader)
            }
            Section {
                SignatureEditor(text: $draft.steps, label: "Checklist steps, one a line")
                    .frame(minHeight: 120)
            } header: {
                Text("Checklist")
            } footer: {
                Text("One step a line: each becomes a task on the assignee's Google Tasks list. Blank lines are dropped.")
            }
            Section("New account") {
                TextField("Org unit", text: $draft.orgUnit, prompt: Text(verbatim: "/Staff"))
                    .autocorrectionDisabled()
                    .accessibilityHint("Where a new account is created. Blank: the domain's top level.")
                SignaturePicker(selection: $draft.signature, templates: templates)
            }
            AddressListSection(title: "Groups", noun: "group", entries: $draft.groups,
                               note: "The new hire joins each as a member.",
                               suggestions: { query in
                                   (groups.rows(query: query) ?? []).prefix(8).map { ($0.email, $0.name == $0.email ? $0.email : "\($0.name) — \($0.email)") }
                               })
            AddressListSection(title: "Calendars", noun: "calendar", entries: $draft.calendars,
                               note: "Each is added to the new hire's calendar list (a calendar's id, like team@group.calendar.google.com).",
                               suggestions: { _ in [] })
            Section("Welcome email") {
                WelcomePicker(selection: $draft.welcome, roles: roles)
            }
            actions { save(replacing: false) }
        }
        .formStyle(.grouped)
    }

    private var welcomeEditor: some View {
        Form {
            storeNotes
            Section {
                TextField("Name", text: $letter.name, prompt: Text("Contractor"))
                    .disabled(isDefault)
                    .accessibilityHint("The name a role picks it by")
                let senders = selection.saved.map(roles.roles(usingWelcome:)) ?? []
                if isDefault {
                    Text("Sent by a role that doesn't pick another, so it can be edited but not renamed or deleted.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(senders.isEmpty ? "No role sends it yet." : "Sent by \(senders.joined(separator: ", ")).")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text(selection == .newWelcome ? "New welcome email" : "Welcome email").accessibilityAddTraits(.isHeader)
            }
            Section {
                TextField("Subject", text: $letter.subject, prompt: Text(verbatim: "Welcome to the team, {name}!"))
                SignatureEditor(text: $letter.body, label: "Body")
                    .frame(minHeight: 160)
            } header: {
                Text("Email")
            } footer: {
                Text(verbatim: "Plain text, sent with each line kept. Filled in for each new hire: {name}, {role}, {email} and {manager}.")
            }
            Section("As Jordan Lee would get it") {
                let sample = Onboarding.welcomeContext(name: "Jordan Lee", email: "jordan@example.com",
                                                       role: selection.saved.flatMap { roles.roles(usingWelcome: $0).first } ?? "Salesperson",
                                                       manager: "manager@example.com")
                Text(verbatim: Onboarding.render(letter.subject, sample)).bold()
                Text(verbatim: Onboarding.render(letter.body, sample))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            actions { saveWelcome(replacing: false) }
        }
        .formStyle(.grouped)
    }

    /// Delete (a saved one; never Default), Revert and Save, and what the last of them did.
    private func actions(save: @escaping () -> Void) -> some View {
        Section {
            HStack {
                if let outcome {
                    Label(outcome.text, systemImage: outcome.failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .symbolRenderingMode(.multicolor)
                } else if dirty {
                    Text("Unsaved changes").foregroundStyle(.secondary)
                }
                Spacer()
                if selection.saved != nil, !isDefault {
                    Button("Delete\u{2026}") { deleting = selection }
                }
                Button("Revert") { revert() }
                    .disabled(!dirty)
                Button("Save", action: save)
                    .keyboardShortcut("s")
                    .disabled(!dirty || roles.store == nil)
            }
        }
    }

    // MARK: actions

    private func choose(_ next: Selection) {
        guard next != selection else { return }
        if dirty { switchTo = next } else { open(next) }
    }

    private func open(_ next: Selection) {
        selection = next
        switch next {
        case .role(let name):
            draft = roles.role(named: name).map(RoleDraft.init) ?? RoleDraft()
            loaded = draft
        case .newRole:
            draft = RoleDraft()
            loaded = draft
        case .welcome(let name):
            letter = WelcomeDraft(name: name, email: roles.welcome(named: name))
            letterLoaded = letter
        case .newWelcome:
            letter = WelcomeDraft()
            letterLoaded = letter
        }
        outcome = nil
    }

    private func revert() {
        if selection.isWelcome { letter = letterLoaded } else { draft = loaded }
        outcome = nil
    }

    private func duplicate() {
        if selection.isWelcome {
            var copy = letter
            copy.name = letter.name + " copy"
            selection = .newWelcome
            letterLoaded = WelcomeDraft()
            letter = copy
        } else {
            var copy = draft
            copy.name = draft.name + " copy"
            selection = .newRole
            loaded = RoleDraft()
            draft = copy
        }
        outcome = nil
    }

    private func save(replacing: Bool) {
        do {
            guard let saved = try roles.save(draft.template, replacing: replacing, renaming: selection.saved) else { return }
            selection = .role(saved.name)
            draft = RoleDraft(saved)
            loaded = draft
            say("Saved \u{201C}\(saved.name)\u{201D}.", failed: false)
        } catch .exists(let name) {
            self.replacing = name
        } catch {
            say(error.message, failed: true)
        }
    }

    private func saveWelcome(replacing: Bool) {
        do {
            guard let saved = try roles.saveWelcome(letter.email, as: letter.name, replacing: replacing, renaming: selection.saved)
            else { return }
            selection = .welcome(saved)
            letter = WelcomeDraft(name: saved, email: roles.welcome(named: saved))
            letterLoaded = letter
            say("Saved \u{201C}\(saved)\u{201D}.", failed: false)
        } catch .welcomeExists(let name) {
            replacingWelcome = name
        } catch {
            say(error.message, failed: true)
        }
    }

    private func delete(_ target: Selection) {
        do {
            switch target {
            case .role(let name): try roles.delete(name)
            case .welcome(let name): try roles.deleteWelcome(name)
            case .newRole, .newWelcome: return
            }
            let name = target.saved ?? ""
            if target.isWelcome {
                open(.welcome(Onboarding.defaultWelcome))
            } else if let first = roles.roles.first {
                open(.role(first.name))
            } else {
                open(.newRole)
            }
            say("Deleted \u{201C}\(name)\u{201D}.", failed: false)
        } catch {
            say(error.message, failed: true)
        }
    }

    private func copy() {
        do {
            report = try roles.copyFromGamGUI()
            if let report {
                say(report.copied.isEmpty && report.copiedWelcomes.isEmpty ? "Nothing new to copy from GamGUI."
                    : "Copied \(report.copied.count) role\(report.copied.count == 1 ? "" : "s") from GamGUI.", failed: false)
            }
        } catch {
            say(error.message, failed: true)
        }
    }

    /// Shown under the buttons, and spoken from the window in front.
    private func say(_ text: String, failed: Bool) {
        outcome = (text, failed)
        if appearsActive { AccessibilityNotification.Announcement(text).post() }
    }

    private func present<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

/// A role as the editor holds it: the checklist as typed (one step a line), the rest as fields.
struct RoleDraft: Equatable {
    var name = ""
    var steps = ""
    var signature = ""
    var orgUnit = ""
    var groups: [String] = []
    var calendars: [String] = []
    /// The welcome email's name; blank is Default.
    var welcome = ""

    init() {}

    init(_ role: RoleTemplate) {
        name = role.name
        steps = role.steps.joined(separator: "\n")
        signature = role.signature
        orgUnit = role.orgUnit
        groups = role.groups
        calendars = role.calendars
        welcome = role.welcome
    }

    var template: RoleTemplate {
        RoleTemplate(name: name, steps: steps.split(whereSeparator: \.isNewline).map(String.init), signature: signature,
                     orgUnit: orgUnit, groups: groups,
                     calendars: calendars, welcome: welcome)
    }
}

/// A welcome email as the editor holds it.
struct WelcomeDraft: Equatable {
    var name = ""
    var subject = ""
    var body = ""

    init() {}

    init(name: String, email: WelcomeEmail?) {
        self.name = name
        subject = email?.subject ?? ""
        body = email?.body ?? ""
    }

    var email: WelcomeEmail { WelcomeEmail(subject: subject, body: body) }
}

/// The role's welcome email: one of the saved ones (Default is stored blank). One the role names that isn't saved
/// any more is shown, and said.
private struct WelcomePicker: View {
    @Binding var selection: String
    let roles: OnboardRoles

    var body: some View {
        Picker("Welcome email", selection: $selection) {
            ForEach(roles.welcomeNames, id: \.self) { name in
                Text(name).tag(name == Onboarding.defaultWelcome ? "" : name)
            }
            if !selection.isEmpty, roles.welcome(named: selection) == nil {
                Text("\(selection) (not saved)").tag(selection)
            }
        }
        .accessibilityHint("The email a new hire in this role gets, when Onboard sends one")
        if !selection.isEmpty, roles.welcome(named: selection) == nil {
            Label("\u{201C}\(selection)\u{201D} isn't saved: pick another before sending it.", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
        Text("Sent when Onboard's \u{201C}Also send the welcome email\u{201D} is on. Edit it under Welcome Emails.")
            .font(.callout).foregroundStyle(.secondary)
    }
}

/// The role's signature: one of the saved templates, or none. One the role names that isn't saved any more is
/// shown, and said.
private struct SignaturePicker: View {
    @Binding var selection: String
    let templates: SignatureTemplates

    var body: some View {
        Picker("Signature", selection: $selection) {
            Text("None").tag("")
            ForEach(templates.names, id: \.self) { Text($0).tag($0) }
            if !selection.isEmpty, templates.body(selection) == nil {
                Text("\(selection) (not saved)").tag(selection)
            }
        }
        .accessibilityHint("The saved signature a new account gets")
        if !selection.isEmpty, templates.body(selection) == nil {
            Label("\u{201C}\(selection)\u{201D} isn't saved on Signatures: a new account would get no signature.",
                  systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
        Text("Set only on an account this onboarding creates.").font(.callout).foregroundStyle(.secondary)
    }
}

/// A role's groups or calendars: each address with Remove, and a field to add one, offered from `suggestions`.
private struct AddressListSection: View {
    let title: String
    let noun: String
    @Binding var entries: [String]
    let note: String
    let suggestions: (String) -> [(address: String, shown: String)]
    @State private var adding = ""
    @State private var problem: String?

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.self) { entry in
                LabeledContent(entry) {
                    Button("Remove") { entries.removeAll { $0 == entry } }
                        .accessibilityLabel("Remove \(entry) from the role's \(title.lowercased())")
                }
            }
            HStack {
                TextField("Add a \(noun)", text: $adding, prompt: Text(verbatim: noun == "group" ? "team@example.com" : "team@group.calendar.google.com"))
                    .autocorrectionDisabled()
                    .labelsHidden()
                    .accessibilityLabel("Add a \(noun) by its address")
                    .textInputSuggestions(suggestions(adding), id: \.address) { item in
                        Text(item.shown).textInputCompletion(item.address)
                    }
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
        } header: {
            Text(title)
        } footer: {
            Text(note)
        }
    }

    /// One address, once; anything else is said here rather than at Save.
    private func add() {
        let entry = adding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }
        guard Address.looksLikeEmail(entry) else {
            problem = "\u{201C}\(entry)\u{201D} isn't one address."
            return
        }
        if !entries.contains(where: { $0.lowercased() == entry.lowercased() }) { entries.append(entry) }
        adding = ""
        problem = nil
    }
}

/// What a copy from GamGUI did.
private struct CopyReportView: View {
    let report: RoleStore.CopyReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !report.copied.isEmpty { Text("Copied: \(report.copied.joined(separator: ", "))") }
            if !report.kept.isEmpty { Text("Kept this app's: \(report.kept.joined(separator: ", "))") }
            ForEach(report.refused, id: \.self) { Text("Not copied: \($0)") }
            if !report.copiedWelcomes.isEmpty { Text("Welcome emails copied: \(report.copiedWelcomes.joined(separator: ", "))") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}
