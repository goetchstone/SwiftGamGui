import ChangeCore
import Directory
import GamEngine
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var typed = ""

    /// The address the executor asks for: an account's own, to delete it.
    private var toType: String? { pending.preview.decision.typedAddresses.first }
    /// The field matches, as the executor compares it (trimmed, case aside): only then is the button offered.
    private var matches: Bool {
        guard let toType else { return true }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == toType.lowercased()
    }

    private func confirm() {
        Task { await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedAddresses: toType == nil ? [] : [typed])) }
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
            if let toType {
                Section("Type \(toType) to delete it") {
                    TextField("Their address", text: $typed, prompt: Text(verbatim: toType))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type the address, \(toType), to delete this account")
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
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { changes.dismiss() }.disabled(changes.isBusy) }
            // A destructive change, or one Siri drafted (it opens on its own), isn't confirmed by Return
            // alone: it isn't the default button, so it has to be chosen (clicked, or Tab and Space).
            if pending.isDestructive || pending.preview.origin != .form {
                ToolbarItem(placement: .primaryAction) {
                    Button(pending.confirmLabel, role: pending.isDestructive ? .destructive : nil) { confirm() }
                        .disabled(changes.isBusy || !matches)
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button(pending.confirmLabel) { confirm() }
                        .disabled(changes.isBusy)
                }
            }
        }
    }
}

