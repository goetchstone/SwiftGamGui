import Directory
import GamEngine
import Stores
import SwiftUI

/// The role editor (onboarding plan O2): the saved roles beside the one being edited. A role is a checklist (one
/// step a line), the org unit an account is created in, a saved signature, and the groups and calendars a new
/// hire joins; the store saves it by GamGUI's rules plus this app's (`Onboarding.savable`). Replacing another
/// role and deleting one are asked; switching away from unsaved edits is asked too. GamGUI's roles can be copied
/// in once.
struct OnboardRolesSheet: View {
    let roles: OnboardRoles
    let templates: SignatureTemplates
    let groups: GroupStore
    let dismiss: () -> Void

    /// The role being edited, by its saved name; nil for a new one.
    @State private var editing: String?
    @State private var draft = RoleDraft()
    /// What the draft was when it was loaded or saved: unsaved edits are the difference.
    @State private var loaded = RoleDraft()
    @State private var switchTo: Selection?
    @State private var closing = false
    @State private var replacing: String?
    @State private var deleting: String?
    @State private var outcome: (text: String, failed: Bool)?
    @State private var report: RoleStore.CopyReport?
    @Environment(\.appearsActive) private var appearsActive

    /// A list choice: a saved role, or a new one (the list's "New Role").
    enum Selection: Hashable { case role(String), new }

    private var dirty: Bool { draft != loaded }

    var body: some View {
        HStack(spacing: 0) {
            roleList
                .frame(width: 210)
            Divider()
            editor
        }
        .frame(minWidth: 760, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { if dirty { closing = true } else { dismiss() } }
                    .help("Closes the editor")
            }
        }
        .onAppear {
            if editing == nil, let first = roles.roles.first { open(.role(first.name)) }
        }
        .task {
            // The picker's suggestions: the tenant's groups, read once if they aren't yet.
            if groups.groups == nil { await groups.load() }
        }
        .confirmationDialog("Discard the changes to \u{201C}\(draft.name)\u{201D}?", isPresented: present($switchTo)) {
            Button("Discard Changes", role: .destructive) { if let switchTo { open(switchTo) } }
            Button("Keep Editing", role: .cancel) {}
        }
        .confirmationDialog("Close without saving \u{201C}\(draft.name)\u{201D}?", isPresented: $closing) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .confirmationDialog("Replace the role \u{201C}\(replacing ?? "")\u{201D}?", isPresented: present($replacing)) {
            Button("Replace") { save(replacing: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its checklist, org unit, signature, groups and calendars become these. The old ones aren't kept.")
        }
        .confirmationDialog("Delete the role \u{201C}\(deleting ?? "")\u{201D}?", isPresented: present($deleting)) {
            Button("Delete", role: .destructive) { if let deleting { delete(deleting) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No copy is kept. People already onboarded with it don't change.")
        }
    }

    // MARK: the list

    private var roleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { editing.map(Selection.role) ?? .new }, set: { choose($0) })) {
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
                    if editing == nil {
                        Text(draft.name.isEmpty ? "New role" : draft.name).italic().tag(Selection.new)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("New Role") { choose(.new) }
                    Button("Duplicate") { duplicate() }
                        .disabled(editing == nil)
                        .help("A new role with this one's contents")
                }
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

    // MARK: the editor

    private var editor: some View {
        Form {
            if let problem = roles.openProblem {
                Label("Roles can't be saved: \(problem)", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            } else if let aside = roles.quarantined {
                Label("The saved roles couldn't be read, so they were moved aside to \(aside.lastPathComponent) in the app's "
                      + "folder, untouched. The starter role is shown instead.", systemImage: "info.circle")
            }
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Warehouse"))
                    .accessibilityHint("The role's name, as the Onboard screen offers it")
            } header: {
                Text(editing == nil ? "New role" : "Role").accessibilityAddTraits(.isHeader)
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
            Section {
                HStack {
                    if let outcome {
                        Label(outcome.text, systemImage: outcome.failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .symbolRenderingMode(.multicolor)
                    } else if dirty {
                        Text("Unsaved changes").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let editing {
                        Button("Delete\u{2026}") { deleting = editing }
                    }
                    Button("Revert") { draft = loaded; outcome = nil }
                        .disabled(!dirty)
                    Button("Save") { save(replacing: false) }
                        .keyboardShortcut("s")
                        .disabled(!dirty || roles.store == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: actions

    private func choose(_ selection: Selection) {
        guard selection != (editing.map(Selection.role) ?? .new) else { return }
        if dirty { switchTo = selection } else { open(selection) }
    }

    private func open(_ selection: Selection) {
        switch selection {
        case .role(let name):
            editing = name
            draft = roles.role(named: name).map(RoleDraft.init) ?? RoleDraft()
        case .new:
            editing = nil
            draft = RoleDraft()
        }
        loaded = draft
        outcome = nil
    }

    private func duplicate() {
        var copy = draft
        copy.name = draft.name + " copy"
        editing = nil
        loaded = RoleDraft()
        draft = copy
        outcome = nil
    }

    private func save(replacing: Bool) {
        do {
            guard let saved = try roles.save(draft.template, replacing: replacing, renaming: editing) else { return }
            editing = saved.name
            draft = RoleDraft(saved)
            loaded = draft
            say("Saved \u{201C}\(saved.name)\u{201D}.", failed: false)
        } catch .exists(let name) {
            self.replacing = name
        } catch {
            say(error.message, failed: true)
        }
    }

    private func delete(_ name: String) {
        do {
            try roles.delete(name)
            say("Deleted \u{201C}\(name)\u{201D}.", failed: false)
            if let first = roles.roles.first { open(.role(first.name)) } else { open(.new) }
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
    /// Kept as saved: the welcome email isn't edited here yet.
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
