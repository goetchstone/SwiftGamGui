import AppKit
import ChangeCore
import Directory
import GamEngine
import Stores
import SwiftUI

/// One audit run on Reports (plan F3, GamGUI's `_audit_run.html`): what it reads, its Run button (Inactive users' window picker
/// first), its steps while it goes, with Stop, and once it ended each step's line and each table it adds up to. A step that
/// failed or never ran is unknown, and so is every table that needs it: said in words, never an empty table. Bounded: while it
/// goes only its steps are drawn; a table draws its first `AuditRuns.rowsShown` rows, and Export CSV… holds all of them. A run
/// changes nothing; Inactive users' Suspend these… is a previewed write of its own.
///
/// The keyboard reaches all of it with the Mac's default settings, where Tab reaches only lists and text fields (review of F3,
/// 2026-11-21, as Reports' ⌘O before it): ⌘R runs, ⌘. stops, ⌘1 to ⌘5 pick Inactive users' window, each table is a list Tab
/// reaches (Return opens the person picked), ⌘E exports the table picked in, ⌘Return previews Suspend these…. Each is said in
/// visible words beside its control.
///
/// A schedule (plan F7a, `RunSchedules`) adds when the run is due, at the top; its schedule and the runs it keeps on this Mac,
/// under Run; and, once a scheduled run ended, what changed in each table since its last kept run. None of it is drawn while
/// a run goes (GamGUI's poll reads no schedule), and none of it runs anything.
///
/// A named report run here (plan F7a, GamGUI #178) is a run of one step: its catalog read built bare, said as GAM's own line,
/// with Open in the Builder (⌘O) to narrow it there.
struct AuditRunPanel: View {
    let run: AuditRuns.Run
    let runs: AuditRunner
    let suspend: InactiveSuspend
    let schedules: RunSchedules
    /// The connected domain, nil when none is.
    let domain: String?
    var connected: Bool { domain != nil }
    /// Inactive users' window, which ⌘R runs with too.
    @Binding var days: Int
    let openPerson: (String) -> Void
    /// Opens a catalog command in the Builder (a named report's read).
    let openCommand: (String) -> Void
    /// What Export CSV… last did, and for which run (its read time): another run's line never shows here.
    @State private var exported: (text: String, failed: Bool, about: Date)?
    /// The table a row was last picked in: what ⌘E exports.
    @State private var picked: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(run.what).foregroundStyle(.secondary)
                    if run.named.isEmpty {
                        Text("Reads: " + run.steps.enumerated().map { $0.offset == 0 ? $0.element.title : $0.element.title.lowercasedFirst }
                            .joined(separator: "; ") + ". A run changes nothing.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        namedLine
                    }
                }
                switch runs.state(of: run) {
                case .running(let progress)?:
                    running(progress)
                case .finished(let outcome)?:
                    due
                    controls
                    schedule
                    finished(outcome)
                case nil:
                    due
                    controls
                    schedule
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { windowShortcuts }
        // Its kept runs, read when the pane opens for the domain connected now (a run's end reads them again).
        .task(id: domain) {
            await schedules.refreshKept(run)
            // Inactive users opens on the window its last kept run read: one click runs the same again.
            if run == AuditRuns.inactiveUsers, runs.state(of: run) == nil,
               let newest = schedules.kept[run.key]?.runs.first(where: { $0.problem.isEmpty }), AuditRuns.windows.contains(newest.days) {
                days = newest.days
            }
        }
        .sheet(item: Binding(get: { sheetPending }, set: { if $0 == nil { suspend.dismiss() } })) { pending in
            InactiveSuspendSheet(pending: pending, suspend: suspend)
        }
        // Suspend these… that ends without a sheet (nothing to suspend, or why not) is said, not only drawn.
        .onChange(of: suspendOutcome) { _, words in
            if let words { AccessibilityNotification.Announcement(words).post() }
        }
    }

