import AppKit
import ChangeCore
import Directory
import GamEngine
import Setup
import SwiftUI

/// Compromised Account (docs/plans/2026-10-19-compromised-account.md): for a person who stays employed but whose account
/// was taken over. Check Account reads what an attacker commonly changes, and changes nothing; the operator ticks what
/// to undo; the lock and the picks are previewed as exact `gam` lines, then run once with the person's address typed,
/// each step's result as it ends, Stop between steps, and the account checked again.
struct CompromisedView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: CompromisedChanges
    let logs: IncidentLogs
    /// This build has GAM: a plan can run. Without it the plan is only shown.
    let hasGam: Bool
    /// A person another screen asked to secure (Users' "Secure Account…"): a new form for them, checked at once, with
    /// nothing ticked (the operator says whether the password was already reset). Cleared once taken.
    @Binding var requested: String?
    @State private var form = CompromisedChanges.Form()
    @State private var confirming: CompromisedChanges.Plan?
    @State private var debugApplied = false
    /// Debug snapshots of the reports: scrolled into view once read.
    @State private var scrollToReports = false
    @Environment(\.appearsActive) private var appearsActive

    private var check: CompromisedChanges.Check? { changes.check.flatMap { $0.isFor(form.person) ? $0 : nil } }

    var body: some View {
        VStack(spacing: 0) {
            if !hasGam { NoGamBanner() }
            ScrollViewReader { scroller in
                Form {
                    if let run = changes.run {
                        CompromisedRunSection(run: run, changes: changes) { rest in
                            form = rest
                            if let check = changes.check { form.keepPicks(in: check) }
                            changes.dismissRun()
                            let form = form, changes = changes
                            Task { await changes.plan(form) }
                        }
                        .id(Self.runAnchor)
                    }
                    Group {
                        Section {
                            Text("For a person who stays employed but whose account was taken over. Check the account first: it "
                                 + "reads what an attacker commonly changes, and changes nothing. Then tick what to undo, and "
                                 + "preview the steps.")
                                .foregroundStyle(.secondary)
                        }
                        whoSection
                        if let check {
                            FindingsSection(check: check)
                            AccountSection(check: check)
                            ForwardingSection(check: check)
                            FiltersSection(check: check, picked: $form.filters)
                            DelegatesSection(check: check, picked: $form.delegates)
                            SendAsSection(check: check, picked: $form.sendAs)
                            DraftsSection(check: check, discard: $form.discardDrafts)
                            AdminRolesSection(check: check)
                            StepsSection(form: $form, draftsChosen: check.drafts(form.discardDrafts).count)
                            previewSection
                        }
                    }
                    .disabled(changes.isRunning)
                    if case .planned(let plan) = changes.planState, plan.form == form, check != nil {
                        CompromisedPlanSection(plan: plan, canRun: plan.preview != nil && !changes.isRunning) { confirming = plan }
                            .id(Self.planAnchor)
                    }
                    if setup.active != nil {
                        IncidentLogsSection(person: check?.user.primaryEmail, logs: logs, directory: directory).id(Self.reportsAnchor)
                    }
                }
                .formStyle(.grouped)
                .onChange(of: planShown) { _, shown in
                    guard shown else { return }
                    withAnimation { scroller.scrollTo(Self.planAnchor, anchor: .top) }
                }
                .onChange(of: changes.run != nil) { _, shown in
                    guard shown else { return }
                    withAnimation { scroller.scrollTo(Self.runAnchor, anchor: .top) }
                }
                .onChange(of: scrollToReports) { _, wanted in
                    if wanted { scroller.scrollTo(Self.reportsAnchor, anchor: .top) }
                }
            }
        }
        .sheet(item: $confirming) { plan in
            CompromisedConfirmSheet(plan: plan, changes: changes) { confirming = nil }
        }
        // An edited form drops the plan's preview: a run is never of a form other than the one shown.
        .onChange(of: form) { _, edited in changes.formChanged(edited) }
        // Another person: the ticks and the picks were the last one's.
        .onChange(of: form.person) { old, new in
            guard old.trimmingCharacters(in: .whitespaces).lowercased() != new.trimmingCharacters(in: .whitespaces).lowercased() else { return }
            (form.done, form.restOf, form.filters, form.delegates, form.sendAs) = ([], "", [], [], [])
            form.discardDrafts = .none
        }
        // A check again (after a run): the ticks on what's gone are dropped.
        .onChange(of: changes.check?.id) {
            if let check = changes.check { form.keepPicks(in: check) }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onAppear {
            if let check = changes.check, form.person.isEmpty, requested == nil { form.person = check.asked }
        }
        .onChange(of: requested, initial: true) { _, email in
            guard let email else { return }
            requested = nil
            // Mid-run the form stays as it is: the check says why it can't start.
            if !changes.isRunning { form = CompromisedChanges.Form(person: email) }
            let changes = changes
            Task { await changes.check(email) }
        }
        .onChange(of: setup.generation) {
            form = CompromisedChanges.Form()
            changes.clear()
            logs.clear()
        }
        .task(id: directory.users?.count ?? -1) { fillForSnapshot() }
        .onChange(of: announcement) { _, text in
            if let text, appearsActive { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private static let planAnchor = "compromised.plan"
    private static let runAnchor = "compromised.run"
    private static let reportsAnchor = "compromised.reports"

    private var planShown: Bool {
        if case .planned(let plan) = changes.planState { return plan.form == form }
        return false
    }

    /// The check's outcome, the plan's header or why there is none, and each step as a run ends it.
    private var announcement: String? {
        if let run = changes.run {
            if run.ended { return run.summary }
            let done = run.results.compactMap { $0 }.count
            guard done > 0, done <= run.plan.runningRows.count else { return nil }
            return "\(run.plan.runningRows[done - 1].label): \(StepStatus(result: run.results[done - 1]).words)."
        }
        if let problem = changes.problem { return problem }
        switch changes.planState {
        case .planned(let plan) where plan.form == form: return plan.header
        case .blocked(let blocked) where blocked.form == form: return blocked.reason
        default: break
        }
        switch changes.checkState {
        case .checked(let check): return "Checked \(check.user.primaryEmail). \(check.findings.count) things to look at."
        case .failed(_, let reason): return reason
        default: return nil
        }
    }

    private var whoSection: some View {
        Section("Whose account") {
            AddressField(title: "Person whose account was taken over", prompt: "person@example.com", text: $form.person,
                         directory: directory)
                .onSubmit(checkAccount)
            HStack(alignment: .firstTextBaseline) {
                switch changes.checkState {
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("Reading the account, its filters, forwarding, delegates, send-as addresses and admin roles…")
                case .failed where changes.checkFailure(for: form.person) != nil:
                    Label(changes.checkFailure(for: form.person) ?? "", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                case .checked(let check) where !check.isFor(form.person):
                    Label("The address changed since the last check. Check the account again.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                default:
                    if let problem = changes.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                }
                Spacer()
                Button(check == nil ? "Check Account" : "Check Again", action: checkAccount)
                    .keyboardShortcut("r")
                    .disabled(changes.isChecking || changes.isRunning || setup.active == nil)
                    .help("Read what an attacker commonly changes (⌘R, or Return in the field). Nothing changes.")
                    .accessibilityHint("Reads the account's filters, forwarding, delegates, send-as addresses and admin roles. Nothing changes.")
            }
            .accessibilityElement(children: .contain)
            if setup.active == nil {
                Text("Connect a domain on Setup first.").foregroundStyle(.secondary)
            }
        }
    }

    private func checkAccount() {
        let person = form.person, changes = changes
        Task { await changes.check(person) }
    }

    private var previewSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                switch changes.planState {
                case .blocked(let blocked) where blocked.form == form:
                    Label(blocked.reason, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                case .planned(let plan) where plan.form != form:
                    Label("The ticks changed since the last plan. Preview the steps again.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                case .planned(let plan) where plan.preview == nil && hasGam:
                    Label("This plan was changed after it was made. Preview the steps again to run them.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                Spacer()
                Button("Preview Steps") {
                    let form = form, changes = changes
                    Task { await changes.plan(form) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(changes.isChecking || changes.isRunning)
                .help("Show every step's exact command (⌘Return). Nothing runs.")
                .accessibilityHint("Shows every step's exact command. Nothing runs.")
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` checks that person once the directory is loaded; `SWIFTGAMGUI_TAB` then shows
    /// the plan with every filter that hides or forwards mail, every delegate and every other send-as address ticked
    /// (`plan`), the confirm sheet over it (`confirm`), a finished run's panel (`result`, made up: nothing runs), or the
    /// person's incident logs, then every account's by the first address on their flagged sign-in (`reports`).
    private func fillForSnapshot() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard directory.users != nil, !debugApplied, let person = environment["SWIFTGAMGUI_SELECT"] else { return }
        debugApplied = true
        form.person = person
        let tab = environment["SWIFTGAMGUI_TAB"] ?? ""
        let changes = changes
        Task {
            await changes.check(person)
            if tab == "reports", let email = changes.check?.user.primaryEmail {
                await logs.pull(IncidentLogs.Query(applications: ActivityLogs.incidentDefault, users: [email], hours: 72, ip: ""))
                if let ip = logs.pull?.addresses.first {
                    await logs.pull(IncidentLogs.Query(applications: ActivityLogs.incidentDefault, users: [], hours: 72, ip: ip))
                }
                scrollToReports = true
                return
            }
            guard ["plan", "confirm", "result"].contains(tab), let check = changes.check else { return }
            form.filters = Set(((try? check.filters.get()) ?? []).filter(\.hidesOrForwards).map(\.id))
            form.delegates = Set((try? check.delegates.get()) ?? [])
            form.sendAs = Set(((try? check.sendAs.get()) ?? []).filter { !$0.isPrimary }.map(\.address))
            // The drafts that share the newest one's subject: an attacker's batch.
            if let subject = (try? check.drafts.get())?.first?.subject { form.discardDrafts = .subjectContaining(subject) }
            await changes.plan(form)
            guard case .planned(let plan) = changes.planState else { return }
            if tab == "confirm" { confirming = plan }
            if tab == "result" { changes.showDemoRun() }
        }
        #endif
    }
}

// MARK: the check

/// A read's failure, in GAM's words: never shown as "none".
private struct Unread: View {
    let what: String
    let problem: UserAccess.Problem

    var body: some View {
        Label("Couldn't read \(what): \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .textSelection(.enabled)
            .accessibilityLabel("Couldn't read \(what). \(problem.summary)")
    }
}

/// What the check found worth looking at first, each in a sentence with a symbol.
private struct FindingsSection: View {
    let check: CompromisedChanges.Check

    var body: some View {
        Section {
            if check.isConnectedAdmin {
                Label("This app is connected as \(check.user.primaryEmail): it can't secure that account (the sign-out would "
                      + "delete the app's own authorization). Use another admin's setup.", systemImage: "exclamationmark.octagon.fill")
                    .symbolRenderingMode(.multicolor)
            }
            if check.findings.isEmpty {
                Label("Nothing stood out in what could be read.", systemImage: "checkmark.circle")
            }
            ForEach(check.findings, id: \.self) { finding in
                Label(finding, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .accessibilityLabel("To look at: \(finding)")
            }
        } header: {
            Text("What to look at").accessibilityAddTraits(.isHeader)
        }
    }
}

private struct AccountSection: View {
    let check: CompromisedChanges.Check

    var body: some View {
        let account = check.account
        Section("Account") {
            LabeledContent("Name", value: account.fullName)
            LabeledContent("Address", value: account.primaryEmail)
            LabeledContent("Suspended", value: account.suspended ? "Yes" : "No")
            LabeledContent("2-Step Verification",
                           value: account.enrolledIn2SV ? (account.enforcedIn2SV ? "On, enforced" : "On") : (account.enforcedIn2SV ? "Off, enforced" : "Off"))
            LabeledContent("Recovery email", value: account.recoveryEmail.isEmpty ? "None" : account.recoveryEmail)
            LabeledContent("Recovery phone", value: account.recoveryPhone.isEmpty ? "None" : account.recoveryPhone)
            LabeledContent("Super admin", value: account.isAdmin ? "Yes" : "No")
        }
        .textSelection(.enabled)
    }
}

private struct ForwardingSection: View {
    let check: CompromisedChanges.Check

    var body: some View {
        Section {
            switch check.forwarding {
            case .success(let forwarding?): LabeledContent("Automatic forwarding", value: forwarding.words)
            case .success(nil): LabeledContent("Automatic forwarding", value: "Gmail didn't say")
            case .failure(let problem): Unread(what: "forwarding", problem: problem)
            }
            switch check.forwardingAddresses {
            case .success(let addresses) where addresses.isEmpty:
                Text("No forwarding addresses.").foregroundStyle(.secondary)
            case .success(let addresses):
                ForEach(addresses) { address in
                    LabeledContent(address.address, value: address.status == "accepted" ? "Verified: forwarding can go here" : address.status)
                }
            case .failure(let problem): Unread(what: "forwarding addresses", problem: problem)
            }
        } header: {
            Text("Forwarding")
        } footer: {
            Text("“Turn off forwarding” always runs. The addresses stay listed: removing one is in Gmail's settings.")
        }
        .textSelection(.enabled)
    }
}

/// Every filter, what it matches and does, with a box to delete it. None is ticked to start.
private struct FiltersSection: View {
    let check: CompromisedChanges.Check
    @Binding var picked: Set<String>

    var body: some View {
        Section {
            switch check.filters {
            case .success(let filters) where filters.isEmpty:
                Text("No filters.").foregroundStyle(.secondary)
            case .success(let filters):
                ForEach(filters) { filter in
                    Toggle(isOn: pick(filter.id)) {
                        Text(filter.words)
                        if filter.hidesOrForwards {
                            Label("Hides mail or sends it on: check it's the person's own", systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                    .accessibilityLabel("Delete the filter: \(filter.words)")
                    .accessibilityHint(filter.hidesOrForwards ? "Hides mail or sends it on." : "")
                }
            case .failure(let problem): Unread(what: "the filters", problem: problem)
            }
        } header: {
            Text("Gmail filters")
        } footer: {
            Text("Tick each filter to delete. The whole filter goes, with all it does. Labels the person made show as their IDs.")
        }
    }

    private func pick(_ id: String) -> Binding<Bool> {
        Binding(get: { picked.contains(id) }, set: { if $0 { picked.insert(id) } else { picked.remove(id) } })
    }
}

private struct DelegatesSection: View {
    let check: CompromisedChanges.Check
    @Binding var picked: Set<String>

    var body: some View {
        Section {
            switch check.delegates {
            case .success(let delegates) where delegates.isEmpty:
                Text("No delegates.").foregroundStyle(.secondary)
            case .success(let delegates):
                ForEach(delegates, id: \.self) { delegate in
                    Toggle(delegate, isOn: pick(delegate))
                        .accessibilityLabel("Remove the delegate \(delegate)")
                }
            case .failure(let problem): Unread(what: "the delegates", problem: problem)
            }
        } header: {
            Text("Mail delegates")
        } footer: {
            Text("A delegate can read, send and delete the person's mail. Tick each to remove.")
        }
    }

    private func pick(_ address: String) -> Binding<Bool> {
        Binding(get: { picked.contains(address) }, set: { if $0 { picked.insert(address) } else { picked.remove(address) } })
    }
}

private struct SendAsSection: View {
    let check: CompromisedChanges.Check
    @Binding var picked: Set<String>

    var body: some View {
        Section {
            switch check.sendAs {
            case .success(let addresses):
                ForEach(addresses) { address in
                    if address.isPrimary {
                        Text(address.words)
                    } else {
                        Toggle(address.words, isOn: pick(address.address))
                            .accessibilityLabel("Remove the send-as address \(address.words)")
                    }
                }
            case .failure(let problem): Unread(what: "the send-as addresses", problem: problem)
            }
        } header: {
            Text("Send mail as")
        } footer: {
            Text("Tick each address to take off the person's “Send mail as” list. Their own address stays.")
        }
    }

    private func pick(_ address: String) -> Binding<Bool> {
        Binding(get: { picked.contains(address) }, set: { if $0 { picked.insert(address) } else { picked.remove(address) } })
    }
}

/// The person's drafts, newest first, and what to do with them: keep them, delete every one, or only those whose subject
/// holds some text (a phishing batch's subject). Keeping them is the start.
private struct DraftsSection: View {
    let check: CompromisedChanges.Check
    @Binding var discard: CompromisedChanges.Form.Discard
    @State private var subject = ""
    private let shown = 50

    private enum Choice: Hashable { case keep, all, matching }

    private var choice: Binding<Choice> {
        Binding(get: {
            switch discard {
            case .none: .keep
            case .all: .all
            case .subjectContaining: .matching
            }
        }, set: { picked in
            switch picked {
            case .keep: discard = .none
            case .all: discard = .all
            case .matching: discard = .subjectContaining(subject)
            }
        })
    }

    var body: some View {
        Section {
            switch check.drafts {
            case .success(let drafts) where drafts.isEmpty:
                Text("No drafts.").foregroundStyle(.secondary)
            case .success(let drafts):
                let chosen = check.drafts(discard).count
                Text(drafts.count >= Compromised.Draft.cap ? "The newest \(Compromised.Draft.cap) drafts, newest first."
                     : "\(drafts.count) draft\(drafts.count == 1 ? "" : "s"), newest first.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Drafts", selection: choice) {
                    Text("Keep them").tag(Choice.keep)
                    Text("Delete all \(drafts.count)").tag(Choice.all)
                    Text("Delete those whose subject contains…").tag(Choice.matching)
                }
                .pickerStyle(.radioGroup)
                if case .subjectContaining = discard {
                    TextField("Subject contains", text: $subject, prompt: Text(verbatim: drafts.first?.subject ?? ""))
                        .autocorrectionDisabled()
                        .onChange(of: subject) { _, text in discard = .subjectContaining(text) }
                        .accessibilityLabel("Delete the drafts whose subject contains")
                }
                if discard != .none {
                    Text("\(chosen) draft\(chosen == 1 ? "" : "s") will be deleted, for good.").fontWeight(.semibold)
                }
                ForEach(drafts.prefix(shown)) { draft in
                    let when = draft.when?.formatted(date: .abbreviated, time: .shortened) ?? draft.date
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.subject.isEmpty ? "(no subject)" : draft.subject)
                        Text(when).font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if drafts.count > shown {
                    Text("Showing the newest \(shown) of \(drafts.count).").font(.callout)
                }
            case .failure(let problem): Unread(what: "the drafts", problem: problem)
            }
        } header: {
            Text("Drafts")
        } footer: {
            Text("Anyone signed in to the account can send a draft. Deleting is for good, as Gmail's Discard: Gmail's log keeps "
                 + "the record of them.")
        }
        .onAppear { if case .subjectContaining(let text) = discard { subject = text } }
    }
}

private struct AdminRolesSection: View {
    let check: CompromisedChanges.Check

    var body: some View {
        Section {
            switch check.adminRoles {
            case .success(let roles) where roles.isEmpty:
                Text(check.account.isDelegatedAdmin ? "No role assigned directly: one comes through a group. See the Admin console."
                     : "No admin roles.").foregroundStyle(.secondary)
            case .success(let roles):
                ForEach(roles) { role in Text(role.words) }
            case .failure(let problem): Unread(what: "the admin roles", problem: problem)
            }
        } header: {
            Text("Admin roles")
        } footer: {
            Text("Shown, not changed here: remove a role in the Admin console.")
        }
        .textSelection(.enabled)
    }
}

/// The lock: the reset (often already done), the two steps that always run, and the three switches.
private struct StepsSection: View {
    @Binding var form: CompromisedChanges.Form
    /// How many drafts the form's choice moves to Trash.
    let draftsChosen: Int

    var body: some View {
        Section {
            Toggle(isOn: resetDone) {
                Text("Password already reset")
                Text("Tick when you reset it in the Admin console: “\(Compromised.Step.password.name)” isn't run, and nothing waits "
                     + "for it. Otherwise it sets a random password, and you give the person a new one afterwards.")
            }
            .accessibilityLabel("Already done: \(Compromised.Step.password.name)")
            ForEach([Compromised.Step.revoke, .forward], id: \.self) { step in
                if form.done.contains(step) {
                    Toggle(isOn: done(step)) {
                        Text("\(step.name): already done")
                        Text("It succeeded in the last run, so it isn't run again. Untick to run it.")
                    }
                    .accessibilityLabel("Already done: \(step.name)")
                } else {
                    LabeledContent(step.name) {
                        Label("Always runs", systemImage: "lock.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(step.name): always runs")
                }
            }
            ForEach(Compromised.Step.switchable, id: \.self) { step in
                if form.done.contains(step) {
                    Toggle(isOn: done(step)) {
                        Text("\(step.name): already done")
                        Text("It succeeded in the last run, so it isn't run again. Untick to run it.")
                    }
                    .accessibilityLabel("Already done: \(step.name)")
                } else {
                    Toggle(isOn: switched(step)) {
                        Text(step.name)
                        if let note = step.note { Text(note) }
                    }
                    .accessibilityLabel("Runs: \(step.name)")
                    .accessibilityHint(step.note ?? "")
                }
            }
            let picks = [(form.filters.count, "filter", "delete"), (form.delegates.count, "delegate", "remove"),
                         (form.sendAs.count, "send-as address", "remove"), (draftsChosen, "draft", "delete")]
                .filter { $0.0 > 0 }
            Text(picks.isEmpty ? "Nothing ticked to undo above: only the lock runs."
                 : "Also: " + picks.map { "\($0.2) \($0.0) \($0.1)\($0.0 == 1 ? "" : ($0.1.hasSuffix("s") ? "es" : "s"))" }
                    .joined(separator: ", ") + ".")
                .font(.callout).foregroundStyle(.secondary)
        } header: {
            Text("Steps")
        } footer: {
            Text("The sign-out ends every session and revokes app passwords and connected apps: the person signs in again and "
                 + "re-grants the apps they use.")
        }
    }

    private var resetDone: Binding<Bool> { done(.password) }

    private func done(_ step: Compromised.Step) -> Binding<Bool> {
        Binding(get: { form.done.contains(step) }, set: { if $0 { form.done.insert(step) } else { form.done.remove(step) } })
    }

    private func switched(_ step: Compromised.Step) -> Binding<Bool> {
        Binding(get: { form.switchedOn.contains(step) }, set: { if $0 { form.switchedOn.insert(step) } else { form.switchedOn.remove(step) } })
    }
}

// MARK: the plan and the run

/// Every step in order with its exact command, or struck through when already done; what a failure stops; then Secure.
private struct CompromisedPlanSection: View {
    let plan: CompromisedChanges.Plan
    let canRun: Bool
    let run: () -> Void

    var body: some View {
        Section {
            Text("Each step shows the exact gam command it would run, in order.").font(.callout).foregroundStyle(.secondary)
            ForEach(Array(plan.rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 4) {
                    switch row.status {
                    case .runs(let full):
                        // Thousands of draft IDs would be a page of text, and spoken one by one: the start, then how much.
                        let commandLine = full.count > 400 ? String(full.prefix(400)) + "… (\(full.count.formatted()) characters in all)" : full
                        Text("\(index + 1). \(row.label)").fontWeight(.semibold)
                        Text(row.summary).foregroundStyle(.secondary)
                        Text(commandLine)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityLabel("Command: \(commandLine)")
                    case .alreadyDone:
                        Text("\(index + 1). \(Text(row.label).strikethrough())")
                        Text("Already done: not run, and counts as succeeded.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            Text(plan.whatStopsWhat)
            if canRun {
                HStack {
                    Spacer()
                    Button("Secure \(plan.person.primaryEmail)…", action: run)
                        .help("Asks you to type the person's address, then runs exactly these steps")
                        .accessibilityHint("Opens the confirmation: type the person's address to run exactly these steps.")
                }
            }
        } header: {
            Text(plan.header).font(.headline).textSelection(.enabled).accessibilityAddTraits(.isHeader)
        }
    }
}

/// The run: each step as it ends and Stop between steps; then the summary, what to do next, and Preview the Rest.
private struct CompromisedRunSection: View {
    let run: CompromisedChanges.Run
    let changes: CompromisedChanges
    let previewTheRest: (CompromisedChanges.Form) -> Void
    @State private var askingStop = false

    private var done: Int { run.results.compactMap { $0 }.count }

    var body: some View {
        Section {
            ForEach(Array(run.plan.runningRows.enumerated()), id: \.element.id) { index, row in
                let status = StepStatus(result: run.results[index], running: !run.ended && index == done)
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(index + 1). \(row.label)", systemImage: status.symbol).symbolRenderingMode(.multicolor)
                    Text(detail(run.results[index]) ?? status.words).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1), \(row.label): \(status.words)")
            }
            if run.ended {
                if let problem = run.auditProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                if run.mayStillBeSignedIn {
                    Label("The attacker may still be signed in, and app passwords and connected apps may still work: "
                          + "“\(Compromised.Step.revoke.name)” didn't run to completion. Fix what it reports and run it again (it is "
                          + "safe to repeat).", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                Text(run.isComplete
                     ? "The account was checked again below: anything made before the sign-out shows there. Next: give the person "
                        + "a new password if the reset ran here, and have them turn on 2-Step Verification and re-grant the apps "
                        + "they use."
                     : "To finish: fix what the failed step reports, then Preview the Rest: it ticks the lock steps that succeeded "
                        + "as already done. The account was checked again below.")
                HStack {
                    Spacer()
                    if !run.isComplete {
                        Button("Preview the Rest") { previewTheRest(run.rest) }
                            .help("A new plan with the steps that succeeded left out")
                    }
                    Button("Done") { changes.dismissRun() }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(run.stopping ? "Stopping after this step…" : "Securing… \(done) of \(run.plan.runningRows.count)"
                         + (done < run.plan.runningRows.count ? " · \(run.plan.runningRows[done].label)" : ""))
                    Spacer()
                    Button("Stop After This Step…") { askingStop = true }.disabled(run.stopping)
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text(run.ended ? run.summary : "Securing \(run.plan.person.primaryEmail)")
                .font(.headline).textSelection(.enabled).accessibilityAddTraits(.isHeader)
        }
        .confirmationDialog("Stop after this step?", isPresented: $askingStop) {
            Button("Stop After This Step", role: .destructive) {
                let changes = changes
                Task { await changes.stop() }
            }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The step running now finishes; the ones after it don't run. Preview the Rest runs them later.")
        }
    }

    private func detail(_ result: RunOutcome.Step?) -> String? {
        switch result {
        case .failed(let message, _)?: message
        case .skipped(let reason)?: reason
        default: nil
        }
    }
}


// MARK: the incident logs

/// Pull Incident Logs: the activity logs an incident needs, for a window, some accounts (none: every one) and an IP
/// address, each a table in the one shape with its CSV. Reads only; the field starts with the checked person.
private struct IncidentLogsSection: View {
    let person: String?
    let logs: IncidentLogs
    let directory: DirectoryStore
    @State private var hours = ActivityLogs.defaultHours
    @State private var accounts = ""
    @State private var ip = ""
    @State private var chosen = Set(ActivityLogs.incidentDefault)
    @State private var flaggedOnly = false
    @State private var exported: (text: String, failed: Bool)?
    @Environment(\.appearsActive) private var appearsActive

    private var typedAccounts: [String] { IncidentLogs.Query.accounts(accounts) }

    private var problem: String? {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        if !ip.isEmpty, !Address.isIP(ip) { return "“\(ip)” isn't one IP address." }
        if let odd = typedAccounts.first(where: { !Address.looksLikeEmail($0) }) { return "“\(odd)” isn't one email address." }
        if typedAccounts.count > 20 { return "At most 20 accounts at once: leave the field empty for every account." }
        // GAM fails the whole log for one address that isn't a user (its entityUnknownWarning): said here first. Chrome's reads
        // one with no events at all, as if nothing happened, so with Chrome picked the directory must be there to check.
        if !typedAccounts.isEmpty, directory.users == nil, chosen.contains(.chrome) {
            return "Chrome's log checks the accounts against the directory first: load it on Home."
        }
        if !typedAccounts.isEmpty, let users = directory.users {
            let known = Set(users.map { $0.primaryEmail.lowercased() })
            if let stranger = typedAccounts.first(where: { !known.contains($0.lowercased()) }) {
                return "“\(stranger)” isn't an account's primary address in the directory."
            }
        }
        if chosen.isEmpty { return "Pick at least one log." }
        return nil
    }

    var body: some View {
        Section {
            Picker("Over the last", selection: $hours) {
                ForEach(ActivityLogs.hours, id: \.self) { hours in Text(Self.window(hours)).tag(hours) }
            }
            .fixedSize()
            TextField("Accounts (empty for every account)", text: $accounts, prompt: Text(verbatim: "person@example.com, other@example.com"))
                .autocorrectionDisabled()
            HStack {
                TextField("Only from IP address (optional)", text: $ip, prompt: Text(verbatim: "198.51.100.23"))
                    .autocorrectionDisabled()
                if let addresses = logs.pull?.addresses, !addresses.isEmpty {
                    Menu("Seen in the sign-ins") {
                        ForEach(addresses.prefix(20), id: \.self) { address in Button(address) { ip = address } }
                    }
                    .fixedSize()
                    .accessibilityLabel("Addresses seen in the last pull's sign-ins, flagged ones first")
                }
            }
            DisclosureGroup("Logs: \(ActivityLogs.Application.allCases.filter(chosen.contains).map(\.name).joined(separator: ", "))") {
                ForEach(ActivityLogs.Application.allCases, id: \.self) { application in
                    Toggle(isOn: pick(application)) {
                        Text(application.name)
                        Text(application.about)
                    }
                    .accessibilityLabel("Read the \(application.name) log")
                }
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor) }
            HStack {
                Toggle("Only what Google flagged", isOn: $flaggedOnly)
                Spacer()
                if logs.isPulling { ProgressView().controlSize(.small) }
                Button("Pull Incident Logs") {
                    let query = IncidentLogs.Query(applications: ActivityLogs.Application.allCases.filter(chosen.contains), users: typedAccounts,
                                                   hours: hours, ip: ip.trimmingCharacters(in: .whitespaces))
                    let logs = logs
                    Task { await logs.pull(query) }
                }
                .disabled(problem != nil || logs.isPulling)
                .help("Read each log picked, for these accounts and that address. Nothing changes.")
            }
            if let exported {
                Label(exported.text, systemImage: exported.failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .symbolRenderingMode(.multicolor).font(.callout)
            }
            if let pull = logs.pull {
                HStack {
                    Text(Self.describe(pull.query) + (pull.ended ? "" : " Reading…")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Export All…") { exportAll(pull) }
                        .disabled(!pull.ended || !pull.logs.contains { (try? $0.rows.get()) != nil })
                        .help("Save every log that was read as CSV files in a new folder, with a note of what was pulled")
                        .accessibilityLabel("Export every log as CSV files into a new folder")
                }
                ForEach(pull.logs) { log in
                    LogGroup(log: log, asked: pull.query.hours, flaggedOnly: flaggedOnly, startsOpen: log.application == .login) {
                        export(log, of: pull.query)
                    }
                }
            }
        } header: {
            Text("Pull incident logs").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("From Google's audit logs, which can lag by up to a few hours. The phish may have reached others: filter every "
                 + "log by the attacker's address to find each account they reached. Failed sign-ins from it show who typed "
                 + "their password into the fake page.")
        }
        .onChange(of: person, initial: true) { _, person in
            if let person, accounts.isEmpty { accounts = person }
        }
    }

    private func pick(_ application: ActivityLogs.Application) -> Binding<Bool> {
        Binding(get: { chosen.contains(application) }, set: { if $0 { chosen.insert(application) } else { chosen.remove(application) } })
    }

    static func window(_ hours: Int) -> String { IncidentLogs.window(hours) }

    static func describe(_ query: IncidentLogs.Query) -> String {
        "Over the last \(window(query.hours)), "
            + (query.users.isEmpty ? "every account" : query.users.joined(separator: ", "))
            + (query.ip.isEmpty ? "" : ", from \(query.ip)") + ", newest first."
    }

    /// The log as a CSV in the one shape, to a file the operator picks: private (0600), whole or not at all.
    private func export(_ log: IncidentLogs.Log, of query: IncidentLogs.Query) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(log.application.rawValue)-log.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.message = "The \(log.application.name) log. " + Self.describe(query)
        let text = IncidentLogs.csv(log)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try AuditExport.writePrivately(text, to: destination)
                say("Exported the \(log.application.name) log to \(destination.lastPathComponent).", failed: false)
            } catch {
                say("Couldn't export to \(destination.lastPathComponent): \(error.localizedDescription)", failed: true)
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    /// Every log that was read, into a new private folder in the folder the operator picks (`IncidentLogs.exportAll`).
    private func exportAll(_ pull: IncidentLogs.Pull) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "A new folder of every log that was read goes here. " + Self.describe(pull.query)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let parent = panel.url else { return }
            do {
                let exported = try IncidentLogs.exportAll(pull, into: parent)
                let skipped = exported.unread.isEmpty ? ""
                    : " Not read, so not exported: " + exported.unread.map(\.name).joined(separator: ", ") + "."
                say("Exported \(exported.written.count) logs to “\(exported.folder.lastPathComponent)”.\(skipped)", failed: !exported.unread.isEmpty)
            } catch {
                say("Couldn't export to \(parent.lastPathComponent): \(error.localizedDescription). Nothing was left there.", failed: true)
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    private func say(_ text: String, failed: Bool) {
        exported = (text, failed)
        if appearsActive { AccessibilityNotification.Announcement(text).post() }
    }
}

/// One log of a pull: its name, how many events and how many flagged, the table, and Export CSV.
private struct LogGroup: View {
    let log: IncidentLogs.Log
    let asked: Int
    let flaggedOnly: Bool
    let export: () -> Void
    @State private var open: Bool

    init(log: IncidentLogs.Log, asked: Int, flaggedOnly: Bool, startsOpen: Bool, export: @escaping () -> Void) {
        self.log = log
        self.asked = asked
        self.flaggedOnly = flaggedOnly
        self.export = export
        _open = State(initialValue: startsOpen)
    }

    private var title: String {
        switch log.rows {
        case .failure: return "\(log.application.name): couldn't be read"
        case .success(let rows):
            let flagged = rows.filter(\.flagged).count
            let people = Set(rows.map(\.who)).count
            return "\(log.application.name): \(rows.count) event\(rows.count == 1 ? "" : "s")"
                + (flagged > 0 ? ", \(flagged) flagged" : "") + (rows.isEmpty ? "" : ", \(people) account\(people == 1 ? "" : "s")")
                + (log.hours < asked ? " (the last \(IncidentLogsSection.window(log.hours)): the most the Gmail log reads)" : "")
        }
    }

    var body: some View {
        DisclosureGroup(title, isExpanded: $open) {
            ActivityList(result: log.rows.map { flaggedOnly ? $0.filter(\.flagged) : $0 }, capped: log.capped,
                         what: "\(log.application.name) events", showsWho: true)
            if case .success(let rows) = log.rows, !rows.isEmpty {
                HStack {
                    Spacer()
                    Button("Export CSV…", action: export)
                        .help("Save this log's events as a CSV file")
                        .accessibilityLabel("Export the \(log.application.name) log as a CSV file")
                }
            }
        }
    }
}

/// A log's events as rows: when, who, what in words with Google's flag said, the IP address, and what else it says.
/// At most `shown` rows, and the rest counted.
private struct ActivityList: View {
    let result: Result<[ActivityLogs.Row], UserAccess.Problem>
    let capped: Bool
    let what: String
    let showsWho: Bool
    private let shown = 300

    var body: some View {
        switch result {
        case .failure(let problem):
            Label("Couldn't read the \(what): \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor).textSelection(.enabled)
        case .success(let rows) where rows.isEmpty:
            Text("None.").foregroundStyle(.secondary)
        case .success(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("When")
                    if showsWho { Text("Who") }
                    Text("What")
                    Text("IP address")
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityHidden(true)
                ForEach(rows.prefix(shown)) { row in
                    let when = row.date?.formatted(date: .abbreviated, time: .shortened) ?? row.time
                    GridRow {
                        Text(when)
                        if showsWho { Text(row.who) }
                        VStack(alignment: .leading, spacing: 2) {
                            if row.flagged {
                                Label(row.words + " · flagged", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                            } else {
                                Text(row.words)
                            }
                            if !row.details.isEmpty {
                                Text(row.details.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Text(row.ip.isEmpty ? "—" : row.ip)
                    }
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel([when, showsWho ? row.who : nil, row.words, row.flagged ? "flagged by Google" : nil,
                                         row.details.isEmpty ? nil : row.details.joined(separator: ", "),
                                         row.ip.isEmpty ? nil : "from \(row.ip)"].compactMap(\.self).joined(separator: ", "))
                }
            }
            if rows.count > shown {
                Text("Showing the newest \(shown) of \(rows.count). Export the CSV for all of them, or narrow the window or the address.")
                    .font(.callout)
            }
            if capped {
                Label("The newest \(ActivityLogs.cap) per account were read: older \(what) weren't, and the CSV doesn't have them "
                      + "either. Narrow the window to read further back.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor).font(.callout)
            }
        }
    }
}
