import AppKit
import ChangeCore
import SwiftUI
import UniformTypeIdentifiers

/// Audit: this app's audit log on this Mac, newest first, 25 records a page, searched and narrowed to failures as
/// GamGUI's Audit screen is (`AuditPage`), each record's masked details behind a disclosure, and GamGUI's CSV
/// export to a file the operator picks. It reads only the local file, off the main actor, a page at a time; it
/// runs no `gam`. An outcome unknown (a write the app stopped in the middle of) can be marked as checked, as on Home.
struct AuditView: View {
    let auditURL: URL
    @State private var query = ""
    @State private var failuresOnly = false
    @State private var page = 1
    @State private var shown: AuditPage?
    /// Bumped to read the log again (Refresh, after Mark as Checked).
    @State private var reloads = 0
    /// The search last read: a new one waits a moment for the typing to stop, as GamGUI's box waits 300 ms.
    @State private var lastSearch = ""
    @State private var reading = false
    @State private var readSerial = 0
    @State private var expanded: Set<AuditEntry.ID> = []
    /// The row the keyboard is on: arrows move between records, Right and Left open and close one.
    @State private var selected: AuditEntry.ID?
    @State private var notice: (text: String, failed: Bool)?
    @State private var exporting = false
    @Environment(\.appearsActive) private var appearsActive

    private var filter: AuditFilter { AuditFilter(text: query, failuresOnly: failuresOnly) }

    private struct ReadKey: Hashable {
        let filter: AuditFilter
        let page: Int
        let reloads: Int
    }

    var body: some View {
        content
            .task(id: ReadKey(filter: filter, page: page, reloads: reloads)) { await read() }
            // A new search or filter starts on its first page, as GamGUI's form does.
            .onChange(of: filter) { page = 1 }
            .onChange(of: page) {
                expanded = []
                selected = nil
            }
            .searchable(text: $query, prompt: "Action, target, error or command")
            .toolbar {
                ToolbarItemGroup {
                    Toggle("Failures Only", systemImage: "exclamationmark.triangle", isOn: $failuresOnly)
                        .help("Show only the records of changes that failed")
                    Button(filter.isActive ? "Export Matches…" : "Export All…", systemImage: "square.and.arrow.up") { export() }
                        .help(filter.isActive ? "Save the records that match as a CSV file" : "Save every record as a CSV file")
                        .disabled(exporting)
                    Button("Refresh", systemImage: "arrow.clockwise") { reloads += 1 }
                        .keyboardShortcut("r")
                        .help("Read the audit log again")
                }
            }
    }

    // MARK: reading

    private func read() async {
        let url = auditURL, filter = filter, page = page
        if filter.text != lastSearch {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            lastSearch = filter.text
        }
        readSerial += 1
        let serial = readSerial
        reading = true
        defer { if serial == readSerial { reading = false } }
        // The log can hold a million records: read off the main actor, and stopped when this read is replaced.
        let task = Task.detached(priority: .userInitiated) { () throws -> AuditPage in
            try AuditPage.read(page, at: url, filter: filter, unfinished: Executor.unfinished(in: url))
        }
        guard let result = try? await withTaskCancellationHandler(operation: { try await task.value },
                                                                   onCancel: { task.cancel() }) else { return }
        shown = result
        if result.page != page { self.page = result.page }
    }

    private func acknowledge(_ write: Executor.Unfinished) async {
        let url = auditURL
        do {
            try await Task.detached { try Executor.acknowledge([write], in: url) }.value
            say("Marked \(write.actionName) for \(write.target) as checked.", failed: false)
        } catch {
            say("The audit log couldn't be written: \(error.localizedDescription)", failed: true)
        }
        reloads += 1
    }

    // MARK: export

