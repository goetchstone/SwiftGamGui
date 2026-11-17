import AppKit
import ChangeCore
import Directory
import Foundation
import GamEngine
import Setup
import Stores
import SwiftUI
import UniformTypeIdentifiers

/// The kept roster for Classroom's Plan an Import (plan 2026-11-11 C2.2, C2.4; GamGUI's `web/routes/roster.py`): what the
/// operator picked, read off the main actor and kept per domain (`RosterStore`), its metadata and issues (never the
/// people), and Purge. Every change here is to this Mac only, and each is audited as a local event: `roster_import`
/// (what was read and how much, never a row) and `roster_purge`. No GAM runs here at all.
///
/// One picked spreadsheet that isn't a known export (C5.3) isn't read at once: it's held in memory (`held`, GamGUI's
/// `roster_pending`: its name, bytes and header, with the domain and tenant generation it was picked on; never on disk)
/// while the operator maps its columns, then read like any export (`readHeld`). A new pick (read or refused), Purge, a
/// read, Cancel or a tenant switch drops it; one held for another domain is never read, and a read is kept under the
/// domain it was picked on, or not at all.
@MainActor @Observable
final class RosterKeeper {
    let store: RosterStore
    let auditURL: URL
    /// The domain shown, and the tenant generation it's shown for: a switch drops everything held.
    private(set) var domain: String?
    private var generation: Int?
    private(set) var meta: RosterStore.Meta?
    private(set) var issues: RosterStore.Issues?
    private(set) var kinds: [RosterImport.Kind] = []
    /// The kept roster couldn't be read.
    private(set) var storeProblem: String?
    /// A roster is kept for this domain though it couldn't be read: Purge still shows (GamGUI's `present`).
    private(set) var keptUnread = false
    /// Why the last pick wasn't kept, under the picker; the last good roster stays.
    private(set) var refusal: String?
    /// What the last action did: purged, or kept without its audit record.
    private(set) var notice: String?
    /// The roster shown was read just now (it reads "Read:", not "Kept:").
    private(set) var justRead = false
    private(set) var isReading = false
    private(set) var isPurging = false

    /// A spreadsheet waiting for its column map: in memory only, for the domain and tenant generation it was picked on.
    struct HeldSheet: Identifiable {
        let id = UUID()
        let domain: String
        let generation: Int
        let name: String
        let bytes: [UInt8]
        let header: [String]
    }

    /// The spreadsheet waiting for its map, if any, and the map being filled in for it (made once per sheet, here rather
    /// than in the view, whose initializer SwiftUI may call many times).
    private(set) var held: HeldSheet? {
        didSet { if held?.id != oldValue?.id { mapStep = held.map { RosterMapStep(sheet: $0, maps: maps) } } }
    }
    private(set) var mapStep: RosterMapStep?
    /// The saved column maps (`roster-maps.json`, beside the offboarding templates).
    let maps: RosterMaps
    private(set) var isReadingHeld = false

    /// The held spreadsheet, when it was picked on the domain and tenant generation shown.
    var heldHere: HeldSheet? {
        guard let held, held.domain == domain, held.generation == generation else { return nil }
        return held
    }

    static let moved = "GAM GUI switched to another domain while the file was read, so nothing was kept. Pick it again on its domain."
    /// A save that finished after the switch: kept, and audited, for the domain it was picked on.
    static func keptElsewhere(_ domain: String) -> String {
        "GAM GUI switched to another domain while the file was saved. It was kept for \(domain); it shows there."
    }

    /// Compare with Classroom (C3) and the hand-over (C4): its change list is of the roster kept now, so a new one or a
    /// purge drops it.
    let compare: RosterCompare

    init(store: RosterStore, auditURL: URL, setup: SetupModel, compare: RosterCompare, maps: RosterMaps) {
        self.store = store
        self.auditURL = auditURL
        self.compare = compare
        self.maps = maps
        // A switch made anywhere (Setup, a reconnect) drops the last domain's roster and its students' issue rows at
        // once, not when Plan an Import next appears: nothing of one domain is held, or drawn, under another.
        setup.onTenantChange { [weak self] in self?.forget() }
    }

    private func forget() {
        (domain, generation) = (nil, nil)
        (meta, issues, kinds, storeProblem, refusal, notice, justRead) = (nil, nil, [], nil, nil, nil, false)
        held = nil
    }

