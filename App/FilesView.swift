import AppKit
import ChangeCore
import Directory
import GamEngine
import Stores
import SwiftUI

/// Files (plan F4, GamGUI's `/files`): what this app made, read only. It runs no `gam` and changes nothing in the domain.
///
/// - **Google Sheets** a Builder table was exported to, read back from the audit log (`MadeFiles`): newest first, the newest
///   `sheetsShown` from the newest `recordsScanned` records, each with its domain, its read, whose Drive and what became of it;
///   the link only when it's a Google file's. A log that can't be read is said, never shown as none.
/// - **Incident evidence**: each kept incident's `evidence` folder with its count of saved reads (`IncidentStore.savedReads`, by
///   descriptor), at most the store's 200; one whose folder or record couldn't be read is named as such.
/// - **Files you saved** through a save panel (`SavedFiles`, the newest 50): where and when, Show in Finder. A listed difference
///   from GamGUI, whose window never learns where a download went.
///
/// Never a run folder (each `gam` call's, wiped after it) or the setup folder (credentials): nothing here lists a folder but an
/// incident's evidence, through the incident store. Keyboard: Tab reaches the list, the arrows pick a row, Return opens a Sheet
/// or shows a folder or file in Finder, ⌘R reads it all again; each is said on the screen.
struct FilesView: View {
    let auditURL: URL
    let incidents: Incidents
    let saved: SavedFiles
    @State private var sheets: MadeFiles.Sheets?
    @State private var names: [String: String] = [:]
    @State private var evidence: [Evidence]?
    @State private var selection: Item?
    @Environment(\.openURL) private var openURL

    enum Item: Hashable {
        case sheet(Int), evidence(String), saved(String)
    }

    struct Evidence: Identifiable, Sendable {
        let id: String
        /// "" for an incident whose record couldn't be read.
        let title: String
        let domain: String
        let opened: Date?
        let folder: URL
        /// Saved reads in it; nil when the folder couldn't be read.
        let reads: Int?
        let problem: String
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                Text("What this app made. Read-only: this reads the audit log, the incidents kept on this Mac and its list of files you "
                     + "saved. It runs no GAM and changes nothing in your domain.")
                Text("Tab to the list and pick a row: Return opens a Sheet, or shows a folder or a file in Finder. ⌘R reads it all again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            sheetsSection
            evidenceSection
            savedSection
        }
        .contextMenu(forSelectionType: Item.self) { items in
            if let item = items.first, let label = actionName(item) {
                Button(label) { act(item) }
            }
        } primaryAction: { items in
            if let item = items.first { act(item) }
        }
        .toolbar {
            ToolbarItem {
                Button("Read Again", systemImage: "arrow.clockwise") { Task { await load() } }
                    .keyboardShortcut("r")
                    .help("Read the audit log, the incidents and the saved files again (⌘R)")
            }
        }
        .task { await load() }
    }

    // MARK: sections

