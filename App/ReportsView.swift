import Directory
import GamEngine
import Setup
import SwiftUI

/// Reports: GamGUI's directory reports (no 2SV, inactive, admins, no recovery, suspended, and the missing title,
/// department, phone and location), each a list of people counted from the loaded directory with no GAM call of
/// its own; and GamGUI's storage and mail usage, read with `gam report users` when its row is first shown for a
/// tenant. A person opens on Users.
struct ReportsView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let usage: UsageStore
    /// Opens a person's page on Users.
    let openPerson: (String) -> Void
    @State private var item: Item? = .report("no_2sv")
    @State private var person: GamUser.ID?
    @State private var usagePerson: UsageRow.ID?
    /// Only the window in front speaks a load's outcome (every window sees the same stores).
    @Environment(\.appearsActive) private var appearsActive

    /// A row of the list on the left.
    enum Item: Hashable {
        case report(String)
        case usage
    }

    var body: some View {
        content
            // GamGUI loads the usage with its page; here when its row is first shown for a tenant, then held.
            .task(id: "\(setup.generation)#\(item == .usage)") {
                guard item == .usage, setup.active != nil, usage.report == nil, usage.problem == nil, !usage.isLoading else { return }
                await usage.load()
            }
            .onChange(of: usage.report) { _, report in
                guard let report else { return }
                announce(report.rows.isEmpty ? "No usage data yet." : "Usage loaded: the top \(report.rows.count) by storage.")
            }
            .onChange(of: usage.problem) { _, problem in
                if let problem { announce("Couldn't load the usage. \(problem.summary)") }
            }
            .onChange(of: item) {
                person = nil
                usagePerson = nil
            }
            .task { selectForSnapshot() }
            .toolbar {
                ToolbarItem {
                    Button(item == .usage ? "Refresh Usage" : "Refresh the Directory", systemImage: "arrow.clockwise") {
                        Task {
                            if item == .usage { await usage.load() } else { await directory.load() }
                        }
                    }
                    .keyboardShortcut("r")
                    .disabled(setup.active == nil || (item == .usage ? usage.isLoading : directory.isLoading))
                    .accessibilityIdentifier("reports.refresh")
                }
            }
    }

    private func announce(_ text: String) {
        guard appearsActive else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` opens a report by its key, or `usage`, for the snapshot of it.
    private func selectForSnapshot() {
        #if DEBUG
        guard let key = ProcessInfo.processInfo.environment["SWIFTGAMGUI_SELECT"] else { return }
        item = key == "usage" ? .usage : .report(key)
        #endif
    }

    @ViewBuilder private var content: some View {
        if let users = directory.users, let reports = directory.reports {
            HStack(spacing: 0) {
                List(selection: $item) {
                    Section("Directory") {
                        ForEach(reports) { report in
                            ReportRow(title: report.title, description: report.description, count: report.count)
                                .tag(Item.report(report.key))
                        }
                    }
                    Section("Usage") {
                        Label("Storage and mail", systemImage: "internaldrive")
                            .tag(Item.usage)
                            .accessibilityHint("Reads the usage report from Google.")
                    }
                }
                .frame(width: 240)
                Divider()
                detail(reports)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // Long text wraps and a table clips rather than widen the screen past the smallest window (ColumnWidths).
            .frame(minWidth: 0, maxWidth: .infinity)
            .safeAreaInset(edge: .bottom) {
                // A refresh of the directory shows here: running, or why it failed (the reports are the last good ones).
                HStack(spacing: 12) {
                    Text(across(users.count)).foregroundStyle(.secondary)
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
        } else {
            VStack(spacing: 12) {
                if directory.isLoading {
                    ProgressView("Loading the directory…")
                } else if let domain = setup.reconnecting {
                    ProgressView("Connecting to \(domain.name)…")
                } else if let failure = setup.reconnectFailure, setup.active == nil {
                    Label("Couldn't reconnect to \(failure.domain.name)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failure.problem).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await setup.reconnect() } }
                        .disabled(setup.isBusy)
                } else if setup.active == nil {
                    Text("Connect a domain on Setup to see its reports.").foregroundStyle(.secondary)
                } else {
                    Text("The reports are counted from the directory, which isn't loaded yet.").foregroundStyle(.secondary)
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

    /// "Across 1,204 accounts · directory as of 9:41 AM".
    private func across(_ count: Int) -> String {
        let counted = "Across \(count.formatted()) account\(count == 1 ? "" : "s")"
        guard let loadedAt = directory.loadedAt else { return counted }
        return "\(counted) · directory as of \(loadedAt.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder private func detail(_ reports: [DirectoryReport]) -> some View {
        switch item {
        case .report(let key):
            if let report = reports.first(where: { $0.key == key }) {
                ReportPeople(report: report, selection: $person, open: openPerson)
            }
        case .usage:
            UsagePanel(usage: usage, directory: directory, selection: $usagePerson, open: openPerson)
        case nil:
            Text("Choose a report.").foregroundStyle(.secondary).padding()
        }
    }
}

/// A report in the list: its title and count, its description beneath (a count means little without it).
private struct ReportRow: View {
    let title: String
    let description: String
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(count.formatted()).monospacedDigit().foregroundStyle(count == 0 ? .secondary : .primary)
            }
            Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count.formatted()) account\(count == 1 ? "" : "s")")
        .accessibilityHint(description)
    }
}

/// One report's people, in the directory's order, as GamGUI's card lists them: the name, the address, and an
/// admin or suspended account said in words. A person opens on Users.
private struct ReportPeople: View {
    let report: DirectoryReport
    @Binding var selection: GamUser.ID?
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(report.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(report.description).foregroundStyle(.secondary)
                Text("\(report.count.formatted()) account\(report.count == 1 ? "" : "s")")
            }
            .padding()
            if report.users.isEmpty {
                Label("None — all clear.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding(.horizontal)
                Spacer()
            } else {
                Table(report.users, selection: $selection) {
                    TableColumn("Name") { user in Text(user.fullName) }
                        .width(min: 100)
                    TableColumn("Address") { user in Text(user.primaryEmail) }
                        .width(min: 120)
                    TableColumn("Also") { user in Text(notes(user)) }
                        .width(min: 60, ideal: 90)
                }
                .contextMenu(forSelectionType: GamUser.ID.self) { ids in
                    Button("Show in Users") { show(ids) }
                } primaryAction: { ids in
                    show(ids)
                }
                HStack {
                    Button("Show in Users") { show(selection.map { [$0] } ?? []) }
                        .disabled(selection == nil)
                        .accessibilityHint("Opens the selected person's page on Users.")
                    Text("Or double-click a person.").foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(8)
            }
        }
    }

    /// GamGUI's badges, in words: an admin, or a suspended account, outside the report that is about it.
    private func notes(_ user: GamUser) -> String {
        var notes: [String] = []
        if report.key != "suspended", user.suspended { notes.append("Suspended") }
        if report.key != "admins", user.isAdmin { notes.append("Admin") }
        return notes.joined(separator: ", ")
    }

    private func show(_ ids: Set<GamUser.ID>) {
        guard let id = ids.first, let user = report.users.first(where: { $0.id == id }) else { return }
        open(user.primaryEmail)
    }

    private func show(_ ids: [GamUser.ID]) { show(Set(ids)) }
}

/// The storage and mail usage, as GamGUI's partial shows it: the top 25 by storage, with the day the counts are for.
private struct UsagePanel: View {
    let usage: UsageStore
    let directory: DirectoryStore
    @Binding var selection: UsageRow.ID?
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Storage and mail usage").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("Google's usage report, read with GAM. Its counts lag two or three days.").foregroundStyle(.secondary)
            }
            .padding()
            if let report = usage.report {
                if report.rows.isEmpty {
                    Text("Usage data isn't available yet — Google's reports lag a few days. Check back later.")
                        .foregroundStyle(.secondary).padding(.horizontal)
                    Spacer()
                } else {
                    Text("Top \(report.rows.count) by storage · as of \(Self.day(report.date))")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 6)
                    Table(report.rows, selection: $selection) {
                        TableColumn("User") { row in Text(row.email) }
                            .width(min: 140)
                        TableColumn("Storage") { row in
                            Text(row.storage).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(min: 70, ideal: 90)
                        TableColumn("Received") { row in
                            Text(row.received.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(min: 60, ideal: 80)
                        TableColumn("Sent") { row in
                            Text(row.sent.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(min: 50, ideal: 70)
                    }
                    .contextMenu(forSelectionType: UsageRow.ID.self) { ids in
                        Button("Show in Users") { show(ids) }.disabled(person(ids) == nil)
                    } primaryAction: { ids in
                        show(ids)
                    }
                    HStack(spacing: 12) {
                        Text("Mail counts are for \(Self.day(report.date)) only; storage is cumulative.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Show in Users") { show(selection.map { [$0] } ?? []) }
                            .disabled(person(selection.map { [$0] } ?? []) == nil)
                            .accessibilityHint("Opens the selected person's page on Users.")
                    }
                    .font(.callout)
                    .padding(8)
                }
                if usage.isLoading { reading("Refreshing usage…") }
            } else if usage.isLoading {
                reading("Loading usage…")
                Spacer()
            } else if let problem = usage.problem {
                VStack(alignment: .leading, spacing: 8) {
                    Label(problem.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    if let detail = problem.detail {
                        Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Button("Try Again") { Task { await usage.load() } }
                }
                .padding(.horizontal)
                Spacer()
            } else {
                Button("Load Usage") { Task { await usage.load() } }.padding(.horizontal)
                Spacer()
            }
            if usage.report != nil, let problem = usage.problem {
                Label(problem.summary, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).padding(.horizontal).help(problem.detail ?? problem.summary)
            }
        }
    }

    private func reading(_ words: String) -> some View {
        HStack { ProgressView().controlSize(.small); Text(words).foregroundStyle(.secondary) }
            .accessibilityElement(children: .combine)
            .padding(.horizontal)
    }

    /// The directory's person at a selected row's address: only someone in it can open on Users.
    private func person(_ ids: some Collection<UsageRow.ID>) -> String? {
        guard let id = ids.first, let row = usage.report?.rows.first(where: { $0.id == id }),
              directory.users?.contains(where: { $0.primaryEmail == row.email }) == true else { return nil }
        return row.email
    }

    private func show(_ ids: some Collection<UsageRow.ID>) {
        if let email = person(ids) { open(email) }
    }

    /// GAM's `YYYY-MM-DD`, as a day in words ("Jun 16, 2026"); as written when it isn't one.
    static func day(_ text: String) -> String {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard parts.count == 3, text.count == 10,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return text }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
