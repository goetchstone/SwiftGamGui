import Directory
import GamEngine
import Setup
import SwiftUI

/// Offboard (Off1, read-only): the form GamGUI's offboarding takes, and the plan it would run, step by
/// step with each exact `gam` line, its warnings, what a failure stops, and the auto-reply as senders will
/// read it. This build can't run it: there is no Run button, and the model it plans with has no executor
/// (`OffboardChangesTests.offboardingCantWrite`). Off2 runs the plan through ChangeCore.
struct OffboardView: View {
    let setup: SetupModel
    let directory: DirectoryStore
    let changes: OffboardChanges
    @State private var form = OffboardChanges.Form()
    @State private var restored = false
    @State private var debugApplied = false
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        VStack(spacing: 0) {
            ReadOnlyBanner()
            ScrollViewReader { scroller in
                Form {
                    Section {
                        Text(Offboarding.intro).foregroundStyle(.secondary)
                    }
                    WhoSection(form: $form, directory: directory)
                    AutoReplySection(form: $form, changes: changes)
                    ReminderSection(form: $form)
                    StepsSection(form: $form)
                    checkSection
                    if case .planned(let plan) = changes.state, plan.form == form {
                        PlanSection(plan: plan).id(Self.planAnchor)
                    }
                }
                .formStyle(.grouped)
                // A new plan is what the operator asked to see: brought into view.
                .onChange(of: planShown) { _, shown in
                    guard shown else { return }
                    withAnimation { scroller.scrollTo(Self.planAnchor, anchor: .top) }
                }
            }
        }
        // Long text wraps rather than widen the screen past the smallest window (ColumnWidths).
        .frame(minWidth: 0, maxWidth: .infinity)
        .onAppear(perform: restore)
        // Another domain: its people aren't this one's.
        .onChange(of: setup.generation) {
            form = OffboardChanges.Form()
            changes.clear()
        }
        .task(id: directory.users?.count ?? -1) { fillForSnapshot() }
        // Said once, from the window in front.
        .onChange(of: announcement) { _, text in
            if let text, appearsActive { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private static let planAnchor = "offboard.plan"

    private var planShown: Bool {
        if case .planned(let plan) = changes.state { return plan.form == form }
        return false
    }

    /// The plan's header when one is made, or why there is none.
    private var announcement: String? {
        switch changes.state {
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
                default:
                    EmptyView()
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

    /// Back on the screen: the last plan's (or refusal's) form, so the plan shown is the form's.
    private func restore() {
        guard !restored else { return }
        restored = true
        switch changes.state {
        case .planned(let plan): form = plan.form
        case .blocked(let blocked): form = blocked.form
        case .checking(let checking): form = checking
        case .idle: break
        }
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` fills the form for that leaver with alice@example.com taking over,
    /// and `SWIFTGAMGUI_TAB=plan` shows its plan, for the snapshots, once the directory is loaded.
    private func fillForSnapshot() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard directory.users != nil, !debugApplied, let leaver = environment["SWIFTGAMGUI_SELECT"] else { return }
        debugApplied = true
        form.leaver = leaver
        form.manager = "alice@example.com"
        if environment["SWIFTGAMGUI_TAB"] == "plan" {
            let form = form, changes = changes
            Task { await changes.plan(form) }
        }
        #endif
    }
}

/// Above the screen, where it can't be missed: nothing here changes anything.
private struct ReadOnlyBanner: View {
    var body: some View {
        Label("Read-only preview — this build can't run offboarding yet.", systemImage: "eye")
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
private struct AddressField: View {
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

/// "Doesn't apply" for the five steps an offboarding may leave out, and "already done" for each of the
/// eight, for a run again after a failure. Each box says which step it's for, to VoiceOver too.
private struct StepsSection: View {
    @Binding var form: OffboardChanges.Form

    var body: some View {
        Section {
            ForEach(Offboarding.optionalSteps, id: \.self) { step in
                Toggle(step.name, isOn: member(step, of: \.notApplicable))
                    .accessibilityLabel("Doesn't apply: \(step.name)")
            }
            Text("A step left out is not run and never counts as done; the plan says what leaving it out means. "
                 + "The password reset, the sign-out and turning off forwarding always run.")
                .font(.callout).foregroundStyle(.secondary)
        } header: {
            Text("Doesn't apply to this leaver? Leave a step out")
        }
        Section {
            ForEach(Offboarding.Step.allCases, id: \.self) { step in
                Toggle(step.name, isOn: member(step, of: \.done))
                    .accessibilityLabel("Already done: \(step.name)")
            }
            Text("A ticked step is not run and counts as done. Don't run one again that succeeded: GAM refuses a "
                 + "delegate that already exists and a second transfer while the first is running, and the reminder "
                 + "would be added twice.")
                .font(.callout).foregroundStyle(.secondary)
        } header: {
            Text("Running again after a failure? Tick the steps that already succeeded")
        }
    }

    private func member(_ step: Offboarding.Step,
                        of set: WritableKeyPath<OffboardChanges.Form, Set<Offboarding.Step>>) -> Binding<Bool> {
        Binding(get: { form[keyPath: set].contains(step) },
                set: { on in
                    if on { form[keyPath: set].insert(step) } else { form[keyPath: set].remove(step) }
                })
    }
}

/// GamGUI's `_offboard_preview.html`: the header, the warnings, every step in order (struck through when
/// it won't run, with why), what a failure stops, the auto-reply, and when the account may be deleted.
private struct PlanSection: View {
    let plan: OffboardChanges.Plan

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