    @ViewBuilder private var sheetsSection: some View {
        Section {
            Text("Each export to a Google Sheet from the Builder, newest first, read back from its audit record, in the Drive named.")
                .font(.callout).foregroundStyle(.secondary)
            if let sheets {
                if !sheets.problem.isEmpty {
                    Label(sheets.problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                } else if sheets.made.isEmpty {
                    Text(sheets.scannedAll ? "No export to a Google Sheet is in the audit log."
                         : "No export to a Google Sheet is in the audit log's newest \(MadeFiles.recordsScanned.formatted()) records.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sheets.made) { sheet in SheetRow(sheet: sheet, name: names[sheet.command]).tag(Item.sheet(sheet.id)) }
                    if sheets.more {
                        Text("The newest \(MadeFiles.sheetsShown) are listed. Search the audit log for “export” for the rest.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if !sheets.scannedAll {
                        Text("From the audit log's newest \(MadeFiles.recordsScanned.formatted()) records. Search the audit log for older ones.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Reading the audit log…").controlSize(.small)
            }
        } header: {
            Text("Google Sheets").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private var evidenceSection: some View {
        Section {
            Text("The reads of the logs kept with each incident on this Mac, a folder each. They name people and addresses: they stay "
                 + "here, readable only by you.")
                .font(.callout).foregroundStyle(.secondary)
            if let problem = incidents.openProblem {
                Label("\(problem) What evidence is kept can't be told.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            } else if let evidence {
                if evidence.isEmpty {
                    Text("No incident kept here has saved evidence.").foregroundStyle(.secondary)
                } else {
                    ForEach(evidence) { item in EvidenceRow(item: item).tag(Item.evidence(item.id)) }
                }
            } else {
                ProgressView("Reading the incidents…").controlSize(.small)
            }
        } header: {
            Text("Incident evidence").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private var savedSection: some View {
        Section {
            Text("The CSV files you saved from this app, newest first: the newest \(SavedFilesStore.cap) are kept in this list.")
                .font(.callout).foregroundStyle(.secondary)
            if let problem = saved.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            if saved.files.isEmpty {
                Text("None saved yet.").foregroundStyle(.secondary)
            } else {
                ForEach(saved.files) { file in SavedRow(file: file).tag(Item.saved(file.path)) }
            }
        } header: {
            Text("Files you saved").accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: acting on a row

    private func actionName(_ item: Item) -> String? {
        switch item {
        case .sheet(let id): link(id) == nil ? nil : "Open Sheet"
        case .evidence, .saved: "Show in Finder"
        }
    }

    private func link(_ id: Int) -> URL? {
        guard let sheet = sheets?.made.first(where: { $0.id == id }), !sheet.outcome.url.isEmpty else { return nil }
        return URL(string: sheet.outcome.url)
    }

    private func act(_ item: Item) {
        switch item {
        case .sheet(let id):
            if let url = link(id) { openURL(url) }
        case .evidence(let id):
            if let folder = evidence?.first(where: { $0.id == id })?.folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        case .saved(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
        }
    }

    // MARK: reading

    /// Reads the audit log, the incidents' evidence and the commands' names off the main actor.
    private func load() async {
        let auditURL = auditURL, store = incidents.store
        async let readSheets = Task.detached(priority: .userInitiated) { MadeFiles.sheets(in: auditURL) }.value
        async let readEvidence = Task.detached(priority: .userInitiated) { Self.evidence(in: store) }.value
        async let readNames = Task.detached(priority: .utility) { Self.commandNames() }.value
        sheets = await readSheets
        evidence = await readEvidence
        names = await readNames
    }

    /// Each kept incident's evidence folder holding a saved read (or that couldn't be read), newest opened first, then each
    /// incident whose record couldn't be read.
    nonisolated static func evidence(in store: IncidentStore?) -> [Evidence] {
        guard let store else { return [] }
        var found: [Evidence] = []
        for record in store.records {
            let folder = store.root.appending(path: record.id, directoryHint: .isDirectory).appending(path: "evidence", directoryHint: .isDirectory)
            do {
                let reads = try store.savedReads(of: record.id)
                if reads > 0 {
                    found.append(Evidence(id: record.id, title: record.title, domain: record.domain, opened: record.opened, folder: folder,
                                          reads: reads, problem: ""))
                }
            } catch {
                found.append(Evidence(id: record.id, title: record.title, domain: record.domain, opened: record.opened, folder: folder,
                                      reads: nil, problem: error.message))
            }
        }
        for id in store.unreadable {
            let folder = store.root.appending(path: id, directoryHint: .isDirectory).appending(path: "evidence", directoryHint: .isDirectory)
            found.append(Evidence(id: id, title: "", domain: "", opened: nil, folder: folder, reads: nil, problem: ""))
        }
        return found
    }

    /// Each command's name by id: GamGUI's curated ones and the catalog's.
    nonisolated static func commandNames() -> [String: String] {
        var names = Dictionary(CuratedCommand.all.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        if case .success(let catalog) = BuilderView.load() {
            for command in catalog.commands where !command.name.isEmpty { names[command.id] = command.name }
        }
        return names
    }
}

/// One export: when, the domain, the read and whose Drive, then what became of it, in words; a link only when it's a Google
/// file's (Return opens it). VoiceOver reads the row as one.
private struct SheetRow: View {
    let sheet: MadeFiles.SheetMade
    let name: String?

    var body: some View {
        let made = sheet.outcome.made
        VStack(alignment: .leading, spacing: 3) {
            Text(name ?? (sheet.command.isEmpty ? "A read" : sheet.command)) + Text(sheet.sensitive ? "  · Sensitive" : "")
            Text([sheet.when.isEmpty ? "When unknown" : String(sheet.when.prefix(19)).replacingOccurrences(of: "T", with: " "),
                  sheet.domain.isEmpty ? "Domain unknown" : sheet.domain,
                  sheet.owner.isEmpty || sheet.owner == "(admin Drive)" ? "the admin's Drive" : "\(sheet.owner)'s Drive"]
                .joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
            Label(sheet.outcome.url.isEmpty ? sheet.outcome.said : "Made: Return opens it. \(sheet.outcome.url)",
                  systemImage: made == .yes ? "checkmark.circle" : made == .no ? "xmark.octagon" : "questionmark.circle")
                .font(.callout)
            if !sheet.commandLine.isEmpty {
                Text(sheet.commandLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// An incident's evidence folder: its title, domain, when it was opened and how many saved reads, and the folder.
private struct EvidenceRow: View {
    let item: FilesView.Evidence

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title.isEmpty ? "An incident whose record couldn't be read" : item.title)
            Text([item.domain.isEmpty ? "domain unknown" : item.domain,
                  item.opened.map { "opened \($0.formatted(date: .abbreviated, time: .omitted))" },
                  item.reads.map { "\($0) saved read\($0 == 1 ? "" : "s")" } ?? "its evidence couldn't be read"]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
            if !item.problem.isEmpty { Text(item.problem).font(.callout).foregroundStyle(.secondary) }
            Text(item.folder.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A file saved from the app: what it was, when, and where (Return shows it in Finder, if it's still there).
private struct SavedRow: View {
    let file: SavedFilesStore.Saved

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.url.lastPathComponent)
            Text("\(file.what) · saved \(file.at.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout).foregroundStyle(.secondary)
            Text(file.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
