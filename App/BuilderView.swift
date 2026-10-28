import AppKit
import ChangeCore
import Directory
import GamEngine
import Setup
import SwiftUI
import UniformTypeIdentifiers

/// Builder (docs/domains/catalog-builder.md): GAM's whole command catalog to browse and search, every command that only reads run
/// from here (GamGUI's generic read builder ported, `CommandCatalog`, invariant 3), and GamGUI's curated commands with typed fields
/// (`CuratedCommand`). A read runs as shown; a curated write is previewed through ChangeCore (`BuilderChanges`), confirmed on its
/// sheet and run once, exactly as held (invariant 2). The exact `gam` command is shown as it's typed. The result of a read is a
/// table, filtered over every row and exported as a CSV, or GAM's words as it printed them.
struct BuilderView: View {
    let setup: SetupModel
    let access: UserAccess
    let directory: DirectoryStore
    let groups: GroupStore
    let changes: BuilderChanges
    @State private var catalog: Result<CommandCatalog, CatalogProblem>?
    @State private var query = ""
    @State private var area = ""
    @State private var runnableOnly = true
    @State private var selected: String?

    struct CatalogProblem: Error, Sendable { let why: String }

    /// A command in the list: one of GamGUI's curated ones or the catalog's, sectioned together as GamGUI lists them.
    struct Row: Identifiable {
        let id: String
        let category: String
        let subcategory: String
        let name: String
        /// The name, or the grammar line for a command the catalog doesn't name.
        let title: String
        let runnable: Bool
        /// What it does here, in words, never by color alone.
        let does: String
    }

    /// The vendored catalog, copied beside GAM into the app (`scripts/embed_gam.sh`).
    nonisolated static func load() -> Result<CommandCatalog, CatalogProblem> {
        guard let url = Bundle.main.url(forResource: "command_catalog", withExtension: "json") else {
            return .failure(CatalogProblem(why: "This build has no command catalog: build the app again, so GAM's catalog is copied in."))
        }
        do { return .success(try CommandCatalog(json: Data(contentsOf: url))) } catch {
            return .failure(CatalogProblem(why: "GAM's command catalog couldn't be read: \(error.localizedDescription)"))
        }
    }

    /// GamGUI's curated commands and the catalog's that match the search and the area (and Runnable Only), by section, runnable
    /// first in each (GamGUI's `_by_section`).
    private var rows: [Row] {
        guard case .success(let catalog)? = catalog else { return [] }
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let curated = CuratedCommand.all.filter {
            (area.isEmpty || $0.area == area)
                && (wanted.isEmpty || $0.name.lowercased().contains(wanted) || $0.syntax.lowercased().contains(wanted))
        }.map {
            Row(id: $0.id, category: $0.category, subcategory: $0.subcategory, name: $0.name, title: $0.name, runnable: true,
                does: CuratedDetail.does($0))
        }
        let listed = catalog.search(query).filter { (!runnableOnly || $0.runnable) && (area.isEmpty || $0.area == area) }.map {
            Row(id: $0.id, category: $0.category, subcategory: $0.subcategory, name: $0.name, title: $0.name.isEmpty ? $0.syntax : $0.name,
                runnable: $0.runnable, does: $0.runnable ? "Reads" : CommandDetail.notRun($0).short)
        }
        return (curated + listed).sorted {
            ($0.category.lowercased(), $0.subcategory.lowercased(), $0.runnable ? 0 : 1, $0.name.lowercased())
                < ($1.category.lowercased(), $1.subcategory.lowercased(), $1.runnable ? 0 : 1, $1.name.lowercased())
        }
    }

