import Foundation
import Observation
import Stores
import SwiftUI

/// The saved column maps for Plan an Import's map step (`RosterMapStore`, `roster-maps.json` beside the offboarding
/// templates): one store for every domain, as the offboarding templates are. A map holds column names and role words only.
@MainActor
@Observable
final class RosterMaps {
    private(set) var store: RosterMapStore?
    /// Why the store didn't open (its file couldn't be read, or moved aside): nothing can be saved, so nothing is saved
    /// over it.
    let openProblem: String?

    init(root: URL) {
        do {
            store = try RosterMapStore(root: root)
            openProblem = nil
        } catch {
            openProblem = error.message
        }
    }

    var names: [String] { store?.names ?? [] }
    /// Where opening moved an unreadable file, for the map step to say.
    var quarantined: URL? { store?.quarantined }
    func map(_ name: String) -> RosterColumnMap? { store?.map(name) }

    /// The name it was saved under (stripped), or why it wasn't, in words.
    func save(_ name: String, _ map: RosterColumnMap) -> Result<String, Refused> {
        guard store != nil else { return .failure(Refused(openProblem ?? "The saved maps couldn't be opened.")) }
        do { return .success(try store?.save(name, map) ?? name) } catch { return .failure(Refused(error.message)) }
    }

    struct Refused: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Nil when deleted (or never saved); else why not, in words.
    func delete(_ name: String) -> String? {
        do { try store?.delete(name) } catch { return error.message }
        return nil
    }
}

/// The map being filled in for the held spreadsheet (GamGUI's `_map_panel`): on first sight a saved map that fits its
/// header, else a guess from its header's names; and the first rows read with it, again on every change, off the main
/// actor. Nothing is kept until Read.
@MainActor
@Observable
final class RosterMapStep {
    let sheet: RosterKeeper.HeldSheet
    private(set) var map: RosterColumnMap
    /// The saved map in use, "" for none: any change to the map leaves it.
    private(set) var using: String
    /// The role words as typed, comma-separated.
    var teacherText: String
    var studentText: String
    /// Why the map can't read the spreadsheet yet, or why its rows couldn't be read; "" when they read.
    private(set) var problem = ""
    private(set) var rows: [RosterMapped.PreviewRow] = []
    private(set) var isPreviewing = false
    private var revision = 0

    init(sheet: RosterKeeper.HeldSheet, maps: RosterMaps) {
        self.sheet = sheet
        let fits = maps.names.first { maps.map($0)?.problem(sheet.header).isEmpty == true }
        let first = fits.flatMap(maps.map) ?? RosterColumnMap.guess(sheet.header)
        (map, using) = (first, fits ?? "")
        teacherText = first.teacherWords.joined(separator: ", ")
        studentText = first.studentWords.joined(separator: ", ")
        refresh()
    }

    /// The header's columns a field can be mapped to: each named one once, in the header's order.
    var columns: [String] {
        var seen: Set<[UInt8]> = []
        return sheet.header.filter { !$0.isEmpty && seen.insert(Array($0.utf8)).inserted }
    }

    func set(_ field: RosterColumnMap.Field, to column: String) {
        guard !map[field].utf8.elementsEqual(column.utf8) else { return }
        map[field] = column
        using = ""
        refresh()
    }

    /// The typed words read as the form reads them (`_map_from`).
    func wordsChanged() {
        let teachers = RosterColumnMap.words(typed: teacherText, default: ["teacher"])
        let students = RosterColumnMap.words(typed: studentText, default: ["student"])
        // By exact text, as the reader matches them: `!=` would take an NFD spelling pasted over an NFC one as no change.
        guard !RosterColumnMap.sameWords(teachers, map.teacherWords) || !RosterColumnMap.sameWords(students, map.studentWords)
        else { return }
        (map.teacherWords, map.studentWords) = (teachers, students)
        using = ""
        refresh()
    }

    /// Load a saved map (only when its own picker changed: picking "—" changes nothing).
    func use(_ name: String, from maps: RosterMaps) {
        guard !name.isEmpty, let saved = maps.map(name) else {
            using = ""
            return
        }
        (map, using) = (saved, name)
        teacherText = map.teacherWords.joined(separator: ", ")
        studentText = map.studentWords.joined(separator: ", ")
        refresh()
    }

    /// After a save under `name`: the map shown is that saved map.
    func saved(as name: String) { using = name }

    func forgetUsing() { using = "" }

