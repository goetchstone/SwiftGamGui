import ChangeCore
import Directory
import GamEngine
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

extension SignatureChanges {
    /// The preview the sheet shows: held, or running (the sheet stays, its buttons off, until it ends).
    var sheetPending: Pending? {
        switch state {
        case .previewing(let pending), .running(let pending): pending
        case .idle, .done, .problem: nil
        }
    }

    /// The sheet was closed: drops a preview still waiting, never the result the run left behind.
    func dismissPreview() {
        if case .previewing = state { dismiss() }
    }
}

/// A signature's confirm step (design doc D5): whose signature, the new one exactly as held (Rendered
/// draws GAM's stored form of it; HTML is the argv element itself, `WriteStep.signatureBody`), the one
/// they have now, what to know first, and that nothing keeps the old one. Confirming runs exactly this
/// preview, once.
struct SignaturePreviewSheet: View {
    let pending: SignatureChanges.Pending
    let changes: SignatureChanges

    private var running: Bool { changes.isBusy }

    private func confirm() {
        Task { await changes.confirm(pending, OperatorConfirmation(confirmed: true)) }
    }

    var body: some View {
        Form {
            Section(pending.title) {
                Text(pending.person.primaryEmail).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section(pending.isPutBack ? "Their previous signature, to set again" : "New") {
                SignaturePane(html: pending.body, rendered: Signature.stored(pending.body),
                              label: "\(pending.isPutBack ? "Previous" : "New") signature for \(pending.person.fullName)",
                              empty: "Empty: confirming clears their signature.", height: 170)
            }
            if !pending.isPutBack {
                Section("Current") {
                    if let previous = pending.previous {
                        SignaturePane(html: previous.body, rendered: previous.body,
                                      label: "Current signature of \(pending.person.fullName)", height: 120)
                    } else {
                        Text("Their current signature wasn't read, so it can't be put back afterwards.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !pending.warnings.isEmpty {
                Section {
                    ForEach(pending.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                }
            }
            Section {
                Label("Replaces their current Gmail signature. Gmail keeps no copy.", systemImage: "info.circle")
                // The exact command is there for an admin who wants it, the signature masked as the audit keeps it.
                DisclosureGroup("Show command") {
                    Text(pending.preview.steps.first?.shownArgv.joined(separator: " ") ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if running {
                Section {
                    HStack { ProgressView().controlSize(.small); Text("Setting the signature…") }
                        .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .interactiveDismissDisabled(running)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { changes.dismiss() }.disabled(running)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(pending.confirmLabel) { confirm() }.disabled(running)
            }
        }
    }
}