    var body: some View {
        // A row, not a split view: a split view's minimum is its whole width, which the smallest window can't hold (the
        // snapshots check every column keeps 100 points to spare).
        HStack(spacing: 0) {
            list
                .frame(width: 260)
            Divider()
            Group {
                if let selected, let curated = CuratedCommand.all.first(where: { $0.id == selected }) {
                    CuratedDetail(command: curated, setup: setup, access: access, directory: directory, groups: groups, changes: changes)
                        .id(curated.id)
                } else if case .success(let catalog)? = catalog, let selected, let command = catalog.commands.first(where: { $0.id == selected }) {
                    CommandDetail(command: command, setup: setup, access: access).id(command.id)
                } else {
                    ContentUnavailableView("Pick a Command", systemImage: "terminal",
                                           description: Text("Search GAM's commands on the left. One that only reads runs from here, "
                                                             + "and GamGUI's curated changes are previewed first; the rest are listed to browse."))
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
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
                    .help("Show only the commands that run from here")
            }
        }
        .task {
            guard catalog == nil else { return }
            catalog = await Task.detached(priority: .userInitiated) { Self.load() }.value
            #if DEBUG
            // Snapshots: a curated command by its id, or the first runnable command whose grammar starts with the words given,
            // `+` between them.
            if let wanted = ProcessInfo.processInfo.environment["SWIFTGAMGUI_SELECT"], case .success(let loaded)? = catalog {
                let words = wanted.replacingOccurrences(of: "+", with: " ")
                selected = CuratedCommand.all.first { $0.id == wanted }?.id
                    ?? loaded.commands.first { $0.runnable && $0.syntax.hasPrefix("gam \(words) ") }?.id
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
            let rows = rows
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(sections(rows), id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in CommandRow(row: row).tag(row.id) }
                        }
                    }
                }
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                Divider()
                Text("\(rows.count.formatted()) of \((catalog.commands.count + CuratedCommand.all.count).formatted()) commands · GAM \(catalog.version)")
                    .font(.callout).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The rows in sections of a category and subcategory, as GamGUI's list heads them.
    private func sections(_ rows: [Row]) -> [(title: String, rows: [Row])] {
        var sections: [(title: String, rows: [Row])] = []
        for row in rows {
            let title = row.subcategory.isEmpty ? row.category : "\(row.category) – \(row.subcategory)"
            if sections.last?.title == title { sections[sections.count - 1].rows.append(row) } else { sections.append((title, [row])) }
        }
        return sections
    }
}

/// A command in the list: its name, and what it does here in words.
private struct CommandRow: View {
    let row: BuilderView.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
            Text(row.does).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A read run from the Builder and what it gave: the table or GAM's words, or why it didn't run. A catalog command's page and a
/// curated read's share it.
@MainActor
@Observable
final class ReadRun {
    var running = false
    var result: CatalogResult?
    var problem: String?
    var filter = ""
    var notice: (text: String, failed: Bool)?

    /// Runs `read` on the domain connected now; a result that comes back after the domain changed is dropped.
    func run(_ read: GamRead, access: UserAccess, setup: SetupModel, announce: Bool) {
        guard !running, let domain = setup.active else { return }
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
                say(found.isTable ? "\(found.rows.count.formatted()) row\(found.rows.count == 1 ? "" : "s")." : "Done.", failed: false,
                    announce: announce)
            case .failure(let failure):
                result = nil
                problem = failure.summary
                if announce { AccessibilityNotification.Announcement(failure.summary).post() }
            }
        }
    }

    /// The rows the filter keeps (every row for none), as a CSV to a file the operator picks: private (0600), whole or not at all.
    func export(_ result: CatalogResult, _ rows: [Int], announce: Bool) {
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
                    self.say("Exported \(rows.count.formatted()) row\(rows.count == 1 ? "" : "s") to \(destination.lastPathComponent).",
                             failed: false, announce: announce)
                } catch {
                    self.say("Couldn't export to \(destination.lastPathComponent): \(error.localizedDescription)", failed: true,
                             announce: announce)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    private func say(_ text: String, failed: Bool, announce: Bool) {
        notice = (text, failed)
        if announce { AccessibilityNotification.Announcement(text).post() }
    }
}

/// A read's state beside its Run button: running, why it didn't, or what it gave.
private struct ReadStatus: View {
    let reading: ReadRun

    var body: some View {
        if reading.running {
            ProgressView().controlSize(.small)
            Text("Running…").foregroundStyle(.secondary)
        }
        if let problem = reading.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).textSelection(.enabled)
        }
        if let notice = reading.notice {
            Label(notice.text, systemImage: notice.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .symbolRenderingMode(.multicolor)
        }
    }
}

/// One catalog command: what it is, its grammar line, and for one that reads, its fields, the exact command, Run, and the result.
private struct CommandDetail: View {
    let command: CommandCatalog.Command
    let setup: SetupModel
    let access: UserAccess
    @State private var values: [String: String] = [:]
    @State private var reading = ReadRun()
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
        case .change: ("Changes the domain", "It changes the domain. The Builder runs only commands that read, and GamGUI's curated "
                       + "changes; the rest have their own screens.")
        case .destructive: ("Deletes or removes", "It deletes or removes. The Builder runs only commands that read, and GamGUI's curated "
                            + "changes; the rest have their own screens.")
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
            .frame(maxHeight: reading.result == nil ? .infinity : 360)
            if let result = reading.result {
                ResultView(result: result, filter: $reading.filter, export: { reading.export(result, $0, announce: appearsActive) })
            }
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
                ReadStatus(reading: reading)
                Spacer()
                Button("Run", action: run)
                    .keyboardShortcut("r")
                    .disabled(reading.running || (try? read.get()) == nil || setup.active == nil)
                    .help(setup.active == nil ? "Connect a domain on Setup first" : "Run this read on the connected domain")
                    .accessibilityHint("Runs the command shown on the connected domain. It only reads.")
            }
        } header: {
            Text("Run").accessibilityAddTraits(.isHeader)
        } footer: {
            if command.slots.isEmpty { Text("This command takes nothing more.") }
        }
    }

    private func run() {
        guard case .success(let read) = read else { return }
        reading.run(read, access: access, setup: setup, announce: appearsActive)
    }
}

