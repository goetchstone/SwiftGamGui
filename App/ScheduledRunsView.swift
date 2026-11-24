import Directory
import Stores
import SwiftUI

/// Schedules on screen (plan F7a, GamGUI's `_audit_run_schedule.html` and Home's "Scheduled audit runs"): which audit runs are due
/// on the connected domain, and a run's schedule and the runs it keeps on this Mac. A schedule only says a run is due: nothing
/// here runs one (`WriteRouteTests.aScheduleRunsNothing`). Home's list opens a run's pane, where Run (⌘R) runs it.
///
/// The keyboard reaches all of it with the Mac's default settings, where Tab reaches only lists and text fields, each shortcut
/// said in visible words beside its control: on Home ⌥⌘1 to ⌥⌘5 open the runs listed; on a run's pane ⌃⌘1 to ⌃⌘3 pick daily,
/// weekly or monthly and ⌃⌘0 not scheduled, Tab reaches the count (Return saves), ⌘S saves, and ⌘⌫ asks to delete the kept runs.

/// Home's card: the scheduled runs on the connected domain (the audit runs, then the named reports run on Reports), due ones
/// first, each opening its pane. Unreadable schedules are said, never "Nothing is due"; so is a schedule for a report this GAM
/// version can't run any more (GamGUI #178), which is never due and opens where it can be stopped.
struct HomeScheduledRuns: View {
    let schedules: RunSchedules
    let openRun: (String) -> Void

    /// Due ones first, then the rest, in the runs' order: what ⌥⌘1 to ⌥⌘5 open.
    private var listed: [(run: AuditRuns.Run, due: AuditSchedules.Due)] {
        let all = schedules.scheduled()
        return all.filter(\.due.due) + all.filter { !$0.due.due }
    }

    /// A schedule for a key nothing here runs any more (kept runs alone are said on Reports).
    private var stranded: [RunSchedules.Stranded] { schedules.stranded.filter { $0.schedule != nil } }

    /// Shown once there is something to say: a schedule, or why they can't be told.
    static func shows(_ schedules: RunSchedules) -> Bool {
        !schedules.schedules.isEmpty || schedules.problem != nil || schedules.setAside != nil
    }

    var body: some View {
        if let problem = schedules.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).textSelection(.enabled)
        }
        if let aside = schedules.setAside {
            Label("The schedules file wasn't one GAM GUI could read, so it was moved to \(aside.path) and the schedules started empty.",
                  systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor).textSelection(.enabled)
        }
        if let unknown = schedules.namedUnknown {
            Label(unknown, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).textSelection(.enabled)
        }
        if !listed.contains(where: \.due.due), schedules.problem == nil, schedules.namedUnknown == nil {
            Text("Nothing is due.").foregroundStyle(.secondary)
        }
        ForEach(Array(listed.enumerated()), id: \.element.run.key) { index, item in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.due.due ? "clock.badge.exclamationmark" : "clock")
                    .foregroundStyle(item.due.due ? .orange : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Button(item.due.due ? item.due.headline : item.run.title) { openRun(item.run.key) }
                        .buttonStyle(.link)
                        .modifier(NumberShortcut(index: index, modifiers: [.command, .option]))
                    Text(item.due.due ? item.due.detail : item.due.headline)
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if index < 5 { Text("⌥⌘\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary).accessibilityHidden(true) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.due.due ? item.due.line : "\(item.run.title): not due. \(item.due.headline).")
            .accessibilityHint("Opens the run on Reports, where Command R runs it.\(index < 5 ? " Option Command \(index + 1) opens it too." : "")")
        }
        ForEach(stranded) { item in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Button("\(item.title) can't run here any more") { openRun(item.key) }
                        .buttonStyle(.link)
                    Text("This GAM version has no plain read for it, so it isn't due. Stop scheduling it on Reports.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.title) can't run here any more: this GAM version has no plain read for it, so it isn't due.")
            .accessibilityHint("Opens it on Reports, where its schedule can be stopped.")
        }
        Text(listed.isEmpty ? "Nothing runs on its own."
             : "Nothing runs on its own: open one (\(listed.count == 1 ? "⌥⌘1" : "⌥⌘1 to ⌥⌘\(min(listed.count, 5))")) and press Run (⌘R).")
            .font(.callout).foregroundStyle(.secondary)
    }
}

/// ⌥⌘1 to ⌥⌘5 (or another modifier set) for the first five of a list.
private struct NumberShortcut: ViewModifier {
    let index: Int
    let modifiers: EventModifiers

    func body(content: Content) -> some View {
        if index < 5 {
            content.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: modifiers)
        } else {
            content
        }
    }
}

/// A run's due line at the top of its pane: due (and why), or when it's next due. Words and a symbol, never color alone.
struct RunDueLine: View {
    let due: AuditSchedules.Due

    var body: some View {
        Label {
            Text(due.line).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: due.due ? "clock.badge.exclamationmark" : "clock").foregroundStyle(due.due ? .orange : .secondary)
        }
        .font(due.due ? .callout.weight(.medium) : .callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(due.due ? "Due. \(due.line)" : "Scheduled. \(due.line)")
    }
}

