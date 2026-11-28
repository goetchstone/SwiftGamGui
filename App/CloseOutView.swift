import Directory
import GamEngine
import SwiftUI

/// Close Out (roadmap 4.5, plan D2), a section of Offboard for after the transfer has finished: check what the leaver still
/// has, pick what goes (each off until picked), preview it, then run exactly that. The delete is their page's, in Users.
struct CloseOutSection: View {
    let model: CloseOutChanges
    @State private var user = ""
    @State private var asked = CloseOut.Asked()
    @State private var manager = ""
    @AccessibilityFocusState private var resultFocused: Bool

    var body: some View {
        Section {
            Text("After the transfer has finished: take the leaver out of their groups, remove their admin roles, move their org "
                 + "unit, suspend or archive them, remove their licenses, and move their aliases to their manager. Each is off "
                 + "until you pick it. Nothing is offered while a transfer from them is unfinished.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Leaver's address", text: $user, prompt: Text(verbatim: "name@example.com"))
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .onSubmit(check)
                Button("Check", action: check)
                    .disabled(model.isBusy || user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Reads what they still have. Nothing changes.")
            }
        } header: {
            Text("Close out").accessibilityAddTraits(.isHeader)
        }
        switch model.state {
        case .idle: EmptyView()
        case .checking:
            Section { ProgressView("Reading what \(user.trimmingCharacters(in: .whitespacesAndNewlines)) still has\u{2026}") }
        case .checked(let found):
            checked(found)
        case .previewing(let pending):
            CloseOutReview(pending: pending, model: model)
        case .running(let pending):
            Section { ProgressView("Closing out \(pending.user)\u{2026}") }
        case .done(let done):
            Section {
                Label(done.message, systemImage: done.partial ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .accessibilityFocused($resultFocused)
                ForEach(done.failures, id: \.self) { Text($0).font(.callout) }
            }
            .onAppear { resultFocused = true }
        case .problem(let why):
            Section {
                Label(why, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    .accessibilityFocused($resultFocused)
            }
            .onAppear { resultFocused = true }
        }
    }

    private func check() {
        asked = CloseOut.Asked()
        let model = model, user = user
        Task { await model.check(user) }
    }

    @ViewBuilder
    private func checked(_ found: CloseOut.Found) -> some View {
        if let refusal = found.refusal {
            Section {
                Label(refusal, systemImage: "hourglass").accessibilityFocused($resultFocused)
                Text("The delete is on their page in Users, with its own checks.").font(.callout).foregroundStyle(.secondary)
            }
            .onAppear { resultFocused = true }
        } else {
            if !found.failedTransfers.isEmpty {
                Section {
                    Label("A transfer from them failed (\(found.failedTransfers.joined(separator: ", "))): what it didn't move is still "
                          + "only theirs.", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
            }
            Section("Groups") {
                if let why = found.unread["groups"] { Text(why).font(.callout) }
                else if found.groups?.isEmpty == true { Text("In no group.").foregroundStyle(.secondary) }
                ForEach(found.groups ?? [], id: \.self) { group in
                    Toggle("Take them out of \(group)", isOn: member(of: \.groups, group))
                }
            }
            Section("Admin roles") {
                if let why = found.unread["roles"] { Text(why).font(.callout) }
                else if found.roles?.isEmpty == true { Text("No role assigned to them directly.").foregroundStyle(.secondary) }
                ForEach(found.roles ?? []) { role in
                    Toggle("Remove \(role.words)", isOn: member(of: \.roles, role.id))
                }
            }
            Section("Org unit and sign-in") {
                if let why = found.unread["units"] { Text(why).font(.callout) }
                if let units = found.units {
                    Picker("Org unit (now \(found.orgUnit))", selection: $asked.orgUnit) {
                        Text("Leave it as it is").tag("")
                        ForEach(units.filter { $0 != found.orgUnit }, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("Sign-in", selection: $asked.state) {
                    Text("Leave it as it is").tag(CloseOut.State?.none)
                    if !found.suspended { Text("Suspend").tag(CloseOut.State?.some(.suspend)) }
                    if found.archived == false { Text("Archive").tag(CloseOut.State?.some(.archive)) }
                }
                if asked.state == .archive {
                    Text(CloseOut.archiveSwaps).font(.callout)
                    Link("Google: Archive former employee accounts", destination: URL(string: CloseOut.archiveSource)!)
                }
            }
            Section {
                if let why = found.unread["seats"] { Text(why).font(.callout) }
                else if found.seats?.isEmpty == true { Text("No license read for them.").foregroundStyle(.secondary) }
                ForEach(found.seats ?? []) { seat in
                    Toggle("Remove \(seat.sku)", isOn: member(of: \.seats, seat.key))
                }
            } header: {
                Text("Licenses")
            } footer: {
                Text(Licenses.onlySeatsRead)
            }
            Section("Aliases") {
                if found.aliases.isEmpty { Text("No alias.").foregroundStyle(.secondary) }
                ForEach(found.aliases, id: \.self) { alias in
                    Toggle("Move \(alias) to their manager", isOn: member(of: \.aliases, alias))
                }
                if !asked.aliases.isEmpty {
                    TextField("Manager's address", text: $manager, prompt: Text(verbatim: "manager@example.com"))
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                }
            }
            Section {
                Button("Preview Changes") {
                    let model = model, asked = asked, manager = manager
                    Task { await model.preview(found.user, asked, manager: manager) }
                }
                .disabled(model.isBusy)
                .accessibilityHint("Reads everything again and shows each change before anything runs.")
                Text("The delete is on their page in Users, with its own checks.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// A toggle over one name in one of the asked sets.
    private func member(of set: WritableKeyPath<CloseOut.Asked, Set<String>>, _ name: String) -> Binding<Bool> {
        Binding(get: { asked[keyPath: set].contains(name) }, set: { on in
            if on { asked[keyPath: set].insert(name) } else { asked[keyPath: set].remove(name) }
        })
    }
}
