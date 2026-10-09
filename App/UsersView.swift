import Directory
import GamEngine
import Setup
import SwiftUI

/// Users: the loaded directory as a table, searched and scoped as GamGUI's list is, with one person's
/// fields beside it. Read-only: writes come with ChangeCore (phase 2).
struct UsersView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    @State private var filter = UserFilter()
    @State private var sortOrder = [KeyPathComparator(\GamUser.fullName, comparator: .localizedStandard)]
    @State private var selection: GamUser.ID?

    var body: some View {
        content
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

    @ViewBuilder private var content: some View {
        if let users = directory.users {
            let rows = filter.apply(users).sorted(using: sortOrder)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.fullName)
                TableColumn("Address", value: \.primaryEmail)
                TableColumn("Title", value: \.title)
                TableColumn("Department", value: \.department)
                TableColumn("Organizational Unit", value: \.orgUnitPath)
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
                    UserDetail(user: user)
                }
            }
        } else {
            VStack(spacing: 12) {
                if directory.isLoading {
                    ProgressView("Loading the directory…")
                } else if setup.active == nil {
                    Text("Connect a domain on Setup to list its users.").foregroundStyle(.secondary)
                } else {
                    Text("Not loaded yet. Nothing is read from Google until you ask.").foregroundStyle(.secondary)
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
private struct UserDetail: View {
    let user: GamUser

    var body: some View {
        Form {
            Section(user.fullName) {
                LabeledContent("Address") { Text(user.primaryEmail).textSelection(.enabled) }
                LabeledContent("Status", value: user.suspended ? "Suspended" : "Active")
                LabeledContent("Organizational unit", value: user.orgUnitPath)
                LabeledContent("Last sign-in", value: user.lastLoginTime ?? "Never")
            }
            Section("Role") {
                LabeledContent("Title", value: user.title.isEmpty ? "—" : user.title)
                LabeledContent("Department", value: user.department.isEmpty ? "—" : user.department)
                LabeledContent("Location", value: user.location.isEmpty ? "—" : user.location)
                LabeledContent("Phone", value: user.phone.isEmpty ? "—" : user.phone)
            }
            Section("Security") {
                LabeledContent("Administrator", value: user.isAdmin ? "Super admin" : user.isDelegatedAdmin ? "Delegated" : "No")
                LabeledContent("2-step verification", value: user.isEnrolledIn2SV ? "Enrolled" : "Not enrolled")
                LabeledContent("Recovery email", value: user.recoveryEmail.isEmpty ? "—" : user.recoveryEmail)
            }
            if !user.aliases.isEmpty {
                Section("Aliases") {
                    ForEach(user.aliases, id: \.self) { Text($0).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 260, ideal: 300)
    }
}
