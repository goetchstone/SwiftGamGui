import AppKit
import ChangeCore
import Directory
import GamEngine
import Setup
import SwiftUI
import UniformTypeIdentifiers

/// Builder, slice 1 (docs/domains/catalog-builder.md): GAM's whole command catalog to browse and search, and every command that
/// only reads run from here, GamGUI's generic read builder ported (`CommandCatalog`, invariant 3). A command's required
/// arguments are fields; the exact `gam` command is shown as it's typed and runs as shown. The result is a table, filtered over
/// every row and exported as a CSV, or GAM's words as it printed them. Reads only: nothing here can change the domain.
struct BuilderView: View {
    let setup: SetupModel
    let access: UserAccess
    @State private var catalog: Result<CommandCatalog, CatalogProblem>?
    @State private var query = ""
    @State private var area = ""
    @State private var runnableOnly = true
    @State private var selected: CommandCatalog.Command.ID?

    struct CatalogProblem: Error, Sendable { let why: String }

    /// The vendored catalog, copied beside GAM into the app (`scripts/embed_gam.sh`).
    nonisolated static func load() -> Result<CommandCatalog, CatalogProblem> {
        guard let url = Bundle.main.url(forResource: "command_catalog", withExtension: "json") else {
            return .failure(CatalogProblem(why: "This build has no command catalog: build the app again, so GAM's catalog is copied in."))
        }
        do { return .success(try CommandCatalog(json: Data(contentsOf: url))) } catch {
            return .failure(CatalogProblem(why: "GAM's command catalog couldn't be read: \(error.localizedDescription)"))
        }
    }

