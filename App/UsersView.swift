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

    /// The list's selection. A person's page opens and closes at once, without the inspector's slide: on
    /// macOS 27, below about 1,300 pt, every frame of the slide lays the window's content out wider than
    /// the window, and the page stuttered in (measured with a copy of this layout: 7 or 8 runs of dropped
    /// frames per opening; none without the slide). Moving from one person to another changes nothing
    /// the slide would animate.
    private var selectionWithoutSlide: Binding<GamUser.ID?> {
        Binding(get: { selection }, set: select)
    }

    private func select(_ id: GamUser.ID?) {
        guard (id == nil) != (selection == nil) else {
            selection = id
            return
        }
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) { selection = id }
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
        // Filtered and sorted once per list, filter and order (`DirectoryStore.rows`), not on every click.
        if let users = directory.users, let rows = directory.rows(filter, sortedBy: sortOrder) {
            UsersTable(rows: rows, selection: selectionWithoutSlide, sortOrder: $sortOrder)
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
            .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { select(nil) } })) {
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

/// The Users list's columns. The raw values key the saved layout: renaming one forgets its width and
/// whether it shows.
enum UserColumn: String, CaseIterable, Identifiable {
    case name, status, address, title, department, orgUnit

    var id: Self { self }

    var label: String {
        switch self {
        case .name: "Name"
        case .status: "Status"
        case .address: "Address"
        case .title: "Title"
        case .department: "Department"
        case .orgUnit: "Organizational Unit"
        }
    }

    /// Every column but Name, which always shows, first.
    static var hideable: [UserColumn] { allCases.filter { $0 != .name } }

    private static let key = "usersHiddenColumns"

    /// This launch's layout (widths, order, which show), kept while the app runs: leaving Users and coming
    /// back doesn't reset it. Only which columns are hidden outlasts the app.
    @MainActor static var session: TableColumnCustomization<GamUser>?

    /// The columns the operator hid, kept in the app's preferences: windows aren't restored
    /// (`restorationBehavior(.disabled)`), so scene storage would forget them at every launch. Only which
    /// columns are hidden is kept, not widths or order: the table rewrites widths by itself whenever the
    /// list narrows or widens (17 times in three openings of a page, measured), which saved squeezed
    /// widths as the operator's choice (failure-log 2026-10-10, "table saved its own widths"). A debug spike or snapshot reads and writes
    /// none of the operator's.
    static func saved() -> TableColumnCustomization<GamUser> {
        var columns = TableColumnCustomization<GamUser>()
        guard !Spikes.isRequested else { return columns }
        UserDefaults.standard.removeObject(forKey: "usersTableColumns")   // PR #29's whole layout
        let hidden = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        for column in hideable where hidden.contains(column.rawValue) { columns[visibility: column.rawValue] = .hidden }
        return columns
    }

    /// The hidden columns' keys, in a fixed order.
    static func hidden(in columns: TableColumnCustomization<GamUser>) -> [String] {
        hideable.filter { columns[visibility: $0.rawValue] == .hidden }.map(\.rawValue)
    }

    /// One list's change, applied to what's saved: a second window with an older set changes only the
    /// column toggled in it.
    static func save(hiding: Set<String>, showing: Set<String>) {
        guard !Spikes.isRequested else { return }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: key) ?? []).subtracting(showing).union(hiding)
        UserDefaults.standard.set(hideable.map(\.rawValue).filter(hidden.contains), forKey: key)
    }
}

