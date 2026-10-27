import AppKit
import Assist
import ChangeCore
import CoreText
import Stores
import SwiftUI

/// What the incident report is made with, from the incident open on Report: its record, its saved reads, the directory's
/// people with 2-Step Verification off, and who's making it; and the two things it may do on this Mac: copy the evidence into
/// an export, and keep the review. Nothing here reaches the tenant.
struct ReportInputs {
    /// What a report was made of: made again only when one of these changed.
    struct Key: Equatable {
        let reading: String
        let record: IncidentStore.Record
        let evidence: [String]
        let directory: String
        let madeBy: String
        let changes: Int
        /// The 2SV list itself: the directory's key stays when only enrolment changes.
        let no2SV: Set<String>?
    }

    let record: IncidentStore.Record
    /// Each saved read's folder name, and what it read in a line.
    let evidence: [(name: String, about: String)]
    /// People here with 2-Step Verification off (Reports' list), lowercased; nil while the directory isn't read.
    let no2SV: Set<String>?
    let directoryKey: String
    let madeBy: String
    /// Copies the incident's evidence into a new folder, each file with its SHA-256. Off the main thread.
    let copyEvidence: @Sendable (URL) throws -> [(file: String, sha256: String)]
    /// Keeps the review with the incident: the problem in words, or nil once saved.
    let saveReview: (IncidentStore.Review) -> String?
}

/// Report's incident report (docs/plans/2026-10-22-incidents.md, slice 4): the numbers, each opening the list behind it; every
/// step taken with the record that shows it; the attacker's emails and whom they reached; the review (lessons learned and the
/// plan going forward, with the review meeting's agenda); and Export Report…, a new private folder with the report as a PDF and
/// as text, its lists as CSVs, and a copy of the evidence with each file's SHA-256. Reads and this Mac only.
struct IncidentReportView: View {
    let report: IncidentReport
    let inputs: ReportInputs
    @State private var shown: IncidentReport.Count?
    @State private var reviewing = false
    @State private var reading = false
    @State private var exporting = false
    @State private var exported: (text: String, failed: Bool, folder: URL?)?
    @Environment(\.appearsActive) private var appearsActive