extension SignatureChanges {
    /// The preview the sheet shows: held, or running (the sheet stays, its buttons off, until it ends). A scope's run
    /// closes its sheet once confirmed: it can run for minutes, so its progress and Stop are on the screen and in the jobs
    /// tray instead.
    var sheetPending: Pending? {
        switch state {
        case .previewing(let pending): pending
        case .running(let pending): pending.isScoped ? nil : pending
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
/// they have now, what to know first, and that the old one is kept on this Mac first. Confirming runs exactly this
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
            Section("New") {
                SignaturePane(html: pending.body, rendered: Signature.stored(pending.body),
                              label: "New signature for \(pending.person.fullName)",
                              empty: "Empty: confirming clears their signature.")
            }
            Section("Current") {
                if let current = pending.current {
                    SignaturePane(html: current, rendered: current,
                                  label: "Current signature of \(pending.person.fullName)", height: 200)
                } else {
                    Text("Their current signature wasn't shown here. It's read again when this runs.")
                        .foregroundStyle(.secondary)
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
                Label(SignatureChanges.keptFirst(1), systemImage: "info.circle")
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
        .frame(minWidth: 640, idealWidth: 760, minHeight: 680, idealHeight: 820)
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

/// A scope's confirm step (GamGUI's `_sig_preview.html`): how many people, the first one's signature exactly as held (a
/// sample: each person's is their own render), what to know first, who is left out, the people, the count typed above the
/// guard's threshold, and that nothing keeps the old signatures. Confirming runs exactly these people and this template,
/// once.
struct SignatureScopePreviewSheet: View {
    let pending: SignatureChanges.Pending
    let changes: SignatureChanges
    @State private var typedCount = ""

    private var count: Int { pending.people.count }
    private var needsCount: Bool { pending.preview.decision.requiresTypedCount }
    /// The people named before the full list (GamGUI's confirm sample).
    private static let named = 10

    private func confirm() {
        let confirmation = OperatorConfirmation(confirmed: true, typedCount: needsCount ? typedCount : "")
        Task { await changes.confirm(pending, confirmation) }
    }

    var body: some View {
        Form {
            Section {
                Text("Applies to \(count) user\(count == 1 ? "" : "s") \u{B7} previewing as \(pending.person.fullName)")
                let addresses = pending.people.map(\.primaryEmail)
                let more = count - min(count, Self.named)
                Text(addresses.prefix(Self.named).joined(separator: ", ") + (more > 0 ? " \u{2026} and \(more) more" : ""))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if more > 0 {
                    DisclosureGroup("Show all \(count)") {
                        Text(addresses.joined(separator: "\n"))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                Text(pending.title).accessibilityAddTraits(.isHeader)
            }
            Section("New, for \(pending.person.fullName)") {
                SignaturePane(html: pending.body, rendered: Signature.stored(pending.body),
                              label: "New signature for \(pending.person.fullName), the first of \(count)",
                              empty: "Empty: confirming clears their signature.")
            }
            let warnings = pending.warnings + pending.preview.decision.warnings
            if !warnings.isEmpty || !pending.notes.isEmpty {
                Section {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                    ForEach(pending.notes, id: \.self) { note in Label(note, systemImage: "info.circle") }
                }
            }
            if needsCount {
                Section("This overwrites the Gmail signature of \(count) people") {
                    TextField("Type \(count) to confirm", text: $typedCount)
                        .accessibilityLabel("Type the number of people, \(count), to confirm")
                        .onChange(of: typedCount) { changes.typingChanged() }
                    if let problem = changes.typedProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            Section {
                Label(SignatureChanges.keptFirst(count), systemImage: "info.circle")
                Text(pending.isRetry ? "Confirming writes exactly this: the template that run used, to the people it failed for."
                     : "Confirming writes exactly this. Change who it's for or the template and you'll need to review again.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("It runs in the jobs tray, one change per person, with Stop.")
                    .font(.callout).foregroundStyle(.secondary)
                // The exact commands are there for an admin who wants them, each signature masked as the audit keeps it.
                DisclosureGroup(count == 1 ? "Show command" : "Show \(count) commands") {
                    Text(pending.preview.steps.map { $0.shownArgv.joined(separator: " ") }.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let fast = pending.fast { SignatureFastSection(pending: pending, fast: fast, changes: changes, typedCount: typedCount) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 600, idealHeight: 780)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { changes.dismiss() }
            }
            // Many signatures at once: Return alone never runs it (not the default button), as the calendar sheet's deletes.
            ToolbarItem(placement: .primaryAction) {
                // Off until the count typed is the guard's (GamGUI's `data-unlocks`); the model refuses a mismatch too.
                Button(pending.confirmLabel) { confirm() }
                    .disabled(changes.isBusy || !pending.preview.decision.typedCountMatches(typedCount))
                    .accessibilityLabel("Replace the Gmail signatures of \(count) \(count == 1 ? "person" : "people")")
            }
        }
        // Said on each refusal, a repeated one too: the label alone appears only once.
        .onChange(of: changes.typedRefusals) {
            if let problem = changes.typedProblem { AccessibilityNotification.Announcement(problem).post() }
        }
    }
}

/// Roadmap 5.4's opt-in (GamGUI's "Faster: all N in one GAM call"): the same people as one GAM call, its own held preview,
/// the same typed count. No live list and no Stop, so its button asks once more; or why it isn't offered.
private struct SignatureFastSection: View {
    let pending: SignatureChanges.Pending
    let fast: SignatureChanges.Fast
    let changes: SignatureChanges
    let typedCount: String
    @State private var asking = false

    private var count: Int { pending.people.count }

    var body: some View {
        Section {
            if let refusal = fast.refusal {
                Label(refusal, systemImage: "info.circle")
            } else {
                DisclosureGroup("Faster: all \(count) in one GAM call") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GAM reads every current signature in one call and keeps them on this Mac, so Put Back still works, "
                             + "then sets them all in a second call. Much quicker for many people, but there's no live count and "
                             + "no Stop: you see who was set when it finishes. Anyone GAM doesn't say it set is listed as failed, "
                             + "and Retry runs them one at a time. Characters outside plain English (\u{E9}, \u{2014}) are sent "
                             + "as HTML codes, which show the same in a signature.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(fast.shownCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Apply to \(count) Users in One GAM Call\u{2026}") { asking = true }
                            .disabled(changes.isBusy || !fast.typedCountMatches(typedCount))
                            .accessibilityLabel("Replace the Gmail signatures of \(count) people in one GAM call")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .confirmationDialog("Set the signature of \(count) people in one GAM call?", isPresented: $asking) {
            Button("Set \(count) in One Call") {
                let confirmation = OperatorConfirmation(confirmed: true, typedCount: typedCount)
                Task { await changes.confirmFast(pending, confirmation) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It can't be stopped once it starts.")
        }
    }
}

/// A Put Back's confirm step (GamGUI's `_sig_putback.html`): the kept run it sets again, whose signatures go back (the first
/// one's shown, as held), who is left out and why, the count typed above the guard's threshold, and what the run checks
/// first. Confirming runs exactly these people and these signatures, once.
struct SignaturePutBackSheet: View {
    let pending: SignatureChanges.Pending
    let changes: SignatureChanges
    @State private var typedCount = ""

    private var count: Int { pending.people.count }
    private var needsCount: Bool { pending.preview.decision.requiresTypedCount }
    private static let named = 10

    private func confirm() {
        let confirmation = OperatorConfirmation(confirmed: true, typedCount: needsCount ? typedCount : "")
        Task { await changes.confirm(pending, confirmation) }
    }

    var body: some View {
        Form {
            Section {
                if let putBack = pending.putBack {
                    Text("Kept \(putBack.when.formatted(date: .abbreviated, time: .shortened)) on \(pending.preview.domain.name)")
                        .foregroundStyle(.secondary)
                }
                let addresses = pending.people.map(\.primaryEmail)
                let more = count - min(count, Self.named)
                Text(addresses.prefix(Self.named).joined(separator: ", ") + (more > 0 ? " \u{2026} and \(more) more" : ""))
                    .textSelection(.enabled)
                if more > 0 {
                    DisclosureGroup("Show all \(count)") {
                        Text(addresses.joined(separator: "\n")).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                Text(pending.title).accessibilityAddTraits(.isHeader)
            }
            Section("Their signature before that run, for \(pending.person.fullName)") {
                SignaturePane(html: pending.body, rendered: pending.body,
                              label: "Signature to put back for \(pending.person.fullName), the first of \(count)",
                              empty: "Empty: they had no signature, so confirming clears theirs.")
            }
            if let leftOut = pending.putBack?.leftOut, !leftOut.isEmpty {
                Section("Left out (\(leftOut.count)), to put back by hand") {
                    ForEach(leftOut, id: \.self) { person in
                        Label("\(person.email): \(person.why).", systemImage: "info.circle").textSelection(.enabled)
                    }
                }
            }
            ForEach(pending.preview.decision.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            if needsCount {
                Section("This puts back the Gmail signature of \(count) people") {
                    TextField("Type \(count) to confirm", text: $typedCount)
                        .accessibilityLabel("Type the number of people, \(count), to confirm")
                        .onChange(of: typedCount) { changes.typingChanged() }
                    if let problem = changes.typedProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            Section {
                Label("Each one's signature is read first: anyone whose signature changed since that run is left as it is. "
                      + "What this replaces is kept on this Mac too, so it can be put back in turn.", systemImage: "info.circle")
                Text("It runs in the jobs tray, one change per person, with Stop.").font(.callout).foregroundStyle(.secondary)
                DisclosureGroup(count == 1 ? "Show command" : "Show \(count) commands") {
                    Text(pending.preview.steps.map { $0.shownArgv.joined(separator: " ") }.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 600, idealHeight: 780)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { changes.dismiss() }
            }
            // Many signatures at once: Return alone never runs it (not the default button).
            ToolbarItem(placement: .primaryAction) {
                Button(pending.confirmLabel) { confirm() }
                    .disabled(changes.isBusy || !pending.preview.decision.typedCountMatches(typedCount))
                    .accessibilityLabel("Put back the Gmail signatures of \(count) \(count == 1 ? "person" : "people")")
            }
        }
        .onChange(of: changes.typedRefusals) {
            if let problem = changes.typedProblem { AccessibilityNotification.Announcement(problem).post() }
        }
    }
}

extension GroupChanges {
    /// The preview `group`'s page shows in its sheet: held, or running (the sheet stays, its buttons off,
    /// until it ends). Another group's page never shows it.
    func sheetPending(for group: String) -> Pending? {
        switch state {
        case .previewing(let pending), .running(let pending): concerns(group) ? pending : nil
        case .idle, .done, .problem: nil
        }
    }

    /// The sheet was closed: drops a preview still waiting, never the result the run left behind.
    func dismissPreview() {
        if case .previewing = state { dismiss() }
    }
}

/// A group change's confirm step: who is added (with which role) or removed, the commands as GAM gets them,
/// what removing means, the count typed when the guard asks for it, then Cancel or the confirm. Confirming
/// runs exactly this preview, once.
struct GroupPreviewSheet: View {
    let pending: GroupChanges.Pending
    let changes: GroupChanges
    @State private var typedCount = ""

    private var running: Bool { changes.isBusy }
    private var count: Int { pending.preview.steps.count }
    private var needsCount: Bool { pending.preview.decision.requiresTypedCount }

    private func confirm() {
        Task { await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedCount: typedCount)) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(pending.preview.steps.enumerated()), id: \.offset) { _, step in
                    Text(step.summary)
                }
                // The exact commands are there for an admin who wants them, not the first thing to read.
                DisclosureGroup(count == 1 ? "Show command" : "Show \(count) commands") {
                    Text(pending.preview.steps.map { $0.shownArgv.joined(separator: " ") }.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text(pending.title).accessibilityAddTraits(.isHeader)
            }
            if !pending.notes.isEmpty || !pending.preview.decision.warnings.isEmpty {
                Section {
                    ForEach(pending.notes, id: \.self) { note in Label(note, systemImage: "info.circle") }
                    ForEach(pending.preview.decision.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                }
            }
            if needsCount {
                Section("This changes \(count) people") {
                    TextField("Type \(count) to confirm", text: $typedCount)
                        .accessibilityLabel("Type the number of people, \(count), to confirm")
                        .disabled(running)
                        .onChange(of: typedCount) { changes.typingChanged() }
                    if let problem = changes.typedProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            if running {
                Section {
                    HStack { ProgressView().controlSize(.small); Text(pending.isAdding ? "Adding…" : "Removing…") }
                        .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 320)
        .interactiveDismissDisabled(running)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(pending.isAdding ? "Back" : "Cancel") { changes.dismiss() }.disabled(running)
            }
            // The default button, so Return runs it: off until the count typed is the guard's (GamGUI's `data-unlocks`),
            // and the model refuses a mismatch too.
            ToolbarItem(placement: .confirmationAction) {
                Button(pending.confirmLabel) { confirm() }
                    .disabled(running || !pending.preview.decision.typedCountMatches(typedCount))
            }
        }
        // Said on each refusal, a repeated one too: the label alone appears only once.
        .onChange(of: changes.typedRefusals) {
            if let problem = changes.typedProblem { AccessibilityNotification.Announcement(problem).post() }
        }
    }
}

extension CalendarChanges {
    /// The preview the sheet shows: held, or running (the sheet stays, its buttons off, until it ends). A group share
    /// closes its sheet once confirmed: it can run for minutes, so its progress and Stop are on the page and in the
    /// jobs tray instead.
    var sheetPending: Pending? {
        switch state {
        case .previewing(let pending): pending
        case .running(let pending): pending.kind == .shareGroup ? nil : pending
        case .idle, .done, .problem: nil
        }
    }

    /// The sheet for this calendar's page: a page shows only its own calendar's change.
    func sheetPending(for calendarID: String) -> Pending? {
        sheetPending.flatMap { concerns(calendarID) && $0.calendarID == calendarID ? $0 : nil }
    }

    /// The sheet was closed: drops a preview still waiting, never the result the run left behind.
    func dismissPreview() {
        if case .previewing = state { dismiss() }
    }
}

/// A calendar change's confirm step (calendars plan D4, GamGUI's confirm partials): each step in words with its
/// command, what to know first, and how it's undone; for a group, how many members and who, with the count typed at
/// the guard's threshold; for a delete, what is lost, and for a calendar DELETE typed. Then Cancel, or the action, off
/// while it runs; a destructive one is never the default button. Confirming runs exactly this preview, once.
struct CalendarPreviewSheet: View {
    let pending: CalendarChanges.Pending
    let changes: CalendarChanges
    @State private var typedCount = ""
    @State private var typedWord = ""

    private var running: Bool { changes.isBusy }
    private var count: Int { pending.preview.steps.count }
    private var needsCount: Bool { pending.preview.decision.requiresTypedCount }

    private func confirm() {
        let confirmation = OperatorConfirmation(confirmed: true, typedWord: pending.kind == .deleteCalendar ? typedWord : "",
                                                typedCount: needsCount ? typedCount : "")
        Task { await changes.confirm(pending, confirmation) }
    }

    var body: some View {
        Form {
            switch pending.detail {
            case .group(let members, let leftOut): groupSections(members: members, leftOut: leftOut)
            case .deleteCalendar(let owner, let rules): deleteCalendarSection(owner: owner, rules: rules)
            case .deleteEvent(let event): deleteEventSection(event)
            case .none: stepsSection
            }
            if !pending.warnings.isEmpty || !pending.preview.decision.warnings.isEmpty {
                Section {
                    ForEach(pending.warnings + pending.preview.decision.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                }
            }
            if needsCount {
                Section("This makes \(count) changes") {
                    TextField("Type \(count) to confirm", text: $typedCount)
                        .accessibilityLabel("Type the number of changes, \(count), to confirm")
                        .disabled(running)
                        .onChange(of: typedCount) { changes.typingChanged() }
                    if pending.kind != .deleteCalendar, let problem = changes.typedProblem { problemLabel(problem) }
                }
            }
            if pending.kind == .deleteCalendar {
                Section("Type DELETE to confirm") {
                    TextField("DELETE", text: $typedWord, prompt: Text(verbatim: CalendarDeletion.typedWord))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type DELETE, in capitals, to delete \(pending.calendarName)")
                        .disabled(running)
                        .onChange(of: typedWord) { changes.typingChanged() }
                    if let problem = changes.typedProblem { problemLabel(problem) }
                }
            }
            Section {
                Label(pending.undo, systemImage: pending.isDestructive ? "exclamationmark.octagon.fill" : "arrow.uturn.backward.circle")
                    .foregroundStyle(pending.isDestructive ? .red : .primary)
            }
            if running {
                Section {
                    HStack { ProgressView().controlSize(.small); Text(runningText) }
                        .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 320)
        .interactiveDismissDisabled(running)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { changes.dismiss() }.disabled(running)
            }
            // A destructive change isn't confirmed by Return alone: it isn't the default button.
            if pending.isDestructive {
                ToolbarItem(placement: .primaryAction) {
                    Button(pending.confirmLabel, role: .destructive) { confirm() }
                        .disabled(running || (pending.kind == .deleteCalendar && typedWord.trimmingCharacters(in: .whitespaces).isEmpty))
                        .accessibilityLabel(pending.kind == .deleteCalendar ? "Delete \(pending.calendarName) for everyone"
                                            : "Delete this event from \(pending.calendarName)")
                }
            } else {
                // The default button, so Return runs it: off until the count typed is the guard's (GamGUI's `data-unlocks`),
                // and the model refuses a mismatch too.
                ToolbarItem(placement: .confirmationAction) {
                    Button(pending.confirmLabel) { confirm() }
                        .disabled(running || !pending.preview.decision.typedCountMatches(typedCount))
                }
            }
        }
        // Said on each refusal, a repeated one too: the label alone appears only once.
        .onChange(of: changes.typedRefusals) {
            if let problem = changes.typedProblem { AccessibilityNotification.Announcement(problem).post() }
        }
    }

    private func problemLabel(_ problem: String) -> some View {
        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
    }

    private var runningText: String {
        switch pending.kind {
        case .share, .shareGroup: "Sharing…"
        case .unshare: "Removing…"
        case .deleteCalendar, .deleteEvent: "Deleting…"
        }
    }

    /// Each step in words, with its command behind a disclosure.
    private var stepsSection: some View {
        Section(pending.title) {
            ForEach(Array(pending.preview.steps.enumerated()), id: \.offset) { _, step in
                Text(step.summary)
                DisclosureGroup("Show command") { command(step.shownArgv.joined(separator: " ")) }
            }
        }
    }

    private func command(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// GamGUI's group confirm (`_calendar_detail.html`): the count, a sample, and "and N more".
    @ViewBuilder private func groupSections(members: [String], leftOut: Int) -> some View {
        Section(pending.title) {
            if let first = pending.preview.steps.first { Text(first.summary) }
            if members.isEmpty {
                Text("\(pending.who) has no members whose calendar list it can be added to: only the group's access is added.")
            } else {
                Text("Then it's added to \(members.count) member\(members.count == 1 ? "'s" : "s'") calendars \u{2014} one change per "
                    + "member, in the jobs tray, with Stop.")
                let sample = members.prefix(CalendarChanges.confirmSample).joined(separator: ", ")
                let more = members.count - min(members.count, CalendarChanges.confirmSample)
                Text(more > 0 ? "\(sample) \u{2026} and \(more) more" : sample)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if leftOut > 0 {
                Text("\(leftOut) member\(leftOut == 1 ? " isn't a person" : "s aren't people") with an active account (a group inside it, a "
                    + "suspended account): they have access through the group, but it isn't added to their list.")
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(count == 1 ? "Show command" : "Show \(count) commands") {
                command(pending.preview.steps.map { $0.shownArgv.joined(separator: " ") }.joined(separator: "\n"))
            }
        }
    }

    /// GamGUI's `_calendar_delete.html`.
    @ViewBuilder private func deleteCalendarSection(owner: String, rules: Int) -> some View {
        Section("Permanently delete this calendar?") {
            Text(pending.calendarName).font(.headline)
            Text(pending.calendarID).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Deletes the calendar and all of its events for everyone it's shared with"
                + (rules > 0 ? " (\(rules) access rule\(rules == 1 ? "" : "s"))" : "") + ". This cannot be undone. Runs as owner \(owner).")
                .foregroundStyle(.red)
            DisclosureGroup("Show command") { command(pending.preview.steps.map { $0.shownArgv.joined(separator: " ") }.joined(separator: "\n")) }
        }
    }

    /// GamGUI's `_event_delete.html`.
    @ViewBuilder private func deleteEventSection(_ event: CalendarEvent) -> some View {
        Section("Delete this event?") {
            Text(event.summary).font(.headline)
            Text(event.organizer.isEmpty ? event.when : "\(event.when) \u{B7} organizer \(event.organizer)")
                .foregroundStyle(.secondary)
            Text("From \(pending.calendarName). No updates are sent to its guests.")
            DisclosureGroup("Show command") { command(pending.preview.steps.map { $0.shownArgv.joined(separator: " ") }.joined(separator: "\n")) }
        }
    }
}

/// One hire's confirm step (slice O1): every step the run will take, by kind, with its command, what to know
/// first, and what it costs. Confirming runs exactly this preview, once; Cancel drops it at once, its
/// temporary password with it. The sheet says "One new hire: N steps" itself: the guard counts steps as
/// targets, and every step here is one person's.
struct OnboardPreviewSheet: View {
    let pending: OnboardChanges.Pending
    let changes: OnboardChanges

    private var plan: OnboardChanges.Plan { pending.plan }

    private func confirm() {
        Task { await changes.confirm(pending, OperatorConfirmation(confirmed: true)) }
    }

    private func rows(_ match: (OnboardChanges.Row.Kind) -> Bool) -> [OnboardChanges.Row] {
        plan.rows.filter { match($0.kind) }
    }

    var body: some View {
        Form {
            Section(pending.isRetry ? "Retry for \(plan.email.isEmpty ? plan.assignee : plan.email)"
                                    : "Onboard \(plan.name) \u{2014} \(plan.role.name)") {
                Text(pending.summary)
            }
            let account = rows { $0 == .account }
            if !account.isEmpty {
                Section("Account") {
                    Text("Creates \(plan.email): \(plan.first) \(plan.last) in \(plan.orgUnit).")
                    Text("The temporary password is shown once, after the account is created; they must change it at first sign-in.")
                    commands(account)
                }
            }
            let signature = rows { if case .signature = $0 { true } else { false } }
            if let held = plan.signature, !signature.isEmpty {
                Section("Signature") {
                    Text("Sets the \u{201C}\(held.template)\u{201D} signature, made out for \(plan.name).")
                    DisclosureGroup("Rendered") {
                        // The argv element itself, as held: what the run sends.
                        SignaturePane(html: held.body, rendered: Signature.stored(held.body),
                                      label: "New signature for \(plan.name)", empty: "Empty: confirming clears their signature.",
                                      height: 140)
                    }
                    commands(signature)
                }
            }
            let groups = rows { if case .group = $0 { true } else { false } }
            if !groups.isEmpty {
                Section("Groups") {
                    Text("Adds \(plan.email) to \(groups.count) group\(groups.count == 1 ? "" : "s"), as a member.")
                    commands(groups)
                }
            }
            let calendars = rows { if case .calendar = $0 { true } else { false } }
            if !calendars.isEmpty {
                Section("Calendars") {
                    Text("Subscribes them to \(calendars.count) shared calendar\(calendars.count == 1 ? "" : "s").")
                    commands(calendars)
                }
            }
            let checklist = rows {
                switch $0 {
                case .taskList, .task: true
                default: false
                }
            }
            if !checklist.isEmpty {
                Section("Checklist") {
                    let tasks = checklist.count { if case .task = $0.kind { true } else { false } }
                    Text("\(tasks) task\(tasks == 1 ? "" : "s") \u{2192} \(plan.assignee)'s Google Tasks, \u{201C}\(plan.title)\u{201D}")
                    commands(checklist)
                }
            }
            let welcomeRows = rows { if case .welcome = $0 { true } else { false } }
            if let welcome = plan.welcome, !welcomeRows.isEmpty {
                Section("Welcome email") {
                    Text("Sends \u{201C}\(welcome.name)\u{201D} to \(plan.email), after everything else, as they'll read it:")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: welcome.subject).bold()
                        Text(verbatim: welcome.body)
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Subject: \(welcome.subject). \(welcome.body)")
                    commands(welcomeRows)
                }
            }
            if !plan.warnings.isEmpty {
                Section {
                    ForEach(plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                }
            }
            Section {
                if plan.creates {
                    Label("Creates a Google account, which uses a license.", systemImage: "person.crop.circle.badge.plus")
                }
                Label("Runs exactly this preview. Change the form and you'll need to preview again.", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { changes.cancelPreview() } }
            // Creating an account isn't confirmed by Return alone: it has to be chosen (clicked, or Tab and Space).
            if plan.creates {
                ToolbarItem(placement: .primaryAction) { Button(pending.confirmLabel) { confirm() } }
            } else {
                ToolbarItem(placement: .confirmationAction) { Button(pending.confirmLabel) { confirm() } }
            }
        }
    }

    /// Each step in words, its command (the password masked) behind a disclosure.
    private func commands(_ rows: [OnboardChanges.Row]) -> some View {
        ForEach(rows) { row in
            DisclosureGroup(row.label) {
                Text(row.shownArgv.joined(separator: " "))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityHint("Shows the command")
        }
    }
}

/// Offboarding's confirm step (the offboarding plan §5): who leaves and who takes over, what runs, how long it
/// can take, and the leaver's address typed to run it (ChangeCore D; the executor checks it, not only this
/// field). Run is the destructive action and never the default button, so Return alone doesn't start it.
/// Confirming runs exactly the plan's preview, once; its progress is on the Offboard screen.
struct OffboardConfirmSheet: View {
    let plan: OffboardChanges.Plan
    let changes: OffboardChanges
    let dismiss: () -> Void
    @State private var typed = ""
    @State private var word = ""

    private var leaver: String { plan.leaver.primaryEmail }
    /// Ten steps or more with a destructive one: the guard asks for the word `confirm` too (GamGUI's rule for a
    /// destructive bulk change), which the executor checks whatever this sheet sends.
    private var needsWord: Bool { plan.preview?.decision.requiresTypedConfirmation == true }
    private var wordMatches: Bool { !needsWord || word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Guard.typedWord }
    /// The address the executor asks for: the leaver's while a step acts on them; none for the reminder alone.
    private var toType: String? { plan.preview?.typedAddress }
    /// The field matches, as the executor compares it (trimmed, case aside): only then is Run offered.
    private var matches: Bool {
        guard let toType else { return true }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == toType.lowercased()
    }

    private func confirm() {
        let plan = plan, changes = changes, typed = toType == nil ? [] : [typed], word = needsWord ? word : ""
        dismiss()
        Task { await changes.confirm(plan, OperatorConfirmation(confirmed: true, typedWord: word, typedAddresses: typed)) }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Leaving", value: "\(plan.leaver.fullName) (\(leaver))")
                if let manager = plan.manager {
                    LabeledContent("Taking over", value: "\(manager.fullName) (\(manager.primaryEmail))")
                }
                if let recipient = plan.recipient {
                    LabeledContent("Transfer goes to", value: "\(recipient.fullName) (\(recipient.primaryEmail))")
                }
                Text(plan.header)
            } header: {
                Text("Offboard \(plan.leaver.fullName)").accessibilityAddTraits(.isHeader)
            }
            Section("What runs") {
                ForEach(Array(plan.runningRows.enumerated()), id: \.element.id) { index, row in
                    Text("\(index + 1). \(row.label)")
                }
                Text(plan.whatStopsWhat).font(.callout).foregroundStyle(.secondary)
            }
            Section {
                let final = plan.runningRows.filter { [.password, .clearRecovery, .revoke].contains($0.key) }.map { "“\($0.label)”" }
                if !final.isEmpty {
                    Label("\(ListFormatter.localizedString(byJoining: final)) can't be undone.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                if plan.runningRows.contains(where: { $0.key == .calacls }) {
                    Label("It can take up to an hour: the calendar step visits every user. Other changes in the app wait until it "
                          + "ends, and Touch ID may be asked again after the calendar step.", systemImage: "clock")
                }
                Label("Stop takes effect between steps: the step running finishes first.", systemImage: "info.circle")
            }
            if let toType {
                Section("Type \(toType) to run it") {
                    TextField("Leaver's address", text: $typed, prompt: Text(verbatim: toType))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type the leaver's address, \(toType), to run the offboarding")
                }
            }
            if needsWord {
                Section {
                    TextField("The word confirm", text: $word, prompt: Text(verbatim: Guard.typedWord))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type the word confirm to run all \(plan.runningRows.count) steps")
                } header: {
                    Text("Type \(Guard.typedWord) too")
                } footer: {
                    Text("\(plan.runningRows.count) steps, some that can't be undone: a run this long is confirmed in words as well.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) }
            // Not the confirmation action: Return in the field mustn't run an offboarding.
            ToolbarItem(placement: .primaryAction) {
                Button("Run Offboarding", role: .destructive) { confirm() }
                    .disabled(!matches || !wordMatches)
                    .help(!matches ? "Type the leaver's address first" : !wordMatches ? "Type confirm first" : "Runs exactly these steps, once")
                    .disabled(plan.preview == nil)
            }
        }
    }
}

/// The compromised-account confirm step (docs/plans/2026-10-19-compromised-account.md): whose account, what runs, what can't be undone, and the person's address typed to run it (the
/// executor checks it, not only this field). Run is destructive and never the default button.
struct CompromisedConfirmSheet: View {
    let plan: CompromisedChanges.Plan
    let changes: CompromisedChanges
    let dismiss: () -> Void
    @State private var typed = ""
    @State private var word = ""

    private var person: String { plan.person.primaryEmail }
    private var needsWord: Bool { plan.preview?.decision.requiresTypedConfirmation == true }
    private var wordMatches: Bool { !needsWord || word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Guard.typedWord }
    private var toType: String? { plan.preview?.typedAddress }
    private var matches: Bool {
        guard let toType else { return true }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == toType.lowercased()
    }

    private func confirm() {
        let plan = plan, changes = changes, typed = toType == nil ? [] : [typed], word = needsWord ? word : ""
        dismiss()
        Task { await changes.confirm(plan, OperatorConfirmation(confirmed: true, typedWord: word, typedAddresses: typed)) }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Account", value: "\(plan.person.fullName) (\(person))")
                Text(plan.header)
            } header: {
                Text("Secure \(plan.person.fullName)").accessibilityAddTraits(.isHeader)
            }
            Section("What runs") {
                ForEach(Array(plan.runningRows.enumerated()), id: \.element.id) { index, row in
                    Text("\(index + 1). \(row.label)")
                }
                Text(plan.whatStopsWhat).font(.callout).foregroundStyle(.secondary)
            }
            Section {
                let final = plan.runningRows.filter { [.password, .clearRecovery, .revoke, .filters, .sendAs, .scheduled, .drafts].contains($0.key) }
                    .map { "“\($0.label)”" }
                if !final.isEmpty {
                    Label("\(ListFormatter.localizedString(byJoining: final)) can't be undone.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                Label("Stop takes effect between steps: the step running finishes first.", systemImage: "info.circle")
            }
            if let toType {
                Section("Type \(toType) to run it") {
                    TextField("The person's address", text: $typed, prompt: Text(verbatim: toType))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type the person's address, \(toType), to run the steps")
                }
            }
            if needsWord {
                Section {
                    TextField("The word confirm", text: $word, prompt: Text(verbatim: Guard.typedWord))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type the word confirm to run all \(plan.runningRows.count) steps")
                } header: {
                    Text("Type \(Guard.typedWord) too")
                } footer: {
                    Text("\(plan.runningRows.count) steps, some that can't be undone: a run this long is confirmed in words as well.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) }
            // Not the confirmation action: Return in the field mustn't run it.
            ToolbarItem(placement: .primaryAction) {
                Button("Run Steps", role: .destructive) { confirm() }
                    .disabled(!matches || !wordMatches || plan.preview == nil)
                    .help(!matches ? "Type the person's address first" : !wordMatches ? "Type confirm first" : "Runs exactly these steps, once")
            }
        }
    }
}

/// Phishing's confirm step: the email by its Message-ID, each trash with its count (a mailbox's copies, or its copies in
/// Spam), the commands as GAM gets them, what trashing means, and the number of steps typed to run it (from ten, the word
/// `confirm` too); the executor checks both, not only these fields. Trash is the destructive action and never the
/// default button, so Return alone doesn't start it. Confirming runs exactly this preview, once; Cancel drops it.
struct PhishingConfirmSheet: View {
    let pending: PhishingChanges.Pending
    let changes: PhishingChanges
    @State private var typedCount = ""
    @State private var word = ""

    /// The steps, the number typed: one a mailbox, and one more for a mailbox with copies in Spam as well.
    private var count: Int { pending.trashes.count }
    /// The guard's own check, so the button and the executor can't disagree on what was typed.
    private var countMatches: Bool { pending.preview.decision.typedCountMatches(typedCount) }
    private var wordMatches: Bool {
        !pending.needsWord || word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Guard.typedWord
    }
    private var mailboxes: String { "\(pending.mailboxes.count) mailbox\(pending.mailboxes.count == 1 ? "" : "es")" }
    /// What the typed number counts, in words.
    private var counted: String { count == pending.mailboxes.count && emails == 1 ? "mailboxes" : "steps" }
    /// Pull All (D12): several emails in one preview, each shown with its own steps.
    private var emails: Int { pending.messages.count }
    /// "the email", or "4 emails".
    private var what: String { emails == 1 ? "the email" : "\(emails) emails" }
    /// Each email's step summaries, in order, grouped once (by position: a step is its trash's).
    private var stepsByEmail: [String: [String]] {
        Dictionary(grouping: zip(pending.trashes, pending.preview.steps), by: { $0.0.message.id }).mapValues { $0.map(\.1.summary) }
    }

    private func confirm() {
        let pending = pending, changes = changes, confirmation = OperatorConfirmation(
            confirmed: true, typedWord: pending.needsWord ? word : "", typedCount: typedCount)
        Task { await changes.confirm(pending, confirmation) }
    }

    var body: some View {
        let stepsByEmail = stepsByEmail
        Form {
            // Each email with its own steps: one section for one email, as before Pull All.
            ForEach(Array(pending.searches.enumerated()), id: \.element.message.id) { index, search in
                Section {
                    LabeledContent("Message-ID") {
                        Text(search.message.id).textSelection(.enabled)
                    }
                    if let sample = search.sample {
                        LabeledContent("From") { Text(sample.copy.from).textSelection(.enabled) }
                        LabeledContent("Subject") { Text(sample.copy.subject).textSelection(.enabled) }
                    } else if emails > 1 {
                        Label("Couldn't read a copy to show what it is: check the Message-ID.", systemImage: "questionmark.circle")
                    }
                    ForEach(pending.trashes.filter { $0.message == search.message && $0.copies > 2 }) { trash in
                        Label("\(trash.name) has \(trash.copies) copies: one email rarely arrives more than twice.",
                              systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                    // A mailbox with copies in Spam as well has two steps.
                    ForEach(Array((stepsByEmail[search.message.id] ?? []).enumerated()), id: \.offset) { _, summary in
                        Text(summary)
                    }
                } header: {
                    Text(emails == 1 ? "Trash this email from \(mailboxes)" : "Email \(index + 1) of \(emails)")
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Section {
                DisclosureGroup(count == 1 ? "Show command" : "Show \(count) commands") {
                    Text(pending.preview.steps.map(\.commandLine).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                if emails > 1 { Text("Trash \(what) from \(mailboxes): \(count) steps").accessibilityAddTraits(.isHeader) }
            }
            Section {
                Label("Each person stops seeing it at once. It stays in their Trash for 30 days, where it can be put back.",
                      systemImage: "trash")
                if pending.trashes.contains(where: { !$0.inSpam }) {
                    Label("Outside Spam, only the copies found: a mailbox that holds more by now is left as it is and shown as failed.",
                          systemImage: "info.circle")
                }
                if pending.trashes.contains(where: \.inSpam) {
                    Label("Copies in Spam are trashed by their IDs: exactly those found, nothing that arrived since.",
                          systemImage: "info.circle")
                }
                Label("Stop takes effect between steps: the one in progress finishes first, and later ones, a mailbox's Spam "
                      + "among them, don't run.", systemImage: "info.circle")
                // The guard's over-cap warning counts steps as accounts; a mailbox with copies in Spam too is two steps.
                if pending.mailboxes.count > Guard.hardCap {
                    Label("This trashes from \(mailboxes) (over the \(Guard.hardCap) safety threshold). Double-check the target set.",
                          systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                } else if emails > 1, count > Guard.hardCap {
                    Label("This runs \(count) steps for \(what) (over the \(Guard.hardCap) safety threshold). Double-check the emails "
                          + "and mailboxes above.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            }
            Section {
                TextField("Number of \(counted)", text: $typedCount, prompt: Text(verbatim: pending.typedCount))
                    .autocorrectionDisabled()
                    .accessibilityLabel("Type the number of \(counted), \(count), to trash \(what) from \(mailboxes)")
            } header: {
                Text("Type \(count) to run it")
            } footer: {
                if emails > 1 {
                    Text("One for each step above: each email's own, and a mailbox with copies in Spam as well has two.")
                } else if count != pending.mailboxes.count {
                    Text("One for each step above: a mailbox with copies in Spam as well has two.")
                }
            }
            if pending.needsWord {
                Section {
                    TextField("The word confirm", text: $word, prompt: Text(verbatim: Guard.typedWord))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type the word confirm to trash \(what) from \(mailboxes)")
                } header: {
                    Text("Type \(Guard.typedWord) too")
                } footer: {
                    Text("Ten steps or more: a change this wide is confirmed in words as well.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { changes.cancelPreview() } }
            // Not the confirmation action: Return in a field mustn't trash anything.
            ToolbarItem(placement: .primaryAction) {
                Button(emails == 1 ? "Trash from \(mailboxes)" : "Trash \(what)", role: .destructive) { confirm() }
                    .disabled(!countMatches || !wordMatches)
                    .help(!countMatches ? "Type \(count) first" : !wordMatches ? "Type confirm first" : "Runs exactly these steps, once")
            }
        }
    }
}

extension BuilderChanges {
    /// The preview `command`'s page shows in its sheet: held, or running (the sheet stays, its buttons off, until it ends).
    /// Another command's page never shows it.
    func sheetPending(for command: CuratedCommand) -> Pending? {
        switch state {
        case .previewing(let pending), .running(let pending): concerns(command) && pending.command == command.id ? pending : nil
        case .idle, .done, .problem: nil
        }
    }

    /// The sheet was closed: drops a preview still waiting, never the result the run left behind.
    func dismissPreview() {
        if case .previewing = state { dismiss() }
    }
}

/// A Builder command's confirm step: the change in words, the command exactly as GAM gets it (masked as the audit keeps it), what
/// to know first, and how much it can hurt, then Cancel or Run. Always a click, as GamGUI's Builder asks; a destructive one is
/// never the default button, so Return alone doesn't run it. Confirming runs exactly this preview, once.
struct BuilderPreviewSheet: View {
    let pending: BuilderChanges.Pending
    let changes: BuilderChanges

    private var running: Bool { changes.isBusy }

    private func confirm() {
        Task { await changes.confirm(pending, OperatorConfirmation(confirmed: true)) }
    }

    var body: some View {
        Form {
            Section(pending.title) {
                ForEach(Array(pending.preview.steps.enumerated()), id: \.offset) { _, step in
                    Text(step.summary).textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The command").font(.callout).foregroundStyle(.secondary)
                        Text(step.commandLine)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let warning = pending.warning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
            }
            Section {
                if pending.isDestructive {
                    Label("Destructive: check it, then click Run to change \(pending.preview.domain.name).",
                          systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("Changes \(pending.preview.domain.name) once you click Run.", systemImage: "pencil.circle")
                }
            }
            if running {
                Section {
                    HStack { ProgressView().controlSize(.small); Text("Running…") }
                        .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520)
        .interactiveDismissDisabled(running)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { changes.dismiss() }.disabled(running) }
            if pending.isDestructive {
                ToolbarItem(placement: .primaryAction) {
                    Button("Run", role: .destructive) { confirm() }
                        .disabled(running)
                        .help("Runs exactly this, once")
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { confirm() }
                        .disabled(running)
                        .help("Runs exactly this, once")
                }
            }
        }
    }
}

/// Inactive users' Suspend these… confirm step (GamGUI's `_inactive_suspend.html`): how many accounts, read again just now; the
/// new accounts among them, flagged in words (a new hire who hasn't signed in yet looks inactive); the admin left out; who it
/// suspends, by name, address and last sign-in; and, as the guard asks, the word `confirm` (ten or more) and the count (more
/// than 25) typed. Suspend is never the default button, so Return alone doesn't run it. Confirming runs exactly these people,
/// once, in the jobs tray with Stop; Cancel drops it.
struct InactiveSuspendSheet: View {
    let pending: InactiveSuspend.Pending
    let suspend: InactiveSuspend
    @State private var typedCount = ""
    @State private var word = ""

    private var count: Int { pending.count }
    private var countMatches: Bool { pending.preview.decision.typedCountMatches(typedCount) }
    private var wordMatches: Bool {
        !pending.needsWord || word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Guard.typedWord
    }
    private var accounts: String { "\(count) account\(count == 1 ? "" : "s")" }

    private func confirm() {
        let pending = pending, suspend = suspend
        let confirmation = OperatorConfirmation(confirmed: true, typedWord: pending.needsWord ? word : "",
                                                typedCount: pending.needsCount ? typedCount : "")
        Task { await suspend.confirm(pending, confirmation) }
    }

    var body: some View {
        Form {
            Section {
                Text("Suspend \(accounts) that \(count == 1 ? "hasn't" : "haven't") signed in for \(pending.days) days, read again just now. "
                     + "Each can't sign in until it's unsuspended; nothing in it is deleted.")
                if pending.new > 0 {
                    Label("\(pending.new) of them \(pending.new == 1 ? "was" : "were") made in the last \(pending.days) days, or when "
                          + "isn't known, marked new account below: a new hire who hasn't signed in yet looks inactive. Check them first.",
                          systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                if !pending.leftOut.isEmpty {
                    Label("Left out: \(pending.leftOut.joined(separator: ", ")), the admin this app is connected as. Suspending it "
                          + "would sign this app out.", systemImage: "info.circle")
                }
                ForEach(pending.preview.decision.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
            } header: {
                Text(pending.preview.title).accessibilityAddTraits(.isHeader)
            }
            Section("Who it suspends") {
                ForEach(pending.targets.prefix(InactiveSuspend.shown)) { target in
                    let last = target.lastLogin.isEmpty ? "never signed in" : "last sign-in \(target.lastLogin.prefix(10))"
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name)
                        Text("\(target.email) · \(last)" + (target.new ? " · new account" : ""))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if count > InactiveSuspend.shown {
                    Text("… and \(count - InactiveSuspend.shown) more.").foregroundStyle(.secondary)
                }
                DisclosureGroup(count == 1 ? "Show command" : "Show \(count) commands") {
                    Text(pending.preview.steps.map(\.commandLine).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if pending.needsWord {
                Section {
                    TextField("The word confirm", text: $word, prompt: Text(verbatim: Guard.typedWord))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type the word confirm to suspend \(accounts)")
                        .onChange(of: word) { suspend.typingChanged() }
                } header: {
                    Text("Type \(Guard.typedWord) to suspend \(count == 1 ? "it" : "them")")
                }
            }
            if pending.needsCount {
                Section {
                    TextField("Number of accounts", text: $typedCount, prompt: Text(verbatim: String(count)))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type the number of accounts, \(count), to confirm")
                        .onChange(of: typedCount) { suspend.typingChanged() }
                } header: {
                    Text("And type \(count), the number of accounts")
                }
            }
            if let problem = suspend.typedProblem {
                Section { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            Section {
                Text("Suspends exactly this list, one account at a time, in the jobs tray with Stop. Preview again for a newer one.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("⌘Return suspends them once what's asked above is typed; Escape cancels. Return alone runs nothing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { suspend.dismiss() } }
            // Not the confirmation action: Return in a field mustn't suspend anyone.
            ToolbarItem(placement: .primaryAction) {
                // ⌘Return, never Return alone: Tab doesn't reach a button with the Mac's default keyboard settings, and with fewer
                // than ten accounts the sheet has no field to type in (review of F3, 2026-11-21).
                Button("Suspend \(accounts)", role: .destructive) { confirm() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(suspend.isBusy || !countMatches || !wordMatches)
                    .help(!wordMatches ? "Type confirm first" : !countMatches ? "Type \(count) first" : "Runs exactly these suspends, once")
            }
        }
        .onChange(of: suspend.typedRefusals) {
            if let problem = suspend.typedProblem { AccessibilityNotification.Announcement(problem).post() }
        }
    }
}

/// Export to a Google Sheet… (plan F4, GamGUI's `_sheet_preview.html` and `_export_result.html`): what will run, exactly; where
/// the Sheet goes (the connected admin's own Drive, shared with nobody, no browser, no email); that it holds a fresh read; the
/// scope check, each scope said in words, never by color alone; then Export, once, exactly as held. A scope known to be refused
/// offers no Export, only Setup's delegation link. Afterwards, what became of it: made, not made or can't be told, the link only
/// when it's a Google file's, what to do, and GAM's own error a click away. Return exports, Escape cancels, said on the sheet.
struct SheetExportSheet: View {
    let exports: SheetExports
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch exports.state {
            case .idle:
                EmptyView()
            case .checking:
                Form {
                    Section {
                        HStack { ProgressView().controlSize(.small); Text("Checking what the service account may do for the admin…") }
                            .accessibilityElement(children: .combine)
                    }
                }
                .formStyle(.grouped)
            case .previewing(let pending), .running(let pending):
                preview(pending)
            case .done(let done):
                result(done)
            case .problem(let words):
                Form {
                    Section {
                        Label(words, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).textSelection(.enabled)
                    } header: {
                        Text("Export to a Google Sheet").accessibilityAddTraits(.isHeader)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .interactiveDismissDisabled(exports.isBusy)
        .toolbar {
            switch exports.state {
            case .previewing(let pending):
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { exports.dismiss() } }
                if pending.canExport {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Export to a New Sheet") {
                            Task { await exports.confirm(pending, OperatorConfirmation(confirmed: true)) }
                        }
                        .help("Runs exactly this, once")
                    }
                }
            case .checking, .running:
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") {}.disabled(true) }
            case .done, .problem, .idle:
                ToolbarItem(placement: .confirmationAction) { Button("Done") { exports.dismiss() } }
            }
        }
        .onChange(of: exports.isBusy) { _, busy in
            guard !busy, case .done(let done) = exports.state else { return }
            AccessibilityNotification.Announcement(done.outcome.said).post()
        }
    }

    private func preview(_ pending: SheetExports.Pending) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Will run").font(.callout).foregroundStyle(.secondary)
                    Text(pending.commandLine).font(.body.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                Label {
                    Text("A new Sheet named “\(pending.name)” in \(pending.owner.isEmpty ? "the connected admin's" : pending.owner + "'s") "
                         + "own Drive. It is shared with nobody, GAM opens no browser and sends no email.")
                } icon: { Image(systemName: "lock.doc") }
                Label {
                    Text("It holds a fresh read: GAM runs this read again and uploads what it gets then, so its rows can differ from the "
                         + "\(pending.rows.formatted()) row\(pending.rows == 1 ? "" : "s") on screen, and it has every row, not only those "
                         + "a filter shows.")
                } icon: { Image(systemName: "arrow.clockwise") }
            } header: {
                Text("Export \(pending.commandName) to a Google Sheet").accessibilityAddTraits(.isHeader)
            }
            Section {
                ForEach(pending.scopes) { scope in
                    let word = scope.allowed == true ? "Allowed" : scope.allowed == false ? "Not allowed" : "Not checked"
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(word) · \(scope.purpose)")
                            Text(scope.scope).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: scope.allowed == true ? "checkmark.circle.fill"
                              : scope.allowed == false ? "xmark.octagon.fill" : "questionmark.circle")
                            .foregroundStyle(scope.allowed == true ? .green : scope.allowed == false ? .red : .orange)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(word): \(scope.purpose)")
                }
                if !pending.scopeWords.isEmpty {
                    Label(pending.scopeWords, systemImage: pending.canExport ? "exclamationmark.triangle" : "hand.raised")
                }
                if let link = pending.delegationLink {
                    // A button with ⌘O, not a bare link: Tab doesn't reach a link with the Mac's default keyboard settings.
                    Button("Authorize It in the Admin Console") { openURL(link) }
                        .keyboardShortcut("o")
                        .help("Domain-Wide Delegation, with every scope this app asks for")
                    Text("⌘O opens it in your browser (Domain-Wide Delegation, every scope this app asks for). Then preview the "
                         + "export again.").font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("The service account, acting for the admin").accessibilityAddTraits(.isHeader)
            }
            Section {
                if case .running = exports.state {
                    HStack { ProgressView().controlSize(.small); Text("Exporting… GAM reads it again, then uploads it.") }
                        .accessibilityElement(children: .combine)
                } else if pending.canExport {
                    Text("Return exports it, once; Escape cancels. Changes \(pending.domain.name)'s Drive: one new file.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Nothing can be exported until the service account is allowed both. Escape closes this.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func result(_ done: SheetExports.Done) -> some View {
        let made = done.outcome.made
        let word = made == .yes ? "Made" : made == .no ? "Not made" : "Can't be told"
        return Form {
            Section {
                Label {
                    Text(done.outcome.said).textSelection(.enabled)
                } icon: {
                    Image(systemName: made == .yes && done.detail.isEmpty ? "checkmark.circle.fill"
                          : made == .no ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                LabeledContent("The Sheet", value: word)
                if let url = URL(string: done.outcome.url), SheetExport.isGoogleLink(done.outcome.url) {
                    // A button with ⌘O, not a bare link: Tab doesn't reach a link with the Mac's default keyboard settings.
                    Button("Open \(done.name)") { openURL(url) }
                        .keyboardShortcut("o")
                        .help("Opens the Sheet in your browser")
                    Text("⌘O opens it in your browser: \(done.outcome.url)").font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !done.outcome.todo.isEmpty { Text(done.outcome.todo) }
                if done.recorded {
                    Text("Kept in the audit log, and listed on Files.").font(.callout).foregroundStyle(.secondary)
                } else if !done.unrecorded.isEmpty {
                    Label("\(done.unrecorded) Files won't list it" + (SheetExport.isGoogleLink(done.outcome.url) ? ": keep the link above." : "."),
                          systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                } else {
                    Text("Nothing ran, so the audit log has no record of it and Files won't list it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Export to a Google Sheet").accessibilityAddTraits(.isHeader)
            }
            Section {
                Text(done.commandLine).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if !done.detail.isEmpty {
                    // Shown, not behind a disclosure: Tab doesn't reach one with the Mac's default keyboard settings.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GAM's error").font(.callout).foregroundStyle(.secondary)
                        Text(done.detail).font(.callout.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Return closes this.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Department for Many…'s review (roadmap 2.1): who it changes, each one's department now, the commands, and the one button that
/// runs exactly this list. Shown in place of the form inside `DepartmentForManySheet`.
struct DepartmentForManyReview: View {
    let pending: DepartmentForMany.Pending
    let model: DepartmentForMany

    var body: some View {
        let n = pending.count
        Section {
            Text("Set the department to “\(pending.department)” for \(n) \(n == 1 ? "person" : "people"), each keeping their title.")
            ForEach(pending.notes, id: \.self) { Label($0, systemImage: "info.circle") }
            ForEach(pending.preview.decision.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
        } header: {
            Text(pending.preview.title).accessibilityAddTraits(.isHeader)
        }
        Section("Who it changes") {
            ForEach(pending.people.prefix(DepartmentForMany.shown)) { person in
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.fullName.isEmpty ? person.primaryEmail : person.fullName)
                    Text("\(person.primaryEmail) \u{B7} now \(person.department.isEmpty ? "no department" : "“\(person.department)”")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if n > DepartmentForMany.shown {
                Text("\u{2026} and \(n - DepartmentForMany.shown) more.").foregroundStyle(.secondary)
            }
            DisclosureGroup(n == 1 ? "Show command" : "Show \(n) commands") {
                Text(pending.preview.steps.map(\.commandLine).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Section {
            Text("Sets exactly this list, one person at a time, in the jobs tray with Stop. Go back to change anything and preview again.")
                .font(.callout).foregroundStyle(.secondary)
            // Not the default button: Return alone changes nobody.
            Button("Set \(n) Department\(n == 1 ? "" : "s")") {
                let pending = pending, model = model
                Task { await model.confirm(pending, OperatorConfirmation(confirmed: true)) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityHint("Runs exactly the list shown, once. Command-Return does the same.")
        }
    }
}

/// Hires from a CSV's review (roadmap 2.3, GamGUI's `_onboard_bulk_preview.html`): the tally, each row left out and why, each
/// hire's steps, the commands, and the one button that runs exactly this. Shown inside `HiresFromCSVSheet`.
struct HiresFromCSVReview: View {
    let pending: HiresFromCSV.Pending
    let model: HiresFromCSV

    var body: some View {
        let n = pending.hires.count
        Section {
            Text("\(n) hire\(n == 1 ? "" : "s"): " + pending.perRole.map { "\($0.count) \($0.role)" }.joined(separator: ", ") + ".")
            if pending.creates > 0 {
                Text("\(pending.creates) account\(pending.creates == 1 ? "" : "s") created: \(pending.notifies) emailed by GAM to the "
                     + "row's notify address, \(pending.sheets) on the sign-in sheet here.")
            }
            ForEach(pending.preview.decision.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
        } header: {
            Text(pending.preview.title).accessibilityAddTraits(.isHeader)
        }
        if !pending.errors.isEmpty {
            Section("Left out (\(pending.errors.count))") {
                ForEach(pending.errors, id: \.self) { Label($0, systemImage: "xmark.circle").foregroundStyle(.secondary) }
            }
        }
        Section("Each hire") {
            ForEach(pending.hires) { hire in
                let plan = hire.plan
                DisclosureGroup {
                    ForEach(plan.rows) { Text($0.label).font(.callout) }
                    ForEach(plan.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.callout) }
                } label: {
                    Text("\(plan.name) \u{B7} \(plan.role.name) \u{B7} \(plan.rows.count) step\(plan.rows.count == 1 ? "" : "s")"
                         + (plan.creates ? " \u{B7} new account" : ""))
                }
            }
            DisclosureGroup("Show \(pending.preview.steps.count) commands") {
                Text(pending.preview.steps.map(\.commandLine).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Section {
            Text("Runs exactly these hires, one step at a time, in the jobs tray with Stop. A failed account skips that hire's other "
                 + "steps only. Choose the file again for a newer one.")
                .font(.callout).foregroundStyle(.secondary)
            // Not the default button: Return alone creates nobody.
            Button("Onboard \(n) Hire\(n == 1 ? "" : "s")") {
                let pending = pending, model = model
                Task { await model.confirm(pending, OperatorConfirmation(confirmed: true)) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityHint("Runs exactly the hires shown, once. Command-Return does the same.")
        }
    }
}

/// The Builder's sequence (GamGUI's `_sequence.html`, roadmap 2.5): the changes added with Add to Sequence, in the order they run,
/// each movable up or down or removable; Preview holds them all as one change. Its review shows every step's command and what to
/// know, asks the word `confirm` typed when the guard does (ten steps with a destructive one), and runs exactly that, once, in
/// the jobs tray and here with Stop; each step's outcome is listed after. A step added, moved or removed drops the preview.
struct BuilderSequenceSheet: View {
    let changes: BuilderChanges
    let close: () -> Void
    /// What the last export said, in words.
    @State private var exported: String?
    @Environment(SavedFiles.self) private var savedFiles: SavedFiles?
    @State private var word = ""
    @State private var stopAsked = false

    private var reviewing: BuilderChanges.Pending? {
        guard changes.concernsSequence, case .previewing(let pending) = changes.state else { return nil }
        return pending
    }

    private var running: Bool {
        guard changes.concernsSequence, case .running = changes.state else { return false }
        return true
    }

    var body: some View {
        Form {
            if let pending = reviewing {
                review(pending)
            } else if running {
                let progress = changes.sequenceProgress ?? (0, changes.sequence.count, false)
                Section {
                    Text(progress.stopping ? "Stopping after this step\u{2026}" : "Running the sequence\u{2026}")
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .accessibilityLabel("Steps done")
                        .accessibilityValue("\(progress.done) of \(progress.total)")
                    Button("Stop\u{2026}") { stopAsked = true }
                        .disabled(progress.stopping)
                        .accessibilityLabel("Stop the sequence")
                }
            } else {
                steps
                outcome
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(reviewing != nil ? "Back" : "Done") {
                    if reviewing != nil { changes.dismiss() } else { close() }
                }
                .disabled(running)
            }
            if reviewing == nil, !running {
                ToolbarItem(placement: .primaryAction) {
                    Button("Preview\u{2026}") { Task { await changes.previewSequence() } }
                        .disabled(changes.sequence.isEmpty || changes.isBusy)
                        .help("Shows every step's exact command before anything changes")
                }
            }
        }
        .confirmationDialog("Stop after this step?", isPresented: $stopAsked) {
            Button("Stop After This Step") { Task { await changes.stopSequence() } }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The step running now finishes. The rest aren't run, and what's done stays done.")
        }
    }

    @ViewBuilder private var steps: some View {
        Section {
            if changes.sequence.isEmpty {
                Text("Nothing yet. On a change's page in the Builder, fill it in and click Add to Sequence.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(changes.sequence.enumerated()), id: \.element.id) { index, queued in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(queued.name)")
                        Text(queued.step.commandLine).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    Button { changes.moveInSequence(from: index, to: index - 1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0)
                        .accessibilityLabel("Move step \(index + 1) up")
                    Button { changes.moveInSequence(from: index, to: index + 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == changes.sequence.count - 1)
                        .accessibilityLabel("Move step \(index + 1) down")
                    Button { changes.removeFromSequence(queued.id) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Remove step \(index + 1)")
                }
                .buttonStyle(.borderless)
            }
            if !changes.sequence.isEmpty {
                Button("Clear", role: .destructive) { changes.clearSequence() }
            }
        } header: {
            Text("Sequence \u{2014} \(changes.sequence.count) of \(BuilderChanges.maxSequenceSteps) steps").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Steps run in this order, each once; a step that fails doesn't stop the rest.")
        }
    }

    @ViewBuilder private var outcome: some View {
        if changes.concernsSequence {
            switch changes.state {
            case .done(let words), .problem(let words):
                Section("Last run") {
                    Text(words).font(.callout).textSelection(.enabled)
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func review(_ pending: BuilderChanges.Pending) -> some View {
        let decision = pending.preview.decision
        Section {
            Text(decision.summary)
            ForEach(decision.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor) }
            if let warning = pending.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
        } header: {
            Text(pending.title).accessibilityAddTraits(.isHeader)
        }
        Section("Steps") {
            ForEach(Array(pending.preview.steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(step.summary)")
                    Text(step.commandLine).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        Section {
            if decision.requiresTypedConfirmation {
                TextField("The word confirm", text: $word, prompt: Text(verbatim: Guard.typedWord))
                    .autocorrectionDisabled()
                    .accessibilityLabel("Type the word confirm to run this destructive sequence")
            }
            // Not the default button: Return alone runs nothing.
            Button(decision.maxRisk == .destructive ? "Run the Sequence" : "Run \(pending.preview.steps.count) Steps",
                   role: decision.maxRisk == .destructive ? .destructive : nil) {
                let pending = pending, changes = changes, word = word
                Task { await changes.confirm(pending, OperatorConfirmation(confirmed: true, typedWord: word)) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(decision.requiresTypedConfirmation && word.trimmingCharacters(in: .whitespaces).lowercased() != Guard.typedWord)
            .accessibilityHint("Runs exactly these steps, once, in order.")
        }
        Section {
            Button("Export as a Batch File\u{2026}") { export(pending) }
                .accessibilityHint("Saves these steps as a file GAM can run on its own. Nothing runs here.")
            if let exported { Text(exported).font(.callout).textSelection(.enabled) }
        } footer: {
            Text("The file runs outside this app: no preview, no confirmation, no audit record when it runs. The export itself is "
                 + "recorded in Audit. A step that sets a password can't be exported.")
        }
    }

    /// Saves the held steps as a batch file through a save panel (roadmap 5.3), recorded in Files.
    private func export(_ pending: BuilderChanges.Pending) {
        let changes = changes
        Task {
            switch await changes.exportSequence(pending) {
            case .failure(let why):
                exported = why.words
            case .success(let file):
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "gamgui-sequence.txt"
                panel.allowedContentTypes = [.plainText]
                guard panel.runModal() == .OK, let url = panel.url else {
                    exported = "Not saved. The export is still recorded in Audit."
                    return
                }
                do {
                    try Data(file.utf8).write(to: url, options: .atomic)
                    savedFiles?.record(url, what: "Builder sequence batch file")
                    exported = "Saved \(url.lastPathComponent). Read every line before you run it."
                } catch {
                    exported = "Couldn't save the file: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// No 2SV / No recovery → Email Them a Reminder… (roadmap 3.3, GamGUI's reminder card): the subject and message, starting from
/// the bucket's own words; Preview reads the directory again and lists who gets it; Send sends exactly that text to exactly
/// those people, once, with the count typed past 25. The operator's text is sent escaped, never as markup.
struct ReminderSheet: View {
    let key: String
    let model: BucketReminders
    let close: () -> Void
    @State private var subject = ""
    @State private var message = ""
    @State private var typedCount = ""
    @State private var started = false

    var body: some View {
        Form {
            switch model.key == key ? model.state : .idle {
            case .previewing(let pending):
                Section {
                    Text("Sends “\(pending.subject)” to \(pending.count) \(pending.count == 1 ? "person" : "people"), read again just now, "
                         + "from the admin this app is connected as.")
                } header: {
                    Text(pending.preview.title).accessibilityAddTraits(.isHeader)
                }
                Section("Who gets it") {
                    ForEach(pending.people.prefix(BucketReminders.shown)) { person in
                        Text("\(person.fullName) \u{2014} \(person.primaryEmail)").accessibilityElement(children: .combine)
                    }
                    if pending.count > BucketReminders.shown {
                        Text("\u{2026} and \(pending.count - BucketReminders.shown) more.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    if pending.needsCount {
                        TextField("Number of people", text: $typedCount, prompt: Text(verbatim: String(pending.count)))
                            .accessibilityLabel("Type the number of people, \(pending.count), to confirm")
                            .onChange(of: typedCount) { model.typingChanged() }
                    }
                    if let problem = model.typedProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Button("Send \(pending.count) Reminder\(pending.count == 1 ? "" : "s")") {
                        let pending = pending, model = model, typed = typedCount
                        Task { await model.confirm(pending, OperatorConfirmation(confirmed: true, typedCount: pending.needsCount ? typed : "")) }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityHint("Sends exactly this text to exactly these people, once.")
                }
            case .running:
                Section {
                    HStack { ProgressView().controlSize(.small); Text("Sending the reminders\u{2026}") }
                        .accessibilityElement(children: .combine)
                    Button("Stop After This One") { Task { await model.stop() } }
                }
            case .done(let words), .problem(let words):
                compose
                Section { Text(words).textSelection(.enabled) }
            case .checking:
                compose
                Section {
                    HStack { ProgressView().controlSize(.small); Text("Reading the directory again\u{2026}") }
                        .accessibilityElement(children: .combine)
                }
            case .idle:
                compose
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 440)
        .onAppear {
            guard !started, let start = BucketReminders.reminders[key] else { return }
            started = true
            subject = start.subject
            message = start.message
        }
        .onChange(of: subject) { model.dismiss() }
        .onChange(of: message) { model.dismiss() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(isReviewing ? "Back" : "Done") {
                    let back = isReviewing
                    model.dismiss()
                    if !back { close() }
                }
                .disabled(model.isBusy)
            }
            if !isReviewing {
                ToolbarItem(placement: .primaryAction) {
                    Button("Preview") { Task { await model.preview(key: key, subject: subject, message: message) } }
                        .disabled(model.isBusy)
                }
            }
        }
    }

    private var isReviewing: Bool {
        guard model.key == key, case .previewing = model.state else { return false }
        return true
    }

    @ViewBuilder private var compose: some View {
        Section {
            TextField("Subject", text: $subject)
            TextEditor(text: $message)
                .frame(minHeight: 160)
                .accessibilityLabel("Message")
        } header: {
            Text("Email them a reminder").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("The fix is theirs to make. Your words are sent as written, from the admin this app is connected as; nothing you type "
                 + "becomes formatting.")
        }
    }
}