    /// A named report's read, as GAM's own line, and the Builder, where it can be narrowed.
    @ViewBuilder private var namedLine: some View {
        let line = "gam " + (run.steps.first.flatMap { AuditRuns.read($0)?.argv } ?? []).joined(separator: " ")
        (Text("Runs ") + Text(line).monospaced() + Text(", the Builder's read with no options. A run changes nothing. It's recorded "
                                                         + "in the Audit log as a named report."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if !run.commandID.isEmpty {
            Button("Open in the Builder") { openCommand(run.commandID) }
                .keyboardShortcut("o")
                .accessibilityHint("Opens \(line) in the Builder, to narrow it. Command O opens it too.")
            Text("⌘O opens it in the Builder, to narrow it there.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The finished run, while there is one.
    private var outcome: AuditRuns.Outcome? {
        if case .finished(let outcome)? = runs.state(of: run) { return outcome }
        return nil
    }

    /// Suspend these…'s held preview, when it was asked from this run's table.
    private var sheetPending: InactiveSuspend.Pending? {
        guard run == AuditRuns.inactiveUsers, let outcome, case .previewing(let pending) = suspend.state(about: outcome.when) else { return nil }
        return pending
    }

    /// Suspend these…'s outcome for this run's table, in words.
    private var suspendOutcome: String? {
        guard run == AuditRuns.inactiveUsers, let outcome else { return nil }
        switch suspend.state(about: outcome.when) {
        case .done(let words), .problem(let words): return words
        default: return nil
        }
    }

    /// ⌘1 to ⌘5 pick Inactive users' window, without Full Keyboard Access (which a pop-up button needs to be reached).
    @ViewBuilder private var windowShortcuts: some View {
        if run == AuditRuns.inactiveUsers {
            ZStack {
                ForEach(Array(AuditRuns.windows.enumerated()), id: \.offset) { index, window in
                    Button("\(window) days") { days = window }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: before and between runs

    /// When it's due on the connected domain, or why that can't be told.
    @ViewBuilder private var due: some View {
        if let due = schedules.due(run) {
            RunDueLine(due: due)
        } else if connected, let problem = schedules.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.callout)
        }
    }

    /// Its schedule and kept runs, when a domain is connected and this build keeps them.
    @ViewBuilder private var schedule: some View {
        if let domain, schedules.store != nil {
            RunScheduleSection(run: run, schedules: schedules, domain: domain)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if run == AuditRuns.inactiveUsers {
                    Picker("No sign-in for", selection: $days) {
                        ForEach(AuditRuns.windows, id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .fixedSize()
                    .accessibilityHint("The window of days without a sign-in the run lists. Command 1 to Command 5 pick it too.")
                }
                Button(runs.state(of: run) == nil ? "Run" : "Run Again") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connected)
                    .accessibilityLabel(runs.state(of: run) == nil ? "Run \(run.title)" : "Run \(run.title) again")
                    .accessibilityHint("Reads the whole domain, one step after another. Nothing changes.")
            }
            Text(run == AuditRuns.inactiveUsers ? "⌘1 to ⌘5 pick 30, 60, 90, 180 or 365 days; ⌘R runs it." : "⌘R runs it.")
                .font(.caption).foregroundStyle(.secondary)
            if !connected { Text("Connect a domain on Setup first.").foregroundStyle(.secondary) }
        }
    }

    private func start() {
        if let refusal = runs.start(run, days: days) {
            AccessibilityNotification.Announcement(refusal).post()
        }
    }

    // MARK: while it goes

    private func running(_ progress: AuditRunner.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .accessibilityLabel("\(run.title): \(progress.done) of \(progress.total) steps done")
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(progress.stopping ? "Stopping after this step…"
                     : "Step \(min(progress.done + 1, progress.total)) of \(progress.total): \(progress.current)…")
                    .foregroundStyle(.secondary)
                // ⌘. as well as the button: the Mac's own Stop, and Tab never reaches a button by default.
                Button("Stop") { runs.stop(run) }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(progress.stopping)
                    .accessibilityHint("Stops the run before its next step. The step running now finishes. Command period stops it too.")
            }
            .accessibilityElement(children: .contain)
            Text("⌘. stops it before its next step.").font(.caption).foregroundStyle(.secondary)
            ForEach(progress.lines) { line in StepLine(title: line.title, ok: line.ok, words: line.ok ? "read" : "unknown. \(line.why)") }
        }
    }

    // MARK: once it ended

    @ViewBuilder private func finished(_ outcome: AuditRuns.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // The time itself, never "now": a pane left open keeps saying when the tables were read.
            Text("Read at \(outcome.when.formatted(date: .abbreviated, time: .shortened))"
                 + (outcome.days > 0 ? ", with a \(outcome.days)-day window." : ".")
                 + (outcome.complete ? " Every step was read." : " Part of this run is unknown: each table that needs it says so."))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(outcome.reads, id: \.step.key) { read in StepReadLine(read: read) }
            // A scheduled run: what happened to its keep.
            if !outcome.keptNote.isEmpty {
                Label(outcome.keptNote, systemImage: outcome.keptProblem ? "exclamationmark.triangle.fill" : "externaldrive")
                    .symbolRenderingMode(outcome.keptProblem ? .multicolor : .monochrome)
                    .font(.callout).foregroundStyle(outcome.keptProblem ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        ForEach(outcome.findings) { finding in
            FindingView(run: run, finding: finding, change: outcome.changes[finding.key], clock: schedules.clock, openPerson: openPerson,
                        export: { export(finding, about: outcome.when) }, picked: { picked = finding.key })
            if run == AuditRuns.inactiveUsers, finding.key == "inactive", finding.known, !finding.rows.isEmpty {
                suspendControls(days: outcome.days, about: outcome.when)
            }
        }
        if let target = exportTarget(outcome) {
            // ⌘E: the table a row was last picked in, else the first with rows.
            Button("Export “\(target.title)” as CSV…") { export(target, about: outcome.when) }
                .keyboardShortcut("e")
                .accessibilityHint("Pick a row in another table to export that one instead.")
            Text("⌘E exports “\(target.title)”; pick a row in another table to export that one.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let exported, exported.about == outcome.when {
            Label(exported.text, systemImage: exported.failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(exported.failed ? .orange : .secondary)
        }
    }

    private func exportTarget(_ outcome: AuditRuns.Outcome) -> AuditRuns.Finding? {
        let exportable = outcome.findings.filter { $0.known && !$0.rows.isEmpty }
        return exportable.first { $0.key == picked } ?? exportable.first
    }

    /// The one write this run leads to: the suspend preview, which reads the directory again for the same window.
    @ViewBuilder private func suspendControls(days: Int, about when: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Suspend These…", role: .destructive) { Task { await suspend.preview(days: days, about: when) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(suspend.isBusy || !connected)
                .accessibilityLabel("Suspend the accounts inactive \(days) days or more, after a preview")
                .accessibilityHint("Reads the directory again and shows exactly who would be suspended. Nothing changes until you confirm. "
                                   + "Command Return opens the preview too.")
            Text("⌘Return previews it: who exactly, read again. Nothing changes until you confirm.")
                .font(.caption).foregroundStyle(.secondary)
            switch suspend.state(about: when) {
            case .checking(let words):
                HStack { ProgressView().controlSize(.small); Text(words).foregroundStyle(.secondary) }
                    .accessibilityElement(children: .combine)
            case .running:
                HStack { ProgressView().controlSize(.small); Text("Suspending, one account at a time: Stop is in the jobs tray.").foregroundStyle(.secondary) }
                    .accessibilityElement(children: .combine)
            case .done(let words):
                Label(words, systemImage: "checkmark.circle").textSelection(.enabled)
            case .problem(let words):
                Label(words, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).textSelection(.enabled)
            case .idle, .previewing:
                EmptyView()
            }
        }
        .padding(.top, 2)
    }

    /// A table, whole, as a CSV to a file the operator picks: private (0600), whole or not at all. An unknown table has none.
    private func export(_ finding: AuditRuns.Finding, about when: Date) {
        guard let table = AuditRuns.exportRows(finding) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(run.key)-\(finding.key)".replacingOccurrences(of: "_", with: "-") + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.message = "\(run.title): \(finding.title)"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                do {
                    try await Task.detached { try AuditExport.writePrivately(AuditExport.csv(table), to: destination) }.value
                    say("Exported \(finding.rows.count.formatted()) row\(finding.rows.count == 1 ? "" : "s") to \(destination.lastPathComponent).",
                        failed: false, about: when)
                } catch {
                    say("Couldn't export to \(destination.lastPathComponent): \(error.localizedDescription)", failed: true, about: when)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    private func say(_ text: String, failed: Bool, about when: Date) {
        exported = (text, failed, when)
        AccessibilityNotification.Announcement(text).post()
    }
}

/// A step's line once the run ended: read with its rows, unknown and why (GAM's own error folded away), or not run.
private struct StepReadLine: View {
    let read: AuditRuns.StepRead

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            StepLine(title: read.step.title, ok: read.state == .read || read.state == .partial, words: words)
            if !read.detail.isEmpty {
                DisclosureGroup("GAM's error") {
                    Text(read.detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .padding(.leading, 22)
            }
        }
    }

    private var words: String {
        switch read.state {
        case .read: "\(read.rows.formatted()) row\(read.rows == 1 ? "" : "s")"
        case .partial: "\(read.rows.formatted()) row\(read.rows == 1 ? "" : "s"), in part. \(read.why)"
        case .unknown: "unknown. \(read.why)"
        case .notRun: "not run. \(read.why)"
        }
    }
}

/// One step: a symbol and the words, which say it all (never color alone).
private struct StepLine: View {
    let title: String
    let ok: Bool
    let words: String

    var body: some View {
        Label {
            Text("\(title): ").fontWeight(.medium) + Text(words)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "questionmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(words)")
    }
}

/// A table the run's reads add up to: its title and count, its summary, its first rows in a list Tab reaches (each row one
/// element for VoiceOver, every column named; Return or a double-click opens the person picked), Export CSV… with every row;
/// or, unknown, why, and no CSV (an empty sheet would read as "none").
private struct FindingView: View {
    let run: AuditRuns.Run
    let finding: AuditRuns.Finding
    /// What changed since the run's last kept run (a scheduled run), or why it wasn't compared.
    let change: AuditSchedules.Change?
    let clock: AuditSchedules.Clock
    let openPerson: (String) -> Void
    let export: () -> Void
    /// A row was picked in this table: ⌘E exports it.
    let picked: () -> Void
    @State private var selection: Int?

    private var shown: [(offset: Int, element: [String])] { Array(finding.rows.prefix(AuditRuns.rowsShown).enumerated()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(finding.known ? "\(finding.title) (\(finding.rows.count.formatted()))" : finding.title)
                .font(.headline).accessibilityAddTraits(.isHeader)
            if finding.known {
                Text(finding.summary)
                if let change { ChangeSinceView(finding: finding, change: change, clock: clock) }
                if finding.partial {
                    Label("Part of this table is unknown: what no read could tell is said beneath it.", systemImage: "questionmark.circle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                if !finding.rows.isEmpty {
                    List(shown, id: \.offset, selection: $selection) { item in
                        FindingRow(columns: finding.columns, row: item.element, opens: person([item.offset]) != nil)
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .contextMenu(forSelectionType: Int.self) { ids in
                        if let email = person(ids) { Button("Show \(email) in Users") { openPerson(email) } }
                        Button("Export CSV…", action: export)
                    } primaryAction: { ids in
                        if let email = person(ids) { openPerson(email) }
                    }
                    .frame(height: CGFloat(min(shown.count, 6)) * 46 + 8)
                    .accessibilityLabel(finding.rows.count > AuditRuns.rowsShown
                                        ? "\(finding.title), the first \(AuditRuns.rowsShown) of \(finding.rows.count.formatted())" : finding.title)
                    .onChange(of: selection) { _, row in if row != nil { picked() } }
                    HStack(spacing: 10) {
                        if finding.rows.count > AuditRuns.rowsShown {
                            Text("Showing the first \(AuditRuns.rowsShown) of \(finding.rows.count.formatted()).").foregroundStyle(.secondary)
                        }
                        if finding.links {
                            Button("Show in Users") { if let email = person(selection.map { [$0] } ?? []) { openPerson(email) } }
                                .disabled(person(selection.map { [$0] } ?? []) == nil)
                                .accessibilityHint("Opens the picked person's page on Users.")
                        }
                        Button("Export CSV…", action: export)
                            .accessibilityLabel("Export \(finding.title) as CSV, \(finding.rows.count.formatted()) row\(finding.rows.count == 1 ? "" : "s")")
                    }
                    .font(.callout)
                    Text(finding.links ? "Tab to the table: the arrows pick a row, Return or a double-click opens the person."
                         : "Tab to the table: the arrows pick a row.")
                        .font(.caption).foregroundStyle(.secondary)
                    if finding.partial {
                        Text("Its CSV starts with a line saying what wasn't read.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Label(finding.why, systemImage: "questionmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .textSelection(.enabled)
                    .accessibilityLabel("Unknown. \(finding.why)")
            }
            if !finding.note.isEmpty {
                Text(finding.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
    }

    /// The picked row's person, when its first column is an account's address in the directory.
    private func person(_ ids: some Collection<Int>) -> String? {
        guard finding.links, let id = ids.first, finding.rows.indices.contains(id), let first = finding.rows[id].first,
              first.contains("@") else { return nil }
        return first
    }
}

/// What changed in one table since the run's last kept run that read it whole (plan F7a, GamGUI's `_audit_run_changes.html`):
/// no change, or how many rows are new and gone, each list its first `AuditRuns.rowsShown` rows in a list Tab reaches. A row
/// counts by all its cells, so one with any cell changed is gone and new. A table not compared says why: never "no change"
/// (invariant 10). The table's change note (a skip GAM makes without a word) is said beside any comparison.
private struct ChangeSinceView: View {
    let finding: AuditRuns.Finding
    let change: AuditSchedules.Change
    let clock: AuditSchedules.Clock

    private var when: String { clock.words(at: change.since) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !change.compared {
                Label(change.why, systemImage: "questionmark.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if change.new.isEmpty && change.gone.isEmpty {
                Label("No change since \(when).", systemImage: "equal.circle").font(.callout)
            } else {
                Label("Since \(when): \(change.new.count.formatted()) new, \(change.gone.count.formatted()) gone.",
                      systemImage: "arrow.left.arrow.right.circle")
                    .font(.callout)
                rows("New", change.new)
                rows("Gone", change.gone)
                Text("A row counts by all its cells: one with any cell changed shows as gone and as new.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if change.compared, !change.leftOut.isEmpty {
                Text(finding.compareNote.isEmpty ? "Compared without \(change.leftOut.joined(separator: ", "))." : finding.compareNote)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if change.compared, !finding.changeNote.isEmpty {
                Label(finding.changeNote, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder private func rows(_ label: String, _ rows: [[String]]) -> some View {
        if !rows.isEmpty {
            let shown = Array(rows.prefix(AuditRuns.rowsShown).enumerated())
            Text("\(label) since then (\(rows.count.formatted()))").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            // In the columns both runs were compared on (their union, without any left out), when not the table's own.
            List(shown, id: \.offset) { item in
                FindingRow(columns: change.columns.isEmpty ? finding.columns : change.columns, row: item.element, opens: false)
            }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: CGFloat(min(shown.count, 4)) * 46 + 8)
                .accessibilityLabel("\(label) in \(finding.title) since \(when)"
                                    + (rows.count > AuditRuns.rowsShown ? ", the first \(AuditRuns.rowsShown) of \(rows.count.formatted())" : ""))
            if rows.count > AuditRuns.rowsShown {
                Text("Showing the first \(AuditRuns.rowsShown) of \(rows.count.formatted()).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One row of a table, laid out to wrap in a narrow window: its first column, then each other column by name. Read whole by
/// VoiceOver, every column named.
private struct FindingRow: View {
    let columns: [String]
    let row: [String]
    /// Its first column opens a person (Return or a double-click on the row).
    let opens: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.first ?? "").fontWeight(.medium).foregroundStyle(opens ? Color.accentColor : .primary)
            Text(rest).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint(opens ? "Return opens their page on Users." : "")
    }

    /// "Name: Alice Anders · Last sign-in: 2026-06-18 · Flags: admin", the empty ones left out.
    private var rest: String {
        zip(columns, row).dropFirst().filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: " · ")
    }

    private var spoken: String {
        zip(columns, row).map { "\($0.0): \($0.1.isEmpty ? "none" : $0.1)" }.joined(separator: ", ")
    }
}