/// The list itself, in the columns the operator chose. The same columns whether or not a person's page is
/// open: a list that dropped four of them when a name was clicked read as lost headers, and rebuilt the
/// table while the page slid in. Beside the page, the list scrolls sideways. Its own view, so a column
/// dragged wider redraws only the list.
private struct UsersTable: View {
    let rows: [GamUser]
    @Binding var selection: GamUser.ID?
    @Binding var sortOrder: [KeyPathComparator<GamUser>]
    @State private var columns = UserColumn.session ?? UserColumn.saved()

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            // Every row keeps its name: Name can't be hidden, or dragged from the front.
            TableColumn(UserColumn.name.label, value: \.fullName)
                .width(min: 160)
                .customizationID(UserColumn.name.rawValue)
                .disabledCustomizationBehavior([.visibility, .reorder])
            // Wide enough for "Suspended" in full: the word, not only its color.
            TableColumn(UserColumn.status.label) { user in
                Text(user.suspended ? "Suspended" : "Active")
                    .foregroundStyle(user.suspended ? .orange : .primary)
            }
            .width(min: 84, max: 120)
            .customizationID(UserColumn.status.rawValue)
            TableColumn(UserColumn.address.label, value: \.primaryEmail)
                .width(min: 120)
                .customizationID(UserColumn.address.rawValue)
            TableColumn(UserColumn.title.label, value: \.title)
                .width(min: 60)
                .customizationID(UserColumn.title.rawValue)
            TableColumn(UserColumn.department.label, value: \.department)
                .width(min: 60)
                .customizationID(UserColumn.department.rawValue)
            TableColumn(UserColumn.orgUnit.label, value: \.orgUnitPath)
                .width(min: 60)
                .customizationID(UserColumn.orgUnit.rawValue)
        }
        .toolbar {
            ToolbarItem {
                // The header's right-click menu, from the keyboard and VoiceOver too.
                Menu("Columns", systemImage: "tablecells") {
                    ForEach(UserColumn.hideable) { column in
                        Toggle(column.label, isOn: shown(column))
                    }
                    Divider()
                    Button("Show All Columns") {
                        for column in UserColumn.hideable { columns[visibility: column.rawValue] = .visible }
                    }
                    Button("Restore Column Order") { columns.resetOrder() }
                }
                .accessibilityHint("Choose which columns the list of users shows.")
            }
        }
        .onChange(of: columns) { _, new in UserColumn.session = new }
        // Saved when the operator hides or shows one, never on the table's own width changes, and only
        // what changed: a second window can't put back what the first changed.
        .onChange(of: UserColumn.hidden(in: columns)) { old, new in
            UserColumn.save(hiding: Set(new).subtracting(old), showing: Set(old).subtracting(new))
        }
    }

    /// Shown unless the operator hid it: a column never touched reads `.automatic`, which shows.
    private func shown(_ column: UserColumn) -> Binding<Bool> {
        Binding(get: { columns[visibility: column.rawValue] != .hidden },
                set: { columns[visibility: column.rawValue] = $0 ? .visible : .hidden })
    }
}

/// The person page's sections, as tabs: a long single column was hard to find things in. The names stay
/// short: the segmented control is as wide as its labels, and the panel can be narrow.
enum PersonTab: String, CaseIterable, Identifiable {
    case profile = "Profile"
    case groups = "Groups"
    /// The auto-reply and who can read the mailbox (Gmail delegates).
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
        // Long values wrap or clip rather than widen the inspector past its bounds (ColumnWidths).
        .frame(minWidth: 0, maxWidth: .infinity)
        .inspectorColumnWidth(min: ColumnWidths.inspector.min, ideal: ColumnWidths.inspector.ideal,
                              max: ColumnWidths.inspector.max)
        // Read when the person is selected, and again after a change of theirs lands; a quarter second later,
        // so arrowing down the list starts no gam for the people passed over, and none as the page appears.
        .task(id: "\(user.id)#\(changes.finished)") { await access.load(user.primaryEmail, after: .milliseconds(250)) }
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
        guard let date = (try? Date(value, strategy: withFraction)) ?? (try? Date(value, strategy: .iso8601))
        else { return value }
        guard date.timeIntervalSince1970 > 0 else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Made once, not on every redraw of the page.
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

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
        case .groups:
            AccessList(kind: .groups, user: user, directory: directory, changes: changes, access: access,
                       newAddress: $newGroup)
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
                    if let problem = access.problem(for: user.primaryEmail) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        NotRead(what: "the auto-reply", user: user, access: access)
                    }
                }
            }
            AccessList(kind: .delegates, user: user, directory: directory, changes: changes, access: access,
                       newAddress: $newDelegate)
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

