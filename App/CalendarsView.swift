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
            if deletedResultShown { CalendarResultBanner(changes: changes).padding(.top, 8) }
            list
        }
        // The list clips rather than widen the screen past the window when a calendar's page is open
        // (failure-log 2026-10-10, "person-page layout loop").
        .frame(minWidth: 0, maxWidth: .infinity)
        // Rooms are read when Rooms is first shown for a tenant, a person's calendars when they're chosen.
        .task(id: "\(setup.generation)#\(source.rawValue)#\(person)") { await loadIfNeeded() }
        .onChange(of: setup.generation) { select(nil) }
        // A calendar deleted: it has left the list, so its page closes; the result stays above the list.
        .onChange(of: deletedCalendar) { _, deleted in
            if let deleted, selection.map({ $0.lowercased() == deleted.lowercased() }) == true { select(nil) }
        }
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

    /// The calendar the last change deleted, while its result is shown.
    private var deletedCalendar: String? {
        if case .done(let done) = changes.state { return done.deletedCalendar }
        return nil
    }

    /// A delete's result goes above the list once its page has closed.
    private var deletedResultShown: Bool { deletedCalendar != nil && selection == nil }

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
    @State private var debugApplied = false
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
            } more: { rules in
                CalendarEventSection(calendarID: row.id, calendarName: row.label, changes: changes)
                CalendarDeleteSection(calendarID: row.id, calendarName: row.label, rules: rules, changes: changes)
            }
        }
        // Long values wrap or clip rather than widen the inspector past its bounds (ColumnWidths).
        .frame(minWidth: 0, maxWidth: .infinity)
        .inspectorColumnWidth(min: ColumnWidths.inspector.min, ideal: ColumnWidths.inspector.ideal,
                              max: ColumnWidths.inspector.max)
        // A quarter second later, so arrowing down the list starts no gam for the calendars passed over.
        .task(id: row.id) { await reads.load(read, after: .milliseconds(250)) }
        // The data owner the Delete section decides from, read once per page open: on the page, not on its section, which the
        // lazy List would start again whenever it scrolled back into view. Later too, for the same reason as the access.
        .task(id: row.id) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await changes.lookUpOwner(of: row.id)
        }
        .onChange(of: row.id) { target = "" }
        // A preview still reading (a group's members) is for what the form said then: it's dropped, never shown.
        .onChange(of: "\(row.id)#\(target)#\(role)") { changes.edited() }
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
        .task(id: reads.access(read) != nil) { await debugAction() }
    }

    /// Debug builds: `SWIFTGAMGUI_TAB` shows a change's state for the snapshots, once the access is read: a group share's
    /// confirm (`share-group`, the mock's twelve-member allhands@, held, never run), a made-up finished group share with
    /// failures (`group-result`, no gam), the calendar delete's confirm (`delete`), the event search's results (`events`)
    /// and an event delete's confirm (`event-delete`).
    private func debugAction() async {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard !debugApplied, reads.access(read) != nil, environment["SWIFTGAMGUI_SNAPSHOT"] != nil,
              let tab = environment["SWIFTGAMGUI_TAB"] else { return }
        debugApplied = true
        switch tab {
        case "share-group":
            await changes.previewShare(calendarID: row.id, name: row.label, target: "allhands@example.com",
                                       role: GamCommands.CalendarRole.reader.rawValue)
        case "group-result":
            let failed = ["member10@example.com", "member11@example.com", "member12@example.com"]
            let why = GamError.Kind.serviceNotEnabled.remediation
            changes.showDemo(CalendarChanges.Done(
                message: "Shared with allhands@example.com. It now appears in 9 of 12 members' Google Calendars. Couldn't add "
                    + "it for 3 \u{2014} they can add it manually.", partial: true,
                failures: failed.map { "\($0) \u{2014} \(why)" }, failedCount: 3), about: row.id)
        case "delete": await changes.previewDeleteCalendar(calendarID: row.id, name: row.label)
        case "events": await changes.events.search(calendarID: row.id, .init(text: "stand"))
        case "event-delete": await changes.previewDeleteEvent(calendarID: row.id, name: row.label, eventID: "4j3k2m1n0p9q8r7s6t5u")
        default: break
        }
        #endif
    }

    /// GamGUI's share form: a person's or a group's address and the access, then a preview.
    private var shareForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Share with", text: $target, prompt: Text(verbatim: "person or group@example.com"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(share)
                .accessibilityLabel("Share \(row.label) with (a person's or a group's address)")
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

/// The last change's result for this calendar, at the top of its page (or above the list, once a deleted calendar's
/// page has closed), and spoken by VoiceOver: done, done in part (said in words, not only amber), or why not. A group
/// share shows how far it is as it runs, with Stop, and then who it couldn't be added for.
struct CalendarResultBanner: View {
    let changes: CalendarChanges
    /// GamGUI lists ten of a run's failures before "and N more" here; the rest are in the jobs tray and Audit.
    static let failuresShown = 10

