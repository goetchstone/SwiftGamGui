import ChangeCore
import Directory
import GamEngine
import Setup
import SwiftUI

/// Onboard: one new hire through one preview. The form (GamGUI's `onboarding.html`) picks one of this app's
/// roles (edited in `OnboardRolesSheet`), names the hire and who gets the checklist, and can create the
/// account. "Preview Onboarding…" holds every step as one preview (`OnboardChanges`); only its sheet runs
/// it. The run panel shows each step as it ends, the sign-in card the moment the account exists, the wait
/// for Google with Stop, and afterwards a retry of what failed, as a new preview.
struct OnboardView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: OnboardChanges
    let roles: OnboardRoles
    let templates: SignatureTemplates
    let groups: GroupStore
    let hasGam: Bool
    @State private var editingRoles = false
    /// Debug snapshots only: what the role editor opens on.
    @State private var rolesStart: OnboardRolesSheet.Selection?
    @SceneStorage("onboard.role") private var roleName = ""
    @State private var name = ""
    @State private var email = ""
    @State private var manager = ""
    @State private var assignee = ""
    @State private var createAccount = false
    @State private var sendWelcome = false
    @State private var first = ""
    @State private var last = ""
    @State private var assigneeApplied = false
    @State private var debugApplied = false
    @Environment(\.appearsActive) private var appearsActive

    private var role: RoleTemplate? { roles.role(named: roleName) }

    private var hire: Hire {
        Hire(name: name, email: email, manager: manager, assignee: assignee, createAccount: createAccount, first: first, last: last,
             sendWelcome: sendWelcome)
    }

    var body: some View {
        Form {
            if let card = changes.card {
                OnboardCredentialCard(card: card, changes: changes)
            }
            if let run = changes.run {
                OnboardRunSections(run: run, changes: changes)
            } else {
                formSections
            }
        }
        .formStyle(.grouped)
        // Long text wraps rather than widen the screen past the smallest window (ColumnWidths).
        .frame(minWidth: 0, maxWidth: .infinity)
        .task { debugSelection() }
        .onChange(of: roles.roles.map(\.name), initial: true) { _, names in
            if !names.contains(roleName) { roleName = names.first ?? "" }
        }
        .onChange(of: changes.defaultAssignee, initial: true) { _, admin in
            // The connected admin, once (§9 Q7); clearing it still means the new hire.
            guard !assigneeApplied, assignee.isEmpty, !admin.isEmpty else { return }
            assigneeApplied = true
            assignee = admin
        }
        .sheet(item: Binding(get: { changes.pending }, set: { if $0 == nil { changes.cancelPreview() } })) { pending in
            OnboardPreviewSheet(pending: pending, changes: changes)
        }
        .sheet(isPresented: $editingRoles) {
            OnboardRolesSheet(roles: roles, templates: templates, groups: groups, start: rolesStart) { editingRoles = false }
        }
        .onChange(of: announcement) { _, text in
            if let text, appearsActive { AccessibilityNotification.Announcement(text).post() }
        }
    }

    // MARK: the form

    @ViewBuilder private var formSections: some View {
        Section("New hire") {
            TextField("Name", text: $name, prompt: Text("Jordan Lee"))
            TextField("Email", text: $email, prompt: Text("jordan@example.com"))
            TextField("Manager", text: $manager, prompt: Text("manager@example.com"))
            TextField("Assignee", text: $assignee, prompt: Text("Blank: the new hire"))
                .accessibilityHint("Whose Google Tasks gets the checklist. Leave blank for the new hire.")
            Text("Assignee: whose Google Tasks gets the checklist (blank = the new hire).")
                .font(.callout).foregroundStyle(.secondary)
            Toggle(isOn: $sendWelcome) {
                Text("Also send the welcome email")
                Text("The role's welcome email, filled in for them, to the email above, after everything else.")
            }
            Toggle(isOn: $createAccount) {
                Text("Create the Google account")
                Text("With a temporary password shown once on a sign-in card; they must change it at first sign-in. "
                     + "Uses the role's org unit and signature.")
            }
            if createAccount {
                TextField("First name", text: $first, prompt: Text(Onboarding.splitName(name: name, first: "", last: "").first))
                TextField("Last name", text: $last, prompt: Text(Onboarding.splitName(name: name, first: "", last: "").last))
            }
        }
        Section {
            if let problem = roles.openProblem {
                Label("The saved roles can't be read: \(problem)", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            } else if roles.roles.isEmpty {
                Text("No roles yet. Add one: its checklist, org unit, signature, groups and calendars.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Role", selection: $roleName) {
                    ForEach(roles.roles, id: \.name) { role in
                        Text("\(role.name) (\(role.steps.count) step\(role.steps.count == 1 ? "" : "s"))").tag(role.name)
                    }
                    // The selection always has an item, as Signatures' picker does: one that matched none (while the
                    // roles load) left the picker blank after, built with Xcode 27.1 (failure log 2026-10-24).
                    if role == nil { Text("Choose a role\u{2026}").tag(roleName) }
                }
                if let role { RoleSummary(role: role, templates: templates, welcomeSaved: roles.welcome(named: role.welcome) != nil) }
            }
        } header: {
            HStack {
                Text("Role")
                Spacer()
                Button("Edit Roles\u{2026}") { editingRoles = true }
                    .help("Add, change or delete the roles a new hire can have")
            }
        }
        Section {
            HStack(alignment: .firstTextBaseline) {
                if let reason = blocked {
                    Label(reason, systemImage: "info.circle").foregroundStyle(.secondary)
                } else if let problem = changes.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                Spacer()
                Button("Preview Onboarding\u{2026}") { preview() }
                    .disabled(blocked != nil)
                    .accessibilityLabel("Preview onboarding for \(shownName)")
                    .accessibilityHint("Shows every step before anything changes.")
            }
        }
    }

    private var shownName: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (email.isEmpty ? "the new hire" : email) : name
    }

    private func preview() {
        guard let role else { return }
        let hire = hire, template = role.signature.isEmpty ? nil : templates.body(role.signature)
        // The role's welcome email as saved now; the preview holds it rendered, so a later edit doesn't change it.
        let welcome = roles.welcome(named: role.welcome).map { (name: role.welcomeName, email: $0) }
        Task { await changes.preview(hire: hire, role: role, signatureTemplate: template, welcome: welcome) }
    }

    /// Why Preview can't go ahead, in words; nil when it can. The model checks again, and refuses in GamGUI's words.
    private var blocked: String? {
        if setup.active == nil { return "Connect a domain on Setup first." }
        if !hasGam { return "This build has no GAM. Build the app again after running scripts/fetch_gam.sh." }
        guard let role else { return roles.roles.isEmpty ? "Add a role first: Edit Roles\u{2026}" : "Choose a role." }
        if changes.isBusy { return "Onboarding is running\u{2026}" }
        return OnboardChanges.refusal(hire: hire, role: role)
    }

    // MARK: words for VoiceOver

    /// What changed, said once: each step as it ends (the account with its card), then how the run and the
    /// wait ended. Never the password.
    private var announcement: String? {
        guard let run = changes.run else { return nil }
        if !run.ended {
            guard let index = run.results.lastIndex(where: { $0 != nil }), let result = run.results[index] else { return nil }
            let row = run.plan.rows[index]
            if row.kind == .account, let card = changes.card { return "Account created for \(card.email); sign-in sheet shown." }
            let word = switch result {
            case .succeeded: "done"
            case .failed: "failed"
            case .skipped: "not run"
            case .waiting: "waiting for Google"
            }
            return "\(row.label): \(word)."
        }
        let done = run.results.count { $0?.isSucceeded == true }
        var said = "Onboarding \(run.plan.email.isEmpty ? run.plan.assignee : run.plan.email): \(done) of \(run.results.count) steps done."
        if let finishing = changes.finishing {
            switch finishing.phase {
            case .waiting, .trying: said += " \(finishing.waiting) waiting for Google."
            case .done: said += " Finishing setup done."
            case .stopped: said += " Finishing setup stopped."
            case .gaveUp: said += " Finishing setup: \(run.notDone.count) not done."
            }
        }
        return said
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` picks a role and `SWIFTGAMGUI_TAB` fills the form (`create`), shows a
    /// made-up finished run (`result`, no gam), or opens the role editor on a role (`roles`) or the Default welcome
    /// email (`welcome`), for the snapshots.
    private func debugSelection() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard !debugApplied, environment["SWIFTGAMGUI_SNAPSHOT"] != nil else { return }
        debugApplied = true
        if let role = environment["SWIFTGAMGUI_SELECT"] { roleName = role }
        guard let tab = environment["SWIFTGAMGUI_TAB"] else { return }
        if tab == "roles" || tab == "welcome" {
            rolesStart = tab == "welcome" ? .welcome(Onboarding.defaultWelcome) : nil
            editingRoles = true
            return
        }
        name = "Jordan Lee"
        email = "jordan@example.com"
        createAccount = true
        sendWelcome = true
        if tab == "result", let role {
            changes.showDemoResult(hire: hire, role: role, signatureTemplate: templates.body(role.signature),
                                   welcome: roles.welcome(named: role.welcome).map { (name: role.welcomeName, email: $0) })
        }
        #endif
    }
}

/// What a role gives a new hire, before the preview.
private struct RoleSummary: View {
    let role: RoleTemplate
    let templates: SignatureTemplates
    let welcomeSaved: Bool

    var body: some View {
        LabeledContent("Checklist", value: role.steps.joined(separator: " \u{B7} "))
        LabeledContent("Org unit", value: Onboarding.shownOrgUnit(role.orgUnit))
        if !role.signature.isEmpty {
            LabeledContent("Signature") {
                if templates.body(role.signature) == nil {
                    Label("\u{201C}\(role.signature)\u{201D} isn't saved on Signatures", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                } else {
                    Text("\u{201C}\(role.signature)\u{201D}, for an account created here")
                }
            }
        }
        if !role.groups.isEmpty { LabeledContent("Groups", value: role.groups.joined(separator: ", ")) }
        if !role.calendars.isEmpty { LabeledContent("Calendars", value: role.calendars.joined(separator: ", ")) }
        LabeledContent("Welcome email") {
            if welcomeSaved {
                Text("\u{201C}\(role.welcomeName)\u{201D}, when sent")
            } else {
                Label("\u{201C}\(role.welcomeName)\u{201D} isn't saved: pick another in Edit Roles\u{2026}",
                      systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
        }
    }
}

/// The run panel: each step as it went, GamGUI's tallies, the wait for Google, and what's next.
private struct OnboardRunSections: View {
    let run: OnboardChanges.Run
    let changes: OnboardChanges

    var body: some View {
        Section(run.isRetry ? "Retrying for \(who)" : "Onboarding \(who)") {
            if let problem = run.accountProblem {
                Label(problem.summary, systemImage: "xmark.octagon.fill").symbolRenderingMode(.multicolor)
                DisclosureGroup("GAM's error") {
                    Text(problem.detail).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            ForEach(run.plan.rows) { row in
                StepRow(row: row, result: run.results[row.index], notDone: run.notDone[row.index],
                        running: changes.isRunning && run.results.firstIndex(where: { $0 == nil }) == row.index)
            }
            if run.ended {
                ForEach(run.tallies, id: \.self) { Text($0) }
            }
            if let audit = run.auditProblem {
                Label(audit, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            if let problem = changes.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
        }
        if let finishing = changes.finishing {
            FinishingSection(finishing: finishing, changes: changes)
        }
        if run.ended {
            Section {
                HStack {
                    let failed = changes.failedSteps.count
                    if failed > 0 {
                        Button("Retry the \(failed) That Failed\u{2026}") { Task { await changes.previewRetry() } }
                            .disabled(changes.isBusy)
                            .accessibilityLabel("Retry the \(failed) that failed")
                            .accessibilityHint("Shows exactly those steps again before anything changes.")
                    }
                    Spacer()
                    Button("Start Another Hire") { changes.startAnother() }
                        .disabled(changes.isBusy)
                }
            }
        }
    }

    private var who: String { run.plan.email.isEmpty ? run.plan.assignee : run.plan.email }
}

/// One step: a mark and words (never color alone), GAM's error behind a disclosure.
private struct StepRow: View {
    let row: OnboardChanges.Row
    let result: RunOutcome.Step?
    let notDone: OnboardChanges.Run.NotDone?
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(row.label).frame(maxWidth: .infinity, alignment: .leading)
                Text(status).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: symbol).symbolRenderingMode(.multicolor)
            }
            .accessibilityElement(children: .combine)
            if let detail {
                DisclosureGroup("GAM's error") {
                    Text(detail).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var symbol: String {
        if notDone != nil { return "xmark.circle.fill" }
        switch result {
        case nil: return running ? "arrow.triangle.2.circlepath" : "circle.dotted"
        case .succeeded?: return "checkmark.circle.fill"
        case .failed?: return "xmark.circle.fill"
        case .skipped?: return "minus.circle"
        case .waiting?: return "hourglass"
        }
    }

    private var status: String {
        if let notDone { return "Not done: \(notDone.reason)" }
        switch result {
        case nil: return running ? "Running\u{2026}" : "Not run yet"
        case .succeeded?: return "Done"
        case .failed(let message, let kind)?:
            return "Failed: " + (kind.map { $0 == .unknown ? message : $0.remediation } ?? message)
        case .skipped(let reason)?: return "Not run: \(reason)"
        case .waiting(let message)?: return message.hasPrefix("Waits for step") ? "Waiting: \(message)" : "Waiting for Google"
        }
    }

    private var detail: String? {
        if let detail = notDone?.detail { return detail }
        if case .failed(let message, let kind)? = result, kind != nil, kind != .unknown { return message }
        return nil
    }
}

/// GamGUI's FinishJob panel for one hire: the rounds, when the next try is, and Stop.
private struct FinishingSection: View {
    let finishing: OnboardChanges.Finishing
    let changes: OnboardChanges

    var body: some View {
        Section(title) {
            if finishing.isLive {
                ProgressView(value: Double(finishing.round), total: Double(max(finishing.rounds, 1)))
                    .accessibilityLabel("Rounds tried")
                    .accessibilityValue("\(finishing.round) of \(finishing.rounds)")
                Text("A new account takes Google a few minutes to set up before its signature, calendars and tasks can be "
                     + "changed, so GAM GUI keeps trying for about \(minutes) minutes. You can leave this screen; quitting asks first.")
                if let next = finishing.nextTryAt {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let seconds = max(0, Int((next - ContinuousClock.now).components.seconds))
                        Text("Next try in \(seconds) s.").monospacedDigit()
                    }
                }
                Text("A change you make meanwhile to their signature or calendars may be overwritten \u{2014} Stop this first.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Stop") { changes.stopFinishing() }
                    .accessibilityLabel("Stop finishing setup for \(finishing.email)")
            }
        }
    }

    private var title: String {
        switch finishing.phase {
        case .waiting, .trying: "Waiting for Google\u{2026} \(finishing.round) / \(finishing.rounds)"
        case .done: "Finishing setup \u{2014} done"
        case .stopped: "Finishing setup \u{2014} stopped"
        case .gaveUp: "Finishing setup \u{2014} \(changes.run?.notDone.count ?? 0) not done"
        }
    }

    private var minutes: Int { max(1, Int((Double(Onboarding.newAccountWaits.reduce(.zero, +).components.seconds) / 60).rounded())) }
}
