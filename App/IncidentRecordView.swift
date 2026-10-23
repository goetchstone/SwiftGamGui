import AppKit
import Directory
import GamEngine
import Setup
import Stores
import SwiftUI

/// The incident kept on this Mac (docs/plans/2026-10-22-incidents.md, slice 3): open one, or make one by hand or from an
/// export of the logs (Export All's folder), so an incident survives the app restarting or being rebuilt and can be picked
/// up after the fact. In two parts: its header above Incident's tabs (which one is open, its details, its saved logs read
/// and shown; each pull made while it's open saved to it), and on Report its evidence and notes. Reads and saves on this
/// Mac only: nothing here changes the tenant.
struct IncidentRecordSection: View {
    /// The header above the tabs (one, always shown: it reads and saves the evidence), or Report's evidence and notes.
    enum Part { case header, report }

    let part: Part
    let setup: SetupModel
    let incidents: Incidents
    let logs: IncidentLogs
    @State private var editing: Editing?
    @State private var note = ""
    /// When the note being typed happened: nil is now, when it's added.
    @State private var noteAt: Date?
    @Environment(\.appearsActive) private var appearsActive

    /// What the details sheet is for.
    struct Editing: Identifiable {
        enum Purpose {
            case new
            case fromExport(IncidentStore.Export)
            case edit(IncidentStore.Record)
        }
        let purpose: Purpose
        let id = UUID()
    }

    private var domain: String { setup.active?.name.lowercased() ?? "" }
    private var open: IncidentStore.Record? { incidents.record(incidents.openID).flatMap { $0.domain == domain ? $0 : nil } }

    var body: some View {
        switch part {
        case .header: header
        case .report: report
        }
    }