/// One of GamGUI's curated commands: what it does, GamGUI's line for it, its typed fields, the exact command as typed, and Run
/// for a read or Preview… for a change. A change is held by ChangeCore and shown on its sheet (`BuilderPreviewSheet`), where
/// the operator confirms it; nothing changes from this page.
private struct CuratedDetail: View {
    let command: CuratedCommand
    let setup: SetupModel
    let access: UserAccess
    let directory: DirectoryStore
    let groups: GroupStore
    let changes: BuilderChanges
    @State private var values: [String: String] = [:]
    @State private var reading = ReadRun()
    @State private var debugApplied = false
    @Environment(\.appearsActive) private var appearsActive

    /// What it does here, for the list.
    static func does(_ command: CuratedCommand) -> String {
        switch command.risk {
        case .read: "Reads"
        case .change: "Changes, previewed first"
        case .destructive: "Destructive, previewed first"
        }
    }

    private var built: Result<CuratedCommand.Built, GamCommands.Invalid> {
        Result { () throws(GamCommands.Invalid) in try command.built(values) }
    }

    /// The change's result, while it's this command's.
    private var outcome: (text: String, failed: Bool)? {
        guard changes.concerns(command) else { return nil }
        return switch changes.state {
        case .done(let text): (text, false)
        case .problem(let text): (text, true)
        case .idle, .previewing, .running: nil
        }
    }

    private var sheet: Binding<BuilderChanges.Pending?> {
        Binding(get: { changes.sheetPending(for: command) }, set: { if $0 == nil { changes.dismissPreview() } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Text(command.description)
                    LabeledContent("Area", value: command.subcategory.isEmpty ? "\(command.area) · \(command.category)"
                                   : "\(command.area) · \(command.category) – \(command.subcategory)")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GamGUI's line").font(.callout).foregroundStyle(.secondary)
                        Text(command.syntax).font(.body.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    switch command.risk {
                    case .read:
                        Label("Reads only: nothing changes.", systemImage: "eye").foregroundStyle(.secondary)
                    case .change:
                        Label("Changes the domain: you see exactly what will run, and nothing runs until you confirm it.",
                              systemImage: "pencil.circle").foregroundStyle(.secondary)
                    case .destructive:
                        Label("Destructive: you see exactly what will run, and nothing runs until you confirm it.",
                              systemImage: "exclamationmark.octagon")
                    }
                } header: {
                    Text(command.name).accessibilityAddTraits(.isHeader)
                }
                fieldsSection
            }
            .formStyle(.grouped)
            .frame(maxHeight: reading.result == nil ? .infinity : 360)
            if let result = reading.result {
                ResultView(result: result, filter: $reading.filter, export: { reading.export(result, $0, announce: appearsActive) })
            }
        }
        .onAppear {
            for field in command.fields where field.kind == .choice && values[field.key] == nil { values[field.key] = field.defaultValue }
        }
        .task(id: directory.users?.count ?? -1) { fillForSnapshot() }
        // A result is the values it ran with: edited, it's no longer said beside them.
        .onChange(of: values) { _, _ in
            guard changes.concerns(command), outcome != nil else { return }
            changes.dismiss()
        }
        .onChange(of: outcome?.text) { _, text in
            if let text, appearsActive { AccessibilityNotification.Announcement(text).post() }
        }
        .sheet(item: sheet) { pending in
            BuilderPreviewSheet(pending: pending, changes: changes)
        }
    }

