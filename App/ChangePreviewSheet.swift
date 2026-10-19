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
                              empty: "Empty: confirming clears their signature.")
            }
            if !pending.isPutBack {
                Section("Current") {
                    if let previous = pending.previous {
                        SignaturePane(html: previous.body, rendered: previous.body,
                                      label: "Current signature of \(pending.person.fullName)", height: 200)
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
            ToolbarItem(placement: .confirmationAction) {
                Button(pending.confirmLabel) { confirm() }
                    .disabled(running || (needsCount && typedCount.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
    }
}

extension CalendarChanges {
    /// The preview the sheet shows: held, or running (the sheet stays, its buttons off, until it ends).
    var sheetPending: Pending? {
        switch state {
        case .previewing(let pending), .running(let pending): pending
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

/// A calendar change's confirm step (calendars plan D4): each step in words with its command, what to know
/// first, and how it's undone; then Cancel, or Share or Remove, both off while it runs. Confirming runs exactly
/// this preview, once.
struct CalendarPreviewSheet: View {
    let pending: CalendarChanges.Pending
    let changes: CalendarChanges

    private var running: Bool { changes.isBusy }

    private func confirm() {
        Task { await changes.confirm(pending, OperatorConfirmation(confirmed: true)) }
    }

    var body: some View {
        Form {
            Section(pending.title) {
                ForEach(Array(pending.preview.steps.enumerated()), id: \.offset) { _, step in
                    Text(step.summary)
                    DisclosureGroup("Show command") {
                        Text(step.shownArgv.joined(separator: " "))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                Label(pending.undo, systemImage: "arrow.uturn.backward.circle")
            }
            if running {
                Section {
                    HStack { ProgressView().controlSize(.small); Text(pending.kind == .share ? "Sharing…" : "Removing…") }
                        .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
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
                LabeledContent("Taking over", value: "\(plan.manager.fullName) (\(plan.manager.primaryEmail))")
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
                let final = plan.runningRows.filter { [.password, .clearRecovery, .revoke, .filters, .sendAs].contains($0.key) }
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

/// Phishing's confirm step: the email by its Message-ID, every mailbox it is trashed from with its count, the
/// commands as GAM gets them, what trashing means, and the number of mailboxes typed to run it (from ten, the word
/// `confirm` too); the executor checks both, not only these fields. Trash is the destructive action and never the
/// default button, so Return alone doesn't start it. Confirming runs exactly this preview, once; Cancel drops it.
struct PhishingConfirmSheet: View {
    let pending: PhishingChanges.Pending
    let changes: PhishingChanges
    @State private var typedCount = ""
    @State private var word = ""

    private var count: Int { pending.mailboxes.count }
    private var countMatches: Bool { typedCount.trimmingCharacters(in: .whitespacesAndNewlines) == pending.typedCount }
    private var wordMatches: Bool {
        !pending.needsWord || word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Guard.typedWord
    }
    private var mailboxes: String { "\(count) mailbox\(count == 1 ? "" : "es")" }

    private func confirm() {
        let pending = pending, changes = changes, confirmation = OperatorConfirmation(
            confirmed: true, typedWord: pending.needsWord ? word : "", typedCount: typedCount)
        Task { await changes.confirm(pending, confirmation) }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Message-ID") {
                    Text(pending.search.message.id).textSelection(.enabled)
                }
                if let sample = pending.search.sample {
                    LabeledContent("From") { Text(sample.copy.from).textSelection(.enabled) }
                    LabeledContent("Subject") { Text(sample.copy.subject).textSelection(.enabled) }
                }
                ForEach(pending.mailboxes.filter { $0.copies > 2 }) { mailbox in
                    Label("\(mailbox.email) has \(mailbox.copies) copies: one email rarely arrives more than twice.",
                          systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                ForEach(pending.preview.steps, id: \.target) { step in
                    Text(step.summary)
                }
                DisclosureGroup(count == 1 ? "Show command" : "Show \(count) commands") {
                    Text(pending.preview.steps.map(\.commandLine).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Trash this email from \(mailboxes)").accessibilityAddTraits(.isHeader)
            }
            Section {
                Label("Each person stops seeing it at once. It stays in their Trash for 30 days, where it can be put back.",
                      systemImage: "trash")
                Label("Only the copies found: a mailbox that holds more by now is left as it is and shown as failed.",
                      systemImage: "info.circle")
                Label("Stop takes effect between mailboxes: the one in progress finishes first.", systemImage: "info.circle")
                ForEach(pending.preview.decision.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
            }
            Section("Type \(count) to run it") {
                TextField("Number of mailboxes", text: $typedCount, prompt: Text(verbatim: pending.typedCount))
                    .autocorrectionDisabled()
                    .accessibilityLabel("Type the number of mailboxes, \(count), to trash the email from them")
            }
            if pending.needsWord {
                Section {
                    TextField("The word confirm", text: $word, prompt: Text(verbatim: Guard.typedWord))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type the word confirm to trash the email from \(mailboxes)")
                } header: {
                    Text("Type \(Guard.typedWord) too")
                } footer: {
                    Text("Ten mailboxes or more: a change this wide is confirmed in words as well.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { changes.cancelPreview() } }
            // Not the confirmation action: Return in a field mustn't trash anything.
            ToolbarItem(placement: .primaryAction) {
                Button("Trash from \(mailboxes)", role: .destructive) { confirm() }
                    .disabled(!countMatches || !wordMatches)
                    .help(!countMatches ? "Type \(count) first" : !wordMatches ? "Type confirm first" : "Runs exactly these steps, once")
            }
        }
    }
}