    /// GamGUI's CSV, to a file the operator picks: every record, or those the search and filter keep.
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AuditExport.suggestedName
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.message = filter.isActive ? "The records that match the search and filter, newest first."
            : "Every record in the audit log, newest first."
        let filter = filter
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { await write(filter, to: destination) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    private func write(_ filter: AuditFilter, to destination: URL) async {
        exporting = true
        defer { exporting = false }
        let url = auditURL
        do {
            let count = try await Task.detached(priority: .userInitiated) {
                try AuditExport.write(from: url, filter: filter, to: destination)
            }.value
            say("Exported \(count.formatted()) record\(count == 1 ? "" : "s") to \(destination.lastPathComponent).", failed: false)
        } catch {
            say("Couldn't export to \(destination.lastPathComponent): \(error.localizedDescription)", failed: true)
        }
    }

    /// Shown above the list, and spoken from the window in front.
    private func say(_ text: String, failed: Bool) {
        notice = (text, failed)
        if appearsActive { AccessibilityNotification.Announcement(text).post() }
    }

    // MARK: the page

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let shown {
                if shown.entries.isEmpty {
                    VStack(spacing: 12) {
                        if filter.isActive {
                            Text("No matches.").foregroundStyle(.secondary)
                            Button("Clear Filters") {
                                query = ""
                                failuresOnly = false
                            }
                        } else {
                            Text("No audited actions yet.").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selected) {
                        ForEach(shown.entries) { entry in
                            DisclosureGroup(isExpanded: isExpanded(entry.id)) {
                                AuditDetails(entry: entry) { write in Task { await acknowledge(write) } }
                            } label: {
                                AuditRow(entry: entry)
                            }
                            .contextMenu {
                                if case .unknown(let write) = entry.outcome {
                                    Button("Mark as Checked") { Task { await acknowledge(write) } }
                                }
                            }
                        }
                    }
                }
                pager(shown)
            } else {
                ProgressView("Reading the audit log…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Long text wraps rather than widen the screen past the smallest window (ColumnWidths).
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let shown {
                Text("\(shown.logged.formatted()) record\(shown.logged == 1 ? "" : "s") logged · "
                     + "\(shown.failures.formatted()) failure\(shown.failures == 1 ? "" : "s")")
                    .font(.headline)
            }
            Text("Read-only: this screen reads the audit log on this Mac and never runs GAM. Each change is "
                 + "recorded when it starts and again when it ends.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let notice {
                Label(notice.text, systemImage: notice.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(notice.failed ? .orange : .secondary)
                    .font(.callout)
            }
        }
        .padding()
    }

    private func pager(_ shown: AuditPage) -> some View {
        HStack(spacing: 12) {
            Text(count(shown)).foregroundStyle(.secondary)
            if reading {
                ProgressView().controlSize(.small).accessibilityLabel("Reading")
            }
            Spacer()
            if shown.pages > 1 {
                Button("Previous", systemImage: "chevron.left") { page = shown.page - 1 }
                    .disabled(shown.page <= 1)
                    .keyboardShortcut("[")
                    .accessibilityLabel("Previous page")
                Button("Next", systemImage: "chevron.right") { page = shown.page + 1 }
                    .disabled(shown.page >= shown.pages)
                    .keyboardShortcut("]")
                    .accessibilityLabel("Next page")
            }
        }
        .font(.callout)
        .padding(8)
    }

    /// GamGUI's line: "69 total (filtered) · page 1 of 3".
    private func count(_ shown: AuditPage) -> String {
        var text = "\(shown.matches.formatted()) total"
        if filter.isActive { text += " (filtered)" }
        if shown.pages > 1 { text += " · page \(shown.page) of \(shown.pages)" }
        return text
    }

    private func isExpanded(_ id: AuditEntry.ID) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}

/// A record's line: what happened in words with a symbol, the action, the target, when, and by whom, and GamGUI's
/// Detail column beneath.
private struct AuditRow: View {
    let entry: AuditEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.outcome.symbol)
                .foregroundStyle(entry.outcome.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.actionName.isEmpty ? "No action recorded" : entry.actionName).bold()
                    if !entry.target.isEmpty { Text(entry.target) }
                }
                Text(line).font(.callout).foregroundStyle(.secondary)
                if !entry.summary.isEmpty {
                    Text(entry.summary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Succeeded · Oct 8, 2026 at 9:41:00 AM · by admin@example.com".
    private var line: String {
        var parts = [entry.outcome.words]
        if let date = entry.date {
            parts.append(date.formatted(date: .abbreviated, time: .standard))
        } else if !entry.time.isEmpty {
            parts.append(entry.time)
        }
        if !entry.actor.isEmpty { parts.append("by \(entry.actor)") }
        return parts.joined(separator: " · ")
    }
}

/// Every field of the record, as the log holds it (already masked), selectable for copying.
private struct AuditDetails: View {
    let entry: AuditEntry
    let markChecked: (Executor.Unfinished) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(entry.details) { detail in
                    GridRow {
                        Text(detail.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(detail.value)
                            .font(["Command", "Error"].contains(detail.label) ? .callout.monospaced() : .callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if case .unknown(let write) = entry.outcome {
                Text("GAM GUI stopped while this change was running. Check it in Google before running it again.")
                    .foregroundStyle(.secondary)
                Button("Mark as Checked") { markChecked(write) }
                    .accessibilityHint("Records that you checked this change in Google, so it stops showing as unknown here and on Home.")
            }
        }
        .padding(.vertical, 4)
    }
}

extension AuditEntry.Outcome {
    /// Never the only sign: the words are always beside it.
    var symbol: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .started: "arrow.right.circle"
        case .unknown: "questionmark.circle.fill"
        case .checked: "checkmark.seal"
        case .notRecorded: "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .succeeded: .green
        case .failed: .red
        case .unknown: .orange
        case .started, .checked, .notRecorded: .secondary
        }
    }
}