    /// Times as the screen says them.
    nonisolated static let when: @Sendable (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }
    /// At most this many steps on screen; every one is in Steps Taken's list and the export.
    private static let actionsShown = 200

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(report.record.title).font(.headline)
                Text(IncidentRecordSection.opened(inputs.record)).foregroundStyle(.secondary)
                Text(timesWords).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
            HStack {
                if exporting {
                    ProgressView().controlSize(.small)
                    Text("Exporting the report and copying the evidence…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show the Report…") { reading = true }
                    .accessibilityHint("Shows the whole report as it will be exported.")
                Button("Export Report…", action: export)
                    .disabled(exporting)
                    .accessibilityHint("Saves the report as a PDF and as text, its lists as CSV files, and a copy of the evidence with "
                                       + "each file's fingerprint, in a new private folder.")
            }
            if let exported {
                HStack {
                    Label(exported.text, systemImage: exported.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .symbolRenderingMode(.multicolor)
                        .textSelection(.enabled)
                    Spacer()
                    if let folder = exported.folder {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                }
            }
        } header: {
            Text("Incident report").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Worked out by rules in code from the incident's saved logs and this app's audit log, as Respond shows them; only the "
                 + "notes and the review are typed.")
        }
        Section {
            ForEach(report.counts) { count in
                Button { shown = count } label: {
                    HStack {
                        Text(count.label)
                        Spacer()
                        Text(count.number.formatted()).monospacedDigit().foregroundStyle(count.number == 0 ? .secondary : .primary)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(count.label): \(count.number.formatted())")
                .accessibilityHint("Opens the list behind it, to read or export.")
            }
        } header: {
            Text("In numbers").accessibilityAddTraits(.isHeader)
        } footer: {
            Text(inputs.no2SV == nil ? "Each number opens its list. Load the directory to see who has 2-Step Verification off."
                 : "Each number opens its list. 2-Step Verification is as Reports shows it, from the directory.")
        }
        Section {
            if report.actions.isEmpty {
                Text("No step taken shows in the logs read, this app's audit log, or the notes.").foregroundStyle(.secondary)
            }
            ForEach(Array(report.actions.prefix(Self.actionsShown).enumerated()), id: \.offset) { _, action in
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.what + (action.account.isEmpty ? "" : " [\(action.account)]"))
                    Text("\(Self.when(action.at)) · shown by \(action.source)").font(.callout).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
            }
            if report.actions.count > Self.actionsShown {
                Text("And \((report.actions.count - Self.actionsShown).formatted()) more: every step is in Steps Taken above, and the export.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("What was done").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Oldest first. Google's logs show what was done to each account, whoever did it; this app's audit log shows what it ran. "
                 + "The two side by side are the record.")
        }
        Section {
            if report.emails.isEmpty { Text("No email the attacker sent shows in the logs read.").foregroundStyle(.secondary) }
            ForEach(Array(report.emails.enumerated()), id: \.offset) { _, email in Text(email).textSelection(.enabled) }
        } header: {
            Text("The attacker's emails").accessibilityAddTraits(.isHeader)
        }
        Section {
            review
        } header: {
            Text("Lessons learned and the plan going forward").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("For the review meeting after the incident: the agenda is filled from the numbers above, and what's agreed is kept "
                 + "with the incident and goes in the report.")
        }
        .sheet(item: $shown) { count in CountSheet(count: count, title: report.record.title) }
        .sheet(isPresented: $reviewing) { ReviewSheet(review: inputs.record.review, save: inputs.saveReview) }
        .sheet(isPresented: $reading) {
            // Made now, as an export would be.
            FullReportSheet(text: { var now = report; now.made = Date(); return now.text(Self.when, zone: TimeZone.current.identifier) }())
        }
    }

    /// "First sign of the attacker Oct 19 at 2:10 PM; contained Oct 19 at 3:05 PM (55 minutes)."
    private var timesWords: String {
        guard let first = report.times.firstSign else { return "No sign of the attacker in the logs read." }
        let detected = report.record.opened >= first ? " Detected after \(IncidentReport.span(report.record.opened.timeIntervalSince(first)))." : ""
        let contained = report.times.contained.map { "Every account touched locked by \(Self.when($0)) (\(IncidentReport.span($0.timeIntervalSince(first))) after)." }
            ?? "Not yet contained: the logs don't show every account touched locked."
        return "First sign of the attacker: \(Self.when(first)).\(detected) \(contained)"
    }

    @ViewBuilder private var review: some View {
        let review = inputs.record.review
        if review == IncidentStore.Review() {
            Text("Not written yet. The review meeting's agenda:").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !review.kind.isEmpty || !review.severity.isEmpty {
                    Text([review.kind.isEmpty ? nil : "Type: \(review.kind)", review.severity.isEmpty ? nil : "Severity: \(review.severity)"]
                        .compactMap(\.self).joined(separator: " · "))
                }
                if let meeting = review.meeting {
                    Text("Review meeting: \(Self.when(meeting))" + (review.attendees.isEmpty ? "" : ", with \(review.attendees)"))
                }
                answer("How they got in", review.cause)
                answer("What went well", review.wentWell)
                answer("What to do better", review.improve)
                answer("The plan going forward", review.plan)
            }
            .textSelection(.enabled)
            Text("The review meeting's agenda:").foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 2) {
            ForEach(IncidentReport.agenda(report), id: \.self) { Text($0) }
        }
        .textSelection(.enabled)
        HStack {
            Spacer()
            Button(review == IncidentStore.Review() ? "Write the Review…" : "Edit the Review…") { reviewing = true }
                .accessibilityHint("The incident's type and severity, the review meeting, how they got in, what went well, what to do "
                                   + "better, and the plan going forward.")
        }
    }

    @ViewBuilder private func answer(_ label: String, _ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).fontWeight(.semibold)
                Text(text)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: export

    /// Asks where, then writes the report's folder there off the main thread: a new folder (never an existing one), `0700`, its
    /// files `0600`, as the evidence is kept.
    private func export() {
        let panel = NSSavePanel()
        let day = Date().formatted(.iso8601.year().month().day())
        let title = String(report.record.title.map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : "-" }.prefix(60))
        panel.nameFieldStringValue = "Incident report \(day) \(title)".trimmingCharacters(in: .whitespaces)
        panel.canCreateDirectories = true
        panel.message = "A new folder for the report, its lists and a copy of the evidence. It names people: keep it private."
        panel.prompt = "Export"
        let report = report, copy = inputs.copyEvidence
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            exporting = true
            exported = nil
            Task {
                var stamped = report
                stamped.made = Date()
                let made = stamped, zone = TimeZone.current.identifier
                let result = await Task.detached { () -> Result<Int, any Error> in
                    Result { try Self.write(made, zone: zone, to: folder, copyEvidence: copy) }
                }.value
                exporting = false
                switch result {
                case .success(let files):
                    exported = ("Exported the report, its lists and \(files) evidence file\(files == 1 ? "" : "s") to \(folder.lastPathComponent).", false, folder)
                case .failure(let error):
                    exported = ("Couldn't export the report: \((error as? IncidentStore.Problem)?.message ?? error.localizedDescription)", true, nil)
                }
                if appearsActive, let text = exported?.text { AccessibilityNotification.Announcement(text).post() }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    /// The report's folder at `folder`, made new: `Incident report.pdf` and `.txt`, a CSV for each list, `evidence/` (every saved
    /// read, copied) and `evidence-sha256.txt`. Returns how many evidence files were copied. A failure removes what was made.
    nonisolated static func write(_ report: IncidentReport, zone: String, to folder: URL,
                                  copyEvidence: (URL) throws -> [(file: String, sha256: String)]) throws -> Int {
        guard mkdir(folder.path, 0o700) == 0 else {
            throw errno == EEXIST ? IncidentStore.Problem.invalid("There's a folder by that name already: pick a new name.")
                : IncidentStore.Problem.file("make the report's folder", errno)
        }
        do {
            let hashes = try copyEvidence(folder.appending(path: "evidence", directoryHint: .isDirectory))
            let text = report.text(when, zone: zone, hashes: hashes)
            try AuditExport.writePrivately(text, to: folder.appending(path: "Incident report.txt"))
            try writePrivately(pdf(text, title: "Incident report: \(report.record.title)"), to: folder.appending(path: "Incident report.pdf"))
            let lists = [("who-it-reached.csv", "addresses"), ("accounts.csv", "accounts"), ("steps-taken.csv", "actions"), ("still-to-do.csv", "toDo"),
                         ("emails-pulled.csv", "pulled")]
            for (name, id) in lists {
                guard let table = report.count(id)?.table else { continue }
                try AuditExport.writePrivately(AuditExport.csv(table.csv), to: folder.appending(path: name))
            }
            try AuditExport.writePrivately(AuditExport.csv(report.timeline.csv), to: folder.appending(path: "timeline.csv"))
            try AuditExport.writePrivately(hashes.map { "\($0.sha256)  \($0.file)\n" }.joined(), to: folder.appending(path: "evidence-sha256.txt"))
            return hashes.count
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// `data` to a new private file (`0600`, never through a link, never over one).
    nonisolated static func writePrivately(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let wrote = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += wrote
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// The report's text as a US Letter PDF, typeset with Core Text from plain text (nothing in it is read as markup): the
    /// first line as the title, each heading (a line over a rule of `=`) in bold, the rest as it is, a page number at the foot.
    nonisolated static func pdf(_ text: String, title: String) -> Data {
        let body = CTFontCreateUIFontForLanguage(.system, 9.5, nil)!, bold = CTFontCreateUIFontForLanguage(.emphasizedSystem, 11, nil)!
        let big = CTFontCreateUIFontForLanguage(.emphasizedSystem, 15, nil)!
        let ink = CGColor(gray: 0, alpha: 1)
        let styled = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            // A heading's rule: only right under a line, as long as it (`IncidentReport.text`'s `heading`).
            if index > 0, !line.isEmpty, line.allSatisfy({ $0 == "=" }), line.count == min(lines[index - 1].count, 72) { continue }
            let heading = index + 1 < lines.count && !lines[index + 1].isEmpty && lines[index + 1].allSatisfy { $0 == "=" }
                && lines[index + 1].count == min(line.count, 72)
            let font = index == 0 ? big : heading ? bold : body
            styled.append(NSAttributedString(string: line + "\n", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
            ]))
        }
        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &page, [kCGPDFContextTitle: title, kCGPDFContextCreator: "GAM GUI"] as CFDictionary)
        else { return Data() }
        let setter = CTFramesetterCreateWithAttributedString(styled)
        let area = CGPath(rect: page.insetBy(dx: 54, dy: 60), transform: nil)
        var start = 0, number = 1
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), area, nil)
            CTFrameDraw(frame, context)
            let foot = CTLineCreateWithAttributedString(NSAttributedString(string: "\(title) · page \(number)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.system, 8, nil)!,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.4, alpha: 1),
            ]))
            context.textPosition = CGPoint(x: 54, y: 30)
            CTLineDraw(foot, context)
            context.endPDFPage()
            let drawn = CTFrameGetVisibleStringRange(frame).length
            guard drawn > 0 else { break }
            start += drawn
            number += 1
        } while start < styled.length
        context.closePDF()
        return data as Data
    }
}