    var body: some View {
        if let (text, detail, symbol, tint) = content {
            HStack(alignment: .firstTextBaseline) {
                if case .running = changes.state {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                    if let detail {
                        Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if case .done(let done) = changes.state, !done.failures.isEmpty {
                        // A bounded box that scrolls (GamGUI's `max-h-24`): the access list below keeps its room in the
                        // smallest window.
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(done.failures.prefix(Self.failuresShown), id: \.self) { failure in
                                    Text(failure).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 96)
                        if done.failedCount > Self.failuresShown {
                            Text("and \(done.failedCount - Self.failuresShown) more (the jobs tray and Audit list each)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let progress = changes.progress {
                    Button(progress.stopping ? "Stopping…" : "Stop") { Task { await changes.stop() } }
                        .disabled(progress.stopping)
                        .accessibilityLabel("Stop adding the calendar to members' lists")
                        .accessibilityHint("The member being added finishes; no further member is added.")
                } else if !changes.isBusy {
                    Button { changes.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
            }
            .padding(10)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .onAppear { AccessibilityNotification.Announcement(text).post() }
            .onChange(of: announced) { _, new in AccessibilityNotification.Announcement(new).post() }
        }
    }

    /// What is spoken: the result, never each member's progress (which would talk over everything).
    private var announced: String {
        if case .running(let pending) = changes.state { return "\(pending.title)…" }
        return content?.0 ?? ""
    }

    private var content: (String, String?, String, Color)? {
        switch changes.state {
        case .done(let done): (done.message, nil, done.partial ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
                               done.partial ? .orange : .green)
        case .problem(let problem): (problem.summary, problem.detail, "exclamationmark.triangle.fill", .orange)
        case .running(let pending):
            if let progress = changes.progress {
                ("Adding to calendars… \(progress.done) of \(progress.total) \u{B7} \(progress.added) added"
                    + (progress.failed > 0 ? " \u{B7} \(progress.failed) failed" : ""), nil, "hourglass", .blue)
            } else {
                ("\(pending.title)…", nil, "hourglass", .blue)
            }
        case .idle, .previewing: nil
        }
    }
}

/// Who has access to a calendar, in GAM's order: who, then the role in words, and a Remove on each rule that
/// isn't an owner's (GamGUI shows none on an owner's). A problem replaces the list (GamGUI's error partial),
/// never a spinner with no read behind it.
struct CalendarAccessList<More: View>: View {
    let read: CalendarReads.Read
    let reads: CalendarReads
    /// What an empty list says (GamGUI's words differ between its two panels).
    let empty: String
    let calendarName: String
    let busy: Bool
    let remove: (CalendarACL) -> Void
    /// The page's sections after who has access (finding an event, the delete), given the rules read.
    @ViewBuilder let more: ([CalendarACL]) -> More

    var body: some View {
        if let rules = reads.access(read) {
            List {
                Section("Who has access") {
                    if rules.isEmpty { Text(empty).foregroundStyle(.secondary) }
                    ForEach(rules) { rule in
                        CalendarRuleRow(rule: rule, calendarName: calendarName, busy: busy, remove: remove)
                    }
                }
                more(rules)
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
                // The role on its own row, then the address with Share beside it: the person page's other add fields'
                // shape (Groups, Mail). A field alone in its row was laid out 452 pt wide, past the inspector in
                // every window (CI's person-calendar and narrow-person-calendar, 2026-10-13).
                LabeledContent("Access") {
                    Picker("Access", selection: $role) {
                        ForEach(CalendarSharing.pickerRoles, id: \.role) { choice in
                            Text(choice.label).tag(choice.role.rawValue)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Access to give")
                }
                HStack {
                    TextField("Share with", text: $target, prompt: Text(verbatim: "person@example.com"))
                        .onSubmit(share)
                        .accessibilityLabel("Share \(calendarName) with (email)")
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
            // The words above the button, not beside it: side by side they were wider than a narrow inspector.
            VStack(alignment: .leading, spacing: 6) {
                Text("Their other calendars, and rooms, are on Calendars.").foregroundStyle(.secondary)
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

/// GamGUI's "Find an event" (`_calendar_detail.html`, `_event_results.html`): a title fragment and/or days, never every
/// event; each result with what it is in words (a series says so), and Delete…, which reads it again and opens its
/// confirm. GamGUI's dates are optional, so each has its switch.
struct CalendarEventSection: View {
    let calendarID: String
    let calendarName: String
    let changes: CalendarChanges
    @State private var text = ""
    @State private var useAfter = false
    @State private var after = Date()
    @State private var useBefore = false
    @State private var before = Date()

    private var search: CalendarEventSearch { changes.events }

    /// GAM's `yyyy-mm-dd`, the day as the operator's calendar has it (GamGUI's browser date field).
    static func day(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private var searching: Bool {
        if case .searching = search.state(for: calendarID) { return true }
        return false
    }

    var body: some View {
        Section("Find an event") {
            TextField("Title contains", text: $text, prompt: Text("Event title contains"))
                .onSubmit(find)
                .accessibilityLabel("Event title contains")
            Toggle("On or after a day", isOn: $useAfter)
            if useAfter {
                DatePicker("On or after", selection: $after, displayedComponents: .date)
            }
            Toggle("Before a day", isOn: $useBefore)
            if useBefore {
                DatePicker("Before", selection: $before, displayedComponents: .date)
            }
            Button("Search Events", action: find)
                .disabled(searching)
                .accessibilityHint("Reads only the events that match; nothing changes.")
            results
        }
        .onChange(of: calendarID) {
            text = ""
            useAfter = false
            useBefore = false
        }
    }

    private func find() {
        let query = CalendarEventSearch.Query(text: text, after: useAfter ? Self.day(after) : "", before: useBefore ? Self.day(before) : "")
        Task { await search.search(calendarID: calendarID, query) }
    }

    @ViewBuilder private var results: some View {
        switch search.state(for: calendarID) {
        case .idle:
            EmptyView()
        case .needsFilter:
            Text("Enter a title to search for, or a date range.").foregroundStyle(.secondary)
        case .searching:
            HStack { ProgressView().controlSize(.small); Text("Searching…") }
                .accessibilityElement(children: .combine)
        case .problem(_, let problem):
            Label(problem.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            if let detail = problem.detail {
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .found(_, let events, let capped):
            if events.isEmpty {
                Text("No matching events.").foregroundStyle(.secondary)
            }
            if capped {
                Label("Showing the first \(events.count) matches \u{2014} narrow your search to see the rest.",
                      systemImage: "exclamationmark.circle")
            }
            ForEach(events) { event in
                EventRow(event: event, busy: changes.isBusy) {
                    Task { await changes.previewDeleteEvent(calendarID: calendarID, name: calendarName, eventID: event.eventID) }
                }
            }
        }
    }
}

/// One event: the title, "Recurring" in words beside it, then when and the organizer; read as one sentence, with Delete…
/// named for what it deletes.
private struct EventRow: View {
    let event: CalendarEvent
    let busy: Bool
    let delete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.isRecurring ? "\(event.summary) (recurring)" : event.summary).lineLimit(1).truncationMode(.tail)
                Text(event.details).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Delete…", action: delete)
                .disabled(busy)
                .accessibilityLabel("Delete \(event.summary), \(event.when)")
                .accessibilityHint("Shows the event first; nothing is deleted until you confirm.")
        }
    }
}

/// GamGUI's danger zone (`_calendar_detail.html`): on a secondary calendar, the data owner read when the page opens (the
/// owner the delete acts as, `CalendarChanges.lookUpOwner`); while that account is active, what a delete costs and the
/// button; otherwise why it can't be deleted here, in the preview's own words. Nothing on a primary, room or holiday calendar.
struct CalendarDeleteSection: View {
    let calendarID: String
    let calendarName: String
    let rules: [CalendarACL]
    let changes: CalendarChanges

    var body: some View {
        if CalendarDeletion.isSecondary(calendarID) {
            Section("Delete this calendar") {
                if let active = changes.activeAddresses {
                    switch changes.ownerLookup(for: calendarID) {
                    case nil, .reading?:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking who owns this calendar\u{2026}").foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    case .gone?:
                        Text(CalendarChanges.calendarGone).foregroundStyle(.secondary)
                    case .failed(let problem)?:
                        Text("Couldn't check who owns this calendar, so it can't be deleted here yet. \(problem.summary)")
                            .foregroundStyle(.secondary)
                        Button("Check Again") { Task { await changes.lookUpOwner(of: calendarID) } }
                            .accessibilityHint("Reads who owns this calendar again.")
                    case .read(let dataOwner)?:
                        switch CalendarDeletion.owner(of: calendarID, dataOwner: dataOwner, active: active) {
                        case .refused(let why):
                            Text(why).foregroundStyle(.secondary)
                        case .owner(let owner):
                            Text("Permanently delete this calendar. It's removed for everyone with access (\(rules.count) access "
                                + "rule\(rules.count == 1 ? "" : "s") above) and can't be undone \u{2014} make sure it's truly unused, "
                                + "not an active shared calendar. It's deleted acting as its owner, \(owner).")
                            Button("Delete This Calendar\u{2026}", role: .destructive) {
                                Task { await changes.previewDeleteCalendar(calendarID: calendarID, name: calendarName) }
                            }
                            .disabled(changes.isBusy)
                            .accessibilityLabel("Delete \(calendarName) for everyone")
                            .accessibilityHint("Shows what is deleted first, and asks you to type DELETE.")
                        }
                    }
                } else {
                    Text("Load the directory (Home or Users) to check who owns this calendar before deleting it.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