/// A run's schedule on the connected domain, and the runs it keeps on this Mac: the cadence, the count, Save, the kept runs and
/// Delete. It says the kept tables are the domain's data at rest, and when they go.
struct RunScheduleSection: View {
    let run: AuditRuns.Run
    let schedules: RunSchedules
    let domain: String
    /// The form, filled from the saved schedule whenever it changes.
    @State private var cadence: AuditSchedules.Cadence?
    @State private var keep = String(AuditSchedules.keepDefault)
    @State private var confirmingDelete = false
    @FocusState private var keepFocused: Bool

    private var saved: AuditSchedules.Schedule? { schedules.schedule(of: run) }
    private var kept: RunSchedules.Kept? { schedules.kept[run.key] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(saved.map { "Schedule: \($0.cadence.word.lowercased())" } ?? "Schedule: not scheduled")
                .font(.headline).accessibilityAddTraits(.isHeader)
            Text("A schedule says when this run is due on \(domain), here and on Home. It never runs on its own: you run it, with Run "
                 + "(⌘R). A scheduled run that reads every step keeps its tables on this Mac, so the next run can say what changed "
                 + "since. They hold your domain's data, in a folder only your Mac account can open, until you lower the count, stop "
                 + "scheduling the run, delete them here, or remove \(domain) on Setup.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Picker("Due", selection: $cadence) {
                    Text("Not scheduled").tag(AuditSchedules.Cadence?.none)
                    ForEach(AuditSchedules.Cadence.allCases) { Text($0.word).tag(Optional($0)) }
                }
                .fixedSize()
                .accessibilityHint("Control Command 1 to 3 pick daily, weekly or monthly; Control Command 0, not scheduled.")
                Text("Keep the last")
                TextField("Runs", text: $keep)
                    .frame(width: 44)
                    .focused($keepFocused)
                    .onSubmit(save)
                    .disabled(cadence == nil)
                    .accessibilityLabel("Runs kept on this Mac, 1 to \(AuditSchedules.keepCap)")
                    .accessibilityHint("Return saves the schedule.")
                Text("runs")
            }
            HStack(spacing: 10) {
                Button("Save Schedule", action: save)
                    .keyboardShortcut("s")
                    .disabled(schedules.isBusy)
                    .accessibilityHint("Saves when \(run.title) is due on \(domain). Nothing runs. Command S saves it too.")
            }
            Text("⌃⌘1, ⌃⌘2 or ⌃⌘3 picks daily, weekly or monthly, ⌃⌘0 not scheduled; Tab reaches the count; ⌘S saves. Up to "
                 + "\(AuditSchedules.keepCap) runs. Not scheduled keeps none: saving it deletes the runs kept.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let notice = schedules.notices[run.key] {
                Label(notice.text, systemImage: notice.problem ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .symbolRenderingMode(notice.problem ? .multicolor : .monochrome)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            keptRuns
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .background { cadenceShortcuts }
        .onAppear { fill() }
        .onChange(of: saved) { fill() }
        .onChange(of: schedules.notices[run.key]) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice.text).post() }
        }
        .confirmationDialog(deleteQuestion, isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await schedules.deleteKept(run) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next run then has nothing to compare with. Its schedule stays.")
        }
    }

    private var deleteQuestion: String {
        let count = kept?.runs.count ?? 0
        return "Delete the \(count) run\(count == 1 ? "" : "s") of \(run.title) kept on this Mac?"
    }

    /// ⌃⌘0 to ⌃⌘3 pick the cadence without Full Keyboard Access (which a pop-up button needs to be reached).
    private var cadenceShortcuts: some View {
        ZStack {
            Button("Not scheduled") { cadence = nil }.keyboardShortcut("0", modifiers: [.command, .control])
            ForEach(Array(AuditSchedules.Cadence.allCases.enumerated()), id: \.offset) { index, each in
                Button(each.word) { cadence = each }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .control])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var keptRuns: some View {
        switch kept {
        case .problem(let why)?:
            Label(why, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).textSelection(.enabled)
        case .runs(let runs)? where !runs.isEmpty:
            Text("Kept on this Mac").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(runs) { kept in
                if kept.problem.isEmpty {
                    Text(line(kept)).font(.callout).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("A kept run that can't be read. \(kept.problem)", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor).font(.callout)
                }
            }
            Button("Delete the Kept Runs…", role: .destructive) { confirmingDelete = true }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(schedules.isBusy)
                .accessibilityHint("Asks first. Deletes the tables of \(run.title) kept on this Mac; its schedule stays. Command Delete asks too.")
            Text("⌘⌫ asks to delete them.").font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// "Wed 18 Nov 2026, 09:14, a 90-day window: Seats per license 3; Seats on suspended accounts 1".
    private func line(_ kept: AuditSchedules.KeptRun) -> String {
        let tables = kept.tables.map { table in
            "\(table.title) \(table.known ? String(table.count) : "unknown")" + (table.known && !table.kept ? " (too many rows to keep)" : "")
        }
        return schedules.clock.words(at: kept.when) + (kept.days > 0 ? ", a \(kept.days)-day window" : "") + ": "
            + tables.joined(separator: "; ")
    }

    private func fill() {
        cadence = saved?.cadence
        keep = String(saved?.keep ?? AuditSchedules.keepDefault)
    }

    private func save() {
        let (cadence, keep) = (cadence, keep)
        Task { await schedules.save(run, cadence: cadence, keep: keep) }
    }
}
