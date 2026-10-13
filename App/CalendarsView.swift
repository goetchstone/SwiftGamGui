import Directory
import GamEngine
import Setup
import SwiftUI

/// Calendars: the tenant's rooms, or one person's calendars, as a list (GamGUI's Calendars screen), with the
/// chosen calendar's page beside it: who has access and at what role, sharing with one person and taking
/// access away. Rooms are read when the list is first shown; a person's calendars when they're chosen; a
/// calendar's access each time its page opens and after each change.
struct CalendarsView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let reads: CalendarReads
    let changes: CalendarChanges
    /// A person another screen sent (Users' "Show Their Calendars…").
    @Binding var requested: String?
    @State private var source = Source.rooms
    @State private var query = ""
    /// The chosen person's address; empty for none, as GamGUI's field starts.
    @State private var person = ""
    @State private var selection: String?
    /// Only the window in front speaks a load's outcome (every window sees the same reads).
    @Environment(\.appearsActive) private var appearsActive

    enum Source: String, CaseIterable, Identifiable {
        case rooms = "Rooms", person = "Person"

        var id: Self { self }
    }

    /// A room, or a calendar in the person's list: GamGUI's row (`_calendar_list.html`).
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let details: String
    }

    /// The read the list shows; nil until a person is chosen.
    private var listRead: CalendarReads.Read? {
        switch source {
        case .rooms: .rooms
        case .person: person.isEmpty ? nil : .calendars(of: person)
        }
    }

    /// Every row the list read, before the room search.
    private var allRows: [Row]? {
        switch source {
        case .rooms: reads.rooms()?.filter { !$0.email.isEmpty }.map(Self.row)
        case .person: person.isEmpty ? nil : reads.calendars(of: person)?.map(Self.row)
        }
    }

    /// The rows shown: GamGUI's room search for rooms (`ResourceCalendar.search`), a person's list whole.
    private var rows: [Row]? {
        switch source {
        case .rooms: reads.rooms(matching: query)?.map(Self.row)
        case .person: allRows
        }
    }

    static func row(_ room: ResourceCalendar) -> Row { Row(id: room.email, label: room.label, details: room.details) }
    static func row(_ calendar: UserCalendar) -> Row { Row(id: calendar.calendarID, label: calendar.label, details: calendar.details) }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            list
        }
        // The list clips rather than widen the screen past the window when a calendar's page is open
        // (failure-log 2026-10-10, "person-page layout loop").
        .frame(minWidth: 0, maxWidth: .infinity)
        // Rooms are read when Rooms is first shown for a tenant, a person's calendars when they're chosen.
        .task(id: "\(setup.generation)#\(source.rawValue)#\(person)") { await loadIfNeeded() }
        .onChange(of: setup.generation) { select(nil) }
        .onChange(of: source) { select(nil) }
        .onChange(of: person) { select(nil) }
        .onChange(of: requested, initial: true) { _, email in
            guard let email else { return }
            source = .person
            person = email
            requested = nil
        }
        .onChange(of: listRead.flatMap { reads.revision(of: $0) }) { _, revision in
            guard revision != nil, let read = listRead else { return }
            if let problem = reads.problem(for: read) {
                announce("Couldn't read the \(source == .rooms ? "rooms" : "calendars"). \(problem.summary)")
            } else if let count = allRows?.count {
                announce(source == .rooms ? "\(count) room\(count == 1 ? "" : "s") read." : "\(count) calendar\(count == 1 ? "" : "s") read.")
            }
        }
        .task(id: allRows?.count ?? -1) { selectForSnapshot() }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    if let read = listRead { Task { await reads.load(read) } }
                }
                .keyboardShortcut("r")
                .disabled(setup.active == nil || listRead.map(reads.isReading) ?? true)
                .accessibilityIdentifier("calendars.load")
            }
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { select(nil) } })) {
            if let row = allRows?.first(where: { $0.id == selection }) {
                CalendarPage(row: row, reads: reads, changes: changes)
            }
        }
    }

    private func loadIfNeeded() async {
        guard setup.active != nil, let read = listRead, reads.revision(of: read) == nil, !reads.isReading(read) else { return }
        await reads.load(read)
    }

    /// A calendar's page opens and closes at once, without the inspector's slide (as Users' and Groups' do).
    private var selectionWithoutSlide: Binding<String?> {
        Binding(get: { selection }, set: select)
    }

    private func select(_ id: String?) {
        guard (id == nil) != (selection == nil) else {
            selection = id
            return
        }
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) { selection = id }
    }

    private func announce(_ text: String) {
        guard appearsActive else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` chooses that person and `SWIFTGAMGUI_CALENDAR` opens that calendar's
    /// page, for the snapshots.
    private func selectForSnapshot() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if person.isEmpty, let email = environment["SWIFTGAMGUI_SELECT"] {
            source = .person
            person = email
        }
        if selection == nil, let id = environment["SWIFTGAMGUI_CALENDAR"], allRows?.contains(where: { $0.id == id }) == true {
            selection = id
        }
        #endif
    }

    /// Rooms or a person, then the room search or the person.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Show rooms or a person's calendars")
            switch source {
            case .rooms:
                TextField("Find a room", text: $query, prompt: Text("Room name, address or ID"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel("Find a room")
            case .person:
                PersonPicker(directory: directory, person: $person)
            }
        }
        .padding()
    }

    /// The search as GamGUI compares it: stripped.
    private var searched: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder private var list: some View {
        if let rows {
            List(rows, selection: selectionWithoutSlide) { row in
                CalendarRow(row: row)
            }
            .overlay {
                if rows.isEmpty {
                    Text(source == .person ? "No calendars." : searched.isEmpty ? "No rooms or resources." : "No calendar matches “\(searched)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Text(count(rows.count)).foregroundStyle(.secondary)
                    if let read = listRead, reads.isReading(read) {
                        HStack { ProgressView().controlSize(.small); Text("Refreshing…").foregroundStyle(.secondary) }
                            .accessibilityElement(children: .combine)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        } else {
            VStack(spacing: 12) {
                if let domain = setup.reconnecting {
                    ProgressView("Connecting to \(domain.name)…")
                } else if let failure = setup.reconnectFailure, setup.active == nil {
                    Label("Couldn't reconnect to \(failure.domain.name)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failure.problem).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await setup.reconnect() } }
                        .disabled(setup.isBusy)
                } else if setup.active == nil {
                    Text("Connect a domain on Setup to see its calendars.").foregroundStyle(.secondary)
                } else if let read = listRead {
                    if reads.isReading(read) {
                        ProgressView(source == .rooms ? "Reading the rooms…" : "Reading \(person)'s calendars…")
                    } else if let problem = reads.problem(for: read) {
                        Label(problem.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        if let detail = problem.detail {
                            Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Button("Try Again") { Task { await reads.load(read) } }
                    } else {
                        Text("Not read.").foregroundStyle(.secondary)
                        Button(source == .rooms ? "Read the Rooms" : "Read Their Calendars") { Task { await reads.load(read) } }
                    }
                } else {
                    Text("Choose a person to see their calendars.").foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// "3 rooms" / "5 of 7 rooms match" / "6 calendars".
    private func count(_ shown: Int) -> String {
        guard source == .rooms else { return "\(shown) calendar\(shown == 1 ? "" : "s")" }
        let all = allRows?.count ?? shown
        return searched.isEmpty ? "\(all) room\(all == 1 ? "" : "s")" : "\(shown) of \(all) room\(all == 1 ? "" : "s")"
    }
}

/// The directory's people, by address in code-point order (GamGUI's lists), a suspended one said so; nobody
/// chosen at first. Its own view, so the directory is sorted again only when it or the choice changes.
private struct PersonPicker: View {
    let directory: DirectoryStore
    @Binding var person: String

    var body: some View {
        if let users = directory.users {
            let people = users.sorted { $0.primaryEmail.unicodeScalars.lexicographicallyPrecedes($1.primaryEmail.unicodeScalars) }
            Picker("Person", selection: $person) {
                Text("Choose a person").tag("")
                ForEach(people) { user in
                    Text(user.suspended ? "\(user.primaryEmail) (suspended)" : user.primaryEmail).tag(user.primaryEmail)
                }
                // Sent from another screen but not in the list: still shown as chosen.
                if !person.isEmpty, !people.contains(where: { $0.primaryEmail == person }) {
                    Text(person).tag(person)
                }
            }
            .accessibilityLabel("Person whose calendars to list")
        } else {
            Text("Load the directory (Home or Users) to choose a person.").foregroundStyle(.secondary)
        }
    }
}

/// One row: the name above the ID, each truncating on its own (GamGUI failure-log 2026-09-15), then the
/// details; read by VoiceOver as one sentence.
private struct CalendarRow: View {
    let row: CalendarsView.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.label).lineLimit(1).truncationMode(.tail)
            Text(row.id).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if !row.details.isEmpty {
                Text(row.details).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.label, row.id, row.details].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

/// One calendar: its name as the heading, its ID, who has access at what role (read each time the page opens,
/// GamGUI's detail panel), a Remove on each rule that isn't an owner's, and GamGUI's share form. Every change
/// opens its preview first (`CalendarChanges`).
private struct CalendarPage: View {
    let row: CalendarsView.Row
    let reads: CalendarReads
    let changes: CalendarChanges
    /// The calendar this page last had access rules for: if they go (sixteen more reads since), it reads again.
    @State private var readFor: String?
    @State private var target = ""
    /// GamGUI's picker starts on "See all details".
    @State private var role = GamCommands.CalendarRole.reader.rawValue

    private var read: CalendarReads.Read { .access(calendar: row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(row.id).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            if changes.concerns(row.id) { CalendarResultBanner(changes: changes) }
            if reads.access(read) != nil { shareForm }
            CalendarAccessList(read: read, reads: reads, empty: "No access rules returned.", calendarName: row.label,
                               busy: changes.isBusy) { rule in
                Task { await changes.previewUnshare(calendarID: row.id, name: row.label, rule: rule) }
            }
        }
        // Long values wrap or clip rather than widen the inspector past its bounds (ColumnWidths).
        .frame(minWidth: 0, maxWidth: .infinity)
        .inspectorColumnWidth(min: ColumnWidths.inspector.min, ideal: ColumnWidths.inspector.ideal,
                              max: ColumnWidths.inspector.max)
        // A quarter second later, so arrowing down the list starts no gam for the calendars passed over.
        .task(id: row.id) { await reads.load(read, after: .milliseconds(250)) }
        .onChange(of: row.id) { target = "" }
        .onChange(of: reads.access(read) != nil || reads.problem(for: read) != nil, initial: true) { _, has in
            if has {
                readFor = row.id
            } else if readFor == row.id, !reads.isReading(read) {
                readFor = nil
                Task { await reads.load(read) }
            }
        }
        .sheet(item: Binding(get: { changes.sheetPending(for: row.id) }, set: { if $0 == nil { changes.dismissPreview() } })) { pending in
            CalendarPreviewSheet(pending: pending, changes: changes)
        }
    }

    /// GamGUI's share form: one person's address and the access, then a preview.
    private var shareForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Share with", text: $target, prompt: Text(verbatim: "person@example.com"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(share)
                .accessibilityLabel("Share \(row.label) with (email)")
            HStack {
                Picker("Access", selection: $role) {
                    ForEach(CalendarSharing.pickerRoles, id: \.role) { choice in
                        Text(choice.label).tag(choice.role.rawValue)
                    }
                }
                .fixedSize()
                .accessibilityLabel("Access to give")
                Spacer()
                Button("Share…", action: share)
                    .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty || changes.isBusy)
                    .accessibilityLabel("Share \(row.label)")
                    .accessibilityHint("Shows what it changes, before anything runs.")
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func share() {
        let typed = target
        Task {
            await changes.previewShare(calendarID: row.id, name: row.label, target: typed, role: role)
            if changes.sheetPending(for: row.id) != nil { target = "" }
        }
    }
}

/// The last change's result for this calendar, at the top of its page, and spoken by VoiceOver: done, done but
/// not added to their list (in words, not only amber), or why not.
private struct CalendarResultBanner: View {
    let changes: CalendarChanges

    var body: some View {
        if let (text, detail, symbol, tint) = content {
            HStack(alignment: .firstTextBaseline) {
                if case .running = changes.state {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                    if let detail {
                        Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private var content: (String, String?, String, Color)? {
        switch changes.state {
        case .done(let done): (done.message, nil, done.partial ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
                               done.partial ? .orange : .green)
        case .problem(let problem): (problem.summary, problem.detail, "exclamationmark.triangle.fill", .orange)
        case .running(let pending): ("\(pending.title)…", nil, "hourglass", .blue)
        case .idle, .previewing: nil
        }
    }
}

/// Who has access to a calendar, in GAM's order: who, then the role in words, and a Remove on each rule that
/// isn't an owner's (GamGUI shows none on an owner's). A problem replaces the list (GamGUI's error partial),
/// never a spinner with no read behind it.
struct CalendarAccessList: View {
    let read: CalendarReads.Read
    let reads: CalendarReads
    /// What an empty list says (GamGUI's words differ between its two panels).
    let empty: String
    let calendarName: String
    let busy: Bool
    let remove: (CalendarACL) -> Void

    var body: some View {
        if let rules = reads.access(read) {
            List {
                Section("Who has access") {
                    if rules.isEmpty { Text(empty).foregroundStyle(.secondary) }
                    ForEach(rules) { rule in
                        CalendarRuleRow(rule: rule, calendarName: calendarName, busy: busy, remove: remove)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if reads.isReading(read) {
                    HStack { ProgressView().controlSize(.small); Text("Reading who has access…") }
                        .accessibilityElement(children: .combine)
                } else if let problem = reads.problem(for: read) {
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
        Button("Read Again") { Task { await reads.load(read) } }
            .accessibilityLabel("Read Again: who has access")
    }
}

/// A rule: who, then the role in words, read as one sentence; and Remove, named for whose access to what.
struct CalendarRuleRow: View {
    let rule: CalendarACL
    let calendarName: String
    let busy: Bool
    let remove: (CalendarACL) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.who).lineLimit(1).truncationMode(.middle)
                Text(rule.roleLabel).font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if !rule.isOwner {
                Button("Remove…") { remove(rule) }
                    .disabled(busy)
                    .accessibilityLabel("Remove \(rule.who)'s access to \(calendarName)")
            }
        }
    }
}

/// The person page's Calendar tab (GamGUI's `_calendar.html`, `users.py:560-604`): who can see their primary
/// calendar, read by GamGUI's user form when the tab is shown, each rule but an owner's with Remove, GamGUI's
/// share form (the user form, no subscribe), and the way to all their calendars on Calendars. Every change opens
/// its preview first (`UserChanges`).
struct PersonCalendarSection: View {
    let user: GamUser
    let reads: CalendarReads
    let changes: UserChanges
    let openCalendars: (String) -> Void
    @State private var target = ""
    @State private var role = GamCommands.CalendarRole.reader.rawValue

    private var read: CalendarReads.Read { .primaryAccess(of: user.primaryEmail) }
    private var calendarName: String { "\(user.fullName)'s calendar" }

    var body: some View {
        Section("Who can see their calendar") {
            if let rules = reads.access(read) {
                if rules.isEmpty { Text("Only the owner has access.").foregroundStyle(.secondary) }
                ForEach(rules) { rule in
                    CalendarRuleRow(rule: rule, calendarName: calendarName, busy: changes.isBusy) { rule in
                        Task { await changes.previewUnshareCalendar(user, rule: rule) }
                    }
                }
                TextField("Share with", text: $target, prompt: Text(verbatim: "person@example.com"))
                    .onSubmit(share)
                    .accessibilityLabel("Share \(calendarName) with (email)")
                HStack {
                    Picker("Access", selection: $role) {
                        ForEach(CalendarSharing.pickerRoles, id: \.role) { choice in
                            Text(choice.label).tag(choice.role.rawValue)
                        }
                    }
                    .fixedSize()
                    .accessibilityLabel("Access to give")
                    Spacer()
                    Button("Share…", action: share)
                        .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty || changes.isBusy)
                        .accessibilityLabel("Share \(calendarName)")
                }
            } else if reads.isReading(read) {
                HStack { ProgressView().controlSize(.small); Text("Reading who can see their calendar…") }
                    .accessibilityElement(children: .combine)
            } else if let problem = reads.problem(for: read) {
                Label(problem.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                if let detail = problem.detail {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                readAgain
            } else {
                HStack { Text("Not read.").foregroundStyle(.secondary); readAgain }
            }
        }
        .onChange(of: user.id) { target = "" }
        Section {
            HStack {
                Text("Their other calendars, and rooms, are on Calendars.").foregroundStyle(.secondary)
                Spacer()
                Button("Show Their Calendars…") { openCalendars(user.primaryEmail) }
                    .accessibilityLabel("Show \(user.fullName)'s calendars")
                    .accessibilityHint("Opens Calendars for them.")
            }
        }
    }

    private func share() {
        let typed = target, rules = reads.access(read)
        Task {
            await changes.previewShareCalendar(user, target: typed, role: role, rules: rules)
            if changes.previewing(for: user.primaryEmail) != nil { target = "" }
        }
    }

    private var readAgain: some View {
        Button("Read Again") { Task { await reads.load(read) } }
            .accessibilityLabel("Read Again: who can see \(user.fullName)'s calendar")
    }
}
