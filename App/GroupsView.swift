import Directory
import GamEngine
import Setup
import SwiftUI

/// Groups: the tenant's groups as a list, searched by name or address as GamGUI's finder is, with the
/// selected group's members beside it, owners first. Read-only for now: adding and removing members from
/// here is the next slice (a person's own groups change on their page in Users).
struct GroupsView: View {
    let setup: SetupModel
    let groups: GroupStore
    let members: GroupMembers
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
                    GroupPage(group: group, store: groups, members: members, show: show)
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

/// One group: its name as the page's heading, its address, and its members, owners first, with a search.
/// The members are read each time the page opens, as GamGUI's panel reads them.
private struct GroupPage: View {
    let group: GamGroup
    /// The tenant's groups, so a nested group's row can open its page.
    let store: GroupStore
    let members: GroupMembers
    let show: (GamGroup) -> Void
    @State private var query = ""
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
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
            if focusNext {
                focusNext = false
                headingFocused = true
                AccessibilityNotification.Announcement("Showing \(title)").post()
            }
        }
        .onChange(of: hasRead, initial: true) { _, has in
            if has {
                readFor = group.id
            } else if readFor == group.id, !members.isReading(group.email) {
                readFor = nil
                Task { await members.load(group.email) }
            }
        }
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
                        Text(searched.isEmpty ? "No members yet." : "No member matches “\(searched)”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { member in
                        MemberRow(member: member, nested: nested(member)) { nested in
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
/// and whether they're a group or suspended, never by color alone.
private struct MemberRow: View {
    let member: GroupMember
    let nested: GamGroup?
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
