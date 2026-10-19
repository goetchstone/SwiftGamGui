import ChangeCore
import Directory
import GamEngine
import Setup
import SwiftUI

/// Offboard: the form GamGUI's offboarding takes, filled from a saved template, the plan it runs, step by
/// step with each exact `gam` line, its warnings, what a failure stops, and the auto-reply as senders will
/// read it; then the run, confirmed with the leaver's address typed (`OffboardConfirmSheet`), each step's
/// result as it ends, Stop between steps, and GamGUI's summary with what to do next.
struct OffboardView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: OffboardChanges
    let templates: OffboardTemplates
    /// This build has GAM: a plan can run. Without it the plan is only shown.
    let hasGam: Bool
    @State private var form = OffboardChanges.Form()
    @State private var confirming: OffboardChanges.Plan?
    /// The template the form was last filled from; nil before one is picked, or when none is saved.
    @State private var chosen: String?
    @State private var restored = false
    @State private var debugApplied = false
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        VStack(spacing: 0) {
            if !hasGam { NoGamBanner() }
            ScrollViewReader { scroller in
                Form {
                    if let run = changes.run {
                        RunSection(run: run, changes: changes) { rest in
                            form = rest
                            changes.dismissRun()
                            let changes = changes
                            Task { await changes.plan(rest) }
                        }
                        .id(Self.runAnchor)
                    }
                    Group {
                        Section {
                            Text(Offboarding.intro(adding: form.added)).foregroundStyle(.secondary)
                        }
                        TemplateSection(form: $form, chosen: $chosen, templates: templates)
                        WhoSection(form: $form, directory: directory)
                        StepsSection(form: $form)
                        AutoReplySection(form: $form, changes: changes)
                        ReminderSection(form: $form)
                        AlreadyDoneSection(form: $form)
                        checkSection
                    }
                    // Nothing in the form changes while a run is going on.
                    .disabled(changes.isRunning)
                    if case .planned(let plan) = changes.state, plan.form == form {
                        PlanSection(plan: plan, canRun: plan.preview != nil && !changes.isRunning) { confirming = plan }
                            .id(Self.planAnchor)
                    }
                }
                .formStyle(.grouped)
                // A new plan, or a run, is what the operator asked to see: brought into view.
                .onChange(of: planShown) { _, shown in
                    guard shown else { return }
                    withAnimation { scroller.scrollTo(Self.planAnchor, anchor: .top) }
                }
                .onChange(of: changes.run != nil) { _, shown in
                    guard shown else { return }
                    withAnimation { scroller.scrollTo(Self.runAnchor, anchor: .top) }
                }
            }
        }
        .sheet(item: $confirming) { plan in
            OffboardConfirmSheet(plan: plan, changes: changes) { confirming = nil }
        }
        // An edited form drops the plan's preview: a run is never of a form other than the one shown.
        .onChange(of: form) { _, edited in changes.formChanged(edited) }
        // Long text wraps rather than widen the screen past the smallest window (ColumnWidths).
        .frame(minWidth: 0, maxWidth: .infinity)
        .onAppear(perform: restore)
        // Another domain: its people aren't this one's.
        .onChange(of: setup.generation) {
            form = OffboardChanges.Form()
            chosen = nil
            fillFromDefault()
            changes.clear()
        }
        .task(id: directory.users?.count ?? -1) { fillForSnapshot() }
        // Said once, from the window in front.
        .onChange(of: announcement) { _, text in
            if let text, appearsActive { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private static let planAnchor = "offboard.plan"
    private static let runAnchor = "offboard.run"

    private var planShown: Bool {
        if case .planned(let plan) = changes.state { return plan.form == form }
        return false
    }

    /// The plan's header when one is made, or why there is none; while a run goes on, each step as it ends.
    private var announcement: String? {
        if let run = changes.run {
            if run.ended { return run.summary }
            let done = run.results.compactMap { $0 }.count
            guard done > 0, done <= run.plan.runningRows.count else { return nil }
            let row = run.plan.runningRows[done - 1]
            return "\(row.label): \(StepStatus(result: run.results[done - 1]).words)."
        }
        if let problem = changes.problem { return problem }
        return switch changes.state {
        case .planned(let plan) where plan.form == form:
            "\(plan.header). \(plan.warnings.count == 0 ? "No warnings." : "\(plan.warnings.count) warnings.")"
        case .blocked(let blocked) where blocked.form == form: blocked.reason
        default: nil
        }
    }

    /// Preview Steps, and what became of the last one: checking, refused (in words), or a plan for another
    /// form than the one shown.
    private var checkSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                switch changes.state {
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("Checking the addresses and reading the leaver's delegates…")
                case .blocked(let blocked) where blocked.form == form:
                    Label(blocked.reason, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                case .planned(let plan) where plan.form != form:
                    Label("The form changed since the last plan. Preview the steps again.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                case .planned(let plan) where plan.preview == nil && hasGam:
                    Label("This plan was changed after it was made. Preview the steps again to run them.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                default:
                    if let problem = changes.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    } else {
                        EmptyView()
                    }
                }
                Spacer()
                Button("Preview Steps") {
                    let form = form, changes = changes
                    Task { await changes.plan(form) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(changes.isChecking || setup.active == nil)
                .help("Check both addresses and show every step's exact command (⌘Return). Nothing runs.")
                .accessibilityHint("Checks both addresses and shows every step's exact command. Nothing runs.")
            }
            .accessibilityElement(children: .contain)
            if setup.active == nil {
                Text("Connect a domain on Setup first.").foregroundStyle(.secondary)
            }
        }
    }

    /// Back on the screen: the last plan's (or refusal's) form, so the plan shown is the form's; otherwise a new
    /// form, filled from the default template.
    private func restore() {
        guard !restored else { return }
        restored = true
        switch changes.state {
        case .planned(let plan): form = plan.form
        case .blocked(let blocked): form = blocked.form
        case .checking(let checking): form = checking
        case .idle:
            fillFromDefault()
            return
        }
        chosen = templates.name(of: form.template)
    }

    /// The default template, when one is saved: a new form starts from the operator's own routine.
    private func fillFromDefault() {
        guard let name = templates.defaultName, let template = templates.template(name) else { return }
        form.apply(template)
        chosen = name
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` fills the form for that leaver with alice@example.com taking over, and
    /// `SWIFTGAMGUI_TAB` shows, for the snapshots, once the directory is loaded: its plan (`plan`), the confirm
    /// sheet over it (`confirm`), or a finished run's panel (`result`, made up: nothing runs). `-added` after any
    /// of them adds every one of this app's own steps first.
    private func fillForSnapshot() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard directory.users != nil, !debugApplied, let leaver = environment["SWIFTGAMGUI_SELECT"] else { return }
        debugApplied = true
        form.leaver = leaver
        form.manager = "alice@example.com"
        guard var tab = environment["SWIFTGAMGUI_TAB"] else { return }
        if tab.hasSuffix("-added") {
            tab.removeLast("-added".count)
            form.added = Set(Offboarding.Step.addable)
        }
        guard ["plan", "confirm", "result"].contains(tab) else { return }
        let form = form, changes = changes
        Task {
            await changes.plan(form)
            guard case .planned(let plan) = changes.state else { return }
            if tab == "confirm" { confirming = plan }
            if tab == "result" { changes.showDemoRun() }
        }
        #endif
    }
}

/// Above the screen, where it can't be missed: without GAM, nothing here runs.
struct NoGamBanner: View {
    var body: some View {
        Label("This build has no GAM: the plan is shown, and can't run. Build the app again after running scripts/fetch_gam.sh.",
              systemImage: "eye")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .padding([.horizontal, .top])
    }
}

/// The leaver and the manager, each completed from the directory as it's typed.
private struct WhoSection: View {
    @Binding var form: OffboardChanges.Form
    let directory: DirectoryStore

    var body: some View {
        Section("Who") {
            AddressField(title: "Departing user", prompt: "leaver@example.com", text: $form.leaver, directory: directory)
            AddressField(title: "Manager (delegate, data and reminder)", prompt: "manager@example.com",
                         text: $form.manager, directory: directory)
            if directory.users == nil {
                Text(directory.isLoading ? "The directory is loading: suggestions follow."
                                         : "The directory isn't loaded, so there are no suggestions: type the addresses.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// An address, with the directory's people who match it offered as completions (a name or an address).
struct AddressField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let directory: DirectoryStore

    var body: some View {
        TextField(title, text: $text, prompt: Text(verbatim: prompt))
            .autocorrectionDisabled()
            .textInputSuggestions(GroupChanges.people(matching: text, in: directory.users ?? []).shown, id: \.id) { person in
                Text(person.fullName == person.primaryEmail ? person.primaryEmail : "\(person.fullName) — \(person.primaryEmail)")
                    .textInputCompletion(person.primaryEmail)
            }
    }
}

/// The auto-reply's subject and message, and the reply as senders will read it, filled in as typed.
private struct AutoReplySection: View {
    @Binding var form: OffboardChanges.Form
    let changes: OffboardChanges

    var body: some View {
        Section("Auto-reply") {
            TextField("Subject", text: $form.subject)
            TextField("Message", text: $form.message, axis: .vertical)
                .lineLimit(3...8)
            Text("{employee} (the departing person) and {manager} (who to contact) are filled in from the directory. "
                 + "An emptied field sends the default text.")
                .font(.callout).foregroundStyle(.secondary)
            if let reply = changes.autoreply(for: form) {
                SendersWillReceive(reply: reply)
            } else {
                Text("No auto-reply: it is left out of this offboarding.").foregroundStyle(.secondary)
            }
        }
    }
}

/// GamGUI's "Auto-reply senders will receive" block.
private struct SendersWillReceive: View {
    let reply: OffboardChanges.Autoreply

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(reply.subject).fontWeight(.semibold)
                Text(reply.message)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Senders will receive").font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Senders will receive: \(reply.subject). \(reply.message)")
    }
}

/// The manager's reminder: how many days out, and who else is invited.
private struct ReminderSection: View {
    @Binding var form: OffboardChanges.Form

    var body: some View {
        Section("Reminder") {
            LabeledContent("Remind the manager in") {
                HStack {
                    TextField("Days", value: $form.days, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .accessibilityLabel("Remind the manager in, days")
                    Stepper("Days", value: $form.days, in: 1...36_500)
                        .labelsHidden()
                        .accessibilityLabel("Remind the manager in, days")
                    Text("days")
                }
            }
            if form.days < 1 {
                Text("At least one day: the reminder is set for tomorrow.").font(.callout).foregroundStyle(.secondary)
            }
            TextField("Also invite to the reminder (IT or HR), optional", text: $form.invitee,
                      prompt: Text(verbatim: "it@example.com"))
                .autocorrectionDisabled()
        }
    }
}

/// The steps in run order, each saying whether it runs: the three that lock the account always do; the five a
/// leaver may not need are switched off here ("doesn't apply"), with what leaving each out means; this app's own
/// steps run only when switched on, with what each is for.
private struct StepsSection: View {
    @Binding var form: OffboardChanges.Form

    var body: some View {
        Section {
            ForEach(Offboarding.Step.allCases, id: \.self) { step in
                if let note = step.addedNote {
                    Toggle(isOn: added(step)) {
                        Text(step.name)
                        Text(note)
                    }
                    .accessibilityLabel("Adds: \(step.name)")
                    .accessibilityHint(note)
                } else if Offboarding.optionalSteps.contains(step) {
                    Toggle(isOn: runs(step)) {
                        Text(step.name)
                        if form.notApplicable.contains(step), let cost = step.leftOutCost {
                            Text("Left out: \(cost)")
                        }
                    }
                    .accessibilityLabel("Runs: \(step.name)")
                    .accessibilityHint(form.notApplicable.contains(step) ? "Left out: \(step.leftOutCost ?? "")" : "")
                } else {
                    LabeledContent(step.name) {
                        Label("Always runs", systemImage: "lock.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(step.name): always runs")
                }
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("Switch off a step that doesn't apply to this leaver: it is not run and never counts as done, and the "
                 + "plan says what leaving it out means. The reset, the sign-out and turning off forwarding lock the "
                 + "account, so they always run. Clearing recovery info and hiding from the directory are this app's own "
                 + "steps: they run only when switched on.")
        }
    }

    /// On when the step is added.
    private func added(_ step: Offboarding.Step) -> Binding<Bool> {
        Binding(get: { form.added.contains(step) },
                set: { on in
                    if on { form.added.insert(step) } else { form.added.remove(step) }
                })
    }

    /// On when the step runs: off is "doesn't apply".
    private func runs(_ step: Offboarding.Step) -> Binding<Bool> {
        Binding(get: { !form.notApplicable.contains(step) },
                set: { on in
                    if on { form.notApplicable.remove(step) } else { form.notApplicable.insert(step) }
                })
    }
}

/// "Already done" for each of the eight, for a run again after a failure: tucked away until wanted, and open
/// whenever one is ticked. Each box says which step it's for, to VoiceOver too.
private struct AlreadyDoneSection: View {
    @Binding var form: OffboardChanges.Form
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup("Running again after a failure? Tick the steps that already succeeded",
                            isExpanded: Binding(get: { expanded || !form.done.isEmpty }, set: { expanded = $0 })) {
                ForEach(Offboarding.routine(adding: form.added), id: \.self) { step in
                    Toggle(step.name, isOn: done(step))
                        .accessibilityLabel("Already done: \(step.name)")
                }
                Text("A ticked step is not run and counts as done. Don't run one again that succeeded: GAM refuses a "
                     + "delegate that already exists and a second transfer while the first is running, and the reminder "
                     + "would be added twice.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func done(_ step: Offboarding.Step) -> Binding<Bool> {
        Binding(get: { form.done.contains(step) },
                set: { on in
                    if on { form.done.insert(step) } else { form.done.remove(step) }
                })
    }
}

/// The saved templates: pick one to fill the form (which steps run, the auto-reply, the reminder and its
/// invitee; never the addresses or the ticks), save the form as a new one or over the one picked, make one
/// the default the screen opens on, or delete one. Replacing and deleting are asked first.
private struct TemplateSection: View {
    @Binding var form: OffboardChanges.Form
    @Binding var chosen: String?
    let templates: OffboardTemplates
    @State private var naming = false
    @State private var newName = ""
    @State private var replacing: String?
    @State private var deleting: String?
    @State private var outcome: (text: String, failed: Bool)?
    @Environment(\.appearsActive) private var appearsActive

    private var saved: Offboarding.Template? { chosen.flatMap(templates.template) }
    private var changed: Bool { saved.map { $0 != form.template } ?? false }
    private var canSave: Bool { templates.openProblem == nil && form.template.problem == nil }

    var body: some View {
        Section {
            Picker("Template", selection: pick) {
                if chosen == nil { Text("None").tag(String?.none) }
                ForEach(templates.names, id: \.self) { name in
                    Text(name == templates.defaultName ? "\(name) (default)" : name).tag(Optional(name))
                }
            }
            Text("Runs \(form.template.runs.count) of \(Offboarding.routine(adding: form.added).count) steps: "
                 + form.template.runs.map(\.name).joined(separator: " → ") + ".")
                .font(.callout).foregroundStyle(.secondary)
            if let chosen, changed {
                Label("Changed from “\(chosen)”: these changes are for this offboarding only, unless you update the template.",
                      systemImage: "pencil")
                    .font(.callout)
            }
            HStack {
                Button("Save as New Template…") {
                    newName = ""
                    naming = true
                }
                .disabled(!canSave)
                .help("Keep which steps run, the auto-reply, the reminder and its invitee, under a new name")
                if let chosen, changed {
                    Button("Update “\(chosen)”") { save(chosen, replacing: true) }
                        .disabled(!canSave)
                        .help("Save these settings over the template “\(chosen)”")
                }
                Spacer()
                if let chosen {
                    Menu("More") {
                        Button("Open with “\(chosen)” by Default") { makeDefault(chosen) }
                            .disabled(templates.defaultName == chosen)
                        Button("Delete “\(chosen)”…", role: .destructive) { deleting = chosen }
                    }
                    .fixedSize()
                    .accessibilityLabel("More template actions")
                }
            }
            if let problem = form.template.problem {
                Label("Can't be saved as a template: \(problem)", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor).font(.callout)
            }
            if let outcome {
                Label(outcome.text, systemImage: outcome.failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .symbolRenderingMode(.multicolor).font(.callout)
            }
            if let problem = templates.openProblem {
                Label("Templates can't be saved: \(problem)", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor).font(.callout)
            } else if let aside = templates.quarantined {
                Label("The saved templates couldn't be read, so they were moved aside to \(aside.lastPathComponent) "
                      + "in the app's folder, untouched. The starters are shown instead.", systemImage: "info.circle")
                    .font(.callout)
            }
        } header: {
            Text("Template")
        }
        .alert("Save as Template", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { save(newName, replacing: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps which steps run, the auto-reply, the reminder and its invitee. Not the two addresses or the ticks.")
        }
        .confirmationDialog("Replace the template “\(replacing ?? "")”?", isPresented: present($replacing)) {
            Button("Replace") { if let name = replacing { save(name, replacing: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its steps, auto-reply, reminder and invitee become this form's. The old ones aren't kept.")
        }
        .confirmationDialog("Delete the template “\(deleting ?? "")”?", isPresented: present($deleting)) {
            Button("Delete", role: .destructive) { if let name = deleting { delete(name) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This form keeps what it was filled with. Templates aren't kept anywhere else.")
        }
    }

    /// Picking a template fills the form from it.
    private var pick: Binding<String?> {
        Binding(get: { chosen }, set: { name in
            chosen = name
            if let name, let template = templates.template(name) { form.apply(template) }
            outcome = nil
        })
    }

    private func present(_ name: Binding<String?>) -> Binding<Bool> {
        Binding(get: { name.wrappedValue != nil }, set: { if !$0 { name.wrappedValue = nil } })
    }

    private func save(_ name: String, replacing: Bool) {
        do {
            guard let saved = try templates.save(name, form.template, replacing: replacing) else { return }
            chosen = saved
            say(replacing ? "Updated “\(saved)”." : "Saved “\(saved)”.", failed: false)
        } catch .exists(let name) {
            self.replacing = name
        } catch {
            say(error.message, failed: true)
        }
    }

    private func makeDefault(_ name: String) {
        do {
            try templates.setDefault(name)
            say("Offboard opens with “\(name)”.", failed: false)
        } catch {
            say(error.message, failed: true)
        }
    }

    private func delete(_ name: String) {
        do {
            try templates.delete(name)
            if chosen == name { chosen = nil }
            say("Deleted “\(name)”.", failed: false)
        } catch {
            say(error.message, failed: true)
        }
    }

    /// Shown under the buttons, and spoken from the window in front.
    private func say(_ text: String, failed: Bool) {
        outcome = (text, failed)
        if appearsActive { AccessibilityNotification.Announcement(text).post() }
    }
}

/// GamGUI's `_offboard_preview.html`: the header, the warnings, every step in order (struck through when
/// it won't run, with why), what a failure stops, the auto-reply, and when the account may be deleted.
private struct PlanSection: View {
    let plan: OffboardChanges.Plan
    let canRun: Bool
    let run: () -> Void

    var body: some View {
        Section {
            ForEach(plan.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Warning: \(warning)")
            }
            Text("Each step shows the exact gam command it would run, in order.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(Array(plan.rows.enumerated()), id: \.element.id) { index, row in
                StepRow(number: index + 1, row: row)
            }
            Text(plan.whatStopsWhat)
            if let reply = plan.autoreply { SendersWillReceive(reply: reply) }
            ForEach(plan.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
            }
            if canRun {
                HStack {
                    Spacer()
                    Button("Offboard \(plan.leaver.primaryEmail)…", action: run)
                        .help("Asks you to type the leaver's address, then runs exactly these steps")
                        .accessibilityHint("Opens the confirmation: type the leaver's address to run exactly these steps.")
                }
            }
        } header: {
            Text(plan.header)
                .font(.headline)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// One step: its name and what it does, then its exact command; or, struck through, why it won't run.
private struct StepRow: View {
    let number: Int
    let row: OffboardChanges.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch row.status {
            case .runs(let commandLine):
                Text("\(number). \(row.label)").fontWeight(.semibold)
                Text(row.summary).foregroundStyle(.secondary)
                Text(commandLine)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Command: \(commandLine)")
            case .alreadyDone:
                Text("\(number). \(Text(row.label).strikethrough())")
                Text("Already done: not run, and counts as succeeded.").foregroundStyle(.secondary)
            case .leftOut(let cost):
                Text("\(number). \(Text(row.label).strikethrough())")
                Text("Doesn't apply: left out. \(cost)").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A step's result in words and a symbol, never color alone.
struct StepStatus {
    let words: String
    let symbol: String

    init(result: RunOutcome.Step?, running: Bool = false) {
        switch result {
        case nil: (words, symbol) = running ? ("Running", "arrow.triangle.2.circlepath") : ("Waiting", "circle.dotted")
        case .succeeded?: (words, symbol) = ("Done", "checkmark.circle.fill")
        case .failed?: (words, symbol) = ("Failed", "xmark.octagon.fill")
        case .skipped(let reason)?: (words, symbol) = ("Not run: \(reason.hasPrefix("Not run: ") ? String(reason.dropFirst(9)) : reason)", "minus.circle")
        case .waiting?: (words, symbol) = ("Waiting", "hourglass")
        }
    }
}

/// The run: "Offboarding… N of M · step", each step as it ends, and Stop between steps; then GamGUI's summary,
/// what to know (the leaver may still be signed in), what to do next, and Preview the Rest.
private struct RunSection: View {
    let run: OffboardChanges.Run
    let changes: OffboardChanges
    let previewTheRest: (OffboardChanges.Form) -> Void
    @State private var askingStop = false

    private var done: Int { run.results.compactMap { $0 }.count }

    var body: some View {
        Section {
            if let elsewhere = changes.runElsewhere {
                Label("This offboarding acts on \(elsewhere), not the domain connected now. It stops after the step "
                      + "running.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            ForEach(Array(run.plan.runningRows.enumerated()), id: \.element.id) { index, row in
                let status = StepStatus(result: run.results[index], running: !run.ended && index == done)
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(index + 1). \(row.label)", systemImage: status.symbol)
                        .symbolRenderingMode(.multicolor)
                    Text(detail(run.results[index]) ?? status.words).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1), \(row.label): \(status.words)")
            }
            if run.ended {
                if let problem = run.auditProblem { Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor) }
                if run.mayStillBeSignedIn {
                    Label("The leaver may still be signed in, and their app passwords and connected apps may still work: "
                          + "“\(Offboarding.Step.revoke.name)” didn't run to completion. Fix what it reports and run it again (it is safe "
                          + "to repeat).", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                Text(run.next)
                HStack {
                    Spacer()
                    if !run.isComplete {
                        Button("Preview the Rest") { previewTheRest(run.rest) }
                            .help("A new plan with the steps that succeeded ticked as already done")
                    }
                    Button("Done") { changes.dismissRun() }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(run.stopping ? "Stopping after this step…" : "Offboarding… \(done) of \(run.plan.runningRows.count)"
                         + (done < run.plan.runningRows.count ? " · \(run.plan.runningRows[done].label)" : ""))
                    Spacer()
                    Button("Stop After This Step…") { askingStop = true }
                        .disabled(run.stopping)
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text(run.ended ? run.summary : "Offboarding \(run.plan.leaver.primaryEmail)")
                .font(.headline)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        }
        .confirmationDialog("Stop the offboarding after this step?", isPresented: $askingStop) {
            Button("Stop After This Step", role: .destructive) {
                let changes = changes
                Task { await changes.stop() }
            }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The step running now finishes; the ones after it don't run. Preview the Rest runs them later.")
        }
    }

    /// GAM's words for a failure, or the reason a step didn't run.
    private func detail(_ result: RunOutcome.Step?) -> String? {
        switch result {
        case .failed(let message, _)?: message
        case .skipped(let reason)?: reason
        case .succeeded(let output)? where output == Executor.toleratedOutput: output
        default: nil
        }
    }
}
