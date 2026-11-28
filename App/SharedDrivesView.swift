import Directory
import GamEngine
import Setup
import SwiftUI

/// Shared Drives (GamGUI's `/drives`, roadmap 4.7): every shared drive, read when the screen opens, and one drive's members, read
/// fresh when it's picked. Add a person or group with a role, change a role, remove one: each previewed (`SharedDriveSheet`)
/// and run only if the members still match. The last manager is never removed or demoted.
struct SharedDrivesView: View {
    let setup: SetupModel
    let model: SharedDriveChanges
    @State private var query = ""
    @State private var picked: SharedDrives.Drive.ID?
    @State private var email = ""
    @State private var kind = "user"
    @State private var role = "reader"

    var body: some View {
        HSplitView {
            drivesList.frame(minWidth: 240, idealWidth: 300)
            detail.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: setup.generation) { if setup.active != nil, model.drives == nil { await model.loadDrives() } }
        .sheet(item: Binding(get: { model.pending }, set: { if $0 == nil { model.dismiss() } })) { pending in
            SharedDriveSheet(pending: pending, model: model)
        }
        .toolbar {
            ToolbarItem {
                Button("Read Again", systemImage: "arrow.clockwise") { Task { await model.loadDrives() } }
                    .disabled(model.isReading || setup.active == nil)
            }
        }
    }

    private var drive: SharedDrives.Drive? { (try? model.drives?.get())?.first { $0.id == picked } }

    @ViewBuilder private var drivesList: some View {
        switch model.drives {
        case nil:
            ProgressView("Reading the shared drives…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let problem)?:
            Label("Couldn't read the shared drives: \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor).padding()
        case .success(let drives)?:
            let shown = query.isEmpty ? drives : drives.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.contains(query) }
            List(shown, selection: $picked) { drive in
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.name.isEmpty ? drive.id : drive.name)
                    Text(drive.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .tag(drive.id)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Drive name or ID")
            .overlay { if drives.isEmpty { ContentUnavailableView("No Shared Drives", systemImage: "externaldrive") } }
            .onChange(of: picked) { _, _ in if let drive { Task { await model.loadMembers(drive) } } }
        }
    }

    @ViewBuilder private var detail: some View {
        if let drive {
            Form {
                Section {
                    switch model.members(of: drive) {
                    case nil:
                        HStack { ProgressView().controlSize(.small); Text("Reading the members…") }
                    case .failure(let problem)?:
                        Label("Couldn't read the members: \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    case .success(let members)?:
                        ForEach(members) { member in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.who)
                                    Text(SharedDrives.label(member.role) + (member.kind == "group" ? " · group" : "")
                                         + (member.deleted ? " · account deleted" : ""))
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                                Spacer()
                                Menu("Role") {
                                    ForEach(SharedDrives.roleChoices, id: \.word) { choice in
                                        Button(choice.label) {
                                            Task { await model.preview(drive, action: .role, role: choice.word, memberID: member.id) }
                                        }
                                    }
                                }
                                .fixedSize()
                                .accessibilityLabel("Change \(member.who)'s role")
                                Button("Remove…", role: .destructive) { Task { await model.preview(drive, action: .remove, memberID: member.id) } }
                                    .accessibilityLabel("Remove \(member.who)")
                            }
                            .disabled(model.isBusy)
                        }
                    }
                } header: {
                    Text(drive.name.isEmpty ? drive.id : drive.name).accessibilityAddTraits(.isHeader)
                }
                Section("Add a member") {
                    TextField("Email address", text: $email, prompt: Text(verbatim: "name@example.com")).autocorrectionDisabled()
                    Picker("Who", selection: $kind) { Text("Person").tag("user"); Text("Group").tag("group") }
                    Picker("Role", selection: $role) { ForEach(SharedDrives.roleChoices, id: \.word) { Text($0.label).tag($0.word) } }
                    Button("Preview…") { Task { await model.preview(drive, action: .add, email: email, kind: kind, role: role) } }
                        .disabled(model.isBusy || email.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                switch model.state {
                case .checking: HStack { ProgressView().controlSize(.small); Text("Reading the members again…") }
                case .done(let words): Label(words, systemImage: "checkmark.circle.fill").symbolRenderingMode(.multicolor)
                case .problem(let words): Label(words, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                default: EmptyView()
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Pick a Shared Drive", systemImage: "externaldrive",
                                   description: Text("Its members are read when you pick it."))
        }
    }
}