/// A person's lists not in hand: reading (in words, for VoiceOver too), or not read, with a way to read
/// them. Never a spinner with no read behind it.
private struct NotRead: View {
    let what: String
    let user: GamUser
    let access: UserAccess

    var body: some View {
        if access.isReading(user.primaryEmail) {
            HStack { ProgressView().controlSize(.small); Text("Reading \(what)…") }
                .accessibilityElement(children: .combine)
        } else {
            HStack {
                Text("Not read.").foregroundStyle(.secondary)
                Button("Read Again") { Task { await access.load(user.primaryEmail) } }
                    .accessibilityLabel("Read \(user.fullName)'s groups, delegates and auto-reply again")
            }
        }
    }
}

/// The person's groups, or their mail delegates: each with Remove, and a field to add one. Every change
/// is a preview first (`UserChanges`).
private struct AccessList: View {
    enum Kind { case groups, delegates }
    let kind: Kind
    let user: GamUser
    let directory: DirectoryStore
    let changes: UserChanges
    let access: UserAccess
    @Binding var newAddress: String

    var body: some View {
        if let lists = access.lists(for: user.primaryEmail) {
            switch kind {
            case .groups: groups(lists.groups)
            case .delegates: delegates(lists.delegates)
            }
        } else if let problem = access.problem(for: user.primaryEmail) {
            Section(heading) {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } else {
            Section(heading) { NotRead(what: heading.lowercased(), user: user, access: access) }
        }
    }

    private var heading: String { kind == .groups ? "Groups" : "Mail delegates" }

    private func groups(_ groups: [String]) -> some View {
        Section(heading) {
            if groups.isEmpty { Text("Not in any group.").foregroundStyle(.secondary) }
            ForEach(groups, id: \.self) { group in
                LabeledContent(group) {
                    Button("Remove…") { Task { await changes.previewRemoveFromGroup(user, group: group) } }
                        .accessibilityLabel("Remove \(user.fullName) from \(group)")
                }
            }
            HStack {
                TextField("Group address", text: $newAddress, prompt: Text(verbatim: "sales@example.com"))
                    .onSubmit(add)
                Button("Add…", action: add)
                    .disabled(newAddress.isEmpty)
                    .accessibilityLabel("Add \(user.fullName) to the group")
            }
        }
        .disabled(changes.isBusy)
    }

    private func delegates(_ delegates: [String]) -> some View {
        Section(heading) {
            if delegates.isEmpty { Text("No one can read this mailbox.").foregroundStyle(.secondary) }
            ForEach(delegates, id: \.self) { delegate in
                LabeledContent(delegate) {
                    Button("Remove…") { Task { await changes.previewRemoveDelegate(user, delegate: delegate) } }
                        .accessibilityLabel("Stop \(delegate) reading \(user.fullName)'s mail")
                }
            }
            HStack {
                TextField("Delegate address", text: $newAddress, prompt: Text(verbatim: "assistant@example.com"))
                    .onSubmit(add)
                Button("Add…", action: add)
                    .disabled(newAddress.isEmpty)
                    .accessibilityLabel("Add a delegate to \(user.fullName)'s mailbox")
            }
        }
        .disabled(changes.isBusy)
    }

    private func add() {
        let address = newAddress
        Task {
            switch kind {
            case .groups: await changes.previewAddToGroup(user, group: address)
            case .delegates: await changes.previewAddDelegate(user, delegate: address, directory: directory.users)
            }
            if changes.previewing != nil { newAddress = "" }
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