    private var header: some View {
        Section {
            if let record = open {
                opened(record)
            } else {
                closed
            }
            if let problem = incidents.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).textSelection(.enabled)
            }
        } header: {
            Text("Incident").accessibilityAddTraits(.isHeader)
        } footer: {
            Text(open == nil
                 ? "Kept on this Mac: its details, notes and every pull of the logs, so it's all here after the app restarts or is rebuilt."
                 : "Pulls of the logs made while it's open are saved to it, on this Mac. Investigate shows everything saved, each event once.")
        }
        .sheet(item: $editing) { editing in
            DetailsSheet(editing: editing) { title, opened, openedBy, reported in save(editing, title, opened, openedBy, reported) }
        }
        .task(id: "\(setup.generation)|\(domain)|\(incidents.openID ?? "")|\(incidents.reload)") { await showEvidence() }
        // A pull made while an incident is open is saved to it, then everything saved is shown.
        .onChange(of: logs.pull?.ended) { _, ended in
            guard ended == true, let pull = logs.pull, !pull.fromEvidence, let record = open,
                  pull.logs.contains(where: { (try? $0.rows.get()) != nil }) else { return }
            Task { if let failed = await incidents.keep(pull, in: record.id) { say(failed) } else { incidents.reload += 1 } }
        }
    }

    @ViewBuilder private func opened(_ record: IncidentStore.Record) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.headline)
                Text(Self.opened(record)).foregroundStyle(.secondary)
                if incidents.loading {
                    HStack { ProgressView().controlSize(.small); Text("Reading the saved logs…").foregroundStyle(.secondary) }
                } else if let evidence = incidents.evidence, evidence.id == record.id {
                    Text(evidence.names.isEmpty ? "No logs saved yet: pull them on Investigate, or add an export on Report."
                         : "Evidence: \(evidence.names.count) \(evidence.names.count == 1 ? "read" : "reads") of the logs saved.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Details…") { editing = Editing(purpose: .edit(record)) }
                .accessibilityLabel("Edit the incident's details")
            Button("Close") {
                incidents.openID = nil
                incidents.evidence = nil
                logs.clear()
            }
            .accessibilityHint("Closes the incident on this screen. It stays kept, to open again.")
        }
    }

    @ViewBuilder private var closed: some View {
        if let failed = incidents.openProblem {
            Label(failed, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        }
        ForEach(incidents.records(for: domain)) { record in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                    Text(Self.opened(record)).font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Button("Open") { incidents.openID = record.id }
                    .accessibilityLabel("Open \(record.title)")
            }
        }
        if let unreadable = incidents.store?.unreadable, !unreadable.isEmpty {
            Label("Some kept incidents couldn't be read and were set aside: " + unreadable.joined(separator: ", ") + ".",
                  systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        }
        HStack {
            Spacer()
            Button("New Incident…") { editing = Editing(purpose: .new) }
            Button("From an Export…") { pickExport { editing = Editing(purpose: .fromExport($0)) } }
                .accessibilityHint("Makes an incident from a folder Export All wrote, its logs as the evidence.")
        }
        .disabled(incidents.store == nil)
    }

    /// Report: the open incident's evidence (each saved read, Add an Export…, Show in Finder) and its notes.
    @ViewBuilder private var report: some View {
        if let record = open {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    if let evidence = incidents.evidence, evidence.id == record.id {
                        Text(evidence.names.isEmpty ? "No logs saved yet."
                             : "\(evidence.names.count) \(evidence.names.count == 1 ? "read" : "reads") of the logs saved.")
                    }
                    Spacer()
                    Button("Add an Export…") { pickExport { add($0, to: record) } }
                        .accessibilityHint("Copies a folder Export All wrote into this incident's evidence.")
                    Button("Show in Finder") { showInFinder(record) }
                        .accessibilityHint("Opens the incident's evidence folder, to hand to anyone who needs it.")
                }
                if let evidence = incidents.evidence, evidence.id == record.id {
                    ForEach(evidence.names, id: \.self) { Text($0).textSelection(.enabled) }
                    if !evidence.unreadable.isEmpty {
                        Label("Couldn't read, so not shown: " + evidence.unreadable.joined(separator: ", ") + ".",
                              systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    }
                }
            } header: {
                Text("Evidence").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Each read of the logs exactly as it was exported, kept on this Mac.")
            }
            Section {
                if record.notes.isEmpty {
                    Text("None yet: what was done outside this app, who was told, and when.").foregroundStyle(.secondary)
                }
                ForEach(Array(record.notes.enumerated()), id: \.offset) { _, note in
                    Text("\(note.at.formatted(date: .abbreviated, time: .shortened)): \(note.text)").textSelection(.enabled)
                }
                HStack {
                    TextField("Add a note", text: $note, prompt: Text("Told the insurer; added an alert rule…"))
                        .onSubmit { addNote(to: record) }
                    DatePicker("When", selection: Binding(get: { noteAt ?? Date() }, set: { noteAt = $0 })).labelsHidden()
                        .accessibilityLabel("When it happened")
                    Button("Add Note") { addNote(to: record) }
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Notes").accessibilityAddTraits(.isHeader)
            }
        } else {
            Section {
                Text("Open or make an incident above to keep its evidence and notes here.").foregroundStyle(.secondary)
            }
        }
    }

    /// "Opened Monday, 19 October 2026 at 9:00 AM by Pat. Reported: a Google alert."
    static func opened(_ record: IncidentStore.Record) -> String {
        "Opened \(record.opened.formatted(date: .complete, time: .shortened))"
            + (record.openedBy.isEmpty ? "" : " by \(record.openedBy)") + "."
            + (record.reported.isEmpty ? "" : " Reported: \(record.reported).")
    }

    // MARK: actions

    /// Reads the open incident's evidence off the main actor and shows it as the last pull.
    private func showEvidence() async {
        guard let record = open, let store = incidents.store else {
            incidents.evidence = nil
            return
        }
        incidents.loading = true
        let id = record.id
        let loaded = await Task.detached { () -> (pull: IncidentLogs.Pull, names: [String], unreadable: [String]) in
            let saved = store.exports(of: id)
            let merged = IncidentLogs.evidence(saved.exports)
            return (merged.pull, saved.exports.map(\.name), saved.unreadable + merged.unreadable)
        }.value
        incidents.loading = false
        guard incidents.openID == id else { return }
        incidents.evidence = (id, loaded.names, loaded.unreadable)
        if loaded.names.isEmpty {
            // A new incident takes the pull just made: pull, then New Incident… keeps what was found.
            if let pull = logs.pull, pull.ended, !pull.fromEvidence, pull.logs.contains(where: { (try? $0.rows.get()) != nil }) {
                if let failed = await incidents.keep(pull, in: id) { say(failed) } else { incidents.reload += 1 }
            }
            return
        }
        // A pull reading now is saved when it ends, and then everything is shown: showing now would drop it.
        guard !logs.isPulling else { return }
        logs.show(loaded.pull)
    }

    private func save(_ editing: Editing, _ title: String, _ opened: Date, _ openedBy: String, _ reported: String) -> String? {
        switch editing.purpose {
        case .edit(var record):
            (record.title, record.opened, record.openedBy, record.reported) = (title, opened, openedBy, reported)
            return incidents.save(record)
        case .new, .fromExport:
            switch incidents.create(domain: domain, title: title, opened: opened, openedBy: openedBy, reported: reported) {
            case .failure(let failure): return failure.message
            case .success(let record):
                if case .fromExport(let export) = editing.purpose, let failed = incidents.keep(export, in: record.id) {
                    say("The incident was made, but its logs weren't saved: \(failed)")
                }
                incidents.openID = record.id
                return nil
            }
        }
    }

    private func add(_ export: IncidentStore.Export, to record: IncidentStore.Record) {
        if let failed = incidents.keep(export, in: record.id) { say(failed) } else {
            incidents.problem = nil
            incidents.reload += 1
        }
    }

    private func addNote(to record: IncidentStore.Record) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let failed = incidents.addNote(text, at: noteAt ?? Date(), to: record.id) { say(failed) } else {
            note = ""
            noteAt = nil
            incidents.problem = nil
        }
    }

    /// Asks for a folder Export All wrote, reads and checks it off the main actor (it may be tens of megabytes), and hands
    /// it on once it's an export of this domain's logs.
    private func pickExport(_ then: @escaping (IncidentStore.Export) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Export"
        panel.message = "Choose a folder Export All wrote (“Incident logs …”). Its files are copied into the incident, on this Mac."
        let domain = domain, incidents = incidents
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            incidents.loading = true
            Task {
                let read = await Task.detached { () -> Result<(IncidentStore.Export, Bool), IncidentStore.Problem> in
                    do throws(IncidentStore.Problem) {
                        let export = try IncidentStore.readExport(at: folder)
                        return .success((export, IncidentLogs.export(export.export, isFrom: domain)))
                    } catch {
                        return .failure(error)
                    }
                }.value
                incidents.loading = false
                switch read {
                case .failure(let failure): say(failure.message)
                case .success((_, false)): say("These logs aren't \(domain)'s accounts', so they weren't used.")
                case .success((let export, true)):
                    incidents.problem = nil
                    then(export)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    private func showInFinder(_ record: IncidentStore.Record) {
        guard let store = incidents.store else { return }
        do { NSWorkspace.shared.activateFileViewerSelecting([try store.evidenceFolder(of: record.id)]) } catch { say(error.message) }
    }

    private func say(_ text: String) {
        incidents.problem = text
        if appearsActive { AccessibilityNotification.Announcement(text).post() }
    }
}

/// An incident's details: its title, when it was opened (the day it was identified, which can be before today), by whom,
/// and how it was reported.
private struct DetailsSheet: View {
    let editing: IncidentRecordSection.Editing
    /// Saves; the problem in words, or nil once saved.
    let save: (_ title: String, _ opened: Date, _ openedBy: String, _ reported: String) -> String?
    @State private var title: String
    @State private var opened: Date
    @State private var openedBy: String
    @State private var reported: String
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    init(editing: IncidentRecordSection.Editing, save: @escaping (String, Date, String, String) -> String?) {
        self.editing = editing
        self.save = save
        if case .edit(let record) = editing.purpose {
            (_title, _opened, _openedBy, _reported) = (State(initialValue: record.title), State(initialValue: record.opened),
                                                       State(initialValue: record.openedBy), State(initialValue: record.reported))
        } else {
            (_title, _opened, _openedBy, _reported) = (State(initialValue: "Account takeover"), State(initialValue: Date()),
                                                       State(initialValue: ""), State(initialValue: ""))
        }
    }

    private var heading: String {
        switch editing.purpose {
        case .new: "New incident"
        case .fromExport(let export): "New incident from “\(export.export.name)”"
        case .edit: "The incident's details"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $title)
                    DatePicker("Opened", selection: $opened)
                    TextField("Opened by", text: $openedBy, prompt: Text("Your name"))
                    TextField("How it was reported", text: $reported, prompt: Text("A Google alert, the person, a check"))
                } header: {
                    Text(heading).accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("Opened is when the incident was identified: it can be before today. Everything is kept on this Mac.")
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let failed = save(title, opened, openedBy, reported) { problem = failed } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 460)
    }
}
