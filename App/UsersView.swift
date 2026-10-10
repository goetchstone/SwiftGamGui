import ChangeCore
import Directory
import GamEngine
import Setup
import SwiftUI

/// Users: the loaded directory as a table, searched and scoped as GamGUI's list is, with one person's
/// fields beside it, where the first writes live: title and department, suspend and unsuspend. Each is
/// previewed, confirmed and run once through ChangeCore (`UserChanges`).
struct UsersView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: UserChanges
    let access: UserAccess
    @State private var filter = UserFilter()
    @State private var sortOrder = [KeyPathComparator(\GamUser.fullName, comparator: .localizedStandard)]
    @State private var selection: GamUser.ID?

    var body: some View {
        content
            .task(id: directory.users?.count ?? 0) { selectForSnapshot() }
            .toolbar {
                ToolbarItem {
                    Picker("Show", selection: $filter.scope) {
                        ForEach(UserFilter.Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(directory.users == nil)
                }
                ToolbarItem {
                    Button(directory.users == nil ? "Load" : "Refresh", systemImage: "arrow.clockwise") {
                        Task { await directory.load() }
                    }
                    .keyboardShortcut("r")
                    .disabled(directory.isLoading || setup.active == nil)
                    .accessibilityIdentifier("users.load")
                }
            }
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` opens that person's page, for the snapshot of it.
    private func selectForSnapshot() {
        #if DEBUG
        guard selection == nil, let email = ProcessInfo.processInfo.environment["SWIFTGAMGUI_SELECT"],
              let user = directory.users?.first(where: { $0.primaryEmail == email }) else { return }
        selection = user.id
        #endif
    }

    @ViewBuilder private var content: some View {
        if let users = directory.users {
            let rows = filter.apply(users).sorted(using: sortOrder)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.fullName)
                // With a person's page open the list narrows: only who and their status, readable.
                if selection == nil {
                    TableColumn("Address", value: \.primaryEmail)
                    TableColumn("Title", value: \.title)
                    TableColumn("Department", value: \.department)
                    TableColumn("Organizational Unit", value: \.orgUnitPath)
                }
                TableColumn("Status") { user in
                    Text(user.suspended ? "Suspended" : "Active")
                        .foregroundStyle(user.suspended ? .orange : .primary)
                }
            }
            .searchable(text: $filter.query, prompt: "Name, address, title, department or unit")
            .safeAreaInset(edge: .bottom) {
                // A refresh shows here: running, or why it failed (the list above is the last good one).
                HStack(spacing: 12) {
                    Text("\(rows.count) of \(users.count) accounts").foregroundStyle(.secondary)
                    if directory.isLoading {
                        HStack { ProgressView().controlSize(.small); Text("Refreshing…").foregroundStyle(.secondary) }
                            .accessibilityElement(children: .combine)
                    }
                    if let problem = directory.problem {
                        Label(problem.summary, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).lineLimit(2)
                            .help(problem.detail ?? problem.summary)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
                if let user = users.first(where: { $0.id == selection }) {
                    UserDetail(user: user, directory: directory, changes: changes, access: access)
                }
            }
        } else {
            VStack(spacing: 12) {
                if directory.isLoading {
                    ProgressView("Loading the directory…")
                } else if setup.active == nil {
                    Text("Connect a domain on Setup to list its users.").foregroundStyle(.secondary)
                } else {
                    Text("Not loaded yet. It loads when a domain connects.").foregroundStyle(.secondary)
                    Button("Load the Directory") { Task { await directory.load() } }
                }
                if let problem = directory.problem {
                    Label(problem.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    if let detail = problem.detail {
                        Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One person's fields, read-only.
/// The person page's sections, as tabs: a long single column was hard to find things in.
enum PersonTab: String, CaseIterable, Identifiable {
    case profile = "Profile"
    case access = "Groups & Delegates"
    case mail = "Mail"
    case security = "Security"

    var id: Self { self }

    /// Profile, or in debug builds `SWIFTGAMGUI_TAB` (for snapshots).
    static var initial: PersonTab {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["SWIFTGAMGUI_TAB"],
           let tab = allCases.first(where: { "\($0)" == name.lowercased() }) { return tab }
        #endif
        return .profile
    }
}

/// One person: who they are and their status at the top, an Actions menu for what changes the account,
/// the result of the last change as a banner, and the rest in tabs. Every change opens a preview first.
private struct UserDetail: View {
    let user: GamUser
    let directory: DirectoryStore
    let changes: UserChanges
    let access: UserAccess
    @State private var tab = PersonTab.initial
    @State private var editingRole = false
    @State private var newGroup = ""
    @State private var newDelegate = ""
    @State private var editingAutoReply = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if changes.concerns(user.primaryEmail) { ResultBanner(changes: changes) }
            Picker("Section", selection: $tab) {
                ForEach(PersonTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Section")
            .padding(.horizontal)
            .padding(.bottom, 8)
            Form { tabContent }
                .formStyle(.grouped)
        }
        .inspectorColumnWidth(min: 380, ideal: 460, max: 720)
        // Read when the person is selected, and again after a change of theirs lands.
        .task(id: "\(user.id)#\(changes.finished)") { await access.load(user.primaryEmail) }
        .sheet(isPresented: $editingAutoReply) {
            AutoReplyEditor(user: user, vacation: (try? access.lists(for: user.primaryEmail)?.vacation.get()) ?? Vacation(),
                            changes: changes) { editingAutoReply = false }
        }
        .sheet(isPresented: $editingRole) {
            RoleEditor(user: user, changes: changes) { editingRole = false }
        }
        .sheet(item: Binding(get: { changes.previewing }, set: { if $0 == nil { changes.dismiss() } })) { pending in
            ChangePreviewSheet(pending: pending, changes: changes)
        }
    }

    /// The name, the address and the status in words, with everything that changes the account in one menu.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(user.fullName).font(.title2.bold())
                Text(user.primaryEmail).foregroundStyle(.secondary).textSelection(.enabled)
                if user.suspended {
                    Label("Suspended", systemImage: "pause.circle.fill").foregroundStyle(.orange)
                } else {
                    Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Spacer()
            Menu {
                Button("Edit Title and Department…") { editingRole = true }
                Divider()
                Button("Sign Out of All Sessions…") { Task { await changes.previewSignOut(user) } }
                Button(user.suspended ? "Unsuspend…" : "Suspend…", role: user.suspended ? nil : .destructive) {
                    Task { await changes.previewSuspend(user, suspend: !user.suspended) }
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(changes.isBusy)
            .accessibilityHint("Each action shows what it changes, before anything runs.")
        }
        .padding()
    }

    /// GAM's ISO 8601 time as a date and time in the Mac's own format; GAM says never with the epoch.
    static func signIn(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Never" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) ?? plain.date(from: value) else { return value }
        guard date.timeIntervalSince1970 > 0 else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .profile:
            Section("Role") {
                LabeledContent("Title", value: user.title.isEmpty ? "—" : user.title)
                LabeledContent("Department", value: user.department.isEmpty ? "—" : user.department)
                Button("Edit Title and Department…") { editingRole = true }
                    .disabled(changes.isBusy)
            }
            Section("Details") {
                LabeledContent("Organizational unit", value: user.orgUnitPath)
                LabeledContent("Location", value: user.location.isEmpty ? "—" : user.location)
                LabeledContent("Phone", value: user.phone.isEmpty ? "—" : user.phone)
                LabeledContent("Last sign-in", value: Self.signIn(user.lastLoginTime))
            }
            if !user.aliases.isEmpty {
                Section("Aliases") {
                    ForEach(user.aliases, id: \.self) { Text($0).textSelection(.enabled) }
                }
            }
        case .access:
            AccessLists(user: user, directory: directory, changes: changes, access: access,
                        newGroup: $newGroup, newDelegate: $newDelegate)
        case .mail:
            switch access.lists(for: user.primaryEmail)?.vacation {
            case .success(let vacation)?:
                AutoReplySection(user: user, vacation: vacation, changes: changes) { editingAutoReply = true }
            case .failure(let problem)?:
                Section("Auto-reply") {
                    Label(problem.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            case nil:
                Section("Auto-reply") {
                    HStack { ProgressView().controlSize(.small); Text("Reading the auto-reply…") }
                        .accessibilityElement(children: .combine)
                }
            }
        case .security:
            Section("Security") {
                LabeledContent("Administrator", value: user.isAdmin ? "Super admin" : user.isDelegatedAdmin ? "Delegated" : "No")
                LabeledContent("2-step verification", value: user.isEnrolledIn2SV ? "Enrolled" : "Not enrolled")
                LabeledContent("Recovery email", value: user.recoveryEmail.isEmpty ? "—" : user.recoveryEmail)
            }
        }
    }
}

/// The last change's result, at the top of the page where it can't be missed, and spoken by VoiceOver.
private struct ResultBanner: View {
    let changes: UserChanges

    var body: some View {
        if let (text, symbol, tint) = content {
            HStack(alignment: .firstTextBaseline) {
                if case .running = changes.state {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                Text(text).frame(maxWidth: .infinity, alignment: .leading)
                if !changes.isBusy {
                    Button { changes.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
            }
            .padding(10)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .onAppear { AccessibilityNotification.Announcement(text).post() }
            .onChange(of: text) { _, new in AccessibilityNotification.Announcement(new).post() }
        }
    }

    private var content: (String, String, Color)? {
        switch changes.state {
        case .done(let text): (text, "checkmark.circle.fill", .green)
        case .problem(let text): (text, "exclamationmark.triangle.fill", .orange)
        case .running(let pending): ("\(pending.title)…", "hourglass", .blue)
        case .idle, .previewing: nil
        }
    }
}

extension UserChanges {
    /// The preview a sheet shows, while one is held.
    var previewing: Pending? {
        if case .previewing(let pending) = state { return pending }
        return nil
    }
}

/// The person's groups and mail delegates, each with Remove, and a field to add one. Every change is a
/// preview first (`UserChanges`).
private struct AccessLists: View {
    let user: GamUser
    let directory: DirectoryStore
    let changes: UserChanges
    let access: UserAccess
    @Binding var newGroup: String
    @Binding var newDelegate: String

    var body: some View {
        if let lists = access.lists(for: user.primaryEmail) {
            Section("Groups") {
                if lists.groups.isEmpty { Text("Not in any group.").foregroundStyle(.secondary) }
                ForEach(lists.groups, id: \.self) { group in
                    LabeledContent(group) {
                        Button("Remove…") { Task { await changes.previewRemoveFromGroup(user, group: group) } }
                            .accessibilityLabel("Remove \(user.fullName) from \(group)")
                    }
                }
                HStack {
                    TextField("Group address", text: $newGroup, prompt: Text(verbatim: "sales@example.com"))
                        .onSubmit(addGroup)
                    Button("Add…", action: addGroup)
                        .disabled(newGroup.isEmpty)
                        .accessibilityLabel("Add \(user.fullName) to the group")
                }
            }
            .disabled(changes.isBusy)
            Section("Mail delegates") {
                if lists.delegates.isEmpty { Text("No one can read this mailbox.").foregroundStyle(.secondary) }
                ForEach(lists.delegates, id: \.self) { delegate in
                    LabeledContent(delegate) {
                        Button("Remove…") { Task { await changes.previewRemoveDelegate(user, delegate: delegate) } }
                            .accessibilityLabel("Stop \(delegate) reading \(user.fullName)'s mail")
                    }
                }
                HStack {
                    TextField("Delegate address", text: $newDelegate, prompt: Text(verbatim: "assistant@example.com"))
                        .onSubmit(addDelegate)
                    Button("Add…", action: addDelegate)
                        .disabled(newDelegate.isEmpty)
                        .accessibilityLabel("Add a delegate to \(user.fullName)'s mailbox")
                }
            }
            .disabled(changes.isBusy)
        } else if let problem = access.problem(for: user.primaryEmail) {
            Section("Groups and delegates") {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } else if access.loading == user.primaryEmail {
            Section("Groups and delegates") {
                HStack { ProgressView().controlSize(.small); Text("Reading groups and delegates…") }
                    .accessibilityElement(children: .combine)
            }
        }
    }

    private func addGroup() {
        let group = newGroup
        Task {
            await changes.previewAddToGroup(user, group: group)
            if changes.previewing != nil { newGroup = "" }
        }
    }

    private func addDelegate() {
        let delegate = newDelegate
        Task {
            await changes.previewAddDelegate(user, delegate: delegate, directory: directory.users)
            if changes.previewing != nil { newDelegate = "" }
        }
    }
}

/// The person's auto-reply: on or off, in words, with Turn On / Change / Turn Off.
private struct AutoReplySection: View {
    let user: GamUser
    let vacation: Vacation
    let changes: UserChanges
    let edit: () -> Void

    var body: some View {
        Section("Auto-reply") {
            LabeledContent("Status", value: vacation.enabled ? "On" : "Off")
            if vacation.enabled {
                LabeledContent("Subject", value: vacation.subject.isEmpty ? "—" : vacation.subject)
                LabeledContent("From", value: vacation.start.isEmpty ? "Already started" : vacation.start)
                LabeledContent("Until", value: vacation.end.isEmpty ? "No end date" : vacation.end)
            }
            HStack {
                Button(vacation.enabled ? "Change…" : "Turn On…", action: edit)
                    .accessibilityLabel(vacation.enabled ? "Change \(user.fullName)'s auto-reply" : "Turn on \(user.fullName)'s auto-reply")
                if vacation.enabled {
                    Button("Turn Off…") { Task { await changes.previewAutoReplyOff(user) } }
                        .accessibilityLabel("Turn off \(user.fullName)'s auto-reply")
                }
            }
        }
        .disabled(changes.isBusy)
    }
}

/// GamGUI's vacation form: the stored reply's text pre-filled (its markup decoded), every setting shown,
/// then a preview of exactly what runs.
private struct AutoReplyEditor: View {
    let user: GamUser
    let changes: UserChanges
    let close: () -> Void
    @State private var subject: String
    @State private var text: String
    @State private var contactsOnly: Bool
    @State private var domainOnly: Bool
    @State private var hasStart: Bool
    @State private var start: Date
    @State private var hasEnd: Bool
    @State private var end: Date

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(user: GamUser, vacation: Vacation, changes: UserChanges, close: @escaping () -> Void) {
        self.user = user
        self.changes = changes
        self.close = close
        _subject = State(initialValue: vacation.enabled ? vacation.subject : "")
        _text = State(initialValue: vacation.enabled ? HTMLText.autoreplyText(vacation.message) : "")
        _contactsOnly = State(initialValue: vacation.contactsOnly)
        _domainOnly = State(initialValue: vacation.domainOnly)
        let startDate = Self.day.date(from: vacation.start), endDate = Self.day.date(from: vacation.end)
        _hasStart = State(initialValue: startDate != nil)
        _start = State(initialValue: startDate ?? .now)
        _hasEnd = State(initialValue: endDate != nil)
        _end = State(initialValue: endDate ?? .now)
    }

    var body: some View {
        Form {
            Section("\(user.fullName)'s auto-reply") {
                TextField("Subject", text: $subject)
                LabeledContent("Message") {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Message")
                }
            }
            Section("Who gets it") {
                Toggle("Only people in their contacts", isOn: $contactsOnly)
                Toggle("Only people in the organization", isOn: $domainOnly)
            }
            Section("When") {
                Toggle("Start on a date", isOn: $hasStart)
                if hasStart { DatePicker("Start", selection: $start, displayedComponents: .date) }
                Toggle("End on a date", isOn: $hasEnd)
                if hasEnd { DatePicker("End", selection: $end, displayedComponents: .date) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Preview") {
                    let start = hasStart ? Self.day.string(from: start) : "", end = hasEnd ? Self.day.string(from: end) : ""
                    let user = user, subject = subject, text = text, contactsOnly = contactsOnly, domainOnly = domainOnly
                    let changes = changes
                    close()
                    Task {
                        await changes.previewAutoReply(user, subject: subject, text: text, contactsOnly: contactsOnly,
                                                       domainOnly: domainOnly, start: start, end: end)
                    }
                }
                .disabled(subject.isEmpty)
            }
        }
    }
}

/// GamGUI's organization form: both fields, prefilled, then a preview of exactly what will run.
private struct RoleEditor: View {
    let user: GamUser
    let changes: UserChanges
    let close: () -> Void
    @State private var title: String
    @State private var department: String

    init(user: GamUser, changes: UserChanges, close: @escaping () -> Void) {
        self.user = user
        self.changes = changes
        self.close = close
        _title = State(initialValue: user.title)
        _department = State(initialValue: user.department)
    }

    var body: some View {
        Form {
            Section("\(user.fullName)'s title and department") {
                TextField("Title", text: $title)
                TextField("Department", text: $department)
            }
            Text("GAM sets the title and department together, so both are sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minWidth: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Preview") {
                    // Close first: the preview opens its own sheet.
                    let user = user, title = title, department = department, changes = changes
                    close()
                    Task { await changes.previewOrganization(of: user, title: title, department: department) }
                }
            }
        }
    }
}

/// What a confirm will run, exactly: the change in words, the command as GAM gets it (secrets masked),
/// how much it can hurt, then Cancel or the confirm. The confirmation is made here, in a screen, never
/// in code that also talks to Siri or a model (invariant 10, `WriteRouteTests`).
private struct ChangePreviewSheet: View {
    let pending: UserChanges.Pending
    let changes: UserChanges

    private func confirm() {
        Task { await changes.confirm(pending, OperatorConfirmation(confirmed: true)) }
    }

    var body: some View {
        Form {
            Section(pending.title) {
                ForEach(Array(pending.preview.steps.enumerated()), id: \.offset) { _, step in
                    Text(step.summary)
                    // The exact command is there for an admin who wants it, not the first thing to read.
                    DisclosureGroup("Show command") {
                        Text(step.shownArgv.joined(separator: " "))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let warning = pending.warning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Section {
                if pending.isDestructive {
                    Label("Destructive: confirm to run it.", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("A reversible change.", systemImage: "arrow.uturn.backward.circle")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { changes.dismiss() } }
            // A destructive change isn't confirmed by Return alone: it isn't the default button, so it has
            // to be chosen (clicked, or reached with Tab and Space).
            if pending.isDestructive {
                ToolbarItem(placement: .primaryAction) {
                    Button(pending.confirmLabel, role: .destructive) { confirm() }
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button(pending.confirmLabel) { confirm() }
                }
            }
        }
    }
}
