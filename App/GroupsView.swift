import Directory
import GamEngine
import Setup
import SwiftUI

/// Groups: the tenant's groups as a list, searched by name or address as GamGUI's finder is, with the
/// selected group's members beside it, owners first. From a group's page people are added with a role
/// and a member removed, each a preview first (`GroupChanges`).
struct GroupsView: View {
    let setup: SetupModel
    /// The directory's people, suggested when adding members.
    let directory: DirectoryStore
    let groups: GroupStore
    let members: GroupMembers
    let changes: GroupChanges
    @State private var query = ""
    @State private var selection: GamGroup.ID?
    /// Only the window in front speaks a load's outcome (every window sees the same groups).
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        content
            // Read when the screen is first shown for a tenant, not when a domain connects: GamGUI reads
            // groups when its board first needs them. Shown again, the list is the one already read.
            .task(id: setup.generation) {
                guard setup.active != nil, groups.groups == nil, groups.problem == nil else { return }
                await groups.load()
            }
            // Another tenant's group isn't this one's: its page closes.
            .onChange(of: setup.generation) { select(nil) }
            // A refresh can take the open group away (deleted elsewhere): its page closes rather than empty.
            .onChange(of: groups.loadedAt) {
                if let selection, groups.groups?.contains(where: { $0.id == selection }) != true { select(nil) }
                if let all = groups.groups { announce("\(all.count.formatted()) group\(all.count == 1 ? "" : "s") loaded.") }
            }
            .onChange(of: groups.problem) { _, problem in
                if let problem { announce("Couldn't load the groups. \(problem.summary)") }
            }
            .task(id: groups.groups?.count ?? 0) { selectForSnapshot() }
            .toolbar {
                ToolbarItem {
                    Button(groups.groups == nil ? "Load" : "Refresh", systemImage: "arrow.clockwise") {
                        Task { await groups.load() }
                    }
                    .keyboardShortcut("r")
                    .disabled(groups.isLoading || setup.active == nil)
                    .accessibilityIdentifier("groups.load")
                }
            }
    }

    /// The list's selection. A group's page opens and closes at once, without the inspector's slide, as a
    /// person's does on Users (on macOS 27 the slide drops frames below about 1,300 pt).
    private var selectionWithoutSlide: Binding<GamGroup.ID?> {
        Binding(get: { selection }, set: select)
    }

    private func select(_ id: GamGroup.ID?) {
        guard (id == nil) != (selection == nil) else {
            selection = id
            return
        }
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) { selection = id }
    }

    /// A nested group's page, from its row on another group's page. The search is cleared if it hid the row.
    private func show(_ group: GamGroup) {
        if groups.rows(query: query)?.contains(where: { $0.id == group.id }) != true { query = "" }
        select(group.id)
    }

    private func announce(_ text: String) {
        guard appearsActive else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` opens that group's page, for the snapshot of it.
    private func selectForSnapshot() {
        #if DEBUG
        guard selection == nil, let email = ProcessInfo.processInfo.environment["SWIFTGAMGUI_SELECT"],
              let group = groups.groups?.first(where: { $0.email == email }) else { return }
        selection = group.id
        #endif
    }

    /// The search as GamGUI compares it: stripped.
    private var searched: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder private var content: some View {
        // Searched once per list and search (`GroupStore.rows`), not on every click.
        if let all = groups.groups, let rows = groups.rows(query: query) {
            Table(rows, selection: selectionWithoutSlide) {
                TableColumn("Name") { group in Text(group.name.isEmpty ? group.email : group.name) }
                    .width(min: 120)
                TableColumn("Address") { group in Text(group.email) }
                    .width(min: 120)
            }
            .overlay {
                if rows.isEmpty {
                    Text(searched.isEmpty ? "No groups yet." : "No group matches “\(searched)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Group name or address")
            .safeAreaInset(edge: .bottom) {
                // A refresh shows here: running, or why it failed (the list above is the last good one).
                HStack(spacing: 12) {
                    Text(count(rows.count, of: all.count)).foregroundStyle(.secondary)
                    if groups.isLoading {
                        HStack { ProgressView().controlSize(.small); Text("Refreshing…").foregroundStyle(.secondary) }
                            .accessibilityElement(children: .combine)
                    }
                    if let problem = groups.problem {
                        Label(problem.summary, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).lineLimit(2)
                            .help(problem.detail ?? problem.summary)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { select(nil) } })) {
                if let group = all.first(where: { $0.id == selection }) {
                    GroupPage(group: group, store: groups, members: members, directory: directory, changes: changes,
                              show: show)
                }
            }
        } else {
            VStack(spacing: 12) {
                if groups.isLoading {
                    ProgressView("Loading groups…")
                } else if let domain = setup.reconnecting {
                    ProgressView("Connecting to \(domain.name)…")
                } else if let failure = setup.reconnectFailure, setup.active == nil {
                    Label("Couldn't reconnect to \(failure.domain.name)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failure.problem).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await setup.reconnect() } }
                        .disabled(setup.isBusy)
                } else if setup.active == nil {
                    Text("Connect a domain on Setup to list its groups.").foregroundStyle(.secondary)
                } else if let problem = groups.problem {
                    Label(problem.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    if let detail = problem.detail {
                        Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Button("Try Again") { Task { await groups.load() } }
                } else {
                    Text("Not loaded yet.").foregroundStyle(.secondary)
                    Button("Load Groups") { Task { await groups.load() } }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// "N of M groups · as of 9:41 AM".
    private func count(_ shown: Int, of all: Int) -> String {
        let counted = "\(shown.formatted()) of \(all.formatted()) group\(all == 1 ? "" : "s")"
        guard let loadedAt = groups.loadedAt else { return counted }
        return "\(counted) · as of \(loadedAt.formatted(date: .omitted, time: .shortened))"
    }
}

/// One group: its name as the page's heading, its address, and its members, owners first, with a search,
/// Add Members… and a Remove… per member. The members are read each time the page opens, as GamGUI's panel
/// reads them, and again after each change.
private struct GroupPage: View {
    let group: GamGroup
    /// The tenant's groups, so a nested group's row can open its page.
    let store: GroupStore
    let members: GroupMembers
    let directory: DirectoryStore
    let changes: GroupChanges
    let show: (GamGroup) -> Void
    @State private var query = ""
    /// The Add Members sheet is open. Its fields live here, so going back from the preview to edit them
    /// keeps what was typed.
    @State private var adding = false
    @State private var addresses = ""
    @State private var role = GamCommands.GroupRole.member
    @State private var peopleSearch = ""
    @State private var debugApplied = false
    /// Only the window in front speaks a change's result.
    @Environment(\.appearsActive) private var appearsActive
    /// The group whose members this page last had: if they go (another window read eight more groups),
    /// the page reads them again rather than sit at "Not read."
    @State private var readFor: GamGroup.ID?
    /// Show Group was used: the new page's heading takes the focus, and VoiceOver says which group.
    @State private var focusNext = false
    @AccessibilityFocusState private var headingFocused: Bool

    private var title: String { group.name.isEmpty ? group.email : group.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                Text(group.email).foregroundStyle(.secondary).textSelection(.enabled)
                if !group.description.isEmpty { Text(group.description).foregroundStyle(.secondary) }
                Button(action: openAdd) {
                    Label("Add Members…", systemImage: "person.badge.plus")
                }
                .disabled(changes.isBusy)
                .accessibilityLabel("Add members to \(title)")
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            if changes.concerns(group.email) { GroupResult(changes: changes) }
            TextField("Find a member", text: $query, prompt: Text("Address or role"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Find a member of \(title)")
                .padding(.horizontal)
                .padding(.bottom, 8)
            memberList
        }
        // Long values wrap or clip rather than widen the inspector past its bounds (ColumnWidths).
        .frame(minWidth: 0, maxWidth: .infinity)
        .inspectorColumnWidth(min: ColumnWidths.inspector.min, ideal: ColumnWidths.inspector.ideal,
                              max: ColumnWidths.inspector.max)
        // Read each time a group is opened; a quarter second later, so arrowing down the list starts no gam
        // for the groups passed over, and none as the page appears.
        .task(id: group.id) { await members.load(group.email, after: .milliseconds(250)) }
        .onChange(of: group.id) {
            query = ""
            addresses = ""
            peopleSearch = ""
            role = .member
            if focusNext {
                focusNext = false
                headingFocused = true
                AccessibilityNotification.Announcement("Showing \(title)").post()
            }
        }
        .onChange(of: hasRead, initial: true) { _, has in
            if has {
                readFor = group.id
                openForSnapshot()
            } else if readFor == group.id, !members.isReading(group.email) {
                readFor = nil
                Task { await members.load(group.email) }
            }
        }
        // One sheet: the Add Members form, then the preview it held (Cancel there goes back to the form), or a
        // removal's preview alone. It closes when the change starts running and its result shows on the page.
        .sheet(isPresented: sheetShown) {
            if let pending = changes.sheetPending(for: group.email) {
                GroupPreviewSheet(pending: pending, changes: changes)
            } else {
                AddMembersForm(title: title, group: group, directory: directory, changes: changes, addresses: $addresses,
                               role: $role, search: $peopleSearch) { adding = false }
            }
        }
        .onChange(of: changes.isBusy) { _, busy in
            guard busy, changes.concerns(group.email) else { return }
            adding = false
            addresses = ""
            peopleSearch = ""
        }
        // Said once, from the window in front.
        .onChange(of: changes.announcement) { _, text in
            if let text, appearsActive, changes.concerns(group.email) { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private var sheetShown: Binding<Bool> {
        Binding(get: { adding || changes.sheetPending(for: group.email) != nil },
                set: { shown in
                    guard !shown else { return }
                    adding = false
                    changes.dismissPreview()
                })
    }

    /// A fresh form: an earlier result or refusal is put away first.
    private func openAdd() {
        changes.dismiss()
        adding = true
    }

    /// Debug builds: `SWIFTGAMGUI_TAB` opens a sheet over the page for its snapshot, once: `add` the form
    /// with an address and a search typed, `remove` the preview of removing the first member.
    private func openForSnapshot() {
        #if DEBUG
        guard !debugApplied, let sheet = ProcessInfo.processInfo.environment["SWIFTGAMGUI_TAB"] else { return }
        debugApplied = true
        switch sheet {
        case "add":
            addresses = "carol@example.com"
            peopleSearch = "a"
            adding = true
        case "remove":
            if let first = members.members(of: group.email)?.first { Task { await changes.previewRemove(first, from: group) } }
        default:
            break
        }
        #endif
    }

    /// The page has this group's members, or why they couldn't be read.
    private var hasRead: Bool {
        members.members(of: group.email) != nil || members.problem(for: group.email) != nil
    }

    /// The search as GamGUI compares it: stripped.
    private var searched: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder private var memberList: some View {
        if let all = members.members(of: group.email), let rows = members.rows(group.email, query: query) {
            List {
                Section {
                    if rows.isEmpty {
                        Text(searched.isEmpty ? "No members yet — add someone with Add Members." : "No member matches “\(searched)”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { member in
                        MemberRow(member: member, nested: nested(member), group: title, busy: changes.isBusy,
                                  remove: member.email.isEmpty ? nil : { Task { await changes.previewRemove(member, from: group) } }) { nested in
                            focusNext = true
                            show(nested)
                        }
                    }
                } header: {
                    Text(searched.isEmpty ? "\(all.count.formatted()) member\(all.count == 1 ? "" : "s")"
                         : "\(rows.count.formatted()) of \(all.count.formatted()) member\(all.count == 1 ? "" : "s") match “\(searched)”")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // Never a spinner with no read behind it: reading, or why the last read failed, or not read.
                if members.isReading(group.email) {
                    HStack { ProgressView().controlSize(.small); Text("Reading members…") }
                        .accessibilityElement(children: .combine)
                } else if let problem = members.problem(for: group.email) {
                    Label(problem.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    if let detail = problem.detail {
                        Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    readAgain
                } else {
                    HStack { Text("Not read.").foregroundStyle(.secondary); readAgain }
                }
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var readAgain: some View {
        Button("Read Again") { Task { await members.load(group.email) } }
            .accessibilityLabel("Read Again: \(title)'s members")
    }

    /// The tenant's group this member is, when it is one (GamGUI links a nested group to its board).
    private func nested(_ member: GroupMember) -> GamGroup? {
        guard member.memberType == "GROUP", !member.email.isEmpty else { return nil }
        return store.group(at: member.email)
    }
}

/// A member: their address (or, for everyone in the organization, GAM's word for it), their role in words,
/// and whether they're a group or suspended, never by color alone; Remove… when they have an address.
private struct MemberRow: View {
    let member: GroupMember
    let nested: GamGroup?
    /// The group's name, for the controls' names ("Remove alice@example.com from Sales").
    let group: String
    let busy: Bool
    let remove: (() -> Void)?
    let show: (GamGroup) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(member.email.isEmpty ? member.memberType.lowercased() : member.email)
                    .lineLimit(1).truncationMode(.middle)
                Text(details).font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if let nested {
                Button("Show Group") { show(nested) }
                    .accessibilityLabel("Show Group \(nested.email)")
            }
            if let remove {
                Button(action: remove) {
                    Label("Remove…", systemImage: "person.badge.minus")
                }
                .buttonStyle(.borderless)
                .disabled(busy)
                .accessibilityLabel("Remove \(member.email) from \(group)")
            }
        }
    }

    /// The role as a word, then a nested group or a suspended account said so.
    private var details: String {
        var words = [role]
        if member.memberType == "GROUP" { words.append("group") }
        if member.status.uppercased() == "SUSPENDED" { words.append("suspended") }
        return words.joined(separator: " · ")
    }

    private var role: String {
        switch member.role {
        case "OWNER": "Owner"
        case "MANAGER": "Manager"
        case "MEMBER": "Member"
        default: member.role.prefix(1).uppercased() + member.role.dropFirst().lowercased()
        }
    }
}

/// Add Members: addresses typed (one per line, or separated by commas), or people chosen from the directory
/// (GamGUI's type-ahead: a name or address, the first 15), and a role. Preview holds them as one change;
/// what it holds is shown and confirmed in `GroupPreviewSheet`. A refusal is said here, in words.
private struct AddMembersForm: View {
    let title: String
    let group: GamGroup
    let directory: DirectoryStore
    let changes: GroupChanges
    @Binding var addresses: String
    @Binding var role: GamCommands.GroupRole
    @Binding var search: String
    let close: () -> Void
    @FocusState private var addressesFocused: Bool

    private var people: (shown: [GamUser], more: Bool) {
        GroupChanges.people(matching: search, in: directory.users ?? [])
    }

    var body: some View {
        Form {
            Section {
                TextField("Addresses", text: $addresses, prompt: Text(verbatim: "person@example.com"), axis: .vertical)
                    .lineLimit(2...6)
                    .focused($addressesFocused)
                    .accessibilityHint("Separate addresses with commas or new lines.")
                Text("Separate addresses with commas or new lines.").font(.callout).foregroundStyle(.secondary)
                Picker("Role", selection: $role) {
                    ForEach(GamCommands.GroupRole.allCases, id: \.self) { role in
                        Text(role.rawValue.prefix(1).uppercased() + role.rawValue.dropFirst()).tag(role)
                    }
                }
            } header: {
                Text("Add to \(title)").accessibilityAddTraits(.isHeader)
            }
            Section("Choose from the directory") {
                TextField("Find people", text: $search, prompt: Text("Name or address"))
                    .accessibilityLabel("Find people in the directory")
                if directory.users == nil {
                    Text("The directory isn't loaded, so there are no suggestions: type the addresses.")
                        .foregroundStyle(.secondary)
                } else if !isBlank(search) {
                    let people = people
                    if people.shown.isEmpty {
                        Text("No one in the directory matches “\(search.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(people.shown) { person in
                        Button { choose(person) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.fullName)
                                    Text(person.suspended ? "\(person.primaryEmail) · suspended" : person.primaryEmail)
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle").accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(person.fullName), \(person.primaryEmail)\(person.suspended ? ", suspended" : ""), to the addresses")
                    }
                    if people.more {
                        Text("Showing the first \(GroupChanges.pickLimit) — keep typing to narrow.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if case .problem(let problem) = changes.state, changes.concerns(group.email) {
                Section {
                    Label(problem.summary, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 460)
        .onAppear { addressesFocused = true }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Preview…") { Task { await changes.previewAdd(addresses, to: group, role: role) } }
                    .disabled(isBlank(addresses) || changes.isBusy)
                    .accessibilityHint("Shows exactly what will change, to confirm.")
            }
        }
    }

    /// The person's address goes on the list, on its own line; said, since the list may be out of view.
    private func choose(_ person: GamUser) {
        let text = addresses.trimmingCharacters(in: .whitespacesAndNewlines)
        addresses = text.isEmpty ? person.primaryEmail : text + "\n" + person.primaryEmail
        AccessibilityNotification.Announcement("Added \(person.primaryEmail) to the addresses.").post()
    }
}

/// Whether text is only white space, for a control's enabled state (the model strips as GamGUI does).
private func isBlank(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
}

/// The last change's result on its group's page: running, done, or why not, with GAM's own error one click
/// away. The list below is already the one read after it.
private struct GroupResult: View {
    let changes: GroupChanges

    var body: some View {
        switch changes.state {
        case .running(let pending):
            banner(tint: .blue) {
                ProgressView().controlSize(.small)
                Text(running(pending)).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .done(let message):
            banner(tint: .green) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                Text(message).frame(maxWidth: .infinity, alignment: .leading)
                dismiss
            }
        case .problem(let problem):
            banner(tint: .orange) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
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

    private func running(_ pending: GroupChanges.Pending) -> String {
        guard pending.isAdding else { return "Removing \(pending.members.first ?? "") from \(pending.group)…" }
        return pending.members.count == 1 ? "Adding \(pending.members[0]) to \(pending.group)…"
                                          : "Adding \(pending.members.count) people to \(pending.group)…"
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
            .padding(.horizontal)
            .padding(.bottom, 8)
    }
}

extension GroupChanges {
    /// What the result says, for the one announcement of it.
    var announcement: String? {
        switch state {
        case .done(let message): message
        case .problem(let problem): problem.summary
        case .idle, .previewing, .running: nil
        }
    }
}
