import AppKit
import ChangeCore
import Directory
import GamEngine
import SwiftUI

/// One audit run on Reports (plan F3, GamGUI's `_audit_run.html`): what it reads, its Run button (Inactive users' window picker
/// first), its steps while it goes, with Stop, and once it ended each step's line and each table it adds up to. A step that
/// failed or never ran is unknown, and so is every table that needs it: said in words, never an empty table. Bounded: while it
/// goes only its steps are drawn; a table draws its first `AuditRuns.rowsShown` rows, and Export CSV… holds all of them. A run
/// changes nothing; Inactive users' Suspend these… is a previewed write of its own.
struct AuditRunPanel: View {
    let run: AuditRuns.Run
    let runs: AuditRunner
    let suspend: InactiveSuspend
    let connected: Bool
    /// Inactive users' window, which ⌘R runs with too.
    @Binding var days: Int
    let openPerson: (String) -> Void
    /// What Export CSV… last did.
    @State private var exported: (text: String, failed: Bool)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(run.what).foregroundStyle(.secondary)
                    Text("Reads: " + run.steps.enumerated().map { $0.offset == 0 ? $0.element.title : $0.element.title.lowercasedFirst }
                        .joined(separator: "; ") + ". A run changes nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                switch runs.state(of: run) {
                case .running(let progress)?:
                    running(progress)
                case .finished(let outcome)?:
                    controls
                    finished(outcome)
                case nil:
                    controls
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: Binding(get: { run == AuditRuns.inactiveUsers ? suspend.previewing : nil },
                             set: { if $0 == nil { suspend.dismiss() } })) { pending in
            InactiveSuspendSheet(pending: pending, suspend: suspend)
        }
    }

    // MARK: before and between runs

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if run == AuditRuns.inactiveUsers {
                    Picker("No sign-in for", selection: $days) {
                        ForEach(AuditRuns.windows, id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .fixedSize()
                    .accessibilityHint("The window of days without a sign-in the run lists.")
                }
                Button(runs.state(of: run) == nil ? "Run" : "Run Again") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connected)
                    .accessibilityLabel(runs.state(of: run) == nil ? "Run \(run.title)" : "Run \(run.title) again")
                    .accessibilityHint("Reads the whole domain, one step after another. Nothing changes.")
            }
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
                Button("Stop") { runs.stop(run) }
                    .disabled(progress.stopping)
                    .accessibilityHint("Stops the run before its next step. The step running now finishes.")
            }
            .accessibilityElement(children: .contain)
            ForEach(progress.lines) { line in StepLine(title: line.title, ok: line.ok, words: line.ok ? "read" : "unknown. \(line.why)") }
        }
    }

    // MARK: once it ended

    @ViewBuilder private func finished(_ outcome: AuditRuns.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Read \(outcome.when.formatted(.relative(presentation: .named)))"
                 + (outcome.days > 0 ? ", with a \(outcome.days)-day window." : ".")
                 + (outcome.complete ? " Every step was read." : " Part of this run is unknown: each table that needs it says so."))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(outcome.reads, id: \.step.key) { read in StepReadLine(read: read) }
        }
        ForEach(outcome.findings) { finding in
            FindingView(run: run, finding: finding, openPerson: openPerson, export: { export(finding) })
            if run == AuditRuns.inactiveUsers, finding.key == "inactive", finding.known, !finding.rows.isEmpty {
                suspendControls(days: outcome.days)
            }
        }
        if let exported {
            Label(exported.text, systemImage: exported.failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(exported.failed ? .orange : .secondary)
        }
    }

    /// The one write this run leads to: the suspend preview, which reads the directory again for the same window.
    @ViewBuilder private func suspendControls(days: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Suspend These…", role: .destructive) { Task { await suspend.preview(days: days) } }
                .disabled(suspend.isBusy || !connected)
                .accessibilityLabel("Suspend the accounts inactive \(days) days or more, after a preview")
                .accessibilityHint("Reads the directory again and shows exactly who would be suspended. Nothing changes until you confirm.")
            switch suspend.state {
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
    private func export(_ finding: AuditRuns.Finding) {
        guard finding.known else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(run.key)-\(finding.key)".replacingOccurrences(of: "_", with: "-") + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.message = "\(run.title): \(finding.title)"
        let table = [finding.columns] + finding.rows
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                do {
                    try await Task.detached { try AuditExport.writePrivately(AuditExport.csv(table), to: destination) }.value
                    say("Exported \(finding.rows.count.formatted()) row\(finding.rows.count == 1 ? "" : "s") to \(destination.lastPathComponent).",
                        failed: false)
                } catch {
                    say("Couldn't export to \(destination.lastPathComponent): \(error.localizedDescription)", failed: true)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    private func say(_ text: String, failed: Bool) {
        exported = (text, failed)
        AccessibilityNotification.Announcement(text).post()
    }
}

/// A step's line once the run ended: read with its rows, unknown and why (GAM's own error folded away), or not run.
private struct StepReadLine: View {
    let read: AuditRuns.StepRead

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            StepLine(title: read.step.title, ok: read.state == .read, words: words)
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

/// A table the run's reads add up to: its title and count, its summary, its first rows (each one element for VoiceOver: every
/// column named), Export CSV… with every row; or, unknown, why, and no CSV (an empty sheet would read as "none").
private struct FindingView: View {
    let run: AuditRuns.Run
    let finding: AuditRuns.Finding
    let openPerson: (String) -> Void
    let export: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(finding.known ? "\(finding.title) (\(finding.rows.count.formatted()))" : finding.title)
                .font(.headline).accessibilityAddTraits(.isHeader)
            if finding.known {
                Text(finding.summary)
                if !finding.rows.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(finding.rows.prefix(AuditRuns.rowsShown).enumerated()), id: \.offset) { index, row in
                            FindingRow(columns: finding.columns, row: row, opens: finding.links && row.first?.contains("@") == true,
                                       openPerson: openPerson)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 8)
                                .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.07))
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(finding.rows.count > AuditRuns.rowsShown
                                        ? "\(finding.title), the first \(AuditRuns.rowsShown) of \(finding.rows.count.formatted())" : finding.title)
                    HStack(spacing: 10) {
                        if finding.rows.count > AuditRuns.rowsShown {
                            Text("Showing the first \(AuditRuns.rowsShown) of \(finding.rows.count.formatted()).").foregroundStyle(.secondary)
                        }
                        Button("Export CSV…", action: export)
                            .accessibilityLabel("Export \(finding.title) as CSV, \(finding.rows.count.formatted()) row\(finding.rows.count == 1 ? "" : "s")")
                    }
                    .font(.callout)
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
}

/// One row of a table, laid out to wrap in a narrow window: its first column, then each other column by name. The person's
/// address opens their page on Users (a button, so the keyboard reaches it). Read whole by VoiceOver, every column named.
private struct FindingRow: View {
    let columns: [String]
    let row: [String]
    let opens: Bool
    let openPerson: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let first = row.first {
                if opens {
                    Button(first) { openPerson(first) }
                        .buttonStyle(.link)
                        .accessibilityLabel(spoken)
                        .accessibilityHint("Opens their page on Users.")
                } else {
                    Text(first).fontWeight(.medium).textSelection(.enabled)
                        .accessibilityLabel(spoken)
                }
            }
            Text(rest).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Name: Alice Anders · Last sign-in: 2026-06-18 · Flags: admin", the empty ones left out.
    private var rest: String {
        zip(columns, row).dropFirst().filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: " · ")
    }

    private var spoken: String {
        zip(columns, row).map { "\($0.0): \($0.1.isEmpty ? "none" : $0.1)" }.joined(separator: ", ")
    }
}

extension InactiveSuspend {
    /// The preview the sheet shows, while one is held.
    var previewing: Pending? {
        if case .previewing(let pending) = state { return pending }
        return nil
    }
}