    /// Show `domain`'s kept roster. A new tenant generation drops what was held for the last one, refusals and notices
    /// included; the same one just reads the store again.
    func show(_ domain: String?, generation: Int) async {
        if generation != self.generation || domain != self.domain {
            forget()
            (self.domain, self.generation) = (domain, generation)
        }
        guard let domain else { return }
        await reload(domain)
        #if DEBUG
        // Kept, not spent: a tenant generation Setup's demo checks bump after the first look drops what was held.
        if let demo = demoPick, domain == "example.com", held == nil, !isReading { await read(demo) }
        #endif
    }

    private func reload(_ domain: String) async {
        let store = self.store
        let found = await Task.detached { () -> Result<(RosterStore.Meta, RosterStore.Issues?)?, RosterStore.Failure> in
            do {
                guard let meta = try store.meta(domain: domain) else { return .success(nil) }
                return .success((meta, try store.issues(domain: domain)))
            } catch let failure as RosterStore.Failure {
                return .failure(failure)
            } catch {
                return .failure(RosterStore.Failure.unknown)
            }
        }.value
        // Asked only after a failure: a roster that failed to read may still be there, and Purge must reach it.
        let stillThere = if case .failure = found { await Task.detached { store.present(domain: domain) }.value } else { false }
        guard domain == self.domain else { return }
        switch found {
        case .success(let kept):
            (meta, issues, storeProblem, keptUnread) = (kept?.0, kept?.1, nil, false)
            kinds = RosterImport.kinds(kept?.1)
        case .failure(let failure):
            (meta, issues, kinds, storeProblem, keptUnread) = (nil, nil, [], failure.message, stillThere)
        }
    }

    /// Read what was picked and keep it, replacing the last, for the domain it was picked on. A refusal is said under the
    /// picker and nothing is kept.
    func read(_ urls: [URL]) async {
        guard let domain, let generation, !isReading, !isReadingHeld else { return }
        isReading = true
        (refusal, notice, justRead) = (nil, nil, false)
        held = nil              // a new pick, read or refused, replaces a spreadsheet waiting for its map
        defer { isReading = false }
        // Off the main actor: a district's export is many megabytes. Each picked file's access ends once it's read.
        let outcome = await Task.detached { () -> Result<(RosterSnapshot, String, String), Roster.Refusal> in
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            let picked: [Roster.Upload]
            do {
                defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
                picked = try RosterImport.readPicked(urls)
            } catch let refusal as Roster.Refusal {
                return .failure(refusal)
            } catch {
                return .failure(.package("The files couldn't be read. Choose them again."))
            }
            do {
                return .success((try Roster.read(picked), RosterImport.label(picked), RosterImport.digest(picked)))
            } catch let refusal as Roster.Refusal {
                return .failure(refusal)
            } catch {
                return .failure(.package("The export couldn't be read. Choose it again."))
            }
        }.value
        guard domain == self.domain, generation == self.generation else {
            refusal = Self.moved
            announce(Self.moved)
            return
        }
        switch outcome {
        case .failure(.needsMap(let name, let bytes)):
            await hold(name: name, bytes: bytes, domain: domain, generation: generation)
        case .failure(let refused):
            refusal = refused.message
            announce(refused.message)
        case .success(let (snapshot, label, digest)):
            await keep(snapshot, label: label, digest: digest, domain: domain, generation: generation)
        }
    }

    /// Keep a read snapshot (replacing the last) and audit it (what, how many; never the rows), only on the domain and
    /// generation it was picked on: a tenant switch during the read discards it, never keeps one district's roster under
    /// another's name.
    private func keep(_ snapshot: RosterSnapshot, label: String, digest: String, domain: String, generation: Int,
                      extra: JSONObject = [:]) async {
        let store = self.store, auditURL = self.auditURL
        let kept = await Task.detached { () -> Result<String?, RosterStore.Failure> in
            do {
                let meta = try store.save(snapshot, domain: domain, label: label, sha256: digest)
                return .success(Self.audit(auditURL, "roster_import", domain: domain,
                                           extra: Self.importExtra(meta, snapshot).merging(extra)))
            } catch let failure as RosterStore.Failure {
                return .failure(failure)
            } catch {
                return .failure(.unknown)
            }
        }.value
        guard domain == self.domain, generation == self.generation else {
            if case .success = kept { refusal = Self.keptElsewhere(domain) } else { refusal = Self.moved }
            announce(refusal ?? "")
            return
        }
        switch kept {
        case .failure(let failure):
            refusal = failure.message
            announce(failure.message)
        case .success(let auditProblem):
            compare.drop()
            (refusal, notice) = (nil, auditProblem)
            justRead = true
            await reload(domain)
            announce("Read \(label): \(snapshot.counts.classes) classes, \(snapshot.counts.teachers + snapshot.counts.students) people.")
        }
    }

