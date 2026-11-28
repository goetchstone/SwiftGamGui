import AppKit
import Directory
import GamEngine
import Stores
import SwiftUI
import UniformTypeIdentifiers

/// Change many people from a CSV (roadmap 4.6), as a sheet from Users: save the template, choose a filled-in CSV, review each
/// person's change and every row left out, save the before file (the undo), then run it once, with Stop. The file is read
/// into memory and never kept.
struct BulkCSVSheet: View {
    let model: BulkCSVChanges
    let close: () -> Void
    @Environment(SavedFiles.self) private var savedFiles: SavedFiles?
    @State private var choosing = false
    @State private var stopAsked = false
    @AccessibilityFocusState private var resultFocused: Bool

    var body: some View {
        Form {
            switch model.state {
            case .previewing(let pending):
                BulkCSVReview(pending: pending, model: model) { save(pending.before, as: "before.csv", what: "Before file (CSV change)") }
            case .running(let pending):
                running(pending)
            case .done(let done):
                result(done)
            case .checking:
                Section { ProgressView("Reading the directory and the org units\u{2026}") }
            case .idle, .problem:
                start
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(isDone ? "Done" : "Cancel") {
                    model.dismiss()
                    close()
                }
                .disabled(model.isBusy)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            read(url)
        }
        .confirmationDialog("Stop after this change?", isPresented: $stopAsked) {
            Button("Stop After This Change") { Task { await model.stop() } }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("The change running now finishes. The rest aren't made, and what's done stays done.")
        }
    }

    private var isDone: Bool {
        if case .done = model.state { true } else { false }
    }

    @ViewBuilder
    private var start: some View {
        Section {
            Text("An email column plus any of title, department, phone and org_unit. A blank cell leaves that value alone: nothing "
                 + "here clears one. Reports' fill-in sheets come back as they went out.")
            HStack {
                Button("Save the Template\u{2026}") { save(BulkCSVChanges.template, as: "people.csv", what: "People CSV template") }
                    .accessibilityHint("Saves a CSV with the columns this reads, to fill in.")
                Button("Choose a CSV\u{2026}") { choosing = true }
                    .accessibilityHint("Reads the file and shows every change before anything changes.")
            }
        } header: {
            Text("Change many people from a CSV").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Columns: \(BulkCSV.header.joined(separator: ", ")). Up to \(BulkCSV.maxRows.formatted()) rows and 1 MB, UTF-8 "
                 + "(Excel's CSV UTF-8). The file is read once and not kept.")
        }
        if case .problem(let why) = model.state {
            Section {
                Label(why, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    .accessibilityFocused($resultFocused)
            }
            .onAppear { resultFocused = true }
        }
        if let nothing = model.nothing {
            Section("Nothing to change") {
                Text(nothing.unchanged > 0 ? "\(nothing.unchanged) already \(nothing.unchanged == 1 ? "has" : "have") what the file says."
                     : "The file holds no change to make.")
                    .accessibilityFocused($resultFocused)
                ForEach(nothing.notes, id: \.self) { Label($0, systemImage: "info.circle") }
                ForEach(nothing.refused.prefix(BulkCSVReview.shown), id: \.self) { Text($0).font(.callout) }
            }
            .onAppear { resultFocused = true }
        }
    }

    @ViewBuilder
    private func running(_ pending: BulkCSVChanges.Pending) -> some View {
        let progress = model.progress ?? BulkCSVChanges.Progress(total: pending.writes)
        Section {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                Text(progress.stopping ? "Stopping after this change\u{2026}" : "Changing \(pending.changes.count) people\u{2026}")
            }
            .accessibilityValue("\(progress.done) of \(progress.total) changes")
            Text("\(progress.done) of \(progress.total) changes done" + (progress.failed > 0 ? ", \(progress.failed) failed" : ""))
                .font(.callout).foregroundStyle(.secondary)
            Button("Stop\u{2026}") { stopAsked = true }
                .disabled(progress.stopping)
        }
    }

    @ViewBuilder
    private func result(_ done: BulkCSVChanges.Done) -> some View {
        Section {
            Label(done.message, systemImage: done.partial ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityFocused($resultFocused)
            if done.failedCount > 0 {
                ForEach(done.failures, id: \.self) { Text($0).font(.callout) }
                if done.failedCount > done.failures.count {
                    Text("\u{2026} and \(done.failedCount - done.failures.count) more, in the jobs tray and Audit.").foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { resultFocused = true }
    }

    private func read(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let bytes = [UInt8]((try? handle.read(upToCount: BulkCSV.maxBytes + 1)) ?? Data())
        Task { await model.preview(bytes) }
    }

    private func save(_ bytes: [UInt8], as name: String, what: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard (try? Data(bytes).write(to: url, options: .atomic)) != nil else { return }
        savedFiles?.record(url, what: what)
    }
}