    private var shown: [CommandCatalog.Command] {
        guard case .success(let catalog)? = catalog else { return [] }
        return catalog.search(query).filter { (!runnableOnly || $0.runnable) && (area.isEmpty || $0.area == area) }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            Group {
                if case .success(let catalog)? = catalog, let selected, let command = catalog.commands.first(where: { $0.id == selected }) {
                    CommandDetail(command: command, setup: setup, access: access).id(command.id)
                } else {
                    ContentUnavailableView("Pick a Command", systemImage: "terminal",
                                           description: Text("Search GAM's commands on the left. One that only reads runs from here; "
                                                             + "the rest are listed to browse."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $query, prompt: "Command or its grammar")
        .toolbar {
            ToolbarItemGroup {
                Picker("Area", selection: $area) {
                    Text("Every Area").tag("")
                    ForEach(CommandCatalog.areas, id: \.self) { Text($0).tag($0) }
                }
                .help("Show one area's commands")
                Toggle("Runnable Only", systemImage: "play.circle", isOn: $runnableOnly)
                    .help("Show only the commands that read, which run from here")
            }
        }
        .task {
            guard catalog == nil else { return }
            catalog = await Task.detached(priority: .userInitiated) { Self.load() }.value
            #if DEBUG
            // Snapshots: the first runnable command whose grammar starts with the words given, `+` between them.
            if let wanted = ProcessInfo.processInfo.environment["SWIFTGAMGUI_SELECT"], case .success(let loaded)? = catalog {
                let words = wanted.replacingOccurrences(of: "+", with: " ")
                selected = loaded.commands.first { $0.runnable && $0.syntax.hasPrefix("gam \(words) ") }?.id
            }
            #endif
        }
    }

    @ViewBuilder private var list: some View {
        switch catalog {
        case nil:
            ProgressView("Reading GAM's commands…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let problem)?:
            ContentUnavailableView("No Command Catalog", systemImage: "exclamationmark.triangle", description: Text(problem.why))
        case .success(let catalog)?:
            let commands = shown
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(sections(commands), id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.commands) { command in CommandRow(command: command).tag(command.id) }
                        }
                    }
                }
                .overlay {
                    if commands.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                Divider()
                Text("\(commands.count.formatted()) of \(catalog.commands.count.formatted()) commands · GAM \(catalog.version)")
                    .font(.callout).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The commands in sections of a category and subcategory, as GamGUI's list heads them.
    private func sections(_ commands: [CommandCatalog.Command]) -> [(title: String, commands: [CommandCatalog.Command])] {
        var sections: [(title: String, commands: [CommandCatalog.Command])] = []
        for command in commands {
            let title = command.subcategory.isEmpty ? command.category : "\(command.category) – \(command.subcategory)"
            if sections.last?.title == title { sections[sections.count - 1].commands.append(command) } else { sections.append((title, [command])) }
        }
        return sections
    }
}

/// A command in the list: its name, and in words when it doesn't run from here, never by color alone.
private struct CommandRow: View {
    let command: CommandCatalog.Command

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(command.name.isEmpty ? command.syntax : command.name)
            Text(command.runnable ? "Reads" : CommandDetail.notRun(command).short).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One command: what it is, its grammar line, and for one that reads, its fields, the exact command, Run, and the result.
private struct CommandDetail: View {
    let command: CommandCatalog.Command
    let setup: SetupModel
    let access: UserAccess
    @State private var values: [String: String] = [:]
    @State private var running = false
    @State private var result: CatalogResult?
    @State private var problem: String?
    @State private var filter = ""
    @State private var notice: (text: String, failed: Bool)?
    @Environment(\.appearsActive) private var appearsActive

    /// Why a command doesn't run from here, short for the list and whole for its page.
    static func notRun(_ command: CommandCatalog.Command) -> (short: String, why: String) {
        if command.sensitive {
            return ("Download or secret", "It saves a file or shows a secret (backup codes, enrollment tokens). GamGUI runs these with an "
                    + "audit record, which this app doesn't keep for a read yet, so it isn't run from here.")
        }
        if command.uncertain {
            return ("Not run here", "What it does can't be told from GAM's grammar, so it isn't run from here.")
        }
        return switch command.risk {
        case .read: ("Not run here", "Its arguments can't be told apart in GAM's grammar, so it isn't run from here.")
        case .change: ("Changes the domain", "It changes the domain. The Builder runs only commands that read; changes have their own screens.")
        case .destructive: ("Deletes or removes", "It deletes or removes. The Builder runs only commands that read; changes have their own screens.")
        }
    }

    private var read: Result<GamRead, GamCommands.Invalid> {
        Result { () throws(GamCommands.Invalid) in try GamCommands.catalogRead(command, values: values) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Area", value: command.subcategory.isEmpty ? "\(command.area) · \(command.category)"
                                   : "\(command.area) · \(command.category) – \(command.subcategory)")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GAM's grammar").font(.callout).foregroundStyle(.secondary)
                        Text(command.syntax).font(.body.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    if command.runnable {
                        Label("Reads only: nothing changes. Optional parts of the grammar are left out.", systemImage: "eye")
                            .foregroundStyle(.secondary)
                    } else {
                        Label(Self.notRun(command).why, systemImage: "hand.raised").foregroundStyle(.secondary)
                    }
                } header: {
                    Text(command.name.isEmpty ? "Command" : command.name).accessibilityAddTraits(.isHeader)
                }
                if command.runnable { runSection }
            }
            .formStyle(.grouped)
            .frame(maxHeight: result == nil ? .infinity : 360)
            if let result { ResultView(result: result, filter: $filter, export: { export(result, $0) }) }
        }
    }

    @ViewBuilder private var runSection: some View {
        Section {
            ForEach(command.slots) { slot in
                TextField(slot.required ? slot.label : "\(slot.label) (optional)", text: Binding(
                    get: { values[slot.key] ?? "" }, set: { values[slot.key] = $0 }), prompt: Text(slot.placeholder))
                    .onSubmit(run)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("The command").font(.callout).foregroundStyle(.secondary)
                switch read {
                case .success(let read):
                    Text(GamCommandLine.text(read.argv)).font(.body.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .failure(.argument(let why)):
                    Text(why + ".").foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text("Running…").foregroundStyle(.secondary)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).textSelection(.enabled)
                }
                if let notice {
                    Label(notice.text, systemImage: notice.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                Spacer()
                Button("Run", action: run)
                    .keyboardShortcut("r")
                    .disabled(running || (try? read.get()) == nil || setup.active == nil)
                    .help(setup.active == nil ? "Connect a domain on Setup first" : "Run this read on the connected domain")
                    .accessibilityHint("Runs the command shown on the connected domain. It only reads.")
            }
        } header: {
            Text("Run").accessibilityAddTraits(.isHeader)
        } footer: {
            if command.slots.isEmpty { Text("This command takes nothing more.") }
        }
    }

    /// Runs the command shown on the domain connected now; a result that comes back after the domain changed is dropped.
    private func run() {
        guard !running, case .success(let read) = read, let domain = setup.active else { return }
        running = true
        problem = nil
        notice = nil
        Task {
            let outcome = await access.catalogRead(read, in: domain)
            running = false
            guard setup.active == domain else {
                problem = "The domain changed while it ran: run it again."
                return
            }
            switch outcome {
            case .success(let found):
                result = found
                filter = ""
                say(found.isTable ? "\(found.rows.count.formatted()) row\(found.rows.count == 1 ? "" : "s")." : "Done.", failed: false)
            case .failure(let failure):
                result = nil
                problem = failure.summary
                if appearsActive { AccessibilityNotification.Announcement(failure.summary).post() }
            }
        }
    }

    /// The rows the filter keeps (every row for none), as a CSV to a file the operator picks: private (0600), whole or not at all.
    private func export(_ result: CatalogResult, _ rows: [Int]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filter.isEmpty ? "gam-results.csv" : "gam-results-filtered.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.message = GamCommandLine.text(result.argv)
        let table = result.csv(rows)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                do {
                    try await Task.detached { try AuditExport.writePrivately(AuditExport.csv(table), to: destination) }.value
                    say("Exported \(rows.count.formatted()) row\(rows.count == 1 ? "" : "s") to \(destination.lastPathComponent).", failed: false)
                } catch {
                    say("Couldn't export to \(destination.lastPathComponent): \(error.localizedDescription)", failed: true)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    private func say(_ text: String, failed: Bool) {
        notice = (text, failed)
        if appearsActive { AccessibilityNotification.Announcement(text).post() }
    }
}

/// A read's result: a table filtered over every row, with a count and Export CSV…; or GAM's words as it printed them.
private struct ResultView: View {
    let result: CatalogResult
    @Binding var filter: String
    let export: ([Int]) -> Void

    struct Row: Identifiable {
        let id: Int
        let record: GamOutput.Record
    }

    var body: some View {
        if result.isTable {
            let matching = result.matching(filter)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Filter the rows", text: $filter, prompt: Text("Any value in a row"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Text(filter.isEmpty ? "\(result.rows.count.formatted()) rows" : "\(matching.count.formatted()) of \(result.rows.count.formatted()) rows")
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer()
                    Button(filter.isEmpty ? "Export CSV…" : "Export Matches…", systemImage: "square.and.arrow.up") { export(matching) }
                        .disabled(matching.isEmpty)
                        .help(filter.isEmpty ? "Save every row as a CSV file" : "Save the rows that match as a CSV file")
                }
                .padding(.horizontal)
                Table(matching.map { Row(id: $0, record: result.rows[$0]) }) {
                    TableColumnForEach(result.columns, id: \.self) { column in
                        TableColumn(column) { row in
                            let text = CatalogResult.cell(row.record[column])
                            Text(text).lineLimit(1).help(text).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } else {
            ScrollView {
                Text(result.text.isEmpty ? "GAM printed nothing." : result.text)
                    .font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .accessibilityLabel("GAM's output")
        }
    }
}