/// A number's list: what it is, every row in a table, and Export CSV…
private struct CountSheet: View {
    let count: IncidentReport.Count
    let title: String
    @State private var exported: (text: String, failed: Bool)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appearsActive) private var appearsActive

    private struct Row: Identifiable {
        let id: Int
        let cells: [IncidentReport.Cell]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(count.label): \(count.number.formatted())").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(count.about).foregroundStyle(.secondary)
            if count.table.rows.isEmpty {
                Text("None.").foregroundStyle(.secondary)
                Spacer()
            } else {
                let columns = count.table.columns
                Table(count.table.rows.enumerated().map { Row(id: $0.offset, cells: $0.element) }) {
                    TableColumnForEach(Array(columns.indices), id: \.self) { index in
                        TableColumn(columns[index]) { (row: Row) in
                            Text(row.cells[index].words(IncidentReportView.when)).lineLimit(3).textSelection(.enabled)
                        }
                        .width(min: 60, ideal: index == 0 || columns[index] == "what" ? 220 : 120)
                    }
                }
            }
            if let exported {
                Label(exported.text, systemImage: exported.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            HStack {
                Text("\(count.table.rows.count.formatted()) row\(count.table.rows.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Spacer()
                Button("Export CSV…", action: export).disabled(count.table.rows.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 640, idealWidth: 900, minHeight: 360, idealHeight: 520)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(count.id).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.message = "\(count.label), from the incident \(title). It names people: keep it private."
        let rows = count.table.csv
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                let text: String, failed: Bool
                do {
                    try await Task.detached { try AuditExport.writePrivately(AuditExport.csv(rows), to: destination) }.value
                    (text, failed) = ("Exported to \(destination.lastPathComponent).", false)
                } catch {
                    (text, failed) = ("Couldn't export to \(destination.lastPathComponent): \(error.localizedDescription)", true)
                }
                exported = (text, failed)
                if appearsActive { AccessibilityNotification.Announcement(text).post() }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

/// The whole report as it will be exported, to read before exporting.
private struct FullReportSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(text).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 640, idealWidth: 820, minHeight: 420, idealHeight: 640)
    }
}

/// The review, typed: the incident's type and severity, the review meeting, how they got in, what went well, what to do
/// better, and the plan going forward.
private struct ReviewSheet: View {
    @State var review: IncidentStore.Review
    let save: (IncidentStore.Review) -> String?
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss
    private static let severities = ["", "Low", "Medium", "High", "Critical"]

    init(review: IncidentStore.Review, save: @escaping (IncidentStore.Review) -> String?) {
        _review = State(initialValue: review)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Type", text: $review.kind, prompt: Text("Account takeover and phishing"))
                    Picker("Severity", selection: $review.severity) {
                        ForEach(Self.severities, id: \.self) { Text($0.isEmpty ? "Not set" : $0).tag($0) }
                    }
                } header: {
                    Text("The incident").accessibilityAddTraits(.isHeader)
                }
                Section {
                    Toggle("Set the meeting's time", isOn: Binding(get: { review.meeting != nil },
                                                                   set: { review.meeting = $0 ? (review.meeting ?? Date()) : nil }))
                    if review.meeting != nil {
                        DatePicker("When", selection: Binding(get: { review.meeting ?? Date() }, set: { review.meeting = $0 }))
                    }
                    TextField("Who attended", text: $review.attendees, prompt: Text("Names, and their roles"))
                } header: {
                    Text("The review meeting").accessibilityAddTraits(.isHeader)
                }
                Section {
                    answer("How they got in, and why it worked", $review.cause)
                    answer("What went well", $review.wentWell)
                    answer("What to do better", $review.improve)
                    answer("The plan going forward: one change a line, with who owns it and by when", $review.plan)
                } header: {
                    Text("Lessons learned").accessibilityAddTraits(.isHeader)
                }
            }
            .formStyle(.grouped)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).padding(.horizontal)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    problem = save(review)
                    if problem == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 720)
    }

    private func answer(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 70)
                .accessibilityLabel(label)
        }
    }
}
