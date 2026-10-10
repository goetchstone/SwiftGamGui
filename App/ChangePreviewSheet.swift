import ChangeCore
import Directory
import SwiftUI

extension UserChanges {
    /// The preview a sheet shows, while one is held.
    var previewing: Pending? {
        if case .previewing(let pending) = state { return pending }
        return nil
    }

    /// The preview held for this person: a person's page shows only its own, so a draft never appears over
    /// someone else's page (or in a window showing another person).
    func previewing(for email: String) -> Pending? {
        previewing.flatMap { $0.email == email ? $0 : nil }
    }
}

/// What a confirm will run, exactly: the change in words, the command as GAM gets it (secrets masked),
/// how much it can hurt, then Cancel or the confirm. The confirmation is made here, in a screen, never
/// in code that also talks to Siri or a model (invariant 10, `WriteRouteTests`).
struct ChangePreviewSheet: View {
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
            if pending.preview.origin != .form {
                Section {
                    Label("Drafted from Siri for \(pending.email) on \(pending.preview.domain.name). Check it, then click \(pending.confirmLabel).",
                          systemImage: "waveform")
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
            // A destructive change, or one Siri drafted (it opens on its own), isn't confirmed by Return
            // alone: it isn't the default button, so it has to be chosen (clicked, or Tab and Space).
            if pending.isDestructive || pending.preview.origin != .form {
                ToolbarItem(placement: .primaryAction) {
                    Button(pending.confirmLabel, role: pending.isDestructive ? .destructive : nil) { confirm() }
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button(pending.confirmLabel) { confirm() }
                }
            }
        }
    }
}