    private func refresh() {
        revision += 1
        problem = map.problem(sheet.header)
        guard problem.isEmpty else {
            (rows, isPreviewing) = ([], false)
            return
        }
        let (revision, map, sheet) = (self.revision, self.map, self.sheet)
        isPreviewing = true
        Task { [weak self] in
            let result = await Task.detached { () -> Result<[RosterMapped.PreviewRow], Roster.Refusal> in
                Result { () throws(Roster.Refusal) in try RosterMapped.preview(name: sheet.name, bytes: sheet.bytes, map: map) }
            }.value
            guard let self, self.revision == revision else { return }
            isPreviewing = false
            switch result {
            case .success(let rows): self.rows = rows
            case .failure(let refused): (self.rows, problem) = ([], refused.message)
            }
        }
    }
}

/// Plan an Import's map step (GamGUI's `_roster_map.html`): the held spreadsheet's columns, a picker for each field, the
/// role words, and the first rows read with the map, updated on every change; then Read with This Map, Save Map As,
/// a saved map used or deleted, or Cancel. Nothing is kept until Read.
struct RosterMapView: View {
    let roster: RosterKeeper
    let step: RosterMapStep
    @State private var saveAs = ""
    /// What the last Save, Delete or Read said.
    @State private var said: String?
    @State private var saidIsProblem = false
    @State private var confirmingDelete = false
    @State private var deleting = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Map the Columns of \(step.sheet.name)").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("This isn't an export GAM GUI knows, so say which column holds what. Each row is one person in one class. "
                     + "Nothing is kept until you read it.")
                    .foregroundStyle(.secondary)
            }
            if let said {
                if saidIsProblem {
                    Label(said, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).textSelection(.enabled)
                } else {
                    Label(said, systemImage: "checkmark.circle").textSelection(.enabled)
                }
            }
            if let aside = roster.maps.quarantined {
                Label("The saved maps file couldn't be read, so it was moved aside to \(aside.lastPathComponent) and no saved maps "
                      + "are showing.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            } else if let problem = roster.maps.openProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            savedMaps
            fields
            preview
            actions
            Text("A saved map holds column names and role words only, never a row.").font(.callout).foregroundStyle(.secondary)
        }
        .confirmationDialog("Delete the saved map “\(deleting)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                let name = deleting
                if let problem = roster.maps.delete(name) {
                    show(problem, problem: true)
                } else {
                    step.forgetUsing()
                    show("Deleted the saved map “\(name)”.", problem: false)
                }
            }
        } message: {
            Text("The spreadsheet isn't affected.")
        }
    }

    private func show(_ text: String, problem: Bool) {
        (said, saidIsProblem) = (text, problem)
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: the map

    @ViewBuilder private var savedMaps: some View {
        if !roster.maps.names.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                // Each name tagged by its place, not its text: two saved names can be canonically equivalent spellings,
                // which String (and so a tag) takes as one while the store keeps both.
                let names = roster.maps.names
                Picker("Use a saved map", selection: Binding(
                    get: { step.using.isEmpty ? -1 : RosterColumnMap.exactIndex(of: step.using, in: names) ?? -1 },
                    set: { step.use(names.indices.contains($0) ? names[$0] : "", from: roster.maps) })) {
                    Text("None").tag(-1)
                    ForEach(names.indices, id: \.self) { Text(names[$0]).tag($0) }
                }
                .frame(maxWidth: 360, alignment: .leading)
                .accessibilityHint("Fills every field with a map you saved before")
                if !step.using.isEmpty {
                    Button("Delete “\(step.using)”…") {
                        deleting = step.using
                        confirmingDelete = true
                    }
                    .accessibilityHint("Deletes the saved map; the spreadsheet isn't affected")
                }
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which column holds what").font(.headline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14, alignment: .topLeading)], alignment: .leading,
                      spacing: 12) {
                ForEach(RosterColumnMap.Field.allCases, id: \.self) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.isRequired ? "\(field.label) (needed)" : field.label)
                            .font(.callout).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        // Tagged by place, as the saved maps are: the columns are kept apart by their bytes. A mapped column
                        // the header lacks matches no tag (-2), as before.
                        let columns = step.columns
                        Picker(field.label, selection: Binding(
                            get: { step.map[field].isEmpty ? -1 : RosterColumnMap.exactIndex(of: step.map[field], in: columns) ?? -2 },
                            set: { if $0 >= -1 { step.set(field, to: columns.indices.contains($0) ? columns[$0] : "") } })) {
                            Text(field.isRequired ? "Choose…" : "Not used").tag(-1)
                            ForEach(columns.indices, id: \.self) { Text(columns[$0]).tag($0) }
                        }
                        .labelsHidden()
                        .accessibilityLabel(field.isRequired ? "\(field.label), needed" : "\(field.label), optional")
                    }
                }
                words("Role words for a teacher", text: Bindable(step).teacherText)
                words("Role words for a student", text: Bindable(step).studentText)
            }
        }
    }

    private func words(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(label, text: text, prompt: Text("Comma-separated"))
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityHint("Words in the role column, separated by commas")
                .onChange(of: text.wrappedValue) { step.wordsChanged() }
        }
    }

    // MARK: the first rows, read with it

    @ViewBuilder private var preview: some View {
        if !step.problem.isEmpty {
            Label(step.problem, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .textSelection(.enabled)
        } else if step.isPreviewing && step.rows.isEmpty {
            ProgressView().controlSize(.small).accessibilityLabel("Reading the first rows")
        } else if step.rows.isEmpty {
            Text("The spreadsheet has no rows after its header.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("The first \(step.rows.count == 1 ? "row" : "\(step.rows.count) rows"), read with this map")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                // A field per line and a spreadsheet row per column, so the six fields fit the narrowest window.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("")
                        ForEach(step.rows.indices, id: \.self) { Text("Row \($0 + 1)").font(.caption).foregroundStyle(.secondary) }
                    }
                    .accessibilityHidden(true)
                    ForEach(RosterColumnMap.Field.allCases, id: \.self) { field in
                        GridRow {
                            Text(field.label).font(.callout).foregroundStyle(.secondary)
                            ForEach(step.rows.indices, id: \.self) { index in
                                cell(step.rows[index], field)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(rowLabel(field.label, step.rows.map { row in
                            row[field].isEmpty ? "empty" : field == .email && !row.isAddress ? "\(row[field]), not one address" : row[field]
                        }))
                    }
                    GridRow {
                        Text("Read as").font(.callout.bold())
                        ForEach(step.rows.indices, id: \.self) { index in
                            readAs(step.rows[index])
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(rowLabel("Read as", step.rows.map { row in
                        row.leftOut.map { "left out, \($0)" } ?? (row.readAs.isEmpty ? "neither, check the role words" : row.readAs)
                    }))
                }
            }
        }
    }

    private func rowLabel(_ label: String, _ values: [String]) -> String {
        "\(label): " + values.enumerated().map { "row \($0.offset + 1), \($0.element)" }.joined(separator: "; ")
    }

    /// Why a row the read leaves out by its address is left out.
    /// A field's text; an address that isn't one plain address is marked, since the read leaves its row out.
    @ViewBuilder private func cell(_ row: RosterMapped.PreviewRow, _ field: RosterColumnMap.Field) -> some View {
        if field == .email, !row.isAddress, !row[field].isEmpty {
            Label(row[field], systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
        } else {
            Text(row[field]).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
        }
    }

    @ViewBuilder private func readAs(_ row: RosterMapped.PreviewRow) -> some View {
        let role = row.readAs
        if let why = row.leftOut {
            Label("Left out: \(why)", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .frame(maxWidth: 220, alignment: .leading)
        } else if role.isEmpty {
            Label("Neither: check the role words", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .frame(maxWidth: 220, alignment: .leading)
        } else {
            Text(role == "teacher" ? "Teacher" : "Student").bold()
        }
    }

    // MARK: read, save, cancel

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("Save this map as", text: $saveAs, prompt: Text("e.g. District schedule export"))
                    .frame(maxWidth: 280)
                    .onSubmit(save)
                Button("Save Map As", action: save)
                    .disabled(saveAs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Keeps this map's column names and role words under that name, never a row")
            }
            HStack(spacing: 8) {
                Button("Read with This Map") {
                    Task {
                        if let refused = await roster.readHeld(with: step.map, saveAs: saveAs) { show(refused, problem: true) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!step.problem.isEmpty || roster.isReadingHeld)
                .accessibilityHint("Reads the whole spreadsheet with this map and keeps it on this Mac, as an export is kept")
                // No Escape shortcut: in the window, not a sheet, a stray Escape while typing would drop the sheet and its map.
                Button("Cancel", role: .cancel) { roster.cancelHeld() }
                    .disabled(roster.isReadingHeld)
                    .accessibilityHint("Drops the spreadsheet without reading it")
                if roster.isReadingHeld { ProgressView().controlSize(.small).accessibilityLabel("Reading the spreadsheet") }
            }
            if !saveAs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Reading it saves the map under that name too.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        let name = saveAs
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch roster.maps.save(name, step.map) {
        case .failure(let refused):
            show(refused.message, problem: true)
        case .success(let kept):
            step.saved(as: kept)
            saveAs = ""
            show("Saved the map as “\(kept)”.", problem: false)
        }
    }
}