    @ViewBuilder private var fieldsSection: some View {
        let built = built
        let ready = (try? built.get()) != nil
        Section {
            ForEach(command.fields) { field in
                FieldRow(field: field, value: Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 }),
                         directory: directory, groups: groups)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("The command").font(.callout).foregroundStyle(.secondary)
                switch built {
                case .success(.read(let read)):
                    Text(GamCommandLine.text(read.argv)).font(.body.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .success(.write(let write)):
                    Text(GamCommandLine.text(write.argv)).font(.body.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .failure(.argument(let why)):
                    Text(why + ".").foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            HStack {
                if command.reads {
                    ReadStatus(reading: reading)
                } else if let outcome {
                    Label(outcome.text, systemImage: outcome.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .symbolRenderingMode(.multicolor).textSelection(.enabled)
                }
                Spacer()
                if command.reads {
                    Button("Run", action: run)
                        .keyboardShortcut("r")
                        .disabled(reading.running || !ready || setup.active == nil)
                        .help(setup.active == nil ? "Connect a domain on Setup first" : "Run this read on the connected domain")
                        .accessibilityHint("Runs the command shown on the connected domain. It only reads.")
                } else {
                    Button("Preview…", action: preview)
                        .keyboardShortcut("r")
                        .disabled(changes.isBusy || !ready || setup.active == nil)
                        .help(setup.active == nil ? "Connect a domain on Setup first" : "Show exactly what will change, to confirm or cancel")
                        .accessibilityHint("Shows the change and the exact command. Nothing changes until you confirm it.")
                }
            }
        } header: {
            Text(command.reads ? "Run" : "Change").accessibilityAddTraits(.isHeader)
        }
    }

    private func run() {
        guard case .success(.read(let read)) = built else { return }
        reading.run(read, access: access, setup: setup, announce: appearsActive)
    }

    private func preview() {
        Task { await changes.preview(command, values: values) }
    }

    /// Debug builds: `SWIFTGAMGUI_TAB` fills the fields for the snapshots, once the directory is loaded, with the mock's people
    /// (carol@example.com, the Sales group): `fill` shows the form, `preview` the confirm sheet over it. Nothing runs.
    private func fillForSnapshot() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["SWIFTGAMGUI_DEMO"] == "1", directory.users != nil, !debugApplied, let tab = environment["SWIFTGAMGUI_TAB"],
              ["fill", "preview"].contains(tab) else { return }
        debugApplied = true
        for field in command.fields {
            switch field.kind {
            case .targetUser, .user: values[field.key] = "carol@example.com"
            case .group: values[field.key] = "sales@example.com"
            case .email: values[field.key] = "c.clark@example.com"
            case .text: values[field.key] = field.required ? "Example" : ""
            case .choice: values[field.key] = field.defaultValue
            }
        }
        if tab == "preview" { preview() }
        #endif
    }
}

/// One field of a curated command: a person (with the directory's people as completions), a group (with the tenant's groups),
/// an address, text (with GamGUI's words to insert), or a choice.
private struct FieldRow: View {
    let field: CuratedCommand.Field
    @Binding var value: String
    let directory: DirectoryStore
    let groups: GroupStore

    private var title: String { field.required ? field.label : "\(field.label) (optional)" }

    var body: some View {
        switch field.kind {
        case .targetUser, .user:
            AddressField(title: title, prompt: "name@example.com", text: $value, directory: directory)
        case .group:
            GroupAddressField(title: title, text: $value, groups: groups)
        case .email:
            TextField(title, text: $value, prompt: Text(verbatim: "name@example.com"))
                .autocorrectionDisabled()
        case .text:
            VStack(alignment: .leading, spacing: 6) {
                TextField(title, text: $value, prompt: Text(field.placeholder), axis: .vertical)
                    .lineLimit(1...6)
                    .autocorrectionDisabled()
                if !field.hints.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(field.hints, id: \.self) { hint in
                                Button(hint) { insert(hint) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Insert \(hint)")
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    Text(field.hintNote).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .choice:
            Picker(title, selection: $value) {
                ForEach(field.choices, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    /// GamGUI's chip: the words added at the end, a space between.
    private func insert(_ hint: String) {
        value = value.isEmpty || value.hasSuffix(" ") ? value + hint : value + " " + hint
    }
}

/// A group's address, with the tenant's groups that match it offered as completions (GamGUI's group finder), read when first
/// needed.
private struct GroupAddressField: View {
    let title: String
    @Binding var text: String
    let groups: GroupStore

    /// As many as a person's field offers (GamGUI's type-ahead's 15); typing more narrows them.
    private static let offered = 15

    private var matches: [GamGroup] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Array((groups.rows(query: text) ?? []).prefix(Self.offered))
    }

    var body: some View {
        TextField(title, text: $text, prompt: Text(verbatim: "group@example.com"))
            .autocorrectionDisabled()
            .textInputSuggestions(matches, id: \.id) { group in
                Text(group.name.isEmpty || group.name == group.email ? group.email : "\(group.name) — \(group.email)")
                    .textInputCompletion(group.email)
            }
            .task {
                if groups.groups == nil { await groups.load() }
            }
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