    // MARK: a spreadsheet mapped by its columns (C5.3)

    /// Hold one picked spreadsheet for its map, once its header reads (GamGUI's `header_of`: a first line holding an
    /// address, or a column name too long to be one, is refused here, before any map).
    private func hold(name: String, bytes: [UInt8], domain: String, generation: Int) async {
        let header = await Task.detached { () -> Result<[String], Roster.Refusal> in
            Result { () throws(Roster.Refusal) in try RosterMapped.header(name: name, bytes: bytes) }
        }.value
        guard domain == self.domain, generation == self.generation else {
            refusal = Self.moved
            announce(Self.moved)
            return
        }
        switch header {
        case .failure(let refused):
            refusal = refused.message
            announce(refused.message)
        case .success(let header):
            held = HeldSheet(domain: domain, generation: generation, name: name, bytes: bytes, header: header)
            announce("Map the columns of \(name).")
        }
    }

    /// Read the held spreadsheet with `map` and keep it like any export, audited with which fields were mapped (never the
    /// column names: they're the sheet's text). Saves the map first when it's named. A sentence when it wasn't read; the
    /// spreadsheet stays held then.
    func readHeld(with map: RosterColumnMap, saveAs: String) async -> String? {
        guard !isReadingHeld else { return nil }
        guard let held = heldHere else { return "Pick the spreadsheet again." }
        let problem = map.problem(held.header)
        if !problem.isEmpty { return problem }
        if !saveAs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, case .failure(let refused) = maps.save(saveAs, map) {
            return refused.message
        }
        isReadingHeld = true
        defer { isReadingHeld = false }
        // Off the main actor, the hash too: the sheet may be up to the upload cap.
        let read = await Task.detached { () -> Result<(RosterSnapshot, String), Roster.Refusal> in
            Result { () throws(Roster.Refusal) in
                (try RosterMapped.read(name: held.name, bytes: held.bytes, map: map),
                 RosterImport.digest([Roster.Upload(name: held.name, bytes: held.bytes)]))
            }
        }.value
        guard held.domain == domain, held.generation == generation else {
            // Switched away from while it was read: keep nothing, and say so.
            refusal = Self.moved
            announce(Self.moved)
            return nil
        }
        // Dropped by Purge or replaced while it was read (Cancel and a new pick wait for the read): keep nothing; what
        // dropped it says its own words.
        guard self.held?.id == held.id else { return nil }
        switch read {
        case .failure(let refused):
            return refused.message
        case .success(let (snapshot, digest)):
            self.held = nil
            (refusal, notice, justRead) = (nil, nil, false)
            await keep(snapshot, label: held.name, digest: digest, domain: held.domain, generation: held.generation,
                       extra: ["mapped_fields": .array(map.mappedFields.map(JSONValue.string))])
            return nil
        }
    }

    /// Drop the held spreadsheet without reading it.
    func cancelHeld() {
        guard !isReadingHeld else { return }     // the read under way decides; its button is disabled meanwhile
        held = nil
        announce("The spreadsheet wasn't read.")
    }

    /// Delete the kept roster now. Audited.
    func purge() async {
        guard let domain, !isPurging else { return }
        isPurging = true
        (refusal, notice, justRead) = (nil, nil, false)
        held = nil
        compare.drop()          // before the purge, as GamGUI: a failed purge leaves no change list of a roster asked gone
        defer { isPurging = false }
        let store = self.store, auditURL = self.auditURL
        let gone = await Task.detached { () -> Result<(Bool, String?), RosterStore.Failure> in
            do {
                let deleted = try store.purge(domain: domain)
                return .success((deleted, Self.audit(auditURL, "roster_purge", domain: domain, extra: ["deleted": .bool(deleted)])))
            } catch let failure as RosterStore.Failure {
                return .failure(failure)
            } catch {
                return .failure(.unknown)
            }
        }.value
        guard domain == self.domain else { return }
        switch gone {
        case .failure(let failure):
            refusal = failure.message
            announce(failure.message)
        case .success(let (deleted, auditProblem)):
            notice = (deleted ? "The kept roster was deleted from this Mac." : "There was no roster kept to delete.")
                + (auditProblem.map { " \($0)" } ?? "")
            announce(notice ?? "")
        }
        await reload(domain)
    }

