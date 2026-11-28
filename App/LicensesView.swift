import Directory
import GamEngine
import SwiftUI

/// A person's licenses (roadmap 4.3, GamGUI's Licenses card): the seats one read found, read when asked, each with Change… and
/// Remove…, and Add a License… with what someone in the domain holds of a product they have none of. Every change is previewed
/// from a fresh read; a removal needs their address typed (`LicensePreviewSheet`).
struct PersonLicensesSection: View {
    let user: GamUser
    let licenses: LicenseChanges

    var body: some View {
        Section {
            switch licenses.choices(for: user.primaryEmail) {
            case nil:
                Button(licenses.isReading ? "Reading…" : "Read Their Licenses") { Task { await licenses.load(user.primaryEmail) } }
                    .disabled(licenses.isReading)
                    .accessibilityHint("Reads every license seat in the domain, or uses a read from the last five minutes. Nothing changes.")
            case .failure(let problem)?:
                Label("Couldn't read the licenses: \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                Button("Read Again") { Task { await licenses.load(user.primaryEmail, fresh: true) } }
            case .success(let choices)?:
                if choices.held.isEmpty { Text("The read found no license for them.").foregroundStyle(.secondary) }
                ForEach(choices.held, id: \.seat.id) { held in
                    HStack {
                        Text(held.seat.sku).accessibilityLabel("License: \(held.seat.sku)")
                        Spacer()
                        if !held.changes.isEmpty {
                            Menu("Change…") {
                                ForEach(held.changes, id: \.id) { to in
                                    Button(to.sku) { Task { await licenses.preview(.change(from: held.seat, to: to), for: user) } }
                                }
                            }
                            .fixedSize()
                            .accessibilityLabel("Change \(held.seat.sku)")
                        }
                        Button("Remove…", role: .destructive) { Task { await licenses.preview(.remove(held.seat), for: user) } }
                            .accessibilityLabel("Remove \(held.seat.sku)")
                    }
                    .disabled(licenses.isBusy)
                }
                if !choices.adds.isEmpty {
                    Menu("Add a License…") {
                        ForEach(choices.adds, id: \.id) { seat in
                            Button(seat.sku) { Task { await licenses.preview(.add(seat), for: user) } }
                        }
                    }
                    .fixedSize()
                    .disabled(licenses.isBusy)
                }
                Text(Licenses.onlySeatsRead).font(.caption).foregroundStyle(.secondary)
            }
            if licenses.subject == user.primaryEmail {
                switch licenses.state {
                case .checking: HStack { ProgressView().controlSize(.small); Text("Reading the licenses again…") }
                case .done(let words): Label(words, systemImage: "checkmark.circle.fill").symbolRenderingMode(.multicolor)
                case .problem(let words): Label(words, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                default: EmptyView()
                }
            }
        } header: {
            Text("Licenses")
        }
    }
}