    /// The Issues CSV, private (0600) and formula-safe, through the app's one private CSV writer.
    func exportIssues(to destination: URL) async -> String {
        let rows = RosterImport.issuesCSV(issues)
        do {
            try await Task.detached { try AuditExport.writePrivately(AuditExport.csv(rows), to: destination) }.value
            return "Saved \(rows.count - 1) row\(rows.count == 2 ? "" : "s") to \(destination.lastPathComponent)."
        } catch {
            return "Couldn't save \(destination.lastPathComponent)."
        }
    }

    /// GamGUI's `roster_import` record: what was read, the picked bytes' hash, how many of each, and each kind of issue's
    /// count. Never a row.
    nonisolated static func importExtra(_ meta: RosterStore.Meta, _ snapshot: RosterSnapshot) -> JSONObject {
        var counts = JSONObject(), issues = JSONObject()
        for (key, value) in meta.counts.ordered { counts[key] = .number(String(value)) }
        for item in snapshot.issueCounts { issues[item.code] = .number(String(item.count)) }
        return ["source": .string(meta.source), "label": .string(meta.label), "sha256": .string(meta.sha256),
                "counts": .object(counts), "issues": .object(issues)]
    }

    /// One local event in the app's audit log; a sentence when it couldn't be written (the change itself stands).
    nonisolated static func audit(_ url: URL, _ action: String, domain: String, extra: JSONObject) -> String? {
        do {
            try AuditLog(url: url).record(action, connector: "local", target: domain, ok: true, extra: extra)
            return nil
        } catch {
            return "Its audit record couldn't be written."
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    #if DEBUG
    /// The snapshots' map step: picked files read through `read` whenever example.com shows with nothing held (a
    /// spreadsheet is held, never kept).
    var demoPick: [URL]?

    /// The snapshots' kept roster: the demo package (`Tests/Fixtures/demo/roster`, beside the mock) read and kept for
    /// example.com in the demo's own temporary store. Nothing is audited.
    nonisolated static func seedForDemo(_ store: RosterStore, from folder: URL, label: String) {
        guard let picked = try? RosterImport.readPicked([folder]), let snapshot = try? Roster.read(picked) else { return }
        _ = try? store.save(snapshot, domain: "example.com", label: label, sha256: RosterImport.digest(picked))
    }
    #endif
}

extension RosterStore.Failure {
    static let unknown = RosterStore.Failure("The kept roster couldn't be read.")
}

/// Plan an Import (GamGUI's `classroom_import.html` and `_roster_kept.html`): the picker and what to export beside the
/// kept roster's counts, its problems for the SIS team, and Compare with Classroom with its hand-over (`RosterCompareView`).
struct RosterImportView: View {
    let setup: SetupModel
    let roster: RosterKeeper
    @State private var choosing = false
    @State private var confirmingPurge = false
    @State private var saved: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    picker
                    whatToExport
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 300)
            Divider()
            ScrollView {
                kept
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .task(id: setup.generation) { await roster.show(setup.active?.name, generation: setup.generation) }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.zip, .commaSeparatedText, .folder],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { await roster.read(urls) }
        }
        .confirmationDialog("Delete the kept roster from this Mac now?", isPresented: $confirmingPurge) {
            Button("Purge", role: .destructive) { Task { await roster.purge() } }
        } message: {
            Text("It holds the names and addresses of the teachers and students in the export. Nothing in Classroom changes.")
        }
    }

    // MARK: the picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your SIS's roster export").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Its ZIP, every CSV file in its folder, or one spreadsheet.").foregroundStyle(.secondary)
            HStack {
                Button("Choose the Export…") { choosing = true }
                    .disabled(setup.active == nil || roster.isReading || roster.isReadingHeld)
                    .accessibilityHint("Picks a ZIP, a folder or CSV files, and reads them on this Mac")
                if roster.isReading { ProgressView().controlSize(.small).accessibilityLabel("Reading the export") }
            }
            if let refusal = roster.refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .textSelection(.enabled)
            }
            Text("Read on this Mac and kept here for \(RosterStore.keepDays) days. Nothing is sent to Google.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var whatToExport: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What to export").font(.headline).accessibilityAddTraits(.isHeader)
            // One literal each: a literal is a LocalizedStringKey, whose Markdown (the bold) SwiftUI reads.
            bullet(Text("**OneRoster 1.1 or 1.2**, as **CSV**, a **full (bulk)** export: not an API, not changes only. SIS products usually keep it under their data-sharing, rostering or OneRoster export settings."))
            bullet(Text("Each teacher and student needs their Google Workspace address in the export's email column."))
            bullet(Text("**Clever**: its CSV files (schools, students, teachers, sections and enrollments), or their ZIP. The passwords and contacts beside them are never read."))
            bullet(Text("**Any other SIS**: one spreadsheet (a CSV) with a row per person in a class. You map its columns next; nothing is kept until it's read."))
        }
    }

    private func bullet(_ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").accessibilityHidden(true)
            text
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: the kept roster

    @ViewBuilder private var kept: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let notice = roster.notice {
                Text(notice).foregroundStyle(.secondary)
            }
            if setup.active == nil {
                Text("Connect a domain on Setup to plan an import.").foregroundStyle(.secondary)
            } else if let held = roster.heldHere, let step = roster.mapStep, step.sheet.id == held.id {
                RosterMapView(roster: roster, step: step).id(held.id)
            } else if let problem = roster.storeProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                if roster.keptUnread {
                    Divider()
                    purge
                }
            } else if let meta = roster.meta {
                summary(meta)
                problems
                Divider()
                RosterCompareView(compare: roster.compare, meta: meta)
                Divider()
                purge
            } else {
                Text("No roster is kept on this Mac. Choose your SIS's export to read it.").foregroundStyle(.secondary)
            }
        }
        // "Saved N rows" belongs to the roster it was saved from: a switch, a new upload or a purge clears it.
        .onChange(of: "\(roster.domain ?? "")|\(roster.meta?.importedAt ?? "")") { saved = nil }
    }

    private func summary(_ meta: RosterStore.Meta) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(roster.justRead ? "Read" : "Kept"): \(meta.label)").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("\(meta.source) · read \(Self.when(meta.importedAt)) · deleted from this Mac on \(meta.expiresAt.prefix(10))")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(RosterSnapshot.Counts.names, id: \.key) { name in
                    let value = meta.counts.ordered.first { $0.key == name.key }?.value ?? 0
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.label).font(.caption).foregroundStyle(.secondary)
                        Text(value.formatted()).font(.title3.monospacedDigit())
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(name.label): \(value.formatted())")
                }
            }
            if meta.others > 0 {
                Text("\(meta.others.formatted()) people in other roles (aides, guardians…) are counted but not rostered.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// `2026-11-11T09:30:00Z` as GamGUI shows it: `2026-11-11 09:30:00 UTC`.
    static func when(_ stamp: String) -> String {
        stamp.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Problems to fix in your SIS").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if !roster.kinds.isEmpty {
                    Button("Issues CSV…", action: exportIssues)
                        .accessibilityHint("Saves every problem row kept, with its cause and fix, for your SIS team")
                }
            }
            if let saved { Text(saved).font(.callout).foregroundStyle(.secondary) }
            if roster.kinds.isEmpty {
                Text("None. Every class, person and enrolment read cleanly.").foregroundStyle(.secondary)
            }
            ForEach(roster.kinds) { kind in
                IssueKindRow(kind: kind)
            }
        }
    }

    private var purge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button("Purge It Now…") { confirmingPurge = true }
                .disabled(roster.isPurging)
                .accessibilityHint("Deletes the kept roster from this Mac")
            Text("Otherwise it's deleted after \(RosterStore.keepDays) days.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func exportIssues() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = RosterImport.issuesFileName
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                let said = await roster.exportIssues(to: destination)
                saved = said
                AccessibilityNotification.Announcement(said).post()
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

/// One kind of problem: its count and cause, opening to its fix and the rows kept (the first 20; the Issues CSV has the
/// rest that were kept).
private struct IssueKindRow: View {
    let kind: RosterImport.Kind
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                Text("**Fix:** \(kind.fix)")
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["File", "Line", "ID", "Detail"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                    .accessibilityHidden(true)
                    ForEach(Array(kind.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.file)
                            Text(String(row.row)).monospacedDigit()
                            Text(row.sourceID).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                            Text(row.detail).lineLimit(1).truncationMode(.tail)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(["\(row.file), line \(row.row)", row.sourceID.isEmpty ? "" : "ID \(row.sourceID)", row.detail]
                            .filter { !$0.isEmpty }.joined(separator: ", "))
                    }
                }
                if kind.count > kind.rows.count {
                    Text("Showing \(kind.rows.count) of \(kind.count.formatted()); the Issues CSV has more.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("**\(kind.count.formatted())** — \(kind.cause)")
                .accessibilityLabel("\(kind.count.formatted()): \(kind.cause)")
        }
    }
}
